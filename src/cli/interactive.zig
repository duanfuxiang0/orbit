const std = @import("std");
const ai = @import("../ai/root.zig");
const agent_mod = @import("../agent/root.zig");
const agent_types = @import("../agent/types.zig");
const session_mod = @import("session.zig");
const runtime = @import("../runtime/root.zig");
const tui = @import("../tui/root.zig");
const ansi = @import("../tui/ansi.zig");
const terminal = @import("../tui/terminal.zig");
const lines_util = @import("../tui/lines_util.zig");
const posix = std.posix;
const MIN_RENDER_INTERVAL_NS: i128 = 16_000_000;
const MD_PADDING_X: u16 = 1;

pub fn run(
    allocator: std.mem.Allocator,
    agent: *agent_mod.Agent,
    session: *session_mod.Session,
) !void {
    _ = session;

    const stdout_file = std.fs.File.stdout();
    const stdin_file = std.fs.File.stdin();

    var event_loop: runtime.EventLoop = undefined;
    try event_loop.init(allocator);
    defer event_loop.deinit();

    if (!stdin_file.isTty() or !stdout_file.isTty()) {
        return runLineBuffered(allocator, agent, stdout_file, stdin_file, &event_loop);
    }

    var raw = try RawMode.init(stdin_file);
    defer raw.deinit();

    var ed = tui.Editor.init(allocator, "> ");
    defer ed.deinit();

    var renderer = tui.InlineRenderer.init(allocator, stdout_file);
    defer renderer.deinit();

    try renderEditor(&renderer, &ed, allocator);

    var byte_buf: [1]u8 = undefined;
    while (true) {
        const count = try stdin_file.read(&byte_buf);
        if (count == 0) break;

        const byte = byte_buf[0];

        if (byte == 0x1b) {
            var seq_buf: [8]u8 = undefined;
            seq_buf[0] = 0x1b;
            const seq_len = 1 + readEscapeTail(stdin_file, seq_buf[1..]);
            const handled = try ed.handleInput(seq_buf[0..seq_len]);
            if (handled) try renderEditor(&renderer, &ed, allocator);
            continue;
        }

        if (byte == 0x04) {
            if (ed.getText().len == 0) {
                try stdout_file.writeAll("\r\n");
                break;
            }
            continue;
        }

        if (byte == '\r' or byte == '\n') {
            const should_exit = try handleSubmit(
                allocator,
                agent,
                &ed,
                &renderer,
                stdout_file,
                &event_loop,
            );
            if (should_exit) break;
            continue;
        }

        var input_buf: [4]u8 = undefined;
        input_buf[0] = byte;
        const input_len = readUtf8Sequence(stdin_file, byte, &input_buf);

        const handled = try ed.handleInput(input_buf[0..input_len]);
        if (handled) try renderEditor(&renderer, &ed, allocator);
    }
}

/// Handle enter-key: submit prompt to agent, stream response, return true to exit.
fn handleSubmit(
    allocator: std.mem.Allocator,
    agent: *agent_mod.Agent,
    ed: *tui.Editor,
    renderer: *tui.InlineRenderer,
    writer: std.fs.File,
    event_loop: *runtime.EventLoop,
) !bool {
    const text = ed.getText();
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return false;

    try writer.writeAll("\r\n");
    renderer.invalidate();

    if (std.mem.eql(u8, trimmed, "/exit")) return true;

    try ed.pushHistory();
    ed.clear();

    var sink_ctx = StreamSinkCtx.init(allocator, writer, event_loop);
    defer sink_ctx.deinit();

    const sink: agent_types.AgentEventSink = .{
        .ctx = &sink_ctx,
        .emit = StreamSinkCtx.onEvent,
    };

    agent.prompt(trimmed, &sink, null);

    // After agent turn, flush any remaining markdown content.
    sink_ctx.flushMarkdown();
    try writer.writeAll("\n");

    renderer.invalidate();
    try renderEditor(renderer, ed, allocator);
    return false;
}

fn renderEditor(
    renderer: *tui.InlineRenderer,
    ed: *tui.Editor,
    allocator: std.mem.Allocator,
) !void {
    const size = terminal.getTerminalSize();
    const width = if (size.width > 0) size.width else 80;
    const lines = try ed.component().render(width, allocator);
    defer {
        for (lines) |line| allocator.free(line);
        allocator.free(lines);
    }
    const cursor_col = ed.cursorColumn();
    try renderer.render(lines, 0, cursor_col);
}

/// Streaming sink that accumulates text and renders markdown incrementally.
const StreamSinkCtx = struct {
    allocator: std.mem.Allocator,
    writer: std.fs.File,
    text_buf: std.ArrayList(u8),
    md: tui.Markdown,
    md_renderer: tui.InlineRenderer,
    render_timer: runtime.Timer,
    mutex: std.Thread.Mutex = .{},
    has_md_content: bool,
    last_render_ns: i128,
    render_pending: bool,
    last_rendered_text_len: usize,
    last_render_width: u16,

    fn init(
        allocator: std.mem.Allocator,
        writer: std.fs.File,
        event_loop: *runtime.EventLoop,
    ) StreamSinkCtx {
        std.debug.assert(event_loop.worker != null);
        return .{
            .allocator = allocator,
            .writer = writer,
            .text_buf = .{},
            .md = tui.Markdown.init(allocator, "", 1, 0),
            .md_renderer = tui.InlineRenderer.init(allocator, writer),
            .render_timer = runtime.Timer.init(event_loop),
            .has_md_content = false,
            .last_render_ns = 0,
            .render_pending = false,
            .last_rendered_text_len = 0,
            .last_render_width = 0,
        };
    }

    fn deinit(self: *StreamSinkCtx) void {
        self.render_timer.deinit();
        self.text_buf.deinit(self.allocator);
        self.md.deinit();
        self.md_renderer.deinit();
    }

    fn flushMarkdown(self: *StreamSinkCtx) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.flushMarkdownLocked();
    }

    fn flushMarkdownLocked(self: *StreamSinkCtx) void {
        self.render_timer.cancel();
        self.flushPendingRenderLocked();
        if (!self.has_md_content) return;
        // Move past the rendered markdown area so it becomes scrollback.
        const line_count = self.md_renderer.backbuffer.items.len;
        if (line_count > 0) {
            // Cursor is at last_cursor_row; move to bottom and newline.
            const bottom = line_count - 1;
            if (bottom > self.md_renderer.last_cursor_row) {
                var buf: [32]u8 = undefined;
                const seq = std.fmt.bufPrint(&buf, "\x1b[{d}B", .{
                    bottom - self.md_renderer.last_cursor_row,
                }) catch return;
                self.writer.writeAll(seq) catch {};
            }
            self.writer.writeAll("\r\n") catch {};
        }
        self.md_renderer.invalidate();
        self.text_buf.clearRetainingCapacity();
        self.has_md_content = false;
        self.render_pending = false;
        self.last_rendered_text_len = 0;
        self.last_render_width = 0;
    }

    fn renderMdLocked(self: *StreamSinkCtx) void {
        const now = std.time.nanoTimestamp();
        if (!shouldThrottleRender(self.last_render_ns, now)) {
            self.render_timer.cancel();
            self.last_render_ns = now;
            self.render_pending = false;
            self.doRenderMdLocked();
            return;
        }

        self.render_pending = true;
        self.schedulePendingRenderLocked(now);
    }

    fn schedulePendingRenderLocked(self: *StreamSinkCtx, now_ns: i128) void {
        const wait_ns = remainingRenderWaitNs(self.last_render_ns, now_ns) orelse return;
        if (wait_ns == 0) {
            self.flushPendingRenderLocked();
            return;
        }
        self.render_timer.armAfter(wait_ns, onRenderDeadline, self) catch {
            self.flushPendingRenderLocked();
        };
    }

    fn doRenderMd(self: *StreamSinkCtx) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.doRenderMdLocked();
    }

    fn doRenderMdLocked(self: *StreamSinkCtx) void {
        const width = markdownRenderWidth();
        if (self.tryRenderMdAppendFastPathLocked(width)) return;

        self.md.setText(self.text_buf.items) catch return;
        const lines = self.md.component().render(width, self.allocator) catch return;
        defer {
            for (lines) |line| self.allocator.free(line);
            self.allocator.free(lines);
        }
        const row: u16 = if (lines.len > 0) @intCast(lines.len - 1) else 0;
        self.md_renderer.render(lines, row, 0) catch {};
        self.has_md_content = true;
        self.last_rendered_text_len = self.text_buf.items.len;
        self.last_render_width = width;
    }

    fn flushPendingRenderLocked(self: *StreamSinkCtx) void {
        if (!self.render_pending) return;
        self.last_render_ns = std.time.nanoTimestamp();
        self.render_pending = false;
        self.doRenderMdLocked();
    }

    fn tryRenderMdAppendFastPath(self: *StreamSinkCtx, width: u16) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.tryRenderMdAppendFastPathLocked(width);
    }

    fn tryRenderMdAppendFastPathLocked(self: *StreamSinkCtx, width: u16) bool {
        if (!self.has_md_content) return false;
        if (self.last_render_width == 0 or self.last_render_width != width) return false;
        if (self.last_rendered_text_len > self.text_buf.items.len) return false;

        const delta = self.text_buf.items[self.last_rendered_text_len..];
        if (delta.len == 0) return true;
        if (!isFastPathMarkdownDelta(delta)) return false;

        const prev_lines = self.md_renderer.backbuffer.items;
        if (prev_lines.len == 0) return false;
        if (lineHasAnsi(prev_lines[prev_lines.len - 1])) return false;

        const updated_lines = appendDeltaToRenderedLines(
            self.allocator,
            prev_lines,
            delta,
            width,
        ) catch return false;
        defer lines_util.freeLines(self.allocator, updated_lines);

        const row: u16 = if (updated_lines.len > 0) @intCast(updated_lines.len - 1) else 0;
        self.md_renderer.render(updated_lines, row, 0) catch return false;
        self.has_md_content = true;
        self.last_rendered_text_len = self.text_buf.items.len;
        self.last_render_width = width;
        return true;
    }

    fn onRenderDeadline(raw_ctx: *anyopaque) void {
        const self: *StreamSinkCtx = @ptrCast(@alignCast(raw_ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.flushPendingRenderLocked();
    }

    fn onEvent(raw_ctx: *anyopaque, event: agent_types.AgentEvent) void {
        const self: *StreamSinkCtx = @ptrCast(@alignCast(raw_ctx));
        switch (event) {
            .text_delta => |text| {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.text_buf.appendSlice(self.allocator, text) catch return;
                self.renderMdLocked();
            },
            .thinking_delta => |text| {
                self.writer.writeAll(ansi.dim) catch {};
                self.writer.writeAll(text) catch {};
                self.writer.writeAll(ansi.reset) catch {};
            },
            .tool_exec_start => |payload| {
                self.flushMarkdown();
                self.writer.writeAll("⟳ ") catch {};
                self.writer.writeAll(payload.name) catch {};
                self.writer.writeAll("\n") catch {};
            },
            .tool_exec_end => |payload| {
                const icon: []const u8 = if (payload.is_error) "✗" else "✓";
                const color: []const u8 = if (payload.is_error)
                    ansi.Color.red.fgCode()
                else
                    ansi.Color.green.fgCode();
                self.writer.writeAll(color) catch {};
                self.writer.writeAll(icon) catch {};
                self.writer.writeAll(" ") catch {};
                self.writer.writeAll(payload.name) catch {};
                if (payload.ui_details) |details| {
                    self.writer.writeAll(" ") catch {};
                    self.writer.writeAll(details) catch {};
                }
                self.writer.writeAll(ansi.reset) catch {};
                self.writer.writeAll("\n") catch {};
            },
            .turn_end => |payload| {
                self.flushMarkdown();
                var buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "{s}tokens: {d} in / {d} out{s}\n", .{
                    ansi.dim,
                    payload.usage.input,
                    payload.usage.output,
                    ansi.reset,
                }) catch return;
                self.writer.writeAll(msg) catch {};
            },
            .err => |message| {
                self.flushMarkdown();
                self.writer.writeAll(ansi.Color.red.fgCode()) catch {};
                self.writer.writeAll("error: ") catch {};
                self.writer.writeAll(message) catch {};
                self.writer.writeAll(ansi.reset) catch {};
                self.writer.writeAll("\n") catch {};
            },
            else => {},
        }
    }
};

fn shouldThrottleRender(last_render_ns: i128, now_ns: i128) bool {
    if (last_render_ns == 0) return false;
    if (now_ns < last_render_ns) return true;
    return now_ns - last_render_ns < MIN_RENDER_INTERVAL_NS;
}

fn remainingRenderWaitNs(last_render_ns: i128, now_ns: i128) ?u64 {
    if (last_render_ns == 0) return 0;
    if (now_ns < last_render_ns) return null;
    const elapsed = now_ns - last_render_ns;
    if (elapsed >= MIN_RENDER_INTERVAL_NS) return 0;
    return std.math.cast(u64, MIN_RENDER_INTERVAL_NS - elapsed);
}

fn markdownRenderWidth() u16 {
    const size = terminal.getTerminalSize();
    return if (size.width > 2) size.width else 80;
}

fn isFastPathMarkdownDelta(delta: []const u8) bool {
    for (delta) |byte| {
        if (byte == '\r') return false;
        if (byte == '`') return false;
        if (byte == '#') return false;
        if (byte == 0x1b) return false;
    }
    return true;
}

fn lineHasAnsi(line: []const u8) bool {
    return std.mem.indexOfScalar(u8, line, 0x1b) != null;
}

fn appendDeltaToRenderedLines(
    allocator: std.mem.Allocator,
    previous_lines: []const []const u8,
    delta: []const u8,
    width: u16,
) ![][]const u8 {
    std.debug.assert(previous_lines.len > 0);

    const max_line_len = markdownMaxLineLen(width);
    var lines: std.ArrayList([]const u8) = .{};
    errdefer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }

    const cloned = try lines_util.cloneLines(allocator, previous_lines);
    try lines_util.appendOwnedLines(&lines, allocator, cloned);
    std.debug.assert(lines.items.len > 0);

    var start: usize = 0;
    while (start <= delta.len) {
        const next_newline = std.mem.indexOfScalarPos(u8, delta, start, '\n') orelse delta.len;
        if (next_newline > start) {
            try appendPlainTextChunk(
                &lines,
                allocator,
                delta[start..next_newline],
                max_line_len,
            );
        }
        if (next_newline == delta.len) break;
        try lines.append(allocator, try allocator.dupe(u8, " "));
        start = next_newline + 1;
    }

    return lines.toOwnedSlice(allocator);
}

fn appendPlainTextChunk(
    lines: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    chunk: []const u8,
    max_line_len: usize,
) !void {
    std.debug.assert(max_line_len > 0);
    if (chunk.len == 0) return;

    var remaining = chunk;
    while (remaining.len > 0) {
        const last_index = lines.items.len - 1;
        const last_line = lines.items[last_index];
        if (lineHasAnsi(last_line)) return error.FastPathAnsiLine;

        const room = if (last_line.len < max_line_len) max_line_len - last_line.len else 0;
        if (room == 0) {
            try lines.append(allocator, try allocator.dupe(u8, " "));
            continue;
        }

        const take = @min(room, remaining.len);
        const merged = try std.fmt.allocPrint(allocator, "{s}{s}", .{
            last_line,
            remaining[0..take],
        });
        allocator.free(last_line);
        lines.items[last_index] = merged;
        remaining = remaining[take..];
    }
}

fn markdownMaxLineLen(width: u16) usize {
    const content_width = markdownContentWidth(width, MD_PADDING_X);
    return content_width + MD_PADDING_X;
}

fn markdownContentWidth(width: u16, padding_x: u16) usize {
    if (padding_x == 0) return @as(usize, width);
    const total_padding = @as(u32, padding_x) * 2;
    if (total_padding >= width) return 1;
    return @as(usize, width - @as(u16, @intCast(total_padding)));
}

fn readEscapeTail(stdin_file: std.fs.File, buf: []u8) usize {
    var len: usize = 0;
    while (len < buf.len) {
        var fds = [_]posix.pollfd{.{
            .fd = stdin_file.handle,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const ready = posix.poll(fds[0..], 0) catch return len;
        if (ready == 0) return len;
        if ((fds[0].revents & posix.POLL.IN) == 0) return len;

        var one: [1]u8 = undefined;
        const n = stdin_file.read(&one) catch return len;
        if (n == 0) return len;
        buf[len] = one[0];
        len += 1;
        if (one[0] >= '@' and one[0] <= '~') return len;
    }
    return len;
}

fn readUtf8Sequence(stdin_file: std.fs.File, lead: u8, buf: *[4]u8) usize {
    buf[0] = lead;
    if (lead < 0x80) return 1;
    const expected = utf8SequenceLengthFromLeadByte(lead);
    var len: usize = 1;
    while (len < expected and len < buf.len) {
        const n = stdin_file.read(buf[len .. len + 1]) catch return len;
        if (n == 0) break;
        len += n;
    }
    return len;
}

fn utf8SequenceLengthFromLeadByte(first_byte: u8) usize {
    if ((first_byte & 0b1000_0000) == 0) return 1;
    if ((first_byte & 0b1110_0000) == 0b1100_0000) return 2;
    if ((first_byte & 0b1111_0000) == 0b1110_0000) return 3;
    if ((first_byte & 0b1111_1000) == 0b1111_0000) return 4;
    return 1;
}

fn runLineBuffered(
    allocator: std.mem.Allocator,
    agent: *agent_mod.Agent,
    stdout_file: std.fs.File,
    stdin_file: std.fs.File,
    event_loop: *runtime.EventLoop,
) !void {
    var stdin_buffer: [4096]u8 = undefined;
    var reader = stdin_file.readerStreaming(&stdin_buffer);

    var sink_ctx = StreamSinkCtx.init(allocator, stdout_file, event_loop);
    defer sink_ctx.deinit();

    const sink: agent_types.AgentEventSink = .{
        .ctx = &sink_ctx,
        .emit = StreamSinkCtx.onEvent,
    };

    while (try reader.interface.takeDelimiter('\n')) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "/exit")) break;

        try stdout_file.writeAll("> ");
        try stdout_file.writeAll(line);
        try stdout_file.writeAll("\n");

        agent.prompt(line, &sink, null);
        sink_ctx.flushMarkdown();
        try stdout_file.writeAll("\n");
    }
}

const RawMode = struct {
    handle: posix.fd_t,
    original: posix.termios,

    fn init(file: std.fs.File) !RawMode {
        std.debug.assert(file.isTty());
        const original = try posix.tcgetattr(file.handle);
        var raw = original;
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        try posix.tcsetattr(file.handle, .FLUSH, raw);
        return .{ .handle = file.handle, .original = original };
    }

    fn deinit(self: *const RawMode) void {
        posix.tcsetattr(self.handle, .FLUSH, self.original) catch {};
    }
};

fn waitForMarkdownRender(sink: *StreamSinkCtx, timeout_ms: u32) bool {
    const start_ns = std.time.nanoTimestamp();
    const timeout_ns = @as(i128, timeout_ms) * std.time.ns_per_ms;

    while (true) {
        sink.mutex.lock();
        const ready = sink.has_md_content and !sink.render_pending;
        sink.mutex.unlock();
        if (ready) return true;

        const now_ns = std.time.nanoTimestamp();
        if (now_ns - start_ns >= timeout_ns) return false;
        std.Thread.sleep(std.time.ns_per_ms);
    }
}

test "utf8 sequence length from lead byte" {
    try std.testing.expectEqual(@as(usize, 1), utf8SequenceLengthFromLeadByte('a'));
    try std.testing.expectEqual(@as(usize, 2), utf8SequenceLengthFromLeadByte(0xC2));
    try std.testing.expectEqual(@as(usize, 3), utf8SequenceLengthFromLeadByte(0xE4));
    try std.testing.expectEqual(@as(usize, 4), utf8SequenceLengthFromLeadByte(0xF0));
    try std.testing.expectEqual(@as(usize, 1), utf8SequenceLengthFromLeadByte(0x80));
}

test "render throttling blocks updates inside frame interval" {
    const now: i128 = 100_000_000;
    try std.testing.expect(shouldThrottleRender(now, now + 1));
    try std.testing.expect(shouldThrottleRender(now, now + MIN_RENDER_INTERVAL_NS - 1));
    try std.testing.expect(!shouldThrottleRender(now, now + MIN_RENDER_INTERVAL_NS));
}

test "remaining render wait computes frame delay" {
    const now: i128 = 200_000_000;
    try std.testing.expectEqual(@as(?u64, 0), remainingRenderWaitNs(0, now));
    try std.testing.expectEqual(@as(?u64, null), remainingRenderWaitNs(now + 1, now));
    try std.testing.expectEqual(@as(?u64, 1), remainingRenderWaitNs(now, now + MIN_RENDER_INTERVAL_NS - 1));
    try std.testing.expectEqual(@as(?u64, 0), remainingRenderWaitNs(now, now + MIN_RENDER_INTERVAL_NS));
}

test "fast path markdown delta filter rejects markdown control bytes" {
    try std.testing.expect(isFastPathMarkdownDelta("plain text"));
    try std.testing.expect(!isFastPathMarkdownDelta("with `fence"));
    try std.testing.expect(!isFastPathMarkdownDelta("with # heading"));
    try std.testing.expect(!isFastPathMarkdownDelta("line\rbreak"));
}

test "append delta to rendered lines wraps and appends" {
    const allocator = std.testing.allocator;
    const previous = [_][]const u8{" hello"};
    const updated = try appendDeltaToRenderedLines(allocator, &previous, " world", 12);
    defer lines_util.freeLines(allocator, updated);

    try std.testing.expectEqual(@as(usize, 2), updated.len);
    try std.testing.expectEqualStrings(" hello worl", updated[0]);
    try std.testing.expectEqualStrings(" d", updated[1]);
}

test "throttled text delta flushes at frame deadline" {
    const allocator = std.testing.allocator;

    var event_loop: runtime.EventLoop = undefined;
    try event_loop.init(allocator);
    defer event_loop.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("stream_sink_deadline", .{ .read = true });
    defer file.close();

    var sink = StreamSinkCtx.init(allocator, file, &event_loop);
    defer sink.deinit();

    sink.last_render_ns = std.time.nanoTimestamp();
    StreamSinkCtx.onEvent(&sink, .{ .text_delta = "deadline flush" });

    try std.testing.expect(waitForMarkdownRender(&sink, 300));
}

test "append-only markdown path updates renderer backbuffer" {
    const allocator = std.testing.allocator;

    var event_loop: runtime.EventLoop = undefined;
    try event_loop.init(allocator);
    defer event_loop.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("stream_sink_append", .{ .read = true });
    defer file.close();

    var sink = StreamSinkCtx.init(allocator, file, &event_loop);
    defer sink.deinit();

    sink.text_buf.appendSlice(allocator, "hello") catch return error.OutOfMemory;
    sink.doRenderMd();
    const width = markdownRenderWidth();
    try std.testing.expect(sink.has_md_content);
    try std.testing.expectEqual(@as(usize, 5), sink.last_rendered_text_len);

    sink.text_buf.appendSlice(allocator, " world") catch return error.OutOfMemory;
    const used_fast_path = sink.tryRenderMdAppendFastPath(width);
    try std.testing.expect(used_fast_path);
    try std.testing.expectEqualStrings(" hello world", sink.md_renderer.backbuffer.items[0]);
}

test "turn_end flushes pending markdown render" {
    const allocator = std.testing.allocator;

    var event_loop: runtime.EventLoop = undefined;
    try event_loop.init(allocator);
    defer event_loop.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("stream_sink_out", .{ .read = true });
    defer file.close();

    var sink = StreamSinkCtx.init(allocator, file, &event_loop);
    defer sink.deinit();

    sink.last_render_ns = std.time.nanoTimestamp() + MIN_RENDER_INTERVAL_NS;
    StreamSinkCtx.onEvent(&sink, .{ .text_delta = "hello throttled markdown" });
    try std.testing.expect(sink.render_pending);
    try std.testing.expect(!sink.has_md_content);

    StreamSinkCtx.onEvent(&sink, .{
        .turn_end = .{
            .usage = .{},
            .tool_call_count = 0,
        },
    });

    try std.testing.expect(!sink.render_pending);
    try std.testing.expect(!sink.has_md_content);

    try file.seekTo(0);
    const stat = try file.stat();
    const output = try file.readToEndAlloc(allocator, @intCast(stat.size));
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "hello throttled markdown") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "tokens: 0 in / 0 out") != null);
}
