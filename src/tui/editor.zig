const std = @import("std");
const component_mod = @import("component.zig");
const input_mod = @import("input.zig");
const lines_util = @import("lines_util.zig");
const viewport_mod = @import("viewport.zig");

const Allocator = std.mem.Allocator;
const Component = component_mod.Component;
const InputAction = input_mod.Action;
const InputEvent = input_mod.InputEvent;
const Position = viewport_mod.Position;

const VisualRow = struct {
    start: usize,
    end: usize,
    prefix_width: usize,
};

pub const Editor = struct {
    allocator: Allocator,
    buffer: std.ArrayList(u8),
    cursor_pos: usize = 0,
    prompt: []const u8,
    history: std.ArrayList([]u8),
    history_index: ?usize = null,
    draft_before_history: ?[]u8 = null,
    preferred_column: ?usize = null,
    cached_width: ?u16 = null,
    cached_lines: ?[][]const u8 = null,
    cached_rows: ?[]VisualRow = null,
    cached_cursor: ?Position = null,
    cached_cursor_row: ?usize = null,

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
        self.freeHistoryBrowseState();
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
        self.preferred_column = null;
        self.freeHistoryBrowseState();
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
        self.preferred_column = null;
        self.freeHistoryBrowseState();
        self.invalidate();
    }

    pub fn cursorPosition(self: *Editor, width: u16) !Position {
        try self.ensureLayout(width);
        return self.cached_cursor orelse .{ .x = 0, .y = 0 };
    }

    pub fn invalidate(self: *Editor) void {
        freeCached(self);
        self.cached_width = null;
    }

    fn renderImpl(ptr: *anyopaque, width: u16, allocator: Allocator) ![][]const u8 {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        std.debug.assert(width > 0);
        try self.ensureLayout(width);
        return lines_util.cloneLines(allocator, self.cached_lines.?);
    }

    fn handleInputImpl(ptr: *anyopaque, event: InputEvent) !bool {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        return try self.handleInput(event);
    }

    pub fn handleInput(self: *Editor, event: InputEvent) !bool {
        switch (event) {
            .text => |value| {
                try self.insertSlice(value);
                return true;
            },
            .paste => |value| {
                try self.insertSlice(value);
                return true;
            },
            .action => |action| return try self.handleAction(action),
        }
    }

    fn handleAction(self: *Editor, action: InputAction) !bool {
        switch (action) {
            .submit, .end_of_transmission => return false,
            .newline => try self.insertSlice("\n"),
            .backspace => self.deleteBackward(),
            .delete => self.deleteForward(),
            .delete_to_end => self.deleteToEnd(),
            .cursor_left => self.moveLeft(),
            .cursor_right => self.moveRight(),
            .cursor_up => try self.moveVertical(-1),
            .cursor_down => try self.moveVertical(1),
            .line_start => self.moveToLineStart(),
            .line_end => self.moveToLineEnd(),
            .clear_input => self.clear(),
        }
        return true;
    }

    fn insertSlice(self: *Editor, value: []const u8) !void {
        if (value.len == 0) return;
        self.leaveHistoryBrowse();
        try self.buffer.insertSlice(self.allocator, self.cursor_pos, value);
        self.cursor_pos += value.len;
        self.preferred_column = null;
        self.invalidate();
    }

    fn deleteBackward(self: *Editor) void {
        if (self.cursor_pos == 0) return;
        self.leaveHistoryBrowse();
        const start = previousCodepointStart(self.buffer.items, self.cursor_pos);
        deleteRange(self, start, self.cursor_pos);
        self.cursor_pos = start;
        self.preferred_column = null;
        self.invalidate();
    }

    fn deleteForward(self: *Editor) void {
        if (self.cursor_pos >= self.buffer.items.len) return;
        self.leaveHistoryBrowse();
        const end = nextCodepointEnd(self.buffer.items, self.cursor_pos);
        deleteRange(self, self.cursor_pos, end);
        self.preferred_column = null;
        self.invalidate();
    }

    fn deleteToEnd(self: *Editor) void {
        if (self.cursor_pos >= self.buffer.items.len) return;
        self.leaveHistoryBrowse();
        deleteRange(self, self.cursor_pos, self.buffer.items.len);
        self.preferred_column = null;
        self.invalidate();
    }

    fn moveLeft(self: *Editor) void {
        if (self.cursor_pos == 0) return;
        self.cursor_pos = previousCodepointStart(self.buffer.items, self.cursor_pos);
        self.preferred_column = null;
        self.invalidate();
    }

    fn moveRight(self: *Editor) void {
        if (self.cursor_pos >= self.buffer.items.len) return;
        self.cursor_pos = nextCodepointEnd(self.buffer.items, self.cursor_pos);
        self.preferred_column = null;
        self.invalidate();
    }

    fn moveToLineStart(self: *Editor) void {
        self.cursor_pos = lineStart(self.buffer.items, self.cursor_pos);
        self.preferred_column = null;
        self.invalidate();
    }

    fn moveToLineEnd(self: *Editor) void {
        self.cursor_pos = lineEnd(self.buffer.items, self.cursor_pos);
        self.preferred_column = null;
        self.invalidate();
    }

    fn moveVertical(self: *Editor, delta: i8) !void {
        const width = self.cached_width orelse 80;
        try self.ensureLayout(width);

        const rows = self.cached_rows orelse return;
        const current_row = self.cached_cursor_row orelse 0;
        if (delta < 0 and current_row == 0) {
            try self.moveHistoryUp();
            return;
        }
        if (delta > 0 and current_row + 1 >= rows.len) {
            try self.moveHistoryDown();
            return;
        }

        const current_column = currentContentColumn(self, rows[current_row]);
        if (self.preferred_column == null) self.preferred_column = current_column;

        const target_row = if (delta < 0) current_row - 1 else current_row + 1;
        self.cursor_pos = cursorForColumn(self.buffer.items, rows[target_row], self.preferred_column.?);
        self.invalidate();
    }

    fn moveHistoryUp(self: *Editor) !void {
        if (self.history.items.len == 0) return;

        if (self.history_index) |idx| {
            if (idx == 0) return;
            self.history_index = idx - 1;
        } else {
            try self.captureDraftBeforeHistory();
            self.history_index = self.history.items.len - 1;
        }

        try self.loadHistoryAt(self.history_index.?);
    }

    fn moveHistoryDown(self: *Editor) !void {
        const idx = self.history_index orelse return;
        if (idx + 1 >= self.history.items.len) {
            self.history_index = null;
            self.restoreDraftBeforeHistory();
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
        self.preferred_column = null;
        self.invalidate();
    }

    fn captureDraftBeforeHistory(self: *Editor) !void {
        self.freeHistoryBrowseState();
        self.draft_before_history = try self.allocator.dupe(u8, self.buffer.items);
    }

    fn restoreDraftBeforeHistory(self: *Editor) void {
        const draft = self.draft_before_history orelse {
            self.clear();
            return;
        };
        self.buffer.clearRetainingCapacity();
        self.buffer.appendSlice(self.allocator, draft) catch unreachable;
        self.cursor_pos = self.buffer.items.len;
        self.preferred_column = null;
        self.allocator.free(draft);
        self.draft_before_history = null;
        self.invalidate();
    }

    fn leaveHistoryBrowse(self: *Editor) void {
        self.history_index = null;
        self.freeHistoryBrowseState();
    }

    fn freeHistoryBrowseState(self: *Editor) void {
        if (self.draft_before_history) |draft| {
            self.allocator.free(draft);
            self.draft_before_history = null;
        }
    }

    fn ensureLayout(self: *Editor, width: u16) !void {
        if (self.cached_width) |cached_width| {
            if (cached_width == width and self.cached_lines != null and self.cached_rows != null) return;
        }
        try self.rebuildLayout(width);
    }

    fn rebuildLayout(self: *Editor, width: u16) !void {
        std.debug.assert(width > 0);

        var lines: std.ArrayList([]const u8) = .{};
        var rows: std.ArrayList(VisualRow) = .{};
        errdefer {
            for (lines.items) |line| self.allocator.free(line);
            lines.deinit(self.allocator);
            rows.deinit(self.allocator);
        }

        const prompt_width = displayWidth(self.prompt);
        const content_width = computeContentWidth(width, prompt_width);
        const continuation = try continuationPrefix(self.allocator, prompt_width);
        defer self.allocator.free(continuation);

        var line_start_idx: usize = 0;
        var is_first_logical = true;
        while (true) {
            const line_end_idx = std.mem.indexOfScalarPos(
                u8,
                self.buffer.items,
                line_start_idx,
                '\n',
            ) orelse self.buffer.items.len;
            try appendLogicalLine(
                self,
                &lines,
                &rows,
                self.buffer.items[line_start_idx..line_end_idx],
                line_start_idx,
                content_width,
                continuation,
                is_first_logical,
            );
            is_first_logical = false;
            if (line_end_idx == self.buffer.items.len) break;
            line_start_idx = line_end_idx + 1;
        }

        if (rows.items.len == 0) {
            try appendRenderedRow(self, &lines, &rows, self.prompt, 0, 0);
        }

        const cursor_info = findCursor(self.buffer.items, rows.items, self.cursor_pos);

        freeCached(self);
        self.cached_lines = try lines.toOwnedSlice(self.allocator);
        self.cached_rows = try rows.toOwnedSlice(self.allocator);
        self.cached_width = width;
        self.cached_cursor = cursor_info.position;
        self.cached_cursor_row = cursor_info.row;
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

const CursorInfo = struct {
    position: Position,
    row: usize,
};

fn appendLogicalLine(
    self: *Editor,
    lines: *std.ArrayList([]const u8),
    rows: *std.ArrayList(VisualRow),
    logical: []const u8,
    logical_start: usize,
    content_width: usize,
    continuation: []const u8,
    is_first_logical: bool,
) !void {
    if (logical.len == 0) {
        const prefix = if (is_first_logical) self.prompt else continuation;
        try appendRenderedRow(self, lines, rows, prefix, logical_start, logical_start);
        return;
    }

    var segment_start: usize = 0;
    var first_segment = true;
    while (segment_start < logical.len) {
        const segment_end = nextWrapBoundary(logical, segment_start, content_width);
        const prefix = if (first_segment and is_first_logical) self.prompt else continuation;
        try appendRenderedRow(
            self,
            lines,
            rows,
            prefix,
            logical_start + segment_start,
            logical_start + segment_end,
        );
        segment_start = segment_end;
        first_segment = false;
    }
}

fn appendRenderedRow(
    self: *Editor,
    lines: *std.ArrayList([]const u8),
    rows: *std.ArrayList(VisualRow),
    prefix: []const u8,
    start: usize,
    end: usize,
) !void {
    const rendered = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{
        prefix,
        self.buffer.items[start..end],
    });
    try lines.append(self.allocator, rendered);
    try rows.append(self.allocator, .{
        .start = start,
        .end = end,
        .prefix_width = displayWidth(prefix),
    });
}

fn continuationPrefix(allocator: Allocator, width: usize) ![]u8 {
    const prefix = try allocator.alloc(u8, width);
    @memset(prefix, ' ');
    return prefix;
}

fn computeContentWidth(width: u16, prompt_width: usize) usize {
    if (prompt_width >= width) return 1;
    return @as(usize, width) - prompt_width;
}

fn nextWrapBoundary(line: []const u8, start: usize, max_width: usize) usize {
    std.debug.assert(max_width > 0);
    var idx = start;
    var used_width: usize = 0;
    while (idx < line.len) {
        const next = nextCodepointEnd(line, idx);
        const cp_width = displayWidth(line[idx..next]);
        if (used_width > 0 and used_width + cp_width > max_width) break;
        if (used_width == 0 and cp_width > max_width) return next;
        used_width += cp_width;
        idx = next;
    }
    return if (idx > start) idx else nextCodepointEnd(line, start);
}

fn findCursor(buffer: []const u8, rows: []const VisualRow, cursor_pos: usize) CursorInfo {
    std.debug.assert(cursor_pos <= buffer.len);
    for (rows, 0..) |row, index| {
        if (cursor_pos < row.start or cursor_pos > row.end) continue;
        const content_col = displayWidth(buffer[row.start..cursor_pos]);
        return .{
            .position = .{
                .x = saturatingU16(row.prefix_width + content_col),
                .y = saturatingU16(index),
            },
            .row = index,
        };
    }

    const fallback_row = rows.len - 1;
    const last = rows[fallback_row];
    return .{
        .position = .{
            .x = saturatingU16(last.prefix_width + displayWidth(buffer[last.start..last.end])),
            .y = saturatingU16(fallback_row),
        },
        .row = fallback_row,
    };
}

fn currentContentColumn(self: *const Editor, row: VisualRow) usize {
    std.debug.assert(self.cursor_pos >= row.start);
    std.debug.assert(self.cursor_pos <= row.end);
    return displayWidth(self.buffer.items[row.start..self.cursor_pos]);
}

fn cursorForColumn(buffer: []const u8, row: VisualRow, target_column: usize) usize {
    var idx = row.start;
    var used_width: usize = 0;
    while (idx < row.end) {
        const next = nextCodepointEnd(buffer, idx);
        const cp_width = displayWidth(buffer[idx..next]);
        if (used_width + cp_width > target_column) break;
        used_width += cp_width;
        idx = next;
    }
    return idx;
}

fn lineStart(buffer: []const u8, cursor_pos: usize) usize {
    var idx = cursor_pos;
    while (idx > 0) {
        if (buffer[idx - 1] == '\n') break;
        idx -= 1;
    }
    return idx;
}

fn lineEnd(buffer: []const u8, cursor_pos: usize) usize {
    var idx = cursor_pos;
    while (idx < buffer.len and buffer[idx] != '\n') : (idx += 1) {}
    return idx;
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

fn nextCodepointEnd(data: []const u8, cursor_pos: usize) usize {
    std.debug.assert(cursor_pos <= data.len);
    if (cursor_pos >= data.len) return data.len;

    const seq_len = std.unicode.utf8ByteSequenceLength(data[cursor_pos]) catch return cursor_pos + 1;
    const end = cursor_pos + seq_len;
    if (end > data.len) return cursor_pos + 1;
    _ = std.unicode.utf8Decode(data[cursor_pos..end]) catch return cursor_pos + 1;
    return end;
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

fn saturatingU16(value: usize) u16 {
    return std.math.cast(u16, value) orelse std.math.maxInt(u16);
}

fn freeCached(self: *Editor) void {
    lines_util.freeOptionalLines(self.allocator, self.cached_lines);
    self.cached_lines = null;
    if (self.cached_rows) |rows| self.allocator.free(rows);
    self.cached_rows = null;
    self.cached_cursor = null;
    self.cached_cursor_row = null;
}

test "editor supports multiline navigation and newline insertion" {
    var editor = Editor.init(std.testing.allocator, "> ");
    defer editor.deinit();

    try std.testing.expect(try editor.handleInput(.{ .text = "ab" }));
    try std.testing.expect(try editor.handleInput(.{ .action = .newline }));
    try std.testing.expect(try editor.handleInput(.{ .text = "cd" }));
    try std.testing.expectEqualStrings("ab\ncd", editor.getText());

    try std.testing.expect(try editor.handleInput(.{ .action = .cursor_left }));
    try std.testing.expect(try editor.handleInput(.{ .action = .cursor_left }));
    try std.testing.expect(try editor.handleInput(.{ .action = .cursor_up }));
    try std.testing.expectEqual(@as(usize, 0), editor.cursor_pos);
}

test "editor preserves draft when leaving history browse" {
    var editor = Editor.init(std.testing.allocator, "> ");
    defer editor.deinit();

    try editor.setText("draft\ntext");
    try editor.history.append(editor.allocator, try editor.allocator.dupe(u8, "saved"));
    try editor.moveHistoryUp();
    try std.testing.expectEqualStrings("saved", editor.getText());

    try editor.moveHistoryDown();
    try std.testing.expectEqualStrings("draft\ntext", editor.getText());
}

test "editor cursor position tracks wrapped rows" {
    var editor = Editor.init(std.testing.allocator, "> ");
    defer editor.deinit();

    try editor.setText("abcdef");
    const cursor = try editor.cursorPosition(5);
    try std.testing.expectEqual(@as(u16, 1), cursor.y);
    try std.testing.expectEqual(@as(u16, 5), cursor.x);
}

test "editor paste inserts multiline content verbatim" {
    var editor = Editor.init(std.testing.allocator, "> ");
    defer editor.deinit();

    try std.testing.expect(try editor.handleInput(.{ .paste = "hello\nworld" }));
    try std.testing.expectEqualStrings("hello\nworld", editor.getText());
}

test "editor supports delete-to-end and clear-input actions" {
    var editor = Editor.init(std.testing.allocator, "> ");
    defer editor.deinit();

    try editor.setText("abcdef");
    try std.testing.expect(try editor.handleInput(.{ .action = .cursor_left }));
    try std.testing.expect(try editor.handleInput(.{ .action = .cursor_left }));
    try std.testing.expect(try editor.handleInput(.{ .action = .delete_to_end }));
    try std.testing.expectEqualStrings("abcd", editor.getText());
    try std.testing.expectEqual(@as(usize, 4), editor.cursor_pos);

    try std.testing.expect(try editor.handleInput(.{ .action = .clear_input }));
    try std.testing.expectEqualStrings("", editor.getText());
    try std.testing.expectEqual(@as(usize, 0), editor.cursor_pos);
}
