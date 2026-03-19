const std = @import("std");
const theme = @import("theme.zig");

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
    bright_black,
    bright_red,
    bright_green,
    bright_yellow,
    bright_blue,
    bright_magenta,
    bright_cyan,
    bright_white,

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
            .bright_black => "\x1b[90m",
            .bright_red => "\x1b[91m",
            .bright_green => "\x1b[92m",
            .bright_yellow => "\x1b[93m",
            .bright_blue => "\x1b[94m",
            .bright_magenta => "\x1b[95m",
            .bright_cyan => "\x1b[96m",
            .bright_white => "\x1b[97m",
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
            .bright_black => "\x1b[100m",
            .bright_red => "\x1b[101m",
            .bright_green => "\x1b[102m",
            .bright_yellow => "\x1b[103m",
            .bright_blue => "\x1b[104m",
            .bright_magenta => "\x1b[105m",
            .bright_cyan => "\x1b[106m",
            .bright_white => "\x1b[107m",
        };
    }
};

pub fn isEnabled(current_theme: theme.Theme) bool {
    return current_theme.isColorEnabled();
}

pub fn resetCode(current_theme: theme.Theme) []const u8 {
    return if (isEnabled(current_theme)) reset else "";
}

pub fn dimCode(current_theme: theme.Theme) []const u8 {
    return if (isEnabled(current_theme)) dim else "";
}

pub fn fgPrefix(
    buf: *[24]u8,
    current_theme: theme.Theme,
    value: theme.ColorValue,
) []const u8 {
    if (!isEnabled(current_theme)) return "";

    return switch (current_theme.depth) {
        .none => "",
        .ansi16 => ansi16ToColor(value.ansi16).fgCode(),
        .ansi256 => std.fmt.bufPrint(buf, "\x1b[38;5;{d}m", .{value.ansi256}) catch "",
        .true_color => std.fmt.bufPrint(
            buf,
            "\x1b[38;2;{d};{d};{d}m",
            .{ value.rgb[0], value.rgb[1], value.rgb[2] },
        ) catch "",
    };
}

pub fn bgPrefix(
    buf: *[24]u8,
    current_theme: theme.Theme,
    value: theme.ColorValue,
) []const u8 {
    if (!isEnabled(current_theme)) return "";

    return switch (current_theme.depth) {
        .none => "",
        .ansi16 => ansi16ToColor(value.ansi16).bgCode(),
        .ansi256 => std.fmt.bufPrint(buf, "\x1b[48;5;{d}m", .{value.ansi256}) catch "",
        .true_color => std.fmt.bufPrint(
            buf,
            "\x1b[48;2;{d};{d};{d}m",
            .{ value.rgb[0], value.rgb[1], value.rgb[2] },
        ) catch "",
    };
}

pub fn fgColor(
    allocator: std.mem.Allocator,
    current_theme: theme.Theme,
    text: []const u8,
    value: theme.ColorValue,
) ![]u8 {
    var buf: [24]u8 = undefined;
    const prefix = fgPrefix(&buf, current_theme, value);
    return wrapWithPrefix(allocator, text, prefix, resetCode(current_theme));
}

pub fn bgColor(
    allocator: std.mem.Allocator,
    current_theme: theme.Theme,
    text: []const u8,
    value: theme.ColorValue,
) ![]u8 {
    var buf: [24]u8 = undefined;
    const prefix = bgPrefix(&buf, current_theme, value);
    return wrapWithPrefix(allocator, text, prefix, resetCode(current_theme));
}

pub fn colored(
    allocator: std.mem.Allocator,
    current_theme: theme.Theme,
    text: []const u8,
    color: Color,
) ![]u8 {
    if (!isEnabled(current_theme)) return allocator.dupe(u8, text);
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ color.fgCode(), text, reset });
}

pub fn boldText(
    allocator: std.mem.Allocator,
    current_theme: theme.Theme,
    text: []const u8,
) ![]u8 {
    if (!isEnabled(current_theme)) return allocator.dupe(u8, text);
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ bold, text, reset });
}

pub fn dimText(
    allocator: std.mem.Allocator,
    current_theme: theme.Theme,
    text: []const u8,
) ![]u8 {
    if (!isEnabled(current_theme)) return allocator.dupe(u8, text);
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ dim, text, reset });
}

fn wrapWithPrefix(
    allocator: std.mem.Allocator,
    text: []const u8,
    prefix: []const u8,
    suffix: []const u8,
) ![]u8 {
    if (prefix.len == 0) return allocator.dupe(u8, text);
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ prefix, text, suffix });
}

fn ansi16ToColor(value: theme.Ansi16Color) Color {
    return switch (value) {
        .black => .black,
        .red => .red,
        .green => .green,
        .yellow => .yellow,
        .blue => .blue,
        .magenta => .magenta,
        .cyan => .cyan,
        .white => .white,
        .bright_black => .bright_black,
        .bright_red => .bright_red,
        .bright_green => .bright_green,
        .bright_yellow => .bright_yellow,
        .bright_blue => .bright_blue,
        .bright_magenta => .bright_magenta,
        .bright_cyan => .bright_cyan,
        .bright_white => .bright_white,
    };
}

test "ansi wraps text" {
    const current_theme = theme.themeFor(.ansi16, .dark);

    const got = try colored(std.testing.allocator, current_theme, "ok", .green);
    defer std.testing.allocator.free(got);

    try std.testing.expect(std.mem.startsWith(u8, got, "\x1b[32m"));
    try std.testing.expect(std.mem.endsWith(u8, got, "\x1b[0m"));
}

test "ansi plain output when disabled" {
    const current_theme = theme.forceNoColor();

    const got = try colored(std.testing.allocator, current_theme, "ok", .green);
    defer std.testing.allocator.free(got);

    try std.testing.expectEqualStrings("ok", got);
}

test "fgColor emits truecolor escape" {
    const current_theme = theme.themeFor(.true_color, .dark);

    const got = try fgColor(
        std.testing.allocator,
        current_theme,
        "x",
        .{ .rgb = .{ 1, 2, 3 }, .ansi256 = 16, .ansi16 = .black },
    );
    defer std.testing.allocator.free(got);

    try std.testing.expect(std.mem.indexOf(u8, got, "\x1b[38;2;1;2;3m") != null);
}
