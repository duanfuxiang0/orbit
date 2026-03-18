const std = @import("std");

pub const SseEvent = struct {
    event_type: []u8,
    data: []u8,

    pub fn deinit(self: *SseEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.event_type);
        allocator.free(self.data);
        self.* = undefined;
    }
};

pub const SseParser = struct {
    buffer: std.ArrayListUnmanaged(u8) = .empty,

    pub fn deinit(self: *SseParser, allocator: std.mem.Allocator) void {
        self.buffer.deinit(allocator);
    }

    pub fn push(self: *SseParser, allocator: std.mem.Allocator, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.buffer.appendSlice(allocator, bytes);
    }

    pub fn nextEvent(self: *SseParser, allocator: std.mem.Allocator) !?SseEvent {
        while (true) {
            const boundary = findEventBoundary(self.buffer.items) orelse return null;
            const raw_event = self.buffer.items[0..boundary.index];
            self.consume(boundary.index + boundary.delimiter_len);

            const parsed = try parseRawEvent(raw_event, allocator);
            if (parsed) |event| return event;
        }
    }

    fn consume(self: *SseParser, consumed: usize) void {
        std.debug.assert(consumed <= self.buffer.items.len);
        const remaining = self.buffer.items.len - consumed;
        if (remaining > 0) {
            std.mem.copyForwards(
                u8,
                self.buffer.items[0..remaining],
                self.buffer.items[consumed..self.buffer.items.len],
            );
        }
        self.buffer.items.len = remaining;
    }
};

const EventBoundary = struct {
    index: usize,
    delimiter_len: usize,
};

fn findEventBoundary(data: []const u8) ?EventBoundary {
    if (data.len < 2) return null;

    var i: usize = 0;
    while (i + 1 < data.len) : (i += 1) {
        if (data[i] == '\n' and data[i + 1] == '\n') {
            return .{ .index = i, .delimiter_len = 2 };
        }
        if (i + 3 < data.len) {
            if (data[i] == '\r' and data[i + 1] == '\n') {
                if (data[i + 2] == '\r' and data[i + 3] == '\n') {
                    return .{ .index = i, .delimiter_len = 4 };
                }
            }
        }
    }
    return null;
}

fn parseRawEvent(raw_event: []const u8, allocator: std.mem.Allocator) !?SseEvent {
    var data_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer data_buf.deinit(allocator);

    var event_name: []const u8 = "message";
    var saw_data = false;

    var line_it = std.mem.splitScalar(u8, raw_event, '\n');
    while (line_it.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == ':') continue;

        if (std.mem.startsWith(u8, trimmed, "event:")) {
            event_name = trimSseValue(trimmed["event:".len..]);
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "data:")) {
            const payload = trimSseValue(trimmed["data:".len..]);
            if (saw_data) {
                try data_buf.append(allocator, '\n');
            }
            try data_buf.appendSlice(allocator, payload);
            saw_data = true;
            continue;
        }
    }

    if (!saw_data) return null;

    return .{
        .event_type = try allocator.dupe(u8, event_name),
        .data = try data_buf.toOwnedSlice(allocator),
    };
}

fn trimSseValue(value: []const u8) []const u8 {
    if (value.len == 0) return value;
    if (value[0] == ' ') return value[1..];
    return value;
}

pub const HttpStream = struct {
    ctx: *anyopaque,
    read_fn: *const fn (ctx: *anyopaque, dest: []u8) anyerror!usize,
    close_fn: ?*const fn (ctx: *anyopaque) void = null,
    parser: SseParser = .{},
    aborted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    reached_eof: bool = false,

    pub fn init(
        ctx: *anyopaque,
        read_fn: *const fn (ctx: *anyopaque, dest: []u8) anyerror!usize,
        close_fn: ?*const fn (ctx: *anyopaque) void,
    ) HttpStream {
        return .{
            .ctx = ctx,
            .read_fn = read_fn,
            .close_fn = close_fn,
        };
    }

    pub fn deinit(self: *HttpStream, allocator: std.mem.Allocator) void {
        self.parser.deinit(allocator);
    }

    pub fn nextEvent(
        self: *HttpStream,
        allocator: std.mem.Allocator,
        scratch: []u8,
    ) !?SseEvent {
        std.debug.assert(scratch.len > 0);

        while (true) {
            if (self.aborted.load(.acquire)) return null;

            if (try self.parser.nextEvent(allocator)) |event| {
                return event;
            }

            if (self.reached_eof) return null;

            const n = try self.read_fn(self.ctx, scratch);
            if (n == 0) {
                self.reached_eof = true;
                continue;
            }
            try self.parser.push(allocator, scratch[0..n]);
        }
    }

    pub fn abort(self: *HttpStream) void {
        self.aborted.store(true, .release);
        if (self.close_fn) |close_fn| {
            close_fn(self.ctx);
        }
    }
};

test "sse parser handles split chunks and multiline data" {
    var parser: SseParser = .{};
    defer parser.deinit(std.testing.allocator);

    try parser.push(
        std.testing.allocator,
        "event: msg\ndata: hello\ndata: world\n\n",
    );

    var event = (try parser.nextEvent(std.testing.allocator)).?;
    defer event.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("msg", event.event_type);
    try std.testing.expectEqualStrings("hello\nworld", event.data);
}

test "sse parser ignores comments and empty payloads" {
    var parser: SseParser = .{};
    defer parser.deinit(std.testing.allocator);

    try parser.push(
        std.testing.allocator,
        ": ping\r\nevent: keepalive\r\n\r\ndata: ok\r\n\r\n",
    );

    var event = (try parser.nextEvent(std.testing.allocator)).?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("message", event.event_type);
    try std.testing.expectEqualStrings("ok", event.data);
}

test "http stream supports abort" {
    const Mock = struct {
        chunks: []const []const u8,
        index: usize = 0,
        closed: bool = false,

        fn read(ctx: *anyopaque, dest: []u8) !usize {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.index >= self.chunks.len) return 0;

            const chunk = self.chunks[self.index];
            std.debug.assert(chunk.len <= dest.len);
            @memcpy(dest[0..chunk.len], chunk);
            self.index += 1;
            return chunk.len;
        }

        fn close(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.closed = true;
        }
    };

    var mock: Mock = .{
        .chunks = &.{"data: hello\n\n"},
    };
    var stream = HttpStream.init(&mock, Mock.read, Mock.close);
    defer stream.deinit(std.testing.allocator);

    stream.abort();
    var scratch: [64]u8 = undefined;
    const event = try stream.nextEvent(std.testing.allocator, &scratch);

    try std.testing.expect(event == null);
    try std.testing.expect(mock.closed);
}
