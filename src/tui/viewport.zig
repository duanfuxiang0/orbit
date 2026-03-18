const std = @import("std");

pub const Position = struct {
    x: u16,
    y: u16,
};

pub const Rect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,

    pub fn top(self: Rect) u16 {
        return self.y;
    }

    pub fn bottom(self: Rect) u16 {
        return self.y +| self.height;
    }
};

pub const Viewport = struct {
    area: Rect,
    last_cursor_pos: Position,

    pub fn init(cursor_pos: Position) Viewport {
        return .{
            .area = .{ .x = 0, .y = cursor_pos.y, .width = 0, .height = 0 },
            .last_cursor_pos = cursor_pos,
        };
    }

    pub fn shiftDown(self: *Viewport, rows: u16) void {
        self.area.y +|= rows;
        self.last_cursor_pos.y +|= rows;
    }
};

test "viewport init starts at cursor row" {
    const vp = Viewport.init(.{ .x = 4, .y = 7 });
    try std.testing.expectEqual(@as(u16, 7), vp.area.y);
    try std.testing.expectEqual(@as(u16, 4), vp.last_cursor_pos.x);
}
