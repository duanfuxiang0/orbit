const ai = @import("../ai/root.zig");
const std = @import("std");
const types = @import("types.zig");

pub const StreamCollector = struct {
    allocator: std.mem.Allocator,
    agent_sink: *const types.AgentEventSink,
    text: std.ArrayListUnmanaged(u8) = .empty,
    thinking: std.ArrayListUnmanaged(u8) = .empty,
    thinking_signature: std.ArrayListUnmanaged(u8) = .empty,
    tool_calls: std.ArrayListUnmanaged(ai.ToolCall) = .empty,
    usage: ai.TokenUsage = .{},
    stop_reason: ai.StopReason = .end_turn,
    had_error: bool = false,
    error_message: ?[]u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        agent_sink: *const types.AgentEventSink,
    ) StreamCollector {
        std.debug.assert(@intFromPtr(agent_sink.ctx) != 0);
        return .{
            .allocator = allocator,
            .agent_sink = agent_sink,
        };
    }

    pub fn deinit(self: *StreamCollector) void {
        self.text.deinit(self.allocator);
        self.thinking.deinit(self.allocator);
        self.thinking_signature.deinit(self.allocator);

        for (self.tool_calls.items) |tool_call| {
            freeToolCall(self.allocator, tool_call);
        }
        self.tool_calls.deinit(self.allocator);

        if (self.error_message) |message| {
            self.allocator.free(message);
            self.error_message = null;
        }
    }

    pub fn eventSink(self: *StreamCollector) ai.EventSink {
        std.debug.assert(@intFromPtr(self) != 0);
        return .{
            .ctx = self,
            .emit = onStreamEvent,
        };
    }

    /// Transfers ownership of collected tool calls to the caller.
    /// Caller must later deinit the returned list and free each tool call payload.
    pub fn takeToolCalls(self: *StreamCollector) std.ArrayListUnmanaged(ai.ToolCall) {
        const moved = self.tool_calls;
        self.tool_calls = .empty;
        return moved;
    }

    fn onStreamEvent(ctx: *anyopaque, event: ai.StreamEvent) void {
        const self: *StreamCollector = @ptrCast(@alignCast(ctx));
        switch (event) {
            .text_delta => |delta| self.onTextDelta(delta),
            .thinking_delta => |delta| self.onThinkingDelta(delta),
            .thinking_signature_delta => |delta| self.onThinkingSignatureDelta(delta),
            .tool_call_start => |tool_call| {
                self.agent_sink.send(.{
                    .tool_call_start = .{
                        .id = tool_call.id,
                        .name = tool_call.name,
                    },
                });
            },
            .tool_call_delta => |delta| {
                self.agent_sink.send(.{
                    .tool_call_delta = .{
                        .id = delta.id,
                        .args_delta = delta.args_delta,
                    },
                });
            },
            .tool_call_done => |tool_call| self.onToolCallDone(tool_call),
            .done => |done| {
                self.usage = done.usage;
                self.stop_reason = done.stop_reason;
            },
            .err => |stream_err| {
                self.setError(stream_err.message);
                self.agent_sink.send(.{ .err = stream_err.message });
            },
        }
    }

    fn onTextDelta(self: *StreamCollector, delta: []const u8) void {
        self.text.appendSlice(self.allocator, delta) catch {
            self.failWithOutOfMemory();
            return;
        };
        self.agent_sink.send(.{ .text_delta = delta });
    }

    fn onThinkingDelta(self: *StreamCollector, delta: []const u8) void {
        self.thinking.appendSlice(self.allocator, delta) catch {
            self.failWithOutOfMemory();
            return;
        };
        self.agent_sink.send(.{ .thinking_delta = delta });
    }

    fn onThinkingSignatureDelta(self: *StreamCollector, delta: []const u8) void {
        self.thinking_signature.appendSlice(self.allocator, delta) catch {
            self.failWithOutOfMemory();
            return;
        };
        self.agent_sink.send(.{ .thinking_signature_delta = delta });
    }

    fn onToolCallDone(self: *StreamCollector, tool_call: ai.ToolCall) void {
        const id = self.allocator.dupe(u8, tool_call.id) catch {
            self.failWithOutOfMemory();
            return;
        };

        const name = self.allocator.dupe(u8, tool_call.name) catch {
            self.allocator.free(id);
            self.failWithOutOfMemory();
            return;
        };

        const arguments = self.allocator.dupe(u8, tool_call.arguments) catch {
            self.allocator.free(id);
            self.allocator.free(name);
            self.failWithOutOfMemory();
            return;
        };

        self.tool_calls.append(self.allocator, .{
            .id = id,
            .name = name,
            .arguments = arguments,
        }) catch {
            self.allocator.free(id);
            self.allocator.free(name);
            self.allocator.free(arguments);
            self.failWithOutOfMemory();
            return;
        };
    }

    fn failWithOutOfMemory(self: *StreamCollector) void {
        self.setError("OutOfMemory");
        self.agent_sink.send(.{ .err = "OutOfMemory" });
    }

    fn setError(self: *StreamCollector, message: []const u8) void {
        self.had_error = true;
        if (self.error_message) |prev| {
            self.allocator.free(prev);
            self.error_message = null;
        }
        self.error_message = self.allocator.dupe(u8, message) catch null;
    }
};

pub fn freeToolCall(allocator: std.mem.Allocator, tool_call: ai.ToolCall) void {
    allocator.free(tool_call.id);
    allocator.free(tool_call.name);
    allocator.free(tool_call.arguments);
}

test "collector forwards stream events and captures payloads" {
    const SinkCtx = struct {
        text_count: u32 = 0,
        thinking_count: u32 = 0,
        tool_start_count: u32 = 0,
        tool_delta_count: u32 = 0,
        err_count: u32 = 0,
    };
    const callbacks = struct {
        fn onEvent(ctx: *anyopaque, event: types.AgentEvent) void {
            const typed: *SinkCtx = @ptrCast(@alignCast(ctx));
            switch (event) {
                .text_delta => typed.text_count += 1,
                .thinking_delta => typed.thinking_count += 1,
                .tool_call_start => typed.tool_start_count += 1,
                .tool_call_delta => typed.tool_delta_count += 1,
                .err => typed.err_count += 1,
                else => {},
            }
        }
    };

    var sink_ctx: SinkCtx = .{};
    const agent_sink: types.AgentEventSink = .{
        .ctx = &sink_ctx,
        .emit = callbacks.onEvent,
    };

    var collector = StreamCollector.init(std.testing.allocator, &agent_sink);
    defer collector.deinit();

    var ai_sink = collector.eventSink();
    ai_sink.send(.{ .text_delta = "hello" });
    ai_sink.send(.{ .thinking_delta = "step" });
    ai_sink.send(.{
        .tool_call_start = .{
            .id = "call_1",
            .name = "echo",
        },
    });
    ai_sink.send(.{
        .tool_call_delta = .{
            .id = "call_1",
            .args_delta = "{\"x\":",
        },
    });
    ai_sink.send(.{
        .tool_call_done = .{
            .id = "call_1",
            .name = "echo",
            .arguments = "{\"x\":1}",
        },
    });
    ai_sink.send(.{
        .done = .{
            .usage = .{ .input = 3, .output = 5 },
            .stop_reason = .tool_use,
        },
    });

    try std.testing.expectEqual(@as(u32, 1), sink_ctx.text_count);
    try std.testing.expectEqual(@as(u32, 1), sink_ctx.thinking_count);
    try std.testing.expectEqual(@as(u32, 1), sink_ctx.tool_start_count);
    try std.testing.expectEqual(@as(u32, 1), sink_ctx.tool_delta_count);
    try std.testing.expectEqual(@as(u32, 0), sink_ctx.err_count);

    try std.testing.expectEqualStrings("hello", collector.text.items);
    try std.testing.expectEqualStrings("step", collector.thinking.items);
    try std.testing.expectEqual(@as(usize, 1), collector.tool_calls.items.len);
    try std.testing.expectEqualStrings("call_1", collector.tool_calls.items[0].id);
    try std.testing.expectEqualStrings("{\"x\":1}", collector.tool_calls.items[0].arguments);
    try std.testing.expectEqual(@as(u32, 3), collector.usage.input);
    try std.testing.expectEqual(ai.StopReason.tool_use, collector.stop_reason);
}

test "collector marks stream errors" {
    const SinkCtx = struct { err_count: u32 = 0 };
    const callbacks = struct {
        fn onEvent(ctx: *anyopaque, event: types.AgentEvent) void {
            const typed: *SinkCtx = @ptrCast(@alignCast(ctx));
            if (event == .err) typed.err_count += 1;
        }
    };

    var sink_ctx: SinkCtx = .{};
    const agent_sink: types.AgentEventSink = .{
        .ctx = &sink_ctx,
        .emit = callbacks.onEvent,
    };

    var collector = StreamCollector.init(std.testing.allocator, &agent_sink);
    defer collector.deinit();

    var ai_sink = collector.eventSink();
    ai_sink.send(.{
        .err = .{
            .kind = .network,
            .message = "network failure",
        },
    });

    try std.testing.expect(collector.had_error);
    try std.testing.expectEqual(@as(u32, 1), sink_ctx.err_count);
    try std.testing.expectEqualStrings("network failure", collector.error_message.?);
}
