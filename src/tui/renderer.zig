const std = @import("std");

const Allocator = std.mem.Allocator;

pub const InlineRenderer = struct {
    allocator: Allocator,
    writer: std.fs.File,
    backbuffer: std.ArrayList([]u8),
    last_cursor_row: u16 = 0,

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
        var out: std.ArrayList(u8) = .{};
        defer out.deinit(self.allocator);

        // Begin synchronized output.
        try out.appendSlice(self.allocator, "\x1b[?2026h");

        // Move cursor to top of our region.
        if (self.last_cursor_row > 0) {
            try out.writer(self.allocator).print("\x1b[{d}A", .{self.last_cursor_row});
        }
        try out.appendSlice(self.allocator, "\r");

        const old_len = self.backbuffer.items.len;
        const new_len = lines.len;
        const max_len = @max(old_len, new_len);

        if (old_len == 0) {
            // First render: output all lines.
            for (lines, 0..) |line, i| {
                if (i > 0) try out.appendSlice(self.allocator, "\r\n");
                try out.appendSlice(self.allocator, line);
                try out.appendSlice(self.allocator, "\x1b[K");
            }
        } else {
            // Diff render.
            var row: usize = 0;
            while (row < max_len) : (row += 1) {
                if (row > 0) try out.appendSlice(self.allocator, "\r\n");

                const old_line: []const u8 = if (row < old_len)
                    self.backbuffer.items[row]
                else
                    "";
                const new_line: []const u8 = if (row < new_len)
                    lines[row]
                else
                    "";

                if (std.mem.eql(u8, old_line, new_line) and row < new_len) {
                    // Line unchanged, skip content but still need to move down.
                    continue;
                }

                // Rewrite this line.
                try out.appendSlice(self.allocator, "\r");
                if (row < new_len) {
                    try out.appendSlice(self.allocator, new_line);
                }
                try out.appendSlice(self.allocator, "\x1b[K");
            }
        }

        // Position cursor.
        const bottom: u16 = if (new_len == 0) 0 else @intCast(new_len - 1);
        if (bottom > cursor_row) {
            try out.writer(self.allocator).print("\x1b[{d}A", .{bottom - cursor_row});
        }
        try out.writer(self.allocator).print("\x1b[{d}G", .{cursor_col + 1});
        try out.appendSlice(self.allocator, "\x1b[?25h");

        // End synchronized output.
        try out.appendSlice(self.allocator, "\x1b[?2026l");

        try self.writer.writeAll(out.items);
        try self.updateBackbuffer(lines);
        self.last_cursor_row = cursor_row;
    }

    pub fn invalidate(self: *InlineRenderer) void {
        self.clearBackbuffer();
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
};

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
