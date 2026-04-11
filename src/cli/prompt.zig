const std = @import("std");
const ai = @import("../ai/root.zig");
const agent_types = @import("../agent/types.zig");
const context_files_mod = @import("context_files.zig");

pub const ContextFile = context_files_mod.ContextFile;

pub fn buildSystemPrompt(
    allocator: std.mem.Allocator,
    tools: []const agent_types.Tool,
    ctx_files: []const ContextFile,
    cwd: []const u8,
    // Future: skills: []const Skill,
    // Future: append_prompt: ?[]const u8,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    // [1] Role declaration
    try buf.appendSlice(allocator, role_text);

    // [2] Available tools (only those with prompt_snippet)
    try buf.appendSlice(
        allocator,
        "\n\nAvailable tools:\n",
    );
    var has_any = false;
    for (tools) |tool| {
        if (tool.prompt_snippet) |snippet| {
            try std.fmt.format(
                buf.writer(allocator),
                "- {s}: {s}\n",
                .{ tool.name, snippet },
            );
            has_any = true;
        }
    }
    if (!has_any) {
        try buf.appendSlice(allocator, "(none)\n");
    }

    // [3] Guidelines
    try buf.appendSlice(allocator, "\nGuidelines:\n");

    var written: std.ArrayListUnmanaged([]const u8) = .empty;
    defer written.deinit(allocator);

    // 3a. Tool-contributed guidelines (deduplicated)
    for (tools) |tool| {
        for (tool.prompt_guidelines) |g| {
            try writeUniqueGuideline(
                &written,
                &buf,
                allocator,
                g,
            );
        }
    }

    // 3b. Conditional exploration guidelines
    const has_bash = hasToolNamed(tools, "bash");
    const has_grep = hasToolNamed(tools, "grep");
    const has_find = hasToolNamed(tools, "find");
    const has_ls = hasToolNamed(tools, "ls");

    if (has_bash and !(has_grep or has_find or has_ls)) {
        try writeUniqueGuideline(
            &written,
            &buf,
            allocator,
            bash_only_guideline,
        );
    } else if (has_bash and
        (has_grep or has_find or has_ls))
    {
        try writeUniqueGuideline(
            &written,
            &buf,
            allocator,
            bash_prefer_tools,
        );
    }

    // 3c. Global guidelines
    for (&global_guidelines) |g| {
        try writeUniqueGuideline(
            &written,
            &buf,
            allocator,
            g,
        );
    }

    // [4] Project Context (structured)
    if (ctx_files.len > 0) {
        try buf.appendSlice(
            allocator,
            "\n# Project Context\n\n" ++
                "Project-specific instructions " ++
                "and guidelines:\n\n",
        );
        for (ctx_files) |cf| {
            try std.fmt.format(
                buf.writer(allocator),
                "## {s}\n\n{s}\n\n",
                .{ cf.path, cf.content },
            );
        }
    }

    // [5] Date and CWD (at end for prompt cache hit)
    const date = try currentDateUtc(allocator);
    defer allocator.free(date);
    try std.fmt.format(
        buf.writer(allocator),
        "\nCurrent date: {s}" ++
            "\nCurrent working directory: {s}",
        .{ date, cwd },
    );

    return buf.toOwnedSlice(allocator);
}

// ---- Constants ----

const role_text =
    "You are an expert coding assistant " ++
    "operating inside orbit, a coding agent. " ++
    "You help users by reading files, " ++
    "executing commands, editing code, " ++
    "and writing new files.";

const bash_only_guideline =
    "Use bash for file exploration: ls, grep, find.";

const bash_prefer_tools =
    "Prefer grep/find/ls tools over bash for " ++
    "file exploration (faster, respects .gitignore).";

const global_guidelines = [_][]const u8{
    "When summarizing your actions, output plain " ++
        "text directly. Do not use bash or code " ++
        "blocks to display what you did.",
    "Be concise in your responses. " ++
        "Show code, not lengthy explanations.",
    "Run tests after making changes " ++
        "when a test command is available.",
};

// ---- Helpers ----

fn hasToolNamed(
    tools: []const agent_types.Tool,
    name: []const u8,
) bool {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return true;
    }
    return false;
}

fn isWritten(
    written: []const []const u8,
    guideline: []const u8,
) bool {
    for (written) |w| {
        if (std.mem.eql(u8, w, guideline)) return true;
    }
    return false;
}

fn writeUniqueGuideline(
    written: *std.ArrayListUnmanaged([]const u8),
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    guideline: []const u8,
) !void {
    if (isWritten(written.items, guideline)) return;
    try std.fmt.format(
        buf.writer(allocator),
        "- {s}\n",
        .{guideline},
    );
    try written.append(allocator, guideline);
}

/// Returns "YYYY-MM-DD" for the current UTC date.
/// Caller owns the returned slice.
pub fn currentDateUtc(
    allocator: std.mem.Allocator,
) ![]const u8 {
    const ts: i64 = std.time.timestamp();
    return formatEpochDate(allocator, ts);
}

fn formatEpochDate(
    allocator: std.mem.Allocator,
    ts: i64,
) ![]const u8 {
    const days = @divTrunc(ts, @as(i64, 86400));
    // Howard Hinnant's civil_from_days algorithm
    const z = days + 719468;
    const era = @divTrunc(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divTrunc(
        doe - @divTrunc(doe, 1460) +
            @divTrunc(doe, 36524) -
            @divTrunc(doe, 146096),
        365,
    );
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe +
        @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const year = if (m <= 2) y + 1 else y;

    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}",
        .{
            @as(u32, @intCast(year)),
            @as(u32, @intCast(m)),
            @as(u32, @intCast(d)),
        },
    );
}

// ---- Tests ----

fn makeTool(opts: struct {
    name: []const u8 = "test",
    snippet: ?[]const u8 = null,
    guidelines: []const []const u8 = &.{},
}) agent_types.Tool {
    const S = struct {
        var dummy: u8 = 0;

        fn execute(
            _: *anyopaque,
            _: []const u8,
            _: []const u8,
            _: *const ai.provider.AbortState,
        ) agent_types.ToolExecResult {
            return .{ .content = "" };
        }
    };
    return .{
        .name = opts.name,
        .description = "",
        .parameters_json = "{}",
        .execute = S.execute,
        .ctx = &S.dummy,
        .prompt_snippet = opts.snippet,
        .prompt_guidelines = opts.guidelines,
    };
}

test "system prompt lists tools with snippets" {
    const allocator = std.testing.allocator;
    const tools = [_]agent_types.Tool{
        makeTool(.{
            .name = "read",
            .snippet = "Read file contents.",
        }),
        makeTool(.{ .name = "hidden" }),
    };
    const ctx = [_]ContextFile{};
    const prompt = try buildSystemPrompt(
        allocator,
        &tools,
        &ctx,
        "/tmp",
    );
    defer allocator.free(prompt);

    try std.testing.expect(
        std.mem.indexOf(u8, prompt, "- read: Read file") !=
            null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, prompt, "hidden") == null,
    );
}

test "system prompt collects tool guidelines" {
    const allocator = std.testing.allocator;
    const tools = [_]agent_types.Tool{
        makeTool(.{
            .name = "edit",
            .snippet = "Edit files.",
            .guidelines = &.{"Use edit for surgical changes."},
        }),
    };
    const ctx = [_]ContextFile{};
    const prompt = try buildSystemPrompt(
        allocator,
        &tools,
        &ctx,
        "/tmp",
    );
    defer allocator.free(prompt);

    try std.testing.expect(
        std.mem.indexOf(
            u8,
            prompt,
            "- Use edit for surgical changes.",
        ) != null,
    );
}

test "system prompt deduplicates guidelines" {
    const allocator = std.testing.allocator;
    const shared = "Shared guideline.";
    const tools = [_]agent_types.Tool{
        makeTool(.{
            .name = "a",
            .snippet = "A",
            .guidelines = &.{shared},
        }),
        makeTool(.{
            .name = "b",
            .snippet = "B",
            .guidelines = &.{shared},
        }),
    };
    const ctx = [_]ContextFile{};
    const prompt = try buildSystemPrompt(
        allocator,
        &tools,
        &ctx,
        "/tmp",
    );
    defer allocator.free(prompt);

    // Find first occurrence
    const first = std.mem.indexOf(u8, prompt, shared).?;
    // No second occurrence
    const rest = prompt[first + shared.len ..];
    try std.testing.expect(
        std.mem.indexOf(u8, rest, shared) == null,
    );
}

test "system prompt conditional bash without grep" {
    const allocator = std.testing.allocator;
    const tools = [_]agent_types.Tool{
        makeTool(.{
            .name = "bash",
            .snippet = "Execute bash.",
        }),
    };
    const ctx = [_]ContextFile{};
    const prompt = try buildSystemPrompt(
        allocator,
        &tools,
        &ctx,
        "/tmp",
    );
    defer allocator.free(prompt);

    try std.testing.expect(
        std.mem.indexOf(
            u8,
            prompt,
            "Use bash for file exploration",
        ) != null,
    );
}

test "system prompt conditional bash with grep" {
    const allocator = std.testing.allocator;
    const tools = [_]agent_types.Tool{
        makeTool(.{
            .name = "bash",
            .snippet = "Execute bash.",
        }),
        makeTool(.{
            .name = "grep",
            .snippet = "Search files.",
        }),
    };
    const ctx = [_]ContextFile{};
    const prompt = try buildSystemPrompt(
        allocator,
        &tools,
        &ctx,
        "/tmp",
    );
    defer allocator.free(prompt);

    try std.testing.expect(
        std.mem.indexOf(
            u8,
            prompt,
            "Prefer grep/find/ls tools over bash",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            prompt,
            "Use bash for file exploration",
        ) == null,
    );
}

test "system prompt structured context files" {
    const allocator = std.testing.allocator;
    const tools = [_]agent_types.Tool{
        makeTool(.{
            .name = "read",
            .snippet = "Read files",
        }),
    };
    const ctx = [_]ContextFile{
        .{
            .path = "/project/AGENTS.md",
            .content = "project rules",
        },
        .{
            .path = "/home/.orbit/AGENTS.md",
            .content = "global rules",
        },
    };
    const prompt = try buildSystemPrompt(
        allocator,
        &tools,
        &ctx,
        "/project",
    );
    defer allocator.free(prompt);

    // Structured headers
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            prompt,
            "## /project/AGENTS.md",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, prompt, "project rules") !=
            null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, prompt, "global rules") !=
            null,
    );
    // No old-style separator
    try std.testing.expect(
        std.mem.indexOf(u8, prompt, "\n---\n") == null,
    );
}

test "system prompt contains cwd and date" {
    const allocator = std.testing.allocator;
    const tools = [_]agent_types.Tool{};
    const ctx = [_]ContextFile{};
    const prompt = try buildSystemPrompt(
        allocator,
        &tools,
        &ctx,
        "/test/dir",
    );
    defer allocator.free(prompt);

    try std.testing.expect(
        std.mem.indexOf(
            u8,
            prompt,
            "Current working directory: /test/dir",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, prompt, "Current date: ") !=
            null,
    );
}

test "system prompt empty tools" {
    const allocator = std.testing.allocator;
    const tools = [_]agent_types.Tool{};
    const ctx = [_]ContextFile{};
    const prompt = try buildSystemPrompt(
        allocator,
        &tools,
        &ctx,
        "/tmp",
    );
    defer allocator.free(prompt);

    try std.testing.expect(
        std.mem.indexOf(u8, prompt, "(none)") != null,
    );
}

test "current date utc returns valid format" {
    const allocator = std.testing.allocator;
    const date = try currentDateUtc(allocator);
    defer allocator.free(date);

    try std.testing.expectEqual(@as(usize, 10), date.len);
    try std.testing.expect(date[4] == '-');
    try std.testing.expect(date[7] == '-');
}

test "format epoch date known values" {
    const allocator = std.testing.allocator;

    // Unix epoch: 1970-01-01
    const d1 = try formatEpochDate(allocator, 0);
    defer allocator.free(d1);
    try std.testing.expectEqualStrings("1970-01-01", d1);

    // 2026-04-10 00:00:00 UTC = 20553 days * 86400
    const d2 = try formatEpochDate(allocator, 1775779200);
    defer allocator.free(d2);
    try std.testing.expectEqualStrings("2026-04-10", d2);
}
