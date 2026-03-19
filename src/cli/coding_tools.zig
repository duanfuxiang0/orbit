const std = @import("std");
const ai = @import("../ai/root.zig");
const agent = @import("../agent/types.zig");

const max_file_bytes: usize = 4 * 1024 * 1024;
const max_read_lines_default: u32 = 2000;
const max_bash_output_bytes: usize = 32 * 1024;

pub const ToolCtx = struct {
    allocator: std.mem.Allocator,
    cwd: []const u8,

    fn deinit(self: *ToolCtx) void {
        self.allocator.free(self.cwd);
        self.* = undefined;
    }
};

pub fn register(
    allocator: std.mem.Allocator,
    cwd: []const u8,
) ![]agent.Tool {
    std.debug.assert(cwd.len > 0);

    const ctx = try allocator.create(ToolCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .allocator = allocator,
        .cwd = try allocator.dupe(u8, cwd),
    };

    const tools = try allocator.alloc(agent.Tool, 4);
    errdefer allocator.free(tools);

    tools[0] = .{
        .name = "read",
        .description = "Read a text file with line numbers.",
        .parameters_json = read_schema,
        .execute = executeRead,
        .ctx = ctx,
    };
    tools[1] = .{
        .name = "write",
        .description = "Create or overwrite a file atomically.",
        .parameters_json = write_schema,
        .execute = executeWrite,
        .ctx = ctx,
    };
    tools[2] = .{
        .name = "edit",
        .description = "Replace the first exact text match in a file.",
        .parameters_json = edit_schema,
        .execute = executeEdit,
        .ctx = ctx,
    };
    tools[3] = .{
        .name = "bash",
        .description = "Execute a bash command in the startup working directory.",
        .parameters_json = bash_schema,
        .execute = executeBash,
        .ctx = ctx,
    };
    return tools;
}

pub fn unregister(
    allocator: std.mem.Allocator,
    tools: []agent.Tool,
) void {
    if (tools.len == 0) {
        allocator.free(tools);
        return;
    }

    const ctx: *ToolCtx = @ptrCast(@alignCast(tools[0].ctx));
    ctx.deinit();
    allocator.destroy(ctx);
    allocator.free(tools);
}

const read_schema =
    \\{"type":"object","properties":{"path":{"type":"string","description":"File path to read"},"offset":{"type":"integer","description":"Starting line (0-indexed)"},"limit":{"type":"integer","description":"Max lines to return"}},"required":["path"]}
;
const write_schema =
    \\{"type":"object","properties":{"path":{"type":"string","description":"File path to write"},"content":{"type":"string","description":"File content"}},"required":["path","content"]}
;
const edit_schema =
    \\{"type":"object","properties":{"path":{"type":"string","description":"File path to edit"},"old_text":{"type":"string","description":"Exact text to replace"},"new_text":{"type":"string","description":"Replacement text"}},"required":["path","old_text","new_text"]}
;
const bash_schema =
    \\{"type":"object","properties":{"command":{"type":"string","description":"Bash command to execute"},"timeout":{"type":"integer","description":"Timeout in seconds (default: 30, max: 300)"}},"required":["command"]}
;

const ReadArgs = struct {
    path: []const u8,
    offset: u32 = 0,
    limit: u32 = max_read_lines_default,
};

const WriteArgs = struct {
    path: []const u8,
    content: []const u8,
};

const EditArgs = struct {
    path: []const u8,
    old_text: []const u8,
    new_text: []const u8,
};

const BashArgs = struct {
    command: []const u8,
    timeout: u32 = 30,
};

fn executeRead(
    raw_ctx: *anyopaque,
    tool_call_id: []const u8,
    arguments: []const u8,
    abort: *const ai.provider.AbortState,
) agent.ToolExecResult {
    _ = tool_call_id;
    _ = abort;
    const ctx: *ToolCtx = @ptrCast(@alignCast(raw_ctx));
    return readImpl(ctx, arguments) catch |err| toolError(ctx.allocator, "{s}", .{@errorName(err)});
}

fn readImpl(ctx: *ToolCtx, arguments: []const u8) !agent.ToolExecResult {
    const parsed = try std.json.parseFromSlice(ReadArgs, ctx.allocator, arguments, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const resolved = try resolvePath(ctx.allocator, ctx.cwd, parsed.value.path);
    defer ctx.allocator.free(resolved);

    const content = try readFileBounded(ctx.allocator, resolved);
    defer ctx.allocator.free(content);

    if (isBinary(content)) {
        return toolError(ctx.allocator, "Refusing to read binary file: {s}", .{parsed.value.path});
    }

    const rendered = try renderNumberedLines(
        ctx.allocator,
        content,
        parsed.value.offset,
        clampLineLimit(parsed.value.limit),
    );
    return .{
        .content = rendered,
        .owns_content = true,
    };
}

fn executeWrite(
    raw_ctx: *anyopaque,
    tool_call_id: []const u8,
    arguments: []const u8,
    abort: *const ai.provider.AbortState,
) agent.ToolExecResult {
    _ = tool_call_id;
    _ = abort;
    const ctx: *ToolCtx = @ptrCast(@alignCast(raw_ctx));
    return writeImpl(ctx, arguments) catch |err| toolError(ctx.allocator, "{s}", .{@errorName(err)});
}

fn writeImpl(ctx: *ToolCtx, arguments: []const u8) !agent.ToolExecResult {
    const parsed = try std.json.parseFromSlice(WriteArgs, ctx.allocator, arguments, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const resolved = try resolvePath(ctx.allocator, ctx.cwd, parsed.value.path);
    defer ctx.allocator.free(resolved);

    try writeFileAtomic(resolved, parsed.value.content);

    const line_count = countLines(parsed.value.content);
    const content = try std.fmt.allocPrint(
        ctx.allocator,
        "Wrote {d} bytes to {s}",
        .{ parsed.value.content.len, parsed.value.path },
    );
    const details = try std.fmt.allocPrint(
        ctx.allocator,
        "{{\"path\":\"{s}\",\"bytes\":{d},\"lines\":{d}}}",
        .{ parsed.value.path, parsed.value.content.len, line_count },
    );
    return .{
        .content = content,
        .ui_details = details,
        .owns_content = true,
        .owns_ui_details = true,
    };
}

fn executeEdit(
    raw_ctx: *anyopaque,
    tool_call_id: []const u8,
    arguments: []const u8,
    abort: *const ai.provider.AbortState,
) agent.ToolExecResult {
    _ = tool_call_id;
    _ = abort;
    const ctx: *ToolCtx = @ptrCast(@alignCast(raw_ctx));
    return editImpl(ctx, arguments) catch |err| toolError(ctx.allocator, "{s}", .{@errorName(err)});
}

fn editImpl(ctx: *ToolCtx, arguments: []const u8) !agent.ToolExecResult {
    const parsed = try std.json.parseFromSlice(EditArgs, ctx.allocator, arguments, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const resolved = try resolvePath(ctx.allocator, ctx.cwd, parsed.value.path);
    defer ctx.allocator.free(resolved);

    const original = try readFileBounded(ctx.allocator, resolved);
    defer ctx.allocator.free(original);

    const match_index = std.mem.indexOf(u8, original, parsed.value.old_text) orelse {
        return toolError(ctx.allocator, "old_text not found in {s}", .{parsed.value.path});
    };

    var rewritten: std.ArrayListUnmanaged(u8) = .empty;
    defer rewritten.deinit(ctx.allocator);
    try rewritten.appendSlice(ctx.allocator, original[0..match_index]);
    try rewritten.appendSlice(ctx.allocator, parsed.value.new_text);
    try rewritten.appendSlice(
        ctx.allocator,
        original[match_index + parsed.value.old_text.len ..],
    );

    try writeFileAtomic(resolved, rewritten.items);

    const content = try std.fmt.allocPrint(ctx.allocator, "Edited {s}", .{parsed.value.path});
    const details = try buildEditDiff(
        ctx.allocator,
        parsed.value.path,
        parsed.value.old_text,
        parsed.value.new_text,
    );
    return .{
        .content = content,
        .ui_details = details,
        .owns_content = true,
        .owns_ui_details = true,
    };
}

fn executeBash(
    raw_ctx: *anyopaque,
    tool_call_id: []const u8,
    arguments: []const u8,
    abort: *const ai.provider.AbortState,
) agent.ToolExecResult {
    _ = tool_call_id;
    const ctx: *ToolCtx = @ptrCast(@alignCast(raw_ctx));
    return bashImpl(ctx, arguments, abort) catch |err| toolError(ctx.allocator, "{s}", .{@errorName(err)});
}

fn bashImpl(
    ctx: *ToolCtx,
    arguments: []const u8,
    abort: *const ai.provider.AbortState,
) !agent.ToolExecResult {
    const parsed = try std.json.parseFromSlice(BashArgs, ctx.allocator, arguments, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const timeout_secs = clampTimeout(parsed.value.timeout);
    const script = try ctx.allocator.dupe(u8, parsed.value.command);
    defer ctx.allocator.free(script);

    const argv = [_][]const u8{ "/bin/bash", "-lc", script };
    var child = std.process.Child.init(&argv, ctx.allocator);
    child.cwd = ctx.cwd;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    var stdout_collector: PipeCollector = .{ .file = child.stdout.? };
    var stderr_collector: PipeCollector = .{ .file = child.stderr.? };
    const stdout_thread = try std.Thread.spawn(.{}, collectPipeThread, .{&stdout_collector});
    const stderr_thread = try std.Thread.spawn(.{}, collectPipeThread, .{&stderr_collector});

    var wait_ctx: WaitCtx = .{ .child = &child };
    const wait_thread = try std.Thread.spawn(.{}, waitThreadMain, .{&wait_ctx});

    const start_ms = std.time.milliTimestamp();
    const deadline_ms = start_ms + @as(i64, timeout_secs) * std.time.ms_per_s;

    var timed_out = false;
    while (!wait_ctx.finished.load(.acquire)) {
        if (abort.isAborted()) {
            terminateProcess(&child, false, &wait_ctx);
            break;
        }
        if (std.time.milliTimestamp() >= deadline_ms) {
            timed_out = true;
            terminateProcess(&child, true, &wait_ctx);
            break;
        }
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }

    wait_thread.join();
    stdout_thread.join();
    stderr_thread.join();

    const merged = try mergePipeOutput(ctx.allocator, &stdout_collector, &stderr_collector);
    defer ctx.allocator.free(merged);

    const duration_ms = std.time.milliTimestamp() - start_ms;
    const output = try finalizeBashOutput(ctx.allocator, merged, wait_ctx.term);
    const details = try bashUiDetails(ctx.allocator, wait_ctx.term, duration_ms);

    if (timed_out) {
        const timeout_text = try std.fmt.allocPrint(
            ctx.allocator,
            "Command timed out after {d}s\n{s}",
            .{ timeout_secs, output },
        );
        ctx.allocator.free(output);
        return .{
            .content = timeout_text,
            .is_error = true,
            .ui_details = details,
            .owns_content = true,
            .owns_ui_details = true,
        };
    }

    return .{
        .content = output,
        .ui_details = details,
        .owns_content = true,
        .owns_ui_details = true,
    };
}

const WaitCtx = struct {
    child: *std.process.Child,
    term: std.process.Child.Term = .{ .Exited = 0 },
    finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn waitThreadMain(ctx: *WaitCtx) void {
    ctx.term = ctx.child.wait() catch {
        ctx.finished.store(true, .release);
        return;
    };
    ctx.finished.store(true, .release);
}

const PipeCollector = struct {
    file: std.fs.File,
    buf: std.ArrayListUnmanaged(u8) = .empty,
    truncated: bool = false,

    fn deinit(self: *PipeCollector, allocator: std.mem.Allocator) void {
        self.buf.deinit(allocator);
        self.* = undefined;
    }
};

fn collectPipeThread(collector: *PipeCollector) void {
    var scratch: [1024]u8 = undefined;
    while (true) {
        const amount = collector.file.read(&scratch) catch break;
        if (amount == 0) break;
        appendLimited(&collector.buf, std.heap.page_allocator, scratch[0..amount], &collector.truncated) catch break;
    }
}

fn appendLimited(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    chunk: []const u8,
    truncated: *bool,
) !void {
    if (buf.items.len >= max_bash_output_bytes) {
        truncated.* = true;
        return;
    }
    const remaining = max_bash_output_bytes - buf.items.len;
    const take = @min(chunk.len, remaining);
    try buf.appendSlice(allocator, chunk[0..take]);
    if (take < chunk.len) truncated.* = true;
}

fn mergePipeOutput(
    allocator: std.mem.Allocator,
    stdout: *PipeCollector,
    stderr: *PipeCollector,
) ![]const u8 {
    defer stdout.deinit(std.heap.page_allocator);
    defer stderr.deinit(std.heap.page_allocator);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, stdout.buf.items);
    if (stdout.buf.items.len > 0 and stderr.buf.items.len > 0) {
        try out.append(allocator, '\n');
    }
    try out.appendSlice(allocator, stderr.buf.items);
    if (stdout.truncated or stderr.truncated) {
        try out.appendSlice(allocator, "\n[output truncated]");
    }
    return out.toOwnedSlice(allocator);
}

fn finalizeBashOutput(
    allocator: std.mem.Allocator,
    merged: []const u8,
    term: std.process.Child.Term,
) ![]const u8 {
    return switch (term) {
        .Exited => |code| std.fmt.allocPrint(
            allocator,
            "{s}\n[exit code: {d}]",
            .{ merged, code },
        ),
        .Signal => |sig| std.fmt.allocPrint(
            allocator,
            "{s}\n[signal: {d}]",
            .{ merged, sig },
        ),
        else => allocator.dupe(u8, merged),
    };
}

fn bashUiDetails(
    allocator: std.mem.Allocator,
    term: std.process.Child.Term,
    duration_ms: i64,
) ![]const u8 {
    return switch (term) {
        .Exited => |code| std.fmt.allocPrint(
            allocator,
            "{{\"exit_code\":{d},\"duration_ms\":{d}}}",
            .{ code, duration_ms },
        ),
        .Signal => |sig| std.fmt.allocPrint(
            allocator,
            "{{\"signal\":{d},\"duration_ms\":{d}}}",
            .{ sig, duration_ms },
        ),
        else => std.fmt.allocPrint(
            allocator,
            "{{\"duration_ms\":{d}}}",
            .{duration_ms},
        ),
    };
}

fn terminateProcess(
    child: *std.process.Child,
    force_kill: bool,
    wait_ctx: *const WaitCtx,
) void {
    _ = std.posix.kill(child.id, std.posix.SIG.TERM) catch {};
    if (!force_kill) return;

    var waited_ms: u32 = 0;
    while (waited_ms < 2000) : (waited_ms += 50) {
        if (wait_ctx.finished.load(.acquire)) return;
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
    _ = std.posix.kill(child.id, std.posix.SIG.KILL) catch {};
}

fn resolvePath(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    path: []const u8,
) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    return std.fs.path.join(allocator, &.{ cwd, path });
}

fn readFileBounded(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    const stat = try file.stat();
    if (stat.size > max_file_bytes) return error.FileTooLarge;
    return file.readToEndAlloc(allocator, @intCast(stat.size));
}

fn renderNumberedLines(
    allocator: std.mem.Allocator,
    content: []const u8,
    offset: u32,
    limit: u32,
) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var line_index: u32 = 0;
    var emitted: u32 = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (line_index >= offset and emitted < limit) {
            const clean = std.mem.trimRight(u8, line, "\r");
            try std.fmt.format(out.writer(allocator), "{d}: {s}\n", .{ line_index + 1, clean });
            emitted += 1;
        }
        line_index += 1;
        if (emitted >= limit) break;
    }
    return out.toOwnedSlice(allocator);
}

fn buildEditDiff(
    allocator: std.mem.Allocator,
    path: []const u8,
    old_text: []const u8,
    new_text: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "--- {s}\n+++ {s}\n-{s}\n+{s}\n",
        .{ path, path, old_text, new_text },
    );
}

fn writeFileAtomic(path: []const u8, content: []const u8) !void {
    var write_buffer: [4096]u8 = undefined;
    var atomic_file = try std.fs.cwd().atomicFile(path, .{
        .make_path = true,
        .write_buffer = &write_buffer,
    });
    defer atomic_file.deinit();

    try atomic_file.file_writer.interface.writeAll(content);
    try atomic_file.finish();
}

fn isBinary(content: []const u8) bool {
    const probe = content[0..@min(content.len, 512)];
    for (probe) |byte| {
        if (byte == 0) return true;
    }
    return false;
}

fn clampLineLimit(limit: u32) u32 {
    if (limit == 0) return max_read_lines_default;
    return @min(limit, max_read_lines_default);
}

fn clampTimeout(timeout: u32) u32 {
    if (timeout == 0) return 30;
    return @min(timeout, 300);
}

fn countLines(content: []const u8) u32 {
    if (content.len == 0) return 0;
    var lines: u32 = 1;
    for (content) |byte| {
        if (byte == '\n') lines += 1;
    }
    return lines;
}

fn toolError(
    allocator: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) agent.ToolExecResult {
    const message = std.fmt.allocPrint(allocator, fmt, args) catch {
        return .{
            .content = "tool error",
            .is_error = true,
        };
    };
    return .{
        .content = message,
        .is_error = true,
        .owns_content = true,
    };
}

test "read tool numbers lines" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    try temp.dir.writeFile(.{ .sub_path = "note.txt", .data = "a\nb\nc\n" });
    const cwd = try temp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    const tools = try register(allocator, cwd);
    defer unregister(allocator, tools);

    const result = tools[0].execute(
        tools[0].ctx,
        "toolu_01",
        "{\"path\":\"note.txt\",\"offset\":1,\"limit\":2}",
        &.{},
    );
    defer result.deinit(allocator);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "2: b") != null);
}

test "write and edit tools update files" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    const cwd = try temp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    const tools = try register(allocator, cwd);
    defer unregister(allocator, tools);

    const write_result = tools[1].execute(
        tools[1].ctx,
        "toolu_01",
        "{\"path\":\"dir/file.txt\",\"content\":\"hello world\"}",
        &.{},
    );
    defer write_result.deinit(allocator);
    try std.testing.expect(!write_result.is_error);

    const edit_result = tools[2].execute(
        tools[2].ctx,
        "toolu_02",
        "{\"path\":\"dir/file.txt\",\"old_text\":\"world\",\"new_text\":\"orbit\"}",
        &.{},
    );
    defer edit_result.deinit(allocator);
    try std.testing.expect(!edit_result.is_error);

    const file = try temp.dir.openFile("dir/file.txt", .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 64);
    defer allocator.free(content);

    try std.testing.expectEqualStrings("hello orbit", content);
}
