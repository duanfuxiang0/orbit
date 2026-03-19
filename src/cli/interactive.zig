const std = @import("std");
const ai = @import("../ai/root.zig");
const agent_mod = @import("../agent/root.zig");
const agent_types = @import("../agent/types.zig");
const session_mod = @import("session.zig");
const tui = @import("../tui/root.zig");
const ansi = @import("../tui/ansi.zig");
const terminal = @import("../tui/terminal.zig");
const posix = std.posix;

pub fn run(
    allocator: std.mem.Allocator,
    agent: *agent_mod.Agent,
    session: *session_mod.Session,
) !void {
    _ = session;

    const stdout_file = std.fs.File.stdout();
    const stdin_file = std.fs.File.stdin();

    if (!stdin_file.isTty() or !stdout_file.isTty()) {
        return runLineBuffered(allocator, agent, stdout_file, stdin_file);
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
            const text = ed.getText();
            const trimmed = std.mem.trim(u8, text, " \t");
            if (trimmed.len == 0) continue;

            try stdout_file.writeAll("\r\n");
            renderer.invalidate();

            if (std.mem.eql(u8, trimmed, "/exit")) break;

            try ed.pushHistory();
            ed.clear();

            var sink_ctx = StreamSinkCtx.init(allocator, stdout_file);
            defer sink_ctx.deinit();

            const sink: agent_types.AgentEventSink = .{
                .ctx = &sink_ctx,
                .emit = StreamSinkCtx.onEvent,
            };

            agent.prompt(trimmed, &sink, null);

            // After agent turn, flush any remaining markdown content.
            sink_ctx.flushMarkdown();
            try stdout_file.writeAll("\n");

            renderer.invalidate();
            try renderEditor(&renderer, &ed, allocator);
            continue;
        }

        var input_buf: [4]u8 = undefined;
        input_buf[0] = byte;
        var input_len: usize = 1;
        if (byte >= 0x80) {
            const expected_len = utf8SequenceLengthFromLeadByte(byte);
            while (input_len < expected_len and input_len < input_buf.len) {
                const read_n = try stdin_file.read(input_buf[input_len .. input_len + 1]);
                if (read_n == 0) break;
                input_len += read_n;
            }
        }

        const handled = try ed.handleInput(input_buf[0..input_len]);
        if (handled) try renderEditor(&renderer, &ed, allocator);
    }
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
    has_md_content: bool,

    fn init(allocator: std.mem.Allocator, writer: std.fs.File) StreamSinkCtx {
        return .{
            .allocator = allocator,
            .writer = writer,
            .text_buf = .{},
            .md = tui.Markdown.init(allocator, "", 1, 0),
            .md_renderer = tui.InlineRenderer.init(allocator, writer),
            .has_md_content = false,
        };
    }

    fn deinit(self: *StreamSinkCtx) void {
        self.text_buf.deinit(self.allocator);
        self.md.deinit();
        self.md_renderer.deinit();
    }

    fn flushMarkdown(self: *StreamSinkCtx) void {
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
    }

    fn renderMd(self: *StreamSinkCtx) void {
        self.md.setText(self.text_buf.items) catch return;
        const size = terminal.getTerminalSize();
        const width = if (size.width > 2) size.width else 80;
        const lines = self.md.component().render(width, self.allocator) catch return;
        defer {
            for (lines) |line| self.allocator.free(line);
            self.allocator.free(lines);
        }
        const row: u16 = if (lines.len > 0) @intCast(lines.len - 1) else 0;
        self.md_renderer.render(lines, row, 0) catch {};
        self.has_md_content = true;
    }

    fn onEvent(raw_ctx: *anyopaque, event: agent_types.AgentEvent) void {
        const self: *StreamSinkCtx = @ptrCast(@alignCast(raw_ctx));
        switch (event) {
            .text_delta => |text| {
                self.text_buf.appendSlice(self.allocator, text) catch return;
                self.renderMd();
            },
            .thinking_delta => |text| {
                self.writer.writeAll(ansi.dim) catch {};
                self.writer.writeAll(text) catch {};
                self.writer.writeAll(ansi.reset) catch {};
            },
            .tool_exec_start => |payload| {
                // Flush markdown before tool output.
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
) !void {
    var stdin_buffer: [4096]u8 = undefined;
    var reader = stdin_file.readerStreaming(&stdin_buffer);

    var sink_ctx = StreamSinkCtx.init(allocator, stdout_file);
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

test "utf8 sequence length from lead byte" {
    try std.testing.expectEqual(@as(usize, 1), utf8SequenceLengthFromLeadByte('a'));
    try std.testing.expectEqual(@as(usize, 2), utf8SequenceLengthFromLeadByte(0xC2));
    try std.testing.expectEqual(@as(usize, 3), utf8SequenceLengthFromLeadByte(0xE4));
    try std.testing.expectEqual(@as(usize, 4), utf8SequenceLengthFromLeadByte(0xF0));
    try std.testing.expectEqual(@as(usize, 1), utf8SequenceLengthFromLeadByte(0x80));
}
