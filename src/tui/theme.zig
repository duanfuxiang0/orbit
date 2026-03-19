const std = @import("std");

pub const Rgb = [3]u8;

pub const ColorDepth = enum {
    none,
    ansi16,
    ansi256,
    true_color,
};

pub const Scheme = enum {
    dark,
    light,
};

pub const Ansi16Color = enum(u8) {
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
};

pub const ColorValue = struct {
    rgb: Rgb,
    ansi256: u8,
    ansi16: Ansi16Color,
};

pub const Palette = struct {
    code_bg: ColorValue,
    code_fg: ColorValue,
    tool_running: ColorValue,
    tool_success: ColorValue,
    tool_error: ColorValue,
    heading: ColorValue,
    dim: ColorValue,
    link: ColorValue,
};

pub const Theme = struct {
    depth: ColorDepth,
    scheme: Scheme,
    palette: Palette,

    pub fn isColorEnabled(self: Theme) bool {
        return self.depth != .none;
    }

    pub fn supportsCodeBlockBackground(self: Theme) bool {
        return switch (self.depth) {
            .ansi256, .true_color => true,
            .none, .ansi16 => false,
        };
    }
};

pub const dark = Palette{
    .code_bg = .{ .rgb = .{ 40, 42, 54 }, .ansi256 = 237, .ansi16 = .black },
    .code_fg = .{ .rgb = .{ 248, 248, 242 }, .ansi256 = 255, .ansi16 = .white },
    .tool_running = .{ .rgb = .{ 241, 250, 140 }, .ansi256 = 229, .ansi16 = .yellow },
    .tool_success = .{ .rgb = .{ 80, 250, 123 }, .ansi256 = 84, .ansi16 = .bright_green },
    .tool_error = .{ .rgb = .{ 255, 85, 85 }, .ansi256 = 203, .ansi16 = .bright_red },
    .heading = .{ .rgb = .{ 255, 255, 255 }, .ansi256 = 15, .ansi16 = .bright_white },
    .dim = .{ .rgb = .{ 108, 112, 134 }, .ansi256 = 60, .ansi16 = .bright_black },
    .link = .{ .rgb = .{ 139, 233, 253 }, .ansi256 = 117, .ansi16 = .bright_cyan },
};

pub const light = Palette{
    .code_bg = .{ .rgb = .{ 235, 237, 240 }, .ansi256 = 255, .ansi16 = .white },
    .code_fg = .{ .rgb = .{ 31, 35, 40 }, .ansi256 = 235, .ansi16 = .black },
    .tool_running = .{ .rgb = .{ 156, 110, 0 }, .ansi256 = 136, .ansi16 = .yellow },
    .tool_success = .{ .rgb = .{ 22, 128, 57 }, .ansi256 = 28, .ansi16 = .green },
    .tool_error = .{ .rgb = .{ 207, 34, 46 }, .ansi256 = 160, .ansi16 = .red },
    .heading = .{ .rgb = .{ 31, 35, 40 }, .ansi256 = 235, .ansi16 = .black },
    .dim = .{ .rgb = .{ 101, 109, 118 }, .ansi256 = 243, .ansi16 = .bright_black },
    .link = .{ .rgb = .{ 9, 105, 218 }, .ansi256 = 26, .ansi16 = .blue },
};

pub fn forceNoColor() Theme {
    return themeFor(.none, .dark);
}

pub fn themeFor(depth: ColorDepth, scheme: Scheme) Theme {
    const palette = switch (scheme) {
        .dark => dark,
        .light => light,
    };
    return .{ .depth = depth, .scheme = scheme, .palette = palette };
}

pub fn detect(stdin_file: std.fs.File, stdout_file: std.fs.File) Theme {
    const stdout_is_tty = stdout_file.isTty();
    const stdin_is_tty = stdin_file.isTty();

    const no_color = envVar("NO_COLOR");
    const colorterm = envVar("COLORTERM");
    const term = envVar("TERM");

    const depth = detectDepthFromVars(no_color, colorterm, term, stdout_is_tty);
    if (depth == .none) return themeFor(.none, .dark);

    if (!stdin_is_tty) return themeFor(depth, .dark);

    if (queryTerminalBackground(stdin_file, stdout_file)) |bg| {
        const scheme: Scheme = if (isLight(bg)) .light else .dark;
        return themeFor(depth, scheme);
    }

    return themeFor(depth, .dark);
}

pub fn isLight(rgb: Rgb) bool {
    const r: u32 = rgb[0];
    const g: u32 = rgb[1];
    const b: u32 = rgb[2];
    const luma = (299 * r + 587 * g + 114 * b) / 1000;
    return luma >= 128;
}

fn envVar(name: [:0]const u8) ?[]const u8 {
    const raw = std.posix.getenv(name) orelse return null;
    return raw;
}

fn detectDepthFromVars(
    no_color: ?[]const u8,
    colorterm: ?[]const u8,
    term: ?[]const u8,
    stdout_is_tty: bool,
) ColorDepth {
    if (!stdout_is_tty) return .none;

    if (no_color) |value| {
        if (value.len > 0) return .none;
    }

    if (colorterm) |value| {
        if (asciiContainsIgnoreCase(value, "truecolor")) return .true_color;
        if (asciiContainsIgnoreCase(value, "24bit")) return .true_color;
    }

    if (term) |value| {
        if (asciiContainsIgnoreCase(value, "256color")) return .ansi256;
    }

    return .ansi16;
}

fn asciiContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        const candidate = haystack[index .. index + needle.len];
        if (std.ascii.eqlIgnoreCase(candidate, needle)) return true;
    }
    return false;
}

fn queryTerminalBackground(stdin_file: std.fs.File, stdout_file: std.fs.File) ?Rgb {
    stdout_file.writeAll("\x1b]11;?\x07") catch return null;

    var buf: [256]u8 = undefined;
    var used: usize = 0;

    const timeout_ms: i32 = if (envVar("SSH_CONNECTION") != null) 80 else 40;
    const start_ns = std.time.nanoTimestamp();
    const timeout_ns = @as(i128, timeout_ms) * std.time.ns_per_ms;

    while (used < buf.len) {
        const now_ns = std.time.nanoTimestamp();
        if (now_ns - start_ns >= timeout_ns) break;

        const remaining_ns = timeout_ns - (now_ns - start_ns);
        const wait_ms_i128 = @max(1, @divFloor(remaining_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms));
        const wait_ms = std.math.cast(i32, wait_ms_i128) orelse 1;

        var fds = [_]std.posix.pollfd{
            .{ .fd = stdin_file.handle, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const ready = std.posix.poll(&fds, wait_ms) catch break;
        if (ready <= 0) continue;

        if ((fds[0].revents & std.posix.POLL.IN) == 0) break;

        const read_len = std.posix.read(stdin_file.handle, buf[used..]) catch break;
        if (read_len == 0) break;
        used += read_len;

        if (std.mem.indexOfScalar(u8, buf[0..used], '\x07') != null) break;
        if (std.mem.indexOf(u8, buf[0..used], "\x1b\\") != null) break;
    }

    if (used == 0) return null;
    return parseOsc11Response(buf[0..used]);
}

fn parseOsc11Response(raw: []const u8) ?Rgb {
    const prefix = "\x1b]11;rgb:";
    const start = std.mem.indexOf(u8, raw, prefix) orelse return null;

    var cursor = start + prefix.len;
    const r = parseChannel(raw, &cursor) orelse return null;

    if (cursor >= raw.len or raw[cursor] != '/') return null;
    cursor += 1;

    const g = parseChannel(raw, &cursor) orelse return null;

    if (cursor >= raw.len or raw[cursor] != '/') return null;
    cursor += 1;

    const b = parseChannel(raw, &cursor) orelse return null;
    return .{ r, g, b };
}

fn parseChannel(raw: []const u8, cursor: *usize) ?u8 {
    const start = cursor.*;
    var end = start;

    while (end < raw.len and std.ascii.isHex(raw[end]) and (end - start) < 4) : (end += 1) {}

    const digits = end - start;
    if (digits == 0) return null;
    if (end < raw.len and std.ascii.isHex(raw[end])) return null;

    const parsed = std.fmt.parseInt(u16, raw[start..end], 16) catch return null;
    cursor.* = end;

    return switch (digits) {
        1 => @as(u8, @intCast(parsed * 17)),
        2 => @as(u8, @intCast(parsed)),
        3 => @as(u8, @intCast((@as(u32, parsed) * 255 + 2047) / 4095)),
        4 => @as(u8, @intCast(parsed >> 8)),
        else => null,
    };
}

test "themeFor picks palette by scheme" {
    const dark_theme = themeFor(.ansi16, .dark);
    try std.testing.expectEqual(@as(u8, 40), dark_theme.palette.code_bg.rgb[0]);

    const light_theme = themeFor(.ansi16, .light);
    try std.testing.expectEqual(@as(u8, 235), light_theme.palette.code_bg.rgb[0]);
}

test "depth detection honors NO_COLOR" {
    const d = detectDepthFromVars("1", "truecolor", "xterm-256color", true);
    try std.testing.expectEqual(ColorDepth.none, d);
}

test "depth detection prefers true color" {
    const d = detectDepthFromVars(null, "truecolor", "xterm-256color", true);
    try std.testing.expectEqual(ColorDepth.true_color, d);
}

test "depth detection handles 256 and ansi16" {
    const d256 = detectDepthFromVars(null, null, "xterm-256color", true);
    try std.testing.expectEqual(ColorDepth.ansi256, d256);

    const d16 = detectDepthFromVars(null, null, "xterm", true);
    try std.testing.expectEqual(ColorDepth.ansi16, d16);
}

test "depth detection disables color for non tty" {
    const d = detectDepthFromVars(null, "truecolor", "xterm-256color", false);
    try std.testing.expectEqual(ColorDepth.none, d);
}

test "parse OSC11 response with BEL terminator" {
    const rgb = parseOsc11Response("\x1b]11;rgb:2828/2a2a/3636\x07") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 40), rgb[0]);
    try std.testing.expectEqual(@as(u8, 42), rgb[1]);
    try std.testing.expectEqual(@as(u8, 54), rgb[2]);
}

test "parse OSC11 response with ST terminator" {
    const rgb = parseOsc11Response("\x1b]11;rgb:eb/ed/f0\x1b\\") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 235), rgb[0]);
    try std.testing.expectEqual(@as(u8, 237), rgb[1]);
    try std.testing.expectEqual(@as(u8, 240), rgb[2]);
}

test "isLight follows BT.601 threshold" {
    try std.testing.expect(isLight(.{ 235, 237, 240 }));
    try std.testing.expect(!isLight(.{ 40, 42, 54 }));
}

test "code block background supported only for ansi256 and truecolor" {
    try std.testing.expect(!themeFor(.none, .dark).supportsCodeBlockBackground());
    try std.testing.expect(!themeFor(.ansi16, .dark).supportsCodeBlockBackground());
    try std.testing.expect(themeFor(.ansi256, .dark).supportsCodeBlockBackground());
    try std.testing.expect(themeFor(.true_color, .dark).supportsCodeBlockBackground());
}
