const std = @import("std");
const posix = std.posix;

pub const Size = struct {
    width: u16,
    height: u16,
};

pub fn getTerminalSize() Size {
    const stdout = std.fs.File.stdout();
    var wsz: posix.winsize = undefined;
    const fd: usize = @bitCast(@as(isize, stdout.handle));
    const rc = std.os.linux.syscall3(
        .ioctl,
        fd,
        std.os.linux.T.IOCGWINSZ,
        @intFromPtr(&wsz),
    );
    if (std.os.linux.E.init(rc) != .SUCCESS) {
        return .{ .width = 80, .height = 24 };
    }
    return .{
        .width = if (wsz.col == 0) 80 else wsz.col,
        .height = if (wsz.row == 0) 24 else wsz.row,
    };
}

test "terminal size returns non-zero" {
    const size = getTerminalSize();
    try std.testing.expect(size.width > 0);
    try std.testing.expect(size.height > 0);
}
