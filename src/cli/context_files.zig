const std = @import("std");

const max_context_file_bytes: usize = 64 * 1024;
const max_git_root_depth: u32 = 16;

pub const ContextFile = struct {
    path: []const u8,
    content: []const u8,
};

pub fn freeContextFiles(
    allocator: std.mem.Allocator,
    files: []const ContextFile,
) void {
    for (files) |cf| {
        allocator.free(cf.path);
        allocator.free(cf.content);
    }
    allocator.free(files);
}

pub fn loadContextFiles(
    allocator: std.mem.Allocator,
    cwd: []const u8,
) ![]const ContextFile {
    const home = std.process.getEnvVarOwned(
        allocator,
        "HOME",
    ) catch return loadContextFilesAt(allocator, cwd, null);
    defer allocator.free(home);

    return loadContextFilesAt(allocator, cwd, home);
}

pub fn loadContextFilesAt(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    home_dir: ?[]const u8,
) ![]const ContextFile {
    std.debug.assert(cwd.len > 0);

    var files: std.ArrayListUnmanaged(ContextFile) = .empty;
    errdefer {
        for (files.items) |cf| {
            allocator.free(cf.path);
            allocator.free(cf.content);
        }
        files.deinit(allocator);
    }

    if (home_dir) |home| {
        const path = try std.fs.path.join(
            allocator,
            &.{ home, ".orbit", "AGENTS.md" },
        );
        defer allocator.free(path);
        try appendContextFile(allocator, &files, path);
    }

    const git_root = try findGitRoot(allocator, cwd);
    defer if (git_root) |path| allocator.free(path);

    if (git_root) |root| {
        const path = try std.fs.path.join(
            allocator,
            &.{ root, "AGENTS.md" },
        );
        defer allocator.free(path);
        try appendContextFile(allocator, &files, path);
    }

    if (git_root == null or
        !std.mem.eql(u8, git_root.?, cwd))
    {
        const path = try std.fs.path.join(
            allocator,
            &.{ cwd, "AGENTS.md" },
        );
        defer allocator.free(path);
        try appendContextFile(allocator, &files, path);
    }

    return files.toOwnedSlice(allocator);
}

pub fn findGitRoot(
    allocator: std.mem.Allocator,
    start_dir: []const u8,
) !?[]const u8 {
    std.debug.assert(start_dir.len > 0);

    var current = try allocator.dupe(u8, start_dir);
    errdefer allocator.free(current);

    var depth: u32 = 0;
    while (depth <= max_git_root_depth) : (depth += 1) {
        const git_path = try std.fs.path.join(
            allocator,
            &.{ current, ".git" },
        );
        defer allocator.free(git_path);

        if (pathExists(git_path)) return current;

        const parent = parentPath(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;

        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }

    allocator.free(current);
    return null;
}

fn appendContextFile(
    allocator: std.mem.Allocator,
    files: *std.ArrayListUnmanaged(ContextFile),
    path: []const u8,
) !void {
    const content = readOptionalContextFile(
        allocator,
        path,
    ) catch return;
    if (content == null) return;
    errdefer allocator.free(content.?);

    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);

    try files.append(allocator, .{
        .path = owned_path,
        .content = content.?,
    });
}

fn readOptionalContextFile(
    allocator: std.mem.Allocator,
    path: []const u8,
) !?[]const u8 {
    const file = std.fs.openFileAbsolute(
        path,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    const stat = try file.stat();
    const limit = if (stat.size > max_context_file_bytes)
        max_context_file_bytes
    else
        @as(usize, @intCast(stat.size));
    return try file.readToEndAlloc(allocator, limit);
}

fn pathExists(path: []const u8) bool {
    const file = std.fs.openFileAbsolute(
        path,
        .{},
    ) catch return dirExists(path);
    file.close();
    return true;
}

fn dirExists(path: []const u8) bool {
    var dir = std.fs.openDirAbsolute(
        path,
        .{},
    ) catch return false;
    dir.close();
    return true;
}

fn parentPath(path: []const u8) ?[]const u8 {
    return std.fs.path.dirname(path);
}

// ---- Tests ----

test "context files returns empty when nothing exists" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    try temp.dir.makePath(
        "d0/d1/d2/d3/d4/d5/d6/d7" ++
            "/d8/d9/d10/d11/d12/d13/d14/d15/d16",
    );
    const cwd = try temp.dir.realpathAlloc(
        allocator,
        "d0/d1/d2/d3/d4/d5/d6/d7" ++
            "/d8/d9/d10/d11/d12/d13/d14/d15/d16",
    );
    defer allocator.free(cwd);

    const files = try loadContextFilesAt(
        allocator,
        cwd,
        null,
    );
    defer freeContextFiles(allocator, files);
    try std.testing.expectEqual(@as(usize, 0), files.len);
}

test "context files loads global and project agents" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    try temp.dir.makePath(".orbit");
    try temp.dir.writeFile(.{
        .sub_path = ".orbit/AGENTS.md",
        .data = "global rules",
    });
    try temp.dir.makePath("repo/.git");
    try temp.dir.writeFile(.{
        .sub_path = "repo/AGENTS.md",
        .data = "project rules",
    });
    try temp.dir.makePath("repo/subdir");

    const home = try temp.dir.realpathAlloc(
        allocator,
        ".",
    );
    defer allocator.free(home);
    const cwd = try temp.dir.realpathAlloc(
        allocator,
        "repo/subdir",
    );
    defer allocator.free(cwd);

    const files = try loadContextFilesAt(
        allocator,
        cwd,
        home,
    );
    defer freeContextFiles(allocator, files);

    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expect(
        std.mem.endsWith(u8, files[0].path, "AGENTS.md"),
    );
    try std.testing.expectEqualStrings(
        "global rules",
        files[0].content,
    );
    try std.testing.expectEqualStrings(
        "project rules",
        files[1].content,
    );
}

test "context files truncates oversized content" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    try temp.dir.makePath("repo");
    const content = try allocator.alloc(
        u8,
        max_context_file_bytes + 128,
    );
    defer allocator.free(content);
    @memset(content, 'a');
    try temp.dir.writeFile(.{
        .sub_path = "repo/AGENTS.md",
        .data = content,
    });

    const cwd = try temp.dir.realpathAlloc(
        allocator,
        "repo",
    );
    defer allocator.free(cwd);

    const files = try loadContextFilesAt(
        allocator,
        cwd,
        null,
    );
    defer freeContextFiles(allocator, files);

    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expect(files[0].content.len > 0);
    try std.testing.expect(
        files[0].content.len <= max_context_file_bytes,
    );
}

test "find git root stops at cwd when repo root equals cwd" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    try temp.dir.makePath("repo/.git");
    const cwd = try temp.dir.realpathAlloc(
        allocator,
        "repo",
    );
    defer allocator.free(cwd);

    const root = (try findGitRoot(allocator, cwd)).?;
    defer allocator.free(root);

    try std.testing.expectEqualStrings(cwd, root);
}

test "find git root returns null without repository" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    try temp.dir.makePath(
        "d0/d1/d2/d3/d4/d5/d6/d7" ++
            "/d8/d9/d10/d11/d12/d13/d14/d15/d16",
    );
    const cwd = try temp.dir.realpathAlloc(
        allocator,
        "d0/d1/d2/d3/d4/d5/d6/d7" ++
            "/d8/d9/d10/d11/d12/d13/d14/d15/d16",
    );
    defer allocator.free(cwd);

    const root = try findGitRoot(allocator, cwd);
    try std.testing.expect(root == null);
}
