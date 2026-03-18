const std = @import("std");

pub const reset = "\x1b[0m";
pub const bold = "\x1b[1m";
pub const dim = "\x1b[2m";
pub const italic = "\x1b[3m";
pub const underline = "\x1b[4m";

pub const Color = enum {
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,

    pub fn fgCode(self: Color) []const u8 {
        return switch (self) {
            .black => "\x1b[30m",
            .red => "\x1b[31m",
            .green => "\x1b[32m",
            .yellow => "\x1b[33m",
            .blue => "\x1b[34m",
            .magenta => "\x1b[35m",
            .cyan => "\x1b[36m",
            .white => "\x1b[37m",
        };
    }

    pub fn bgCode(self: Color) []const u8 {
        return switch (self) {
            .black => "\x1b[40m",
            .red => "\x1b[41m",
            .green => "\x1b[42m",
            .yellow => "\x1b[43m",
            .blue => "\x1b[44m",
            .magenta => "\x1b[45m",
            .cyan => "\x1b[46m",
            .white => "\x1b[47m",
        };
    }
};

pub fn colored(
    allocator: std.mem.Allocator,
    text: []const u8,
    color: Color,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ color.fgCode(), text, reset });
}

pub fn boldText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ bold, text, reset });
}

pub fn dimText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ dim, text, reset });
}

pub fn bgGray(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "\x1b[48;5;236m{s}{s}", .{ text, reset });
}

test "ansi wraps text" {
    const got = try colored(std.testing.allocator, "ok", .green);
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.startsWith(u8, got, "\x1b[32m"));
    try std.testing.expect(std.mem.endsWith(u8, got, "\x1b[0m"));
}
