const std = @import("std");
const terminal = @import("terminal.zig");

const Allocator = std.mem.Allocator;
const LINE_RESET = "\x1b[0m";

const ChangedRange = struct {
    first: usize,
    last: usize,
};

const RenderMode = enum {
    no_change,
    diff,
    append_only,
};

pub const InlineRenderer = struct {
    allocator: Allocator,
    writer: std.fs.File,
    backbuffer: std.ArrayList([]u8),
    last_cursor_row: u16 = 0,
    last_width: u16 = 0,
    max_lines_rendered: u32 = 0,

    pub fn init(allocator: Allocator, writer: std.fs.File) InlineRenderer {
        return .{
            .allocator = allocator,
            .writer = writer,
            .backbuffer = .{},
        };
    }

    pub fn deinit(self: *InlineRenderer) void {
        self.clearBackbuffer();
        self.backbuffer.deinit(self.allocator);
    }

    /// Render lines to terminal with diff against backbuffer.
    /// cursor_row/cursor_col specify where the cursor should end up.
    pub fn render(
        self: *InlineRenderer,
        lines: []const []const u8,
        cursor_row: u16,
        cursor_col: u16,
    ) !void {
        assertCursorInBounds(lines.len, cursor_row);
        self.refreshWidth();

        const old_len = self.backbuffer.items.len;
        const new_len = lines.len;
        const max_len = @max(old_len, new_len);
        const changed = findChangedRange(self.backbuffer.items, lines);

        var mode: RenderMode = .no_change;
        var range: ChangedRange = .{ .first = 0, .last = 0 };
        if (changed) |base_range| {
            range = base_range;
            if (self.changeIsAboveViewport(range.first)) {
                range.first = self.viewportTop();
                range.last = max_len - 1;
            }

            mode = .diff;
            if (isAppendOnly(self, old_len, new_len, range, cursor_row)) {
                mode = .append_only;
            }
        }

        var out: std.ArrayList(u8) = .{};
        defer out.deinit(self.allocator);

        // Begin synchronized output.
        try out.appendSlice(self.allocator, "\x1b[?2026h");

        var current_row: i32 = @intCast(self.last_cursor_row);
        switch (mode) {
            .no_change => {},
            .diff => {
                current_row = try self.renderDiffRange(&out, lines, range);
            },
            .append_only => {
                current_row = try self.renderAppendOnly(&out, lines, old_len);
            },
        }

        try positionCursor(&out, self.allocator, current_row, cursor_row);
        try out.writer(self.allocator).print("\x1b[{d}G", .{cursor_col + 1});
        try out.appendSlice(self.allocator, "\x1b[?25h");

        // End synchronized output.
        try out.appendSlice(self.allocator, "\x1b[?2026l");

        try self.writer.writeAll(out.items);
        try self.updateBackbuffer(lines);
        self.last_cursor_row = cursor_row;
        self.updateMaxLinesRendered(new_len);
    }

    pub fn invalidate(self: *InlineRenderer) void {
        self.clearBackbuffer();
        self.last_cursor_row = 0;
        self.max_lines_rendered = 0;
    }

    fn updateBackbuffer(self: *InlineRenderer, lines: []const []const u8) !void {
        self.clearBackbuffer();
        try self.backbuffer.ensureTotalCapacity(self.allocator, lines.len);
        for (lines) |line| {
            const copy = try self.allocator.dupe(u8, line);
            try self.backbuffer.append(self.allocator, copy);
        }
    }

    fn clearBackbuffer(self: *InlineRenderer) void {
        for (self.backbuffer.items) |line| {
            self.allocator.free(line);
        }
        self.backbuffer.clearRetainingCapacity();
    }

    fn refreshWidth(self: *InlineRenderer) void {
        const size = terminal.getTerminalSize();
        const width = if (size.width > 0) size.width else 80;
        if (self.last_width != 0 and self.last_width != width) {
            self.invalidate();
        }
        self.last_width = width;
    }

    fn viewportTop(self: *const InlineRenderer) usize {
        const term_h: usize = @intCast(
            terminal.getTerminalSize().height,
        );
        const cursor: usize = @intCast(self.last_cursor_row);
        if (cursor >= term_h) return cursor + 1 - term_h;
        return 0;
    }

    fn changeIsAboveViewport(
        self: *const InlineRenderer,
        first_changed: usize,
    ) bool {
        return first_changed < self.viewportTop();
    }

    fn renderDiffRange(
        self: *InlineRenderer,
        out: *std.ArrayList(u8),
        lines: []const []const u8,
        range: ChangedRange,
    ) !i32 {
        const effective_top = try self.moveCursorToTop(out);
        const first = @max(range.first, effective_top);
        const skip = first - effective_top;
        if (skip > 0) {
            try out.writer(self.allocator).print(
                "\x1b[{d}B",
                .{skip},
            );
        }

        var row: usize = first;
        while (true) {
            if (row > first) {
                try out.appendSlice(self.allocator, "\r\n");
            }

            const line: ?[]const u8 = if (row < lines.len)
                lines[row]
            else
                null;
            try writeLine(out, self.allocator, line);

            if (row == range.last) break;
            row += 1;
        }

        return @intCast(range.last);
    }

    fn renderAppendOnly(
        self: *InlineRenderer,
        out: *std.ArrayList(u8),
        lines: []const []const u8,
        append_start: usize,
    ) !i32 {
        var row: i32 = @intCast(self.last_cursor_row);
        var i: usize = append_start;
        while (i < lines.len) : (i += 1) {
            try out.appendSlice(self.allocator, "\r\n");
            row += 1;
            try writeLine(out, self.allocator, lines[i]);
        }
        return row;
    }

    /// Move cursor to the top of reachable content.
    /// Returns the content line the cursor lands on
    /// (may be > 0 when content has scrolled past the
    /// terminal viewport).
    fn moveCursorToTop(
        self: *InlineRenderer,
        out: *std.ArrayList(u8),
    ) !usize {
        if (self.last_cursor_row > 0) {
            try out.writer(self.allocator).print(
                "\x1b[{d}A",
                .{self.last_cursor_row},
            );
        }
        try out.appendSlice(self.allocator, "\r");
        return self.viewportTop();
    }

    fn updateMaxLinesRendered(self: *InlineRenderer, line_count: usize) void {
        const count_u32 = std.math.cast(u32, line_count) orelse std.math.maxInt(u32);
        if (count_u32 > self.max_lines_rendered) {
            self.max_lines_rendered = count_u32;
        }
    }
};

fn findChangedRange(
    old_lines: []const []const u8,
    new_lines: []const []const u8,
) ?ChangedRange {
    const max_len = @max(old_lines.len, new_lines.len);
    var first: ?usize = null;
    var last: usize = 0;

    for (0..max_len) |i| {
        const old_line: []const u8 = if (i < old_lines.len) old_lines[i] else "";
        const new_line: []const u8 = if (i < new_lines.len) new_lines[i] else "";
        if (!std.mem.eql(u8, old_line, new_line)) {
            if (first == null) first = i;
            last = i;
        }
    }

    if (first == null) return null;
    return .{ .first = first.?, .last = last };
}

fn isAppendOnly(
    renderer: *const InlineRenderer,
    old_len: usize,
    new_len: usize,
    range: ChangedRange,
    cursor_row: u16,
) bool {
    if (old_len == 0) return false;
    if (new_len <= old_len) return false;
    if (range.first != old_len) return false;

    const old_bottom = std.math.cast(u16, old_len - 1) orelse return false;
    const new_bottom = std.math.cast(u16, new_len - 1) orelse return false;
    if (renderer.last_cursor_row != old_bottom) return false;
    return cursor_row == new_bottom;
}

fn positionCursor(
    out: *std.ArrayList(u8),
    allocator: Allocator,
    current_row: i32,
    target_row: u16,
) !void {
    const target: i32 = @intCast(target_row);
    if (current_row > target) {
        try out.writer(allocator).print("\x1b[{d}A", .{current_row - target});
    } else if (target > current_row) {
        try out.writer(allocator).print("\x1b[{d}B", .{target - current_row});
    }
}

fn assertCursorInBounds(line_count: usize, cursor_row: u16) void {
    if (line_count == 0) {
        std.debug.assert(cursor_row == 0);
        return;
    }

    std.debug.assert(line_count - 1 <= std.math.maxInt(u16));
    const max_row: u16 = @intCast(line_count - 1);
    std.debug.assert(cursor_row <= max_row);
}

fn writeLine(
    out: *std.ArrayList(u8),
    allocator: Allocator,
    line: ?[]const u8,
) !void {
    try out.appendSlice(allocator, "\r\x1b[2K");
    if (line) |line_text| {
        try out.appendSlice(allocator, line_text);
    }
    try out.appendSlice(allocator, LINE_RESET);
}

fn countSubstr(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, pos, needle)) |at| {
        count += 1;
        pos = at + needle.len;
    }
    return count;
}

fn fileSize(file: std.fs.File) !u64 {
    const stat = try file.stat();
    return stat.size;
}

fn readDelta(
    allocator: Allocator,
    file: std.fs.File,
    start: u64,
) ![]u8 {
    const end = try fileSize(file);
    std.debug.assert(end >= start);
    try file.seekTo(start);
    return try file.readToEndAlloc(allocator, @intCast(end - start));
}

test "inline renderer tracks backbuffer" {
    // We can't test actual terminal output, but we can test the backbuffer logic.
    const allocator = std.testing.allocator;

    // Create a temporary file as the writer target.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("out", .{ .read = true });
    defer file.close();

    var r = InlineRenderer.init(allocator, file);
    defer r.deinit();

    const lines = [_][]const u8{ "hello", "world" };
    try r.render(&lines, 1, 2);

    try std.testing.expectEqual(@as(usize, 2), r.backbuffer.items.len);
    try std.testing.expectEqualStrings("hello", r.backbuffer.items[0]);
    try std.testing.expectEqualStrings("world", r.backbuffer.items[1]);
    try std.testing.expectEqual(@as(u16, 1), r.last_cursor_row);
}

test "inline renderer invalidate clears backbuffer" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("out2", .{ .read = true });
    defer file.close();

    var r = InlineRenderer.init(allocator, file);
    defer r.deinit();

    const lines = [_][]const u8{"test"};
    try r.render(&lines, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), r.backbuffer.items.len);

    r.invalidate();
    try std.testing.expectEqual(@as(usize, 0), r.backbuffer.items.len);
}

test "inline renderer precise diff renders only changed band" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("out3", .{ .read = true });
    defer file.close();

    var r = InlineRenderer.init(allocator, file);
    defer r.deinit();

    const old_lines = [_][]const u8{ "line-a", "line-b", "line-c" };
    try r.render(&old_lines, 2, 0);

    const start = try fileSize(file);
    const new_lines = [_][]const u8{ "line-a", "line-b-updated", "line-c" };
    try r.render(&new_lines, 2, 0);

    const delta = try readDelta(allocator, file, start);
    defer allocator.free(delta);

    try std.testing.expect(std.mem.indexOf(u8, delta, "line-b-updated") != null);
    try std.testing.expect(std.mem.indexOf(u8, delta, "line-a") == null);
    try std.testing.expect(std.mem.indexOf(u8, delta, "line-c") == null);
    try std.testing.expectEqual(@as(usize, 0), countSubstr(delta, "\r\n"));
}

test "inline renderer append-only path skips upward cursor jumps" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("out4", .{ .read = true });
    defer file.close();

    var r = InlineRenderer.init(allocator, file);
    defer r.deinit();

    const old_lines = [_][]const u8{"alpha"};
    try r.render(&old_lines, 0, 0);

    const start = try fileSize(file);
    const new_lines = [_][]const u8{ "alpha", "beta" };
    try r.render(&new_lines, 1, 0);

    const delta = try readDelta(allocator, file, start);
    defer allocator.free(delta);

    try std.testing.expect(std.mem.indexOf(u8, delta, "\r\n\r\x1b[2Kbeta") != null);
    try std.testing.expect(std.mem.indexOf(u8, delta, "\x1b[1A") == null);
}

test "inline renderer clears trailing rows when content shrinks" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("out5", .{ .read = true });
    defer file.close();

    var r = InlineRenderer.init(allocator, file);
    defer r.deinit();

    const old_lines = [_][]const u8{ "one", "two", "three" };
    try r.render(&old_lines, 2, 0);

    const start = try fileSize(file);
    const new_lines = [_][]const u8{"one"};
    try r.render(&new_lines, 0, 0);

    const delta = try readDelta(allocator, file, start);
    defer allocator.free(delta);

    try std.testing.expect(countSubstr(delta, "\x1b[2K") >= 2);
}

test "inline renderer appends line reset for every rendered line" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("out6", .{ .read = true });
    defer file.close();

    var r = InlineRenderer.init(allocator, file);
    defer r.deinit();

    const lines = [_][]const u8{ "hello", "world" };
    try r.render(&lines, 1, 0);

    const output = try readDelta(allocator, file, 0);
    defer allocator.free(output);

    try std.testing.expect(countSubstr(output, LINE_RESET) >= 2);
}

test "inline renderer width change invalidates and redraws full content" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("out7", .{ .read = true });
    defer file.close();

    var r = InlineRenderer.init(allocator, file);
    defer r.deinit();

    const lines = [_][]const u8{ "first", "second" };
    try r.render(&lines, 1, 0);

    const start = try fileSize(file);
    r.last_width +|= 1;
    try r.render(&lines, 1, 0);

    const delta = try readDelta(allocator, file, start);
    defer allocator.free(delta);

    try std.testing.expect(std.mem.indexOf(u8, delta, "first") != null);
    try std.testing.expect(std.mem.indexOf(u8, delta, "second") != null);
}

test "inline renderer clamps range when change is above viewport" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("out8", .{ .read = true });
    defer file.close();

    var r = InlineRenderer.init(allocator, file);
    defer r.deinit();

    // Build enough lines to scroll past the terminal viewport.
    const term_h: usize = @intCast(
        terminal.getTerminalSize().height,
    );
    const line_count = term_h + 6;
    const cursor_row: u16 = @intCast(line_count - 1);

    const old_lines = try allocator.alloc(
        []const u8,
        line_count,
    );
    defer allocator.free(old_lines);
    const new_lines = try allocator.alloc(
        []const u8,
        line_count,
    );
    defer allocator.free(new_lines);

    for (0..line_count) |i| {
        old_lines[i] = if (i == 0) "line-0" else "filler";
        new_lines[i] = if (i == 0)
            "line-0-updated"
        else
            "filler";
    }

    try r.render(old_lines, cursor_row, 0);

    const start = try fileSize(file);
    try r.render(new_lines, cursor_row, 0);

    const delta = try readDelta(allocator, file, start);
    defer allocator.free(delta);

    // Line 0 is above the viewport — must not appear.
    try std.testing.expect(
        std.mem.indexOf(u8, delta, "line-0-updated") == null,
    );
    // Viewport lines should still be re-rendered.
    try std.testing.expect(
        std.mem.indexOf(u8, delta, "filler") != null,
    );
}
