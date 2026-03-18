const std = @import("std");
const types = @import("types.zig");
const stream_mod = @import("stream.zig");
const http = @import("http.zig");

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Transport = struct {
    ctx: *anyopaque,
    open_stream: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        url: []const u8,
        headers: []const Header,
        body: []const u8,
    ) anyerror!http.HttpStream,
};

pub const Request = struct {
    messages: []const types.Message,
    system: ?[]const u8 = null,
    model: []const u8,
    tools: ?[]const types.ToolSpec = null,
    max_tokens: ?u32 = null,
    temperature: f64 = 0.0,
};

pub const Provider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        stream: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            request: Request,
            sink: *stream_mod.EventSink,
        ) anyerror!void,
        abort: *const fn (ptr: *anyopaque) void,
        name: *const fn (ptr: *anyopaque) []const u8,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn stream(
        self: Provider,
        allocator: std.mem.Allocator,
        request: Request,
        sink: *stream_mod.EventSink,
    ) !void {
        std.debug.assert(request.model.len > 0);
        std.debug.assert(request.max_tokens == null or request.max_tokens.? > 0);
        std.debug.assert(@intFromPtr(sink.ctx) != 0);
        return self.vtable.stream(self.ptr, allocator, request, sink);
    }

    pub fn abort(self: Provider) void {
        self.vtable.abort(self.ptr);
    }

    pub fn name(self: Provider) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn deinit(self: Provider) void {
        self.vtable.deinit(self.ptr);
    }
};

pub const AbortState = struct {
    flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn abort(self: *AbortState) void {
        self.flag.store(true, .release);
    }

    pub fn reset(self: *AbortState) void {
        self.flag.store(false, .release);
    }

    pub fn isAborted(self: *const AbortState) bool {
        return self.flag.load(.acquire);
    }
};

test "provider vtable forwards calls" {
    const Fake = struct {
        aborts: u32 = 0,
        streams: u32 = 0,
        deinits: u32 = 0,

        fn streamImpl(
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            request: Request,
            sink: *stream_mod.EventSink,
        ) !void {
            _ = allocator;
            _ = request;
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.streams += 1;
            sink.send(.{
                .done = .{
                    .usage = .{},
                    .stop_reason = .end_turn,
                },
            });
        }

        fn abortImpl(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.aborts += 1;
        }

        fn nameImpl(ptr: *anyopaque) []const u8 {
            _ = ptr;
            return "fake";
        }

        fn deinitImpl(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.deinits += 1;
        }
    };

    var fake: Fake = .{};
    const vtable: Provider.VTable = .{
        .stream = Fake.streamImpl,
        .abort = Fake.abortImpl,
        .name = Fake.nameImpl,
        .deinit = Fake.deinitImpl,
    };
    const provider: Provider = .{
        .ptr = &fake,
        .vtable = &vtable,
    };

    const SinkCtx = struct { seen_done: bool = false };
    const sink_callbacks = struct {
        fn onEvent(ctx: *anyopaque, event: stream_mod.StreamEvent) void {
            const typed: *SinkCtx = @ptrCast(@alignCast(ctx));
            if (event == .done) typed.seen_done = true;
        }
    };

    var sink_ctx: SinkCtx = .{};
    var sink: stream_mod.EventSink = .{
        .ctx = &sink_ctx,
        .emit = sink_callbacks.onEvent,
    };

    try provider.stream(std.testing.allocator, .{
        .messages = &.{},
        .model = "fake",
    }, &sink);
    provider.abort();
    provider.deinit();

    try std.testing.expectEqual(@as(u32, 1), fake.streams);
    try std.testing.expectEqual(@as(u32, 1), fake.aborts);
    try std.testing.expectEqual(@as(u32, 1), fake.deinits);
    try std.testing.expectEqualStrings("fake", provider.name());
    try std.testing.expect(sink_ctx.seen_done);
}

test "abort state tracks cancellation" {
    var abort_state: AbortState = .{};
    try std.testing.expect(!abort_state.isAborted());
    abort_state.abort();
    try std.testing.expect(abort_state.isAborted());
    abort_state.reset();
    try std.testing.expect(!abort_state.isAborted());
}
