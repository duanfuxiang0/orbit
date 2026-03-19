const std = @import("std");
const component_mod = @import("component.zig");
const lines_util = @import("lines_util.zig");

const Allocator = std.mem.Allocator;
const Component = component_mod.Component;

pub const Editor = struct {
    allocator: Allocator,
    buffer: std.ArrayList(u8),
    cursor_pos: usize = 0,
    prompt: []const u8,
    history: std.ArrayList([]u8),
    history_index: ?usize = null,
    cached_width: ?u16 = null,
    cached_lines: ?[][]const u8 = null,

    pub fn init(allocator: Allocator, prompt: []const u8) Editor {
        return .{
            .allocator = allocator,
            .buffer = .{},
            .prompt = prompt,
            .history = .{},
        };
    }

    pub fn deinit(self: *Editor) void {
        self.buffer.deinit(self.allocator);
        for (self.history.items) |entry| {
            self.allocator.free(entry);
        }
        self.history.deinit(self.allocator);
        freeCached(self);
    }

    pub fn component(self: *Editor) Component {
        return .{
            .ptr = self,
            .vtable = &.{
                .render = renderImpl,
                .handle_input = handleInputImpl,
                .invalidate = invalidateImpl,
                .deinit = deinitImpl,
            },
        };
    }

    pub fn getText(self: *const Editor) []const u8 {
        return self.buffer.items;
    }

    pub fn clear(self: *Editor) void {
        self.buffer.clearRetainingCapacity();
        self.cursor_pos = 0;
        self.history_index = null;
        self.invalidate();
    }

    pub fn pushHistory(self: *Editor) !void {
        if (self.buffer.items.len == 0) return;
        const item = try self.allocator.dupe(u8, self.buffer.items);
        try self.history.append(self.allocator, item);
        self.history_index = null;
    }

    pub fn setText(self: *Editor, text: []const u8) !void {
        self.buffer.clearRetainingCapacity();
        try self.buffer.appendSlice(self.allocator, text);
        self.cursor_pos = self.buffer.items.len;
        self.history_index = null;
        self.invalidate();
    }

    pub fn cursorColumn(self: *const Editor) u16 {
        std.debug.assert(self.cursor_pos <= self.buffer.items.len);
        const prompt_width = displayWidth(self.prompt);
        const input_width = displayWidth(self.buffer.items[0..self.cursor_pos]);
        const total = prompt_width + input_width;
        if (total > std.math.maxInt(u16)) return std.math.maxInt(u16);
        return @intCast(total);
    }

    pub fn invalidate(self: *Editor) void {
        freeCached(self);
        self.cached_width = null;
    }

    fn renderImpl(ptr: *anyopaque, width: u16, allocator: Allocator) ![][]const u8 {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        std.debug.assert(width > 0);

        if (self.cached_width) |cached_width| {
            if (cached_width == width) {
                if (self.cached_lines) |lines| {
                    return lines_util.cloneLines(allocator, lines);
                }
            }
        }

        const rendered = try allocator.alloc([]const u8, 1);
        errdefer allocator.free(rendered);
        rendered[0] = try std.fmt.allocPrint(allocator, "{s}{s}", .{ self.prompt, self.buffer.items });

        freeCached(self);
        self.cached_lines = try lines_util.cloneLines(self.allocator, rendered);
        self.cached_width = width;
        return rendered;
    }

    fn handleInputImpl(ptr: *anyopaque, data: []const u8) !bool {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        return try self.handleInput(data);
    }

    pub fn handleInput(self: *Editor, data: []const u8) !bool {
        if (std.mem.eql(u8, data, "\x7f")) {
            if (self.cursor_pos == 0) return true;
            const start = previousCodepointStart(self.buffer.items, self.cursor_pos);
            deleteRange(self, start, self.cursor_pos);
            self.cursor_pos = start;
            self.invalidate();
            return true;
        }

        if (std.mem.eql(u8, data, "\x01")) {
            self.cursor_pos = 0;
            self.invalidate();
            return true;
        }

        if (std.mem.eql(u8, data, "\x05")) {
            self.cursor_pos = self.buffer.items.len;
            self.invalidate();
            return true;
        }

        if (std.mem.eql(u8, data, "\x1b[A")) {
            try self.moveHistoryUp();
            return true;
        }

        if (std.mem.eql(u8, data, "\x1b[B")) {
            try self.moveHistoryDown();
            return true;
        }

        if (!isPrintable(data)) return false;

        try self.buffer.insertSlice(self.allocator, self.cursor_pos, data);
        self.cursor_pos += data.len;
        self.invalidate();
        return true;
    }

    fn moveHistoryUp(self: *Editor) !void {
        if (self.history.items.len == 0) return;

        if (self.history_index) |idx| {
            if (idx == 0) return;
            self.history_index = idx - 1;
        } else {
            self.history_index = self.history.items.len - 1;
        }

        try self.loadHistoryAt(self.history_index.?);
    }

    fn moveHistoryDown(self: *Editor) !void {
        const idx = self.history_index orelse return;
        if (idx + 1 >= self.history.items.len) {
            self.history_index = null;
            self.clear();
            return;
        }

        self.history_index = idx + 1;
        try self.loadHistoryAt(self.history_index.?);
    }

    fn loadHistoryAt(self: *Editor, idx: usize) !void {
        std.debug.assert(idx < self.history.items.len);
        self.buffer.clearRetainingCapacity();
        try self.buffer.appendSlice(self.allocator, self.history.items[idx]);
        self.cursor_pos = self.buffer.items.len;
        self.invalidate();
    }

    fn invalidateImpl(ptr: *anyopaque) void {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        self.invalidate();
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

fn isPrintable(data: []const u8) bool {
    if (data.len == 0) return false;
    for (data) |ch| {
        if (ch < 32) return false;
    }
    return true;
}

fn previousCodepointStart(data: []const u8, cursor_pos: usize) usize {
    std.debug.assert(cursor_pos <= data.len);
    if (cursor_pos == 0) return 0;

    var start = cursor_pos - 1;
    while (start > 0 and isUtf8ContinuationByte(data[start])) : (start -= 1) {}

    const seq_len = std.unicode.utf8ByteSequenceLength(data[start]) catch return cursor_pos - 1;
    if (start + seq_len != cursor_pos) return cursor_pos - 1;
    _ = std.unicode.utf8Decode(data[start..cursor_pos]) catch return cursor_pos - 1;
    return start;
}

fn isUtf8ContinuationByte(byte: u8) bool {
    return (byte & 0b1100_0000) == 0b1000_0000;
}

fn deleteRange(self: *Editor, start: usize, end: usize) void {
    std.debug.assert(start <= end);
    std.debug.assert(end <= self.buffer.items.len);

    const tail_len = self.buffer.items.len - end;
    std.mem.copyForwards(
        u8,
        self.buffer.items[start .. start + tail_len],
        self.buffer.items[end..],
    );
    self.buffer.items.len -= end - start;
}

fn displayWidth(text: []const u8) usize {
    var total: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            total += 1;
            i += 1;
            continue;
        };
        if (i + seq_len > text.len) {
            total += 1;
            break;
        }

        const cp = std.unicode.utf8Decode(text[i .. i + seq_len]) catch {
            total += 1;
            i += 1;
            continue;
        };
        total += codepointDisplayWidth(cp);
        i += seq_len;
    }
    return total;
}

fn codepointDisplayWidth(cp: u21) usize {
    if (cp == 0) return 0;
    if (cp < 32) return 0;
    if (cp >= 0x7f and cp < 0xa0) return 0;
    if (isZeroWidthCodepoint(cp)) return 0;
    if (isWideCodepoint(cp)) return 2;
    return 1;
}

fn isZeroWidthCodepoint(cp: u21) bool {
    if (cp == 0x00ad or cp == 0x034f) return true;
    if (cp == 0x200b or cp == 0x200c or cp == 0x200d) return true;
    if (cp == 0x2060 or cp == 0xfeff) return true;
    if (cp >= 0x0300 and cp <= 0x036f) return true;
    if (cp >= 0x1ab0 and cp <= 0x1aff) return true;
    if (cp >= 0x1dc0 and cp <= 0x1dff) return true;
    if (cp >= 0x20d0 and cp <= 0x20ff) return true;
    if (cp >= 0xfe00 and cp <= 0xfe0f) return true;
    if (cp >= 0xfe20 and cp <= 0xfe2f) return true;
    if (cp >= 0xe0100 and cp <= 0xe01ef) return true;
    return false;
}

fn isWideCodepoint(cp: u21) bool {
    if (cp < 0x1100) return false;
    if (cp <= 0x115f) return true;
    if (cp == 0x2329 or cp == 0x232a) return true;
    if (cp >= 0x2e80 and cp <= 0xa4cf and cp != 0x303f) return true;
    if (cp >= 0xac00 and cp <= 0xd7a3) return true;
    if (cp >= 0xf900 and cp <= 0xfaff) return true;
    if (cp >= 0xfe10 and cp <= 0xfe19) return true;
    if (cp >= 0xfe30 and cp <= 0xfe6f) return true;
    if (cp >= 0xff00 and cp <= 0xff60) return true;
    if (cp >= 0xffe0 and cp <= 0xffe6) return true;
    if (cp >= 0x1f300 and cp <= 0x1f64f) return true;
    if (cp >= 0x1f900 and cp <= 0x1f9ff) return true;
    if (cp >= 0x20000 and cp <= 0x2fffd) return true;
    if (cp >= 0x30000 and cp <= 0x3fffd) return true;
    return false;
}

fn freeCached(self: *Editor) void {
    lines_util.freeOptionalLines(self.allocator, self.cached_lines);
    self.cached_lines = null;
}

test "editor inserts and removes text" {
    var editor = Editor.init(std.testing.allocator, "> ");
    defer editor.deinit();

    try std.testing.expect(try editor.handleInput("abc"));
    try std.testing.expectEqualStrings("abc", editor.getText());

    try std.testing.expect(try editor.handleInput("\x7f"));
    try std.testing.expectEqualStrings("ab", editor.getText());
}

test "editor backspace removes full utf8 codepoint" {
    var editor = Editor.init(std.testing.allocator, "> ");
    defer editor.deinit();

    try std.testing.expect(try editor.handleInput("\xE4\xBD\xA0"));
    try std.testing.expectEqualStrings("\xE4\xBD\xA0", editor.getText());

    try std.testing.expect(try editor.handleInput("\x7f"));
    try std.testing.expectEqualStrings("", editor.getText());
    try std.testing.expectEqual(@as(usize, 0), editor.cursor_pos);
}

test "editor cursor column uses display width for utf8 text" {
    var editor = Editor.init(std.testing.allocator, "> ");
    defer editor.deinit();

    try editor.setText("\xE4\xBD\xA0a");
    try std.testing.expectEqual(@as(u16, 5), editor.cursorColumn());

    editor.cursor_pos = 3;
    try std.testing.expectEqual(@as(u16, 4), editor.cursorColumn());
}

test "editor history load propagates allocator failure" {
    var storage: [256]u8 = [_]u8{0} ** 256;
    var backing = std.heap.FixedBufferAllocator.init(&storage);
    var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = 2 });

    var editor = Editor.init(failing.allocator(), "> ");
    defer editor.deinit();

    try editor.history.append(editor.allocator, try editor.allocator.dupe(u8, "saved"));
    try std.testing.expectError(error.OutOfMemory, editor.moveHistoryUp());
}
