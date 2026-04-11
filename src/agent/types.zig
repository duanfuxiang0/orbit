const ai = @import("../ai/root.zig");
const std = @import("std");

pub const ToolExecResult = struct {
    content: []const u8,
    is_error: bool = false,
    ui_details: ?[]const u8 = null,
    owns_content: bool = false,
    owns_ui_details: bool = false,

    pub fn deinit(self: ToolExecResult, allocator: std.mem.Allocator) void {
        if (self.owns_content) allocator.free(self.content);
        if (self.owns_ui_details) {
            if (self.ui_details) |details| allocator.free(details);
        }
    }
};

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
    execute: *const fn (
        ctx: *anyopaque,
        tool_call_id: []const u8,
        arguments: []const u8,
        abort: *const ai.provider.AbortState,
    ) ToolExecResult,
    ctx: *anyopaque,

    /// One-line description for the "Available tools" prompt section.
    /// If null, this tool is omitted from the prompt tool list.
    prompt_snippet: ?[]const u8 = null,

    /// Usage guidelines contributed to the "Guidelines" section.
    prompt_guidelines: []const []const u8 = &.{},

    pub fn toSpec(self: Tool) ai.ToolSpec {
        return .{
            .name = self.name,
            .description = self.description,
            .parameters_json = self.parameters_json,
        };
    }
};

pub const AgentEndInfo = struct {
    total_usage: ai.TokenUsage,
    stop_reason: StopReason,
};

pub const StopReason = enum {
    complete,
    aborted,
    err,
};

pub const TurnEndInfo = struct {
    usage: ai.TokenUsage,
    tool_call_count: u32,
};

pub const ToolExecEndInfo = struct {
    id: []const u8,
    name: []const u8,
    is_error: bool,
    ui_details: ?[]const u8,
};

pub const AgentEvent = union(enum) {
    agent_start,
    agent_end: AgentEndInfo,
    turn_start,
    turn_end: TurnEndInfo,

    text_delta: []const u8,
    thinking_delta: []const u8,
    thinking_signature_delta: []const u8,
    tool_call_start: struct {
        id: []const u8,
        name: []const u8,
    },
    tool_call_delta: struct {
        id: []const u8,
        args_delta: []const u8,
    },

    tool_exec_start: struct {
        id: []const u8,
        name: []const u8,
        arguments: []const u8,
    },
    tool_exec_end: ToolExecEndInfo,

    steering_injected: []const u8,
    err: []const u8,
};

pub const AgentEventSink = struct {
    ctx: *anyopaque,
    emit: *const fn (ctx: *anyopaque, event: AgentEvent) void,

    pub fn send(self: *const AgentEventSink, event: AgentEvent) void {
        self.emit(self.ctx, event);
    }
};

pub const MessageQueue = struct {
    ctx: *anyopaque,
    get_steering: *const fn (ctx: *anyopaque) ?[]const u8,
    get_follow_up: *const fn (ctx: *anyopaque) ?[]const u8,
};

test "tool converts to ai spec" {
    var dummy_ctx: u8 = 0;
    const fake = struct {
        fn execute(
            ctx: *anyopaque,
            tool_call_id: []const u8,
            arguments: []const u8,
            abort: *const ai.provider.AbortState,
        ) ToolExecResult {
            _ = ctx;
            _ = tool_call_id;
            _ = arguments;
            _ = abort;
            return .{ .content = "ok" };
        }
    };

    const tool: Tool = .{
        .name = "read_file",
        .description = "Read a file",
        .parameters_json = "{\"type\":\"object\"}",
        .execute = fake.execute,
        .ctx = &dummy_ctx,
    };
    const spec = tool.toSpec();

    try std.testing.expectEqualStrings("read_file", spec.name);
    try std.testing.expectEqualStrings("Read a file", spec.description);
    try std.testing.expectEqualStrings("{\"type\":\"object\"}", spec.parameters_json);
}

test "agent event sink forwards payloads" {
    const Ctx = struct {
        seen_start: bool = false,
        seen_text: bool = false,
        seen_end: bool = false,
    };
    const callbacks = struct {
        fn onEvent(ctx: *anyopaque, event: AgentEvent) void {
            const typed: *Ctx = @ptrCast(@alignCast(ctx));
            switch (event) {
                .agent_start => typed.seen_start = true,
                .text_delta => typed.seen_text = true,
                .agent_end => typed.seen_end = true,
                else => {},
            }
        }
    };

    var ctx: Ctx = .{};
    const sink: AgentEventSink = .{
        .ctx = &ctx,
        .emit = callbacks.onEvent,
    };

    sink.send(.agent_start);
    sink.send(.{ .text_delta = "hello" });
    sink.send(.{
        .agent_end = .{
            .total_usage = .{},
            .stop_reason = .complete,
        },
    });

    try std.testing.expect(ctx.seen_start);
    try std.testing.expect(ctx.seen_text);
    try std.testing.expect(ctx.seen_end);
}
