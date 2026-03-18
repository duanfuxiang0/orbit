const std = @import("std");
const posix = std.posix;

pub const Size = struct {
    width: u16,
    height: u16,
};

pub const Terminal = struct {
    stdin: std.fs.File,
    stdout: std.fs.File,
    size: Size,

    pub fn init() !Terminal {
        var term = Terminal{
            .stdin = std.io.getStdIn(),
            .stdout = std.io.getStdOut(),
            .size = .{ .width = 80, .height = 24 },
        };
        try term.refreshSize();
        return term;
    }

    pub fn refreshSize(self: *Terminal) !void {
        const ws = try posix.ioctl(self.stdout.handle, posix.T.IOCGWINSZ, 0);
        var raw: posix.winsize = @bitCast(@as(usize, @intCast(ws)));
        if (raw.ws_col == 0) raw.ws_col = 80;
        if (raw.ws_row == 0) raw.ws_row = 24;
        self.size = .{ .width = raw.ws_col, .height = raw.ws_row };
    }

    pub fn write(self: *Terminal, data: []const u8) !void {
        try self.stdout.writeAll(data);
    }

    pub fn moveTo(self: *Terminal, col: u16, row: u16) !void {
        try self.stdout.writer().print("\x1b[{d};{d}H", .{ row + 1, col + 1 });
    }

    pub fn setScrollRegion(self: *Terminal, top: u16, bottom: u16) !void {
        std.debug.assert(top > 0);
        std.debug.assert(bottom >= top);
        try self.stdout.writer().print("\x1b[{d};{d}r", .{ top, bottom });
    }

    pub fn resetScrollRegion(self: *Terminal) !void {
        try self.write("\x1b[r");
    }

    pub fn getSize(self: *const Terminal) Size {
        return self.size;
    }
};
