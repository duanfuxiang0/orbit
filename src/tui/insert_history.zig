const std = @import("std");
const viewport_mod = @import("viewport.zig");

const Viewport = viewport_mod.Viewport;

pub const InsertResult = struct {
    wrapped_count: usize,
    sequence: []u8,

    pub fn deinit(self: *InsertResult, allocator: std.mem.Allocator) void {
        allocator.free(self.sequence);
    }
};

pub fn buildInsertHistorySequence(
    allocator: std.mem.Allocator,
    viewport: *Viewport,
    screen_height: u16,
    lines: []const []const u8,
    wrap_width: u16,
) !InsertResult {
    std.debug.assert(wrap_width > 0);

    var wrapped_count: usize = 0;
    for (lines) |line| {
        wrapped_count += wrappedLineCount(line, wrap_width);
    }

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);

    if (viewport.area.bottom() < screen_height) {
        const scroll_amount = wrapped_count;
        try out.writer(allocator).print("\x1b[{d};{d}r", .{ viewport.area.top() + 1, screen_height });
        try out.writer(allocator).print("\x1b[{d};1H", .{viewport.area.top() + 1});
        var i: usize = 0;
        while (i < scroll_amount) : (i += 1) {
            try out.appendSlice(allocator, "\x1bM");
        }
        try out.appendSlice(allocator, "\x1b[r");
        viewport.shiftDown(@intCast(scroll_amount));
    }

    const region_bottom = viewport.area.top();
    try out.writer(allocator).print("\x1b[1;{d}r", .{region_bottom});
    if (region_bottom > 0) {
        try out.writer(allocator).print("\x1b[{d};1H", .{region_bottom});
    }

    for (lines) |line| {
        try out.appendSlice(allocator, "\r\n");
        try out.appendSlice(allocator, line);
    }

    try out.appendSlice(allocator, "\x1b[r");
    try out.writer(allocator).print(
        "\x1b[{d};{d}H",
        .{ viewport.last_cursor_pos.y + 1, viewport.last_cursor_pos.x + 1 },
    );

    return .{
        .wrapped_count = wrapped_count,
        .sequence = try out.toOwnedSlice(allocator),
    };
}

fn wrappedLineCount(line: []const u8, width: u16) usize {
    if (line.len == 0) return 1;
    return (line.len + width - 1) / width;
}

test "wrapped line count is width aware" {
    try std.testing.expectEqual(@as(usize, 1), wrappedLineCount("abc", 80));
    try std.testing.expectEqual(@as(usize, 2), wrappedLineCount("abcdef", 3));
}

test "build insert history sequence restores cursor and updates viewport" {
    var viewport = Viewport.init(.{ .x = 2, .y = 10 });
    viewport.area.width = 40;
    viewport.area.height = 4;

    var result = try buildInsertHistorySequence(
        std.testing.allocator,
        &viewport,
        24,
        &.{ "alpha", "beta" },
        40,
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.sequence, "\x1b[1;12r") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.sequence, "\r\nalpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.sequence, "\x1b[13;3H") != null);
    try std.testing.expectEqual(@as(u16, 12), viewport.area.y);
}
