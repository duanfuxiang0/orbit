const std = @import("std");
const provider_mod = @import("provider.zig");

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
            const raw_event = try allocator.dupe(u8, self.buffer.items[0..boundary.index]);
            defer allocator.free(raw_event);
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

    var line_start: usize = 0;
    var previous_break_len: usize = 0;
    var saw_data = false;
    var saw_any = false;

    while (line_start < data.len) {
        const boundary = findLineBoundary(data, line_start) orelse return null;
        const line = data[line_start..boundary.line_end];

        if (line.len == 0) {
            if (saw_any) {
                return .{
                    .index = line_start,
                    .delimiter_len = boundary.break_len,
                };
            }
        } else {
            if (std.mem.startsWith(u8, line, "event:")) {
                if (saw_data) {
                    return .{
                        .index = line_start - previous_break_len,
                        .delimiter_len = previous_break_len,
                    };
                }
                saw_any = true;
            }
            if (std.mem.startsWith(u8, line, "data:")) {
                saw_data = true;
                saw_any = true;
            }
            if (line.len > 0 and !std.mem.startsWith(u8, line, ":")) {
                saw_any = true;
            }
        }

        previous_break_len = boundary.break_len;
        line_start = boundary.line_end + boundary.break_len;
    }
    return null;
}

const LineBoundary = struct {
    line_end: usize,
    break_len: usize,
};

fn findLineBoundary(data: []const u8, start: usize) ?LineBoundary {
    var i = start;
    while (i < data.len) : (i += 1) {
        if (data[i] == '\n') {
            return .{
                .line_end = i,
                .break_len = 1,
            };
        }
        if (data[i] == '\r') {
            if (i + 1 < data.len and data[i + 1] == '\n') {
                return .{
                    .line_end = i,
                    .break_len = 2,
                };
            }
            return .{
                .line_end = i,
                .break_len = 1,
            };
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
    abort_fn: ?*const fn (ctx: *anyopaque) void = null,
    destroy_fn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void = null,
    parser: SseParser = .{},
    aborted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    reached_eof: bool = false,

    pub fn init(
        ctx: *anyopaque,
        read_fn: *const fn (ctx: *anyopaque, dest: []u8) anyerror!usize,
        abort_fn: ?*const fn (ctx: *anyopaque) void,
        destroy_fn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void,
    ) HttpStream {
        return .{
            .ctx = ctx,
            .read_fn = read_fn,
            .abort_fn = abort_fn,
            .destroy_fn = destroy_fn,
        };
    }

    pub fn deinit(self: *HttpStream, allocator: std.mem.Allocator) void {
        self.parser.deinit(allocator);
        if (self.destroy_fn) |destroy_fn| {
            destroy_fn(self.ctx, allocator);
        }
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
        if (self.abort_fn) |abort_fn| {
            abort_fn(self.ctx);
        }
    }
};

pub const StdHttpTransport = struct {
    verbose: bool = false,

    pub fn asTransport(self: *StdHttpTransport) provider_mod.Transport {
        return .{
            .ctx = self,
            .open_stream = openStream,
        };
    }

    fn openStream(
        raw_ctx: *anyopaque,
        allocator: std.mem.Allocator,
        url: []const u8,
        headers: []const provider_mod.Header,
        body: []const u8,
    ) !HttpStream {
        const self: *StdHttpTransport = @ptrCast(@alignCast(raw_ctx));
        const conn = try HttpConnection.create(allocator, url, headers, body, self.verbose);
        return HttpStream.init(conn, HttpConnection.read, HttpConnection.abort, HttpConnection.destroy);
    }
};

const HttpConnection = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,
    request: ?std.http.Client.Request = null,
    body_reader: ?*std.Io.Reader = null,
    extra_headers: []std.http.Header,
    transfer_buf: [4096]u8 = undefined,
    redirect_buf: [4096]u8 = undefined,
    verbose: bool,

    fn create(
        allocator: std.mem.Allocator,
        url: []const u8,
        headers: []const provider_mod.Header,
        body: []const u8,
        verbose: bool,
    ) !*HttpConnection {
        const conn = try allocator.create(HttpConnection);
        errdefer allocator.destroy(conn);

        conn.* = .{
            .allocator = allocator,
            .client = .{ .allocator = allocator },
            .extra_headers = try allocator.alloc(std.http.Header, headers.len),
            .verbose = verbose,
        };
        errdefer {
            allocator.free(conn.extra_headers);
            conn.client.deinit();
        }

        for (headers, 0..) |header, index| {
            conn.extra_headers[index] = .{
                .name = header.name,
                .value = header.value,
            };
        }

        const uri = try std.Uri.parse(url);
        conn.request = try conn.client.request(.POST, uri, .{
            .extra_headers = conn.extra_headers,
        });
        errdefer {
            if (conn.request) |*request| request.deinit();
        }

        var request = &conn.request.?;
        if (verbose) {
            std.debug.print("orbit: POST {s}\n", .{url});
        }

        const body_copy = try allocator.dupe(u8, body);
        defer allocator.free(body_copy);
        try request.sendBodyComplete(body_copy);

        const response = try request.receiveHead(&conn.redirect_buf);
        const status_code = @intFromEnum(response.head.status);
        if (status_code < 200 or status_code >= 300) {
            return error.HttpStatusError;
        }

        conn.body_reader = request.reader.bodyReader(
            &conn.transfer_buf,
            response.head.transfer_encoding,
            response.head.content_length,
        );
        return conn;
    }

    fn destroy(raw_ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *HttpConnection = @ptrCast(@alignCast(raw_ctx));
        if (self.request) |*request| {
            request.deinit();
            self.request = null;
        }
        self.client.deinit();
        allocator.free(self.extra_headers);
        allocator.destroy(self);
    }

    fn abort(raw_ctx: *anyopaque) void {
        const self: *HttpConnection = @ptrCast(@alignCast(raw_ctx));
        if (self.request) |*request| {
            request.deinit();
            self.request = null;
            self.body_reader = null;
        }
    }

    fn read(raw_ctx: *anyopaque, dest: []u8) !usize {
        const self: *HttpConnection = @ptrCast(@alignCast(raw_ctx));
        const reader = self.body_reader orelse return 0;
        if (dest.len == 0) return 0;

        var copied: usize = 0;
        while (copied < dest.len) {
            const available = reader.bufferedLen();
            if (available > 0) {
                const take = @min(available, dest.len - copied);
                const bytes = reader.take(take) catch |err| switch (err) {
                    error.EndOfStream => return copied,
                    else => return err,
                };
                if (bytes.len == 0) return copied;
                @memcpy(dest[copied..][0..bytes.len], bytes);
                copied += bytes.len;
                continue;
            }

            // Return immediately when we already have data. Waiting for
            // more would stall SSE streaming by up to the poll timeout.
            if (copied > 0) return copied;

            if (!(try self.waitForReadable())) return 0;

            const bytes = reader.take(1) catch |err| switch (err) {
                error.EndOfStream => return copied,
                else => return err,
            };
            if (bytes.len == 0) return copied;
            dest[copied] = bytes[0];
            copied += 1;
        }
        return copied;
    }

    fn waitForReadable(self: *HttpConnection) !bool {
        const request = self.request orelse return false;
        const conn = request.connection orelse return false;
        if (conn.reader().bufferedLen() > 0) return true;

        const stream = conn.stream_reader.getStream();
        var poll_fds = [_]std.posix.pollfd{
            .{
                .fd = stream.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
        };

        const events = try std.posix.poll(&poll_fds, 1000);
        if (events == 0) return false;
        if (poll_fds[0].revents & std.posix.POLL.IN != 0) return true;
        return false;
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

test "sse parser tolerates adjacent events without blank line" {
    var parser: SseParser = .{};
    defer parser.deinit(std.testing.allocator);

    try parser.push(
        std.testing.allocator,
        "event: ping\ndata: {\"type\":\"ping\"}\nevent: message\n" ++
            "data: {\"type\":\"message_start\"}\n\n",
    );

    var first = (try parser.nextEvent(std.testing.allocator)).?;
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("ping", first.event_type);
    try std.testing.expectEqualStrings("{\"type\":\"ping\"}", first.data);

    var second = (try parser.nextEvent(std.testing.allocator)).?;
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("message", second.event_type);
    try std.testing.expectEqualStrings("{\"type\":\"message_start\"}", second.data);
}

test "sse parser keeps first event data when buffer contains multiple events" {
    var parser: SseParser = .{};
    defer parser.deinit(std.testing.allocator);

    try parser.push(
        std.testing.allocator,
        "event: ping\ndata: {\"type\":\"ping\"}\n\n" ++
            "event: text\ndata: {\"type\":\"text_delta\",\"text\":\"hello\"}\n\n",
    );

    var first = (try parser.nextEvent(std.testing.allocator)).?;
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("ping", first.event_type);
    try std.testing.expectEqualStrings("{\"type\":\"ping\"}", first.data);

    var second = (try parser.nextEvent(std.testing.allocator)).?;
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("text", second.event_type);
    try std.testing.expectEqualStrings(
        "{\"type\":\"text_delta\",\"text\":\"hello\"}",
        second.data,
    );
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
    var stream = HttpStream.init(&mock, Mock.read, Mock.close, null);
    defer stream.deinit(std.testing.allocator);

    stream.abort();
    var scratch: [64]u8 = undefined;
    const event = try stream.nextEvent(std.testing.allocator, &scratch);

    try std.testing.expect(event == null);
    try std.testing.expect(mock.closed);
}
