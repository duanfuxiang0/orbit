const std = @import("std");
const types = @import("types.zig");

pub const StopReason = enum {
    end_turn,
    tool_use,
    max_tokens,
    aborted,
};

pub const ErrorKind = enum {
    rate_limited,
    context_exhausted,
    auth_failed,
    network,
    timeout,
    other,
};

pub const StreamError = struct {
    kind: ErrorKind,
    message: []const u8,
};

/// Event payload slices are owned by the provider stream call and remain valid
/// until `Provider.stream()` returns.
pub const StreamEvent = union(enum) {
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
    tool_call_done: types.ToolCall,
    done: struct {
        usage: types.TokenUsage,
        stop_reason: StopReason,
    },
    err: StreamError,
};

pub const EventSink = struct {
    ctx: *anyopaque,
    emit: *const fn (ctx: *anyopaque, event: StreamEvent) void,

    pub fn send(self: *const EventSink, event: StreamEvent) void {
        self.emit(self.ctx, event);
    }
};

test "event sink receives events in order" {
    const Ctx = struct {
        seen_text: bool = false,
        seen_done: bool = false,
        count: u32 = 0,
    };

    const callbacks = struct {
        fn onEvent(ctx: *anyopaque, event: StreamEvent) void {
            const typed: *Ctx = @ptrCast(@alignCast(ctx));
            typed.count += 1;

            switch (event) {
                .text_delta => |delta| {
                    std.debug.assert(delta.len > 0);
                    typed.seen_text = true;
                },
                .done => {
                    typed.seen_done = true;
                },
                else => {},
            }
        }
    };

    var ctx: Ctx = .{};
    const sink: EventSink = .{
        .ctx = &ctx,
        .emit = callbacks.onEvent,
    };

    sink.send(.{ .text_delta = "hello" });
    sink.send(.{
        .done = .{
            .usage = .{ .input = 1, .output = 2 },
            .stop_reason = .end_turn,
        },
    });

    try std.testing.expect(ctx.seen_text);
    try std.testing.expect(ctx.seen_done);
    try std.testing.expectEqual(@as(u32, 2), ctx.count);
}
