const std = @import("std");

pub const Action = enum {
    submit,
    newline,
    backspace,
    delete,
    delete_to_end,
    cursor_left,
    cursor_right,
    cursor_up,
    cursor_down,
    line_start,
    line_end,
    clear_input,
    end_of_transmission,
};

pub const InputEvent = union(enum) {
    action: Action,
    text: []const u8,
    paste: []const u8,
};

const SequenceStatus = enum {
    incomplete,
    complete,
};

const CsiUSequence = struct {
    codepoint: u32,
    shifted: ?u32,
    base: ?u32,
    modifier: u32,
    event_type: u32,
};

const CsiActionSequence = struct {
    action: Action,
    event_type: u32,
};

pub const InputDecoder = struct {
    pending: [128]u8 = undefined,
    pending_len: usize = 0,
    in_paste: bool = false,

    const bracketed_paste_start = "\x1b[200~";
    const bracketed_paste_end = "\x1b[201~";

    pub fn pushBytes(
        self: *InputDecoder,
        data: []const u8,
        ctx: anytype,
        comptime on_event: fn (@TypeOf(ctx), InputEvent) anyerror!void,
    ) !void {
        for (data) |byte| {
            try self.appendByte(byte);
            try self.processPending(ctx, on_event);
        }
    }

    fn processPending(
        self: *InputDecoder,
        ctx: anytype,
        comptime on_event: fn (@TypeOf(ctx), InputEvent) anyerror!void,
    ) !void {
        while (self.pending_len > 0) {
            if (self.in_paste) {
                if (!try self.processPaste(ctx, on_event)) return;
                continue;
            }

            if (self.pending[0] == 0x1b) {
                const status = classifyEscape(self.pendingSlice());
                if (status == .incomplete) return;
                try self.processEscape(ctx, on_event);
                continue;
            }

            if (!try self.processPlain(ctx, on_event)) return;
        }
    }

    fn processPaste(
        self: *InputDecoder,
        ctx: anytype,
        comptime on_event: fn (@TypeOf(ctx), InputEvent) anyerror!void,
    ) !bool {
        const pending = self.pendingSlice();
        if (std.mem.indexOf(u8, pending, bracketed_paste_end)) |idx| {
            if (idx > 0) {
                try on_event(ctx, .{ .paste = pending[0..idx] });
            }
            self.consume(idx + bracketed_paste_end.len);
            self.in_paste = false;
            return true;
        }

        if (self.pending_len > bracketed_paste_end.len) {
            const emit_len = self.pending_len - bracketed_paste_end.len;
            try on_event(ctx, .{ .paste = pending[0..emit_len] });
            self.consume(emit_len);
            return true;
        }

        return false;
    }

    fn processPlain(
        self: *InputDecoder,
        ctx: anytype,
        comptime on_event: fn (@TypeOf(ctx), InputEvent) anyerror!void,
    ) !bool {
        const byte = self.pending[0];
        if (controlAction(byte)) |action| {
            self.consume(1);
            try on_event(ctx, .{ .action = action });
            return true;
        }
        if (byte < 32 or byte == 0x7f) {
            self.consume(1);
            return true;
        }

        const text_len = utf8SequenceLength(byte);
        if (self.pending_len < text_len) return false;

        try on_event(ctx, .{ .text = self.pendingSlice()[0..text_len] });
        self.consume(text_len);
        return true;
    }

    fn processEscape(
        self: *InputDecoder,
        ctx: anytype,
        comptime on_event: fn (@TypeOf(ctx), InputEvent) anyerror!void,
    ) !void {
        const seq = self.pendingSlice();
        if (std.mem.eql(u8, seq, bracketed_paste_start)) {
            self.consume(bracketed_paste_start.len);
            self.in_paste = true;
            return;
        }
        if (std.mem.eql(u8, seq, bracketed_paste_end)) {
            self.consume(bracketed_paste_end.len);
            return;
        }
        if (std.mem.eql(u8, seq, "\x1b\r")) {
            self.consume(2);
            try on_event(ctx, .{ .action = .newline });
            return;
        }
        if (legacyEscapeAction(seq)) |action| {
            self.consume(seq.len);
            try on_event(ctx, .{ .action = action });
            return;
        }
        if (parseParameterizedCsiAction(seq)) |parsed| {
            self.consume(seq.len);
            if (parsed.event_type != 3) {
                try on_event(ctx, .{ .action = parsed.action });
            }
            return;
        }
        if (try decodeCsiU(seq, ctx, on_event)) {
            self.consume(seq.len);
            return;
        }
        if (parseModifyOtherKeys(seq)) |action| {
            self.consume(seq.len);
            try on_event(ctx, .{ .action = action });
            return;
        }

        self.consume(seq.len);
    }

    fn appendByte(self: *InputDecoder, byte: u8) !void {
        if (self.pending_len >= self.pending.len) return error.InputSequenceTooLong;
        self.pending[self.pending_len] = byte;
        self.pending_len += 1;
    }

    fn pendingSlice(self: *const InputDecoder) []const u8 {
        return self.pending[0..self.pending_len];
    }

    fn consume(self: *InputDecoder, len: usize) void {
        std.debug.assert(len <= self.pending_len);
        const remaining = self.pending_len - len;
        if (remaining > 0) {
            std.mem.copyForwards(u8, self.pending[0..remaining], self.pending[len..self.pending_len]);
        }
        self.pending_len = remaining;
    }
};

fn classifyEscape(seq: []const u8) SequenceStatus {
    std.debug.assert(seq.len > 0);
    std.debug.assert(seq[0] == 0x1b);

    if (seq.len == 1) return .incomplete;
    if (std.mem.startsWith(u8, InputDecoder.bracketed_paste_start, seq)) {
        return incompleteIfShort(seq, InputDecoder.bracketed_paste_start.len);
    }
    if (std.mem.startsWith(u8, InputDecoder.bracketed_paste_end, seq)) {
        return incompleteIfShort(seq, InputDecoder.bracketed_paste_end.len);
    }
    if (std.mem.eql(u8, seq, "\x1b\r")) return .complete;

    if (std.mem.startsWith(u8, seq, "\x1b[")) {
        const last = seq[seq.len - 1];
        if (last >= '@' and last <= '~') return .complete;
        return .incomplete;
    }

    if (std.mem.startsWith(u8, seq, "\x1bO")) {
        return incompleteIfShort(seq, 3);
    }

    return .complete;
}

fn incompleteIfShort(seq: []const u8, needed: usize) SequenceStatus {
    if (seq.len < needed) return .incomplete;
    return .complete;
}

fn controlAction(byte: u8) ?Action {
    return switch (byte) {
        '\r' => .submit,
        '\n' => .newline,
        0x7f, 0x08 => .backspace,
        0x0b => .delete_to_end,
        0x01 => .line_start,
        0x05 => .line_end,
        0x02 => .cursor_left,
        0x03 => .clear_input,
        0x06 => .cursor_right,
        0x10 => .cursor_up,
        0x0e => .cursor_down,
        0x04 => .end_of_transmission,
        else => null,
    };
}

fn legacyEscapeAction(seq: []const u8) ?Action {
    if (std.mem.eql(u8, seq, "\x1b[A") or std.mem.eql(u8, seq, "\x1bOA")) return .cursor_up;
    if (std.mem.eql(u8, seq, "\x1b[B") or std.mem.eql(u8, seq, "\x1bOB")) return .cursor_down;
    if (std.mem.eql(u8, seq, "\x1b[C") or std.mem.eql(u8, seq, "\x1bOC")) return .cursor_right;
    if (std.mem.eql(u8, seq, "\x1b[D") or std.mem.eql(u8, seq, "\x1bOD")) return .cursor_left;
    if (std.mem.eql(u8, seq, "\x1b[H") or std.mem.eql(u8, seq, "\x1bOH")) return .line_start;
    if (std.mem.eql(u8, seq, "\x1b[F") or std.mem.eql(u8, seq, "\x1bOF")) return .line_end;
    if (std.mem.eql(u8, seq, "\x1b[3~")) return .delete;
    return null;
}

fn parseParameterizedCsiAction(seq: []const u8) ?CsiActionSequence {
    if (!std.mem.startsWith(u8, seq, "\x1b[")) return null;
    if (seq.len < 4) return null;

    const final = seq[seq.len - 1];
    const body = seq[2 .. seq.len - 1];
    if (final == '~') return parseCsiTildeAction(body);
    if (final == 'A' or final == 'B' or final == 'C' or final == 'D' or final == 'H' or final == 'F') {
        return parseCsiCursorAction(body, final);
    }

    return null;
}

fn parseCsiCursorAction(body: []const u8, final: u8) ?CsiActionSequence {
    const action = switch (final) {
        'A' => Action.cursor_up,
        'B' => Action.cursor_down,
        'C' => Action.cursor_right,
        'D' => Action.cursor_left,
        'H' => Action.line_start,
        'F' => Action.line_end,
        else => return null,
    };

    const semi = std.mem.indexOfScalar(u8, body, ';');
    const first = if (semi) |idx| body[0..idx] else body;
    if (!std.mem.eql(u8, first, "1")) return null;

    const modifier_part = if (semi) |idx| blk: {
        if (std.mem.indexOfScalarPos(u8, body, idx + 1, ';') != null) return null;
        break :blk body[idx + 1 ..];
    } else "1";

    _ = parseFirstNumber(modifier_part) orelse return null;
    const event_type = parseNumberAt(modifier_part, 1) orelse 1;
    return .{ .action = action, .event_type = event_type };
}

fn parseCsiTildeAction(body: []const u8) ?CsiActionSequence {
    const semi = std.mem.indexOfScalar(u8, body, ';');
    const key_part = if (semi) |idx| body[0..idx] else body;
    const key = parseFirstNumber(key_part) orelse return null;

    const action = switch (key) {
        1, 7 => Action.line_start,
        3 => Action.delete,
        4, 8 => Action.line_end,
        else => return null,
    };

    const modifier_part = if (semi) |idx| blk: {
        if (std.mem.indexOfScalarPos(u8, body, idx + 1, ';') != null) return null;
        break :blk body[idx + 1 ..];
    } else "1";

    _ = parseFirstNumber(modifier_part) orelse return null;
    const event_type = parseNumberAt(modifier_part, 1) orelse 1;
    return .{ .action = action, .event_type = event_type };
}

fn decodeCsiU(
    seq: []const u8,
    ctx: anytype,
    comptime on_event: fn (@TypeOf(ctx), InputEvent) anyerror!void,
) !bool {
    const parsed = parseCsiU(seq) orelse return false;
    if (parsed.event_type == 3) return true;
    if (try emitCsiUPrintable(parsed, ctx, on_event)) return true;
    if (mapCsiUAction(parsed)) |action| {
        try on_event(ctx, .{ .action = action });
        return true;
    }
    return false;
}

fn emitCsiUPrintable(
    parsed: CsiUSequence,
    ctx: anytype,
    comptime on_event: fn (@TypeOf(ctx), InputEvent) anyerror!void,
) !bool {
    if (!(parsed.modifier == 1 or parsed.modifier == 2)) return false;
    if (parsed.codepoint < 32) return false;

    const printable = if (parsed.modifier == 2)
        parsed.shifted orelse parsed.codepoint
    else
        parsed.codepoint;
    if (printable < 32) return false;

    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(@intCast(printable), &buf) catch return false;
    try on_event(ctx, .{ .text = buf[0..len] });
    return true;
}

fn mapCsiUAction(parsed: CsiUSequence) ?Action {
    if (parsed.codepoint == 13 and (parsed.modifier == 2 or parsed.modifier == 5)) {
        return .newline;
    }
    if (parsed.modifier != 5) return null;

    const codepoint = parsed.base orelse parsed.codepoint;
    return switch (codepoint) {
        'a' => .line_start,
        'b' => .cursor_left,
        'c' => .clear_input,
        'd' => .end_of_transmission,
        'e' => .line_end,
        'f' => .cursor_right,
        'h' => .backspace,
        'j' => .newline,
        'k' => .delete_to_end,
        'n' => .cursor_down,
        'p' => .cursor_up,
        else => null,
    };
}

fn parseCsiU(seq: []const u8) ?CsiUSequence {
    if (!std.mem.startsWith(u8, seq, "\x1b[")) return null;
    if (seq.len < 4 or seq[seq.len - 1] != 'u') return null;

    const body = seq[2 .. seq.len - 1];
    const semi = std.mem.indexOfScalar(u8, body, ';');
    const code_part = if (semi) |idx| body[0..idx] else body;
    const modifier_part = if (semi) |idx| body[idx + 1 ..] else "1";

    const codepoint = parseFirstNumber(code_part) orelse return null;
    const shifted = parseNumberAt(code_part, 1);
    const base = parseNumberAt(code_part, 2);
    const modifier = parseFirstNumber(modifier_part) orelse 1;
    const event_type = parseNumberAt(modifier_part, 1) orelse 1;

    return .{
        .codepoint = codepoint,
        .shifted = shifted,
        .base = base,
        .modifier = modifier,
        .event_type = event_type,
    };
}

fn parseFirstNumber(part: []const u8) ?u32 {
    const end = std.mem.indexOfScalar(u8, part, ':') orelse part.len;
    if (end == 0) return null;
    return std.fmt.parseInt(u32, part[0..end], 10) catch null;
}

fn parseNumberAt(part: []const u8, index: usize) ?u32 {
    var iter = std.mem.splitScalar(u8, part, ':');
    var i: usize = 0;
    while (iter.next()) |segment| : (i += 1) {
        if (i != index) continue;
        if (segment.len == 0) return null;
        return std.fmt.parseInt(u32, segment, 10) catch null;
    }
    return null;
}

fn parseModifyOtherKeys(seq: []const u8) ?Action {
    if (!std.mem.startsWith(u8, seq, "\x1b[27;")) return null;
    if (seq.len < 8 or seq[seq.len - 1] != '~') return null;

    const body = seq[5 .. seq.len - 1];
    var iter = std.mem.splitScalar(u8, body, ';');
    const modifier = iter.next() orelse return null;
    const code = iter.next() orelse return null;
    if (iter.next() != null) return null;

    const modifier_value = std.fmt.parseInt(u32, modifier, 10) catch return null;
    const code_value = std.fmt.parseInt(u32, code, 10) catch return null;

    if (code_value == 13 and (modifier_value == 2 or modifier_value == 5)) return .newline;
    if (modifier_value != 5) return null;

    return switch (code_value) {
        'a' => .line_start,
        'b' => .cursor_left,
        'c' => .clear_input,
        'd' => .end_of_transmission,
        'e' => .line_end,
        'f' => .cursor_right,
        'h' => .backspace,
        'j' => .newline,
        'k' => .delete_to_end,
        'n' => .cursor_down,
        'p' => .cursor_up,
        else => null,
    };
}

fn utf8SequenceLength(first_byte: u8) usize {
    if ((first_byte & 0b1000_0000) == 0) return 1;
    if ((first_byte & 0b1110_0000) == 0b1100_0000) return 2;
    if ((first_byte & 0b1111_0000) == 0b1110_0000) return 3;
    if ((first_byte & 0b1111_1000) == 0b1111_0000) return 4;
    return 1;
}

const OwnedEvent = union(enum) {
    action: Action,
    text: []u8,
    paste: []u8,

    fn deinit(self: *OwnedEvent, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .action => {},
            .text => |value| allocator.free(value),
            .paste => |value| allocator.free(value),
        }
    }
};

const Collector = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(OwnedEvent),

    fn init(allocator: std.mem.Allocator) Collector {
        return .{ .allocator = allocator, .events = .{} };
    }

    fn deinit(self: *Collector) void {
        for (self.events.items) |*event| event.deinit(self.allocator);
        self.events.deinit(self.allocator);
    }

    fn onEvent(self: *Collector, event: InputEvent) !void {
        switch (event) {
            .action => |value| try self.events.append(self.allocator, .{ .action = value }),
            .text => |value| try self.events.append(self.allocator, .{ .text = try self.allocator.dupe(u8, value) }),
            .paste => |value| try self.events.append(self.allocator, .{ .paste = try self.allocator.dupe(u8, value) }),
        }
    }
};

test "decoder merges fragmented legacy arrow sequence" {
    var decoder = InputDecoder{};
    var collector = Collector.init(std.testing.allocator);
    defer collector.deinit();

    try decoder.pushBytes("\x1b", &collector, Collector.onEvent);
    try decoder.pushBytes("[", &collector, Collector.onEvent);
    try decoder.pushBytes("C", &collector, Collector.onEvent);

    try std.testing.expectEqual(@as(usize, 1), collector.events.items.len);
    try std.testing.expectEqual(Action.cursor_right, collector.events.items[0].action);
}

test "decoder maps ctrl+j and shift+enter newlines" {
    var decoder = InputDecoder{};
    var collector = Collector.init(std.testing.allocator);
    defer collector.deinit();

    try decoder.pushBytes("\n", &collector, Collector.onEvent);
    try decoder.pushBytes("\x1b[13;2u", &collector, Collector.onEvent);
    try decoder.pushBytes("\x1b[27;5;13~", &collector, Collector.onEvent);

    try std.testing.expectEqual(@as(usize, 3), collector.events.items.len);
    try std.testing.expectEqual(Action.newline, collector.events.items[0].action);
    try std.testing.expectEqual(Action.newline, collector.events.items[1].action);
    try std.testing.expectEqual(Action.newline, collector.events.items[2].action);
}

test "decoder maps ctrl+b and ctrl+f navigation" {
    var decoder = InputDecoder{};
    var collector = Collector.init(std.testing.allocator);
    defer collector.deinit();

    try decoder.pushBytes("\x1b[98;5u", &collector, Collector.onEvent);
    try decoder.pushBytes("\x1b[27;5;102~", &collector, Collector.onEvent);

    try std.testing.expectEqual(@as(usize, 2), collector.events.items.len);
    try std.testing.expectEqual(Action.cursor_left, collector.events.items[0].action);
    try std.testing.expectEqual(Action.cursor_right, collector.events.items[1].action);
}

test "decoder maps ctrl+k and ctrl+c editing actions" {
    var decoder = InputDecoder{};
    var collector = Collector.init(std.testing.allocator);
    defer collector.deinit();

    try decoder.pushBytes("\x0b", &collector, Collector.onEvent);
    try decoder.pushBytes("\x03", &collector, Collector.onEvent);
    try decoder.pushBytes("\x1b[107;5u", &collector, Collector.onEvent);
    try decoder.pushBytes("\x1b[27;5;99~", &collector, Collector.onEvent);

    try std.testing.expectEqual(@as(usize, 4), collector.events.items.len);
    try std.testing.expectEqual(Action.delete_to_end, collector.events.items[0].action);
    try std.testing.expectEqual(Action.clear_input, collector.events.items[1].action);
    try std.testing.expectEqual(Action.delete_to_end, collector.events.items[2].action);
    try std.testing.expectEqual(Action.clear_input, collector.events.items[3].action);
}

test "decoder emits bracketed paste without submit actions" {
    var decoder = InputDecoder{};
    var collector = Collector.init(std.testing.allocator);
    defer collector.deinit();

    try decoder.pushBytes("\x1b[200~hello\nworld", &collector, Collector.onEvent);
    try decoder.pushBytes("\x1b[201~", &collector, Collector.onEvent);

    var pasted: std.ArrayList(u8) = .{};
    defer pasted.deinit(std.testing.allocator);

    for (collector.events.items) |event| {
        switch (event) {
            .paste => |value| try pasted.appendSlice(std.testing.allocator, value),
            else => return error.UnexpectedInputEvent,
        }
    }

    try std.testing.expectEqualStrings("hello\nworld", pasted.items);
}

test "decoder supports kitty printable text sequences" {
    var decoder = InputDecoder{};
    var collector = Collector.init(std.testing.allocator);
    defer collector.deinit();

    try decoder.pushBytes("\x1b[97u", &collector, Collector.onEvent);
    try decoder.pushBytes("\x1b[47:63;2u", &collector, Collector.onEvent);

    try std.testing.expectEqual(@as(usize, 2), collector.events.items.len);
    try std.testing.expectEqualStrings("a", collector.events.items[0].text);
    try std.testing.expectEqualStrings("?", collector.events.items[1].text);
}

test "decoder ignores kitty key release events" {
    var decoder = InputDecoder{};
    var collector = Collector.init(std.testing.allocator);
    defer collector.deinit();

    try decoder.pushBytes("\x1b[104;1u", &collector, Collector.onEvent);
    try decoder.pushBytes("\x1b[104;1:3u", &collector, Collector.onEvent);

    try std.testing.expectEqual(@as(usize, 1), collector.events.items.len);
    try std.testing.expectEqualStrings("h", collector.events.items[0].text);
}

test "decoder maps parameterized csi arrow sequences" {
    var decoder = InputDecoder{};
    var collector = Collector.init(std.testing.allocator);
    defer collector.deinit();

    try decoder.pushBytes("\x1b[1;1A", &collector, Collector.onEvent);
    try decoder.pushBytes("\x1b[1;1B", &collector, Collector.onEvent);
    try decoder.pushBytes("\x1b[1;1C", &collector, Collector.onEvent);
    try decoder.pushBytes("\x1b[1;1D", &collector, Collector.onEvent);

    try std.testing.expectEqual(@as(usize, 4), collector.events.items.len);
    try std.testing.expectEqual(Action.cursor_up, collector.events.items[0].action);
    try std.testing.expectEqual(Action.cursor_down, collector.events.items[1].action);
    try std.testing.expectEqual(Action.cursor_right, collector.events.items[2].action);
    try std.testing.expectEqual(Action.cursor_left, collector.events.items[3].action);
}

test "decoder ignores parameterized csi release events" {
    var decoder = InputDecoder{};
    var collector = Collector.init(std.testing.allocator);
    defer collector.deinit();

    try decoder.pushBytes("\x1b[1;1:1A", &collector, Collector.onEvent);
    try decoder.pushBytes("\x1b[1;1:3A", &collector, Collector.onEvent);

    try std.testing.expectEqual(@as(usize, 1), collector.events.items.len);
    try std.testing.expectEqual(Action.cursor_up, collector.events.items[0].action);
}
