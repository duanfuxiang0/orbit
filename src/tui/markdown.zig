const std = @import("std");
const ansi = @import("ansi.zig");
const component_mod = @import("component.zig");
const lines_util = @import("lines_util.zig");

const Allocator = std.mem.Allocator;
const Component = component_mod.Component;

pub const Markdown = struct {
    allocator: Allocator,
    text: []const u8,
    owned_text: ?[]u8 = null,
    padding_x: u16,
    padding_y: u16,
    cached_width: ?u16 = null,
    cached_lines: ?[][]const u8 = null,

    pub fn init(
        allocator: Allocator,
        text: []const u8,
        padding_x: u16,
        padding_y: u16,
    ) Markdown {
        return .{
            .allocator = allocator,
            .text = text,
            .padding_x = padding_x,
            .padding_y = padding_y,
        };
    }

    pub fn deinit(self: *Markdown) void {
        lines_util.freeOptionalLines(self.allocator, self.cached_lines);
        self.cached_lines = null;
        if (self.owned_text) |buf| {
            self.allocator.free(buf);
            self.owned_text = null;
        }
    }

    pub fn setText(self: *Markdown, text: []const u8) !void {
        const copy = try self.allocator.dupe(u8, text);
        if (self.owned_text) |old| {
            self.allocator.free(old);
        }
        self.owned_text = copy;
        self.text = copy;
        self.invalidate();
    }

    pub fn component(self: *Markdown) Component {
        return .{
            .ptr = self,
            .vtable = &.{
                .render = renderImpl,
                .handle_input = null,
                .invalidate = invalidateImpl,
                .deinit = deinitImpl,
            },
        };
    }

    pub fn invalidate(self: *Markdown) void {
        lines_util.freeOptionalLines(self.allocator, self.cached_lines);
        self.cached_lines = null;
        self.cached_width = null;
    }

    fn renderImpl(ptr: *anyopaque, width: u16, allocator: Allocator) ![][]const u8 {
        const self: *Markdown = @ptrCast(@alignCast(ptr));
        std.debug.assert(width > 0);

        if (self.cached_width) |cached_width| {
            if (cached_width == width) {
                if (self.cached_lines) |cached| {
                    return lines_util.cloneLines(allocator, cached);
                }
            }
        }

        const rendered = try renderMarkdown(self, width, allocator);
        errdefer {
            for (rendered) |line| allocator.free(line);
            allocator.free(rendered);
        }

        lines_util.freeOptionalLines(self.allocator, self.cached_lines);
        self.cached_lines = try lines_util.cloneLines(self.allocator, rendered);
        self.cached_width = width;
        return rendered;
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *Markdown = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    fn invalidateImpl(ptr: *anyopaque) void {
        const self: *Markdown = @ptrCast(@alignCast(ptr));
        self.invalidate();
    }
};

const StyledSpan = struct {
    style: TextStyle,
    text: []const u8,
};

const TextStyle = enum {
    plain,
    heading,
    inline_code,
};

fn renderMarkdown(self: *Markdown, width: u16, allocator: Allocator) ![][]const u8 {
    var lines: std.ArrayList([]const u8) = .{};
    errdefer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }

    for (0..self.padding_y) |_| {
        try lines.append(allocator, try allocator.dupe(u8, ""));
    }

    const content_width = computeContentWidth(width, self.padding_x);
    var in_code_block = false;
    var previous_blank = false;
    var iterator = std.mem.splitScalar(u8, self.text, '\n');
    while (iterator.next()) |raw_line| {
        if (std.mem.startsWith(u8, raw_line, "```")) {
            in_code_block = !in_code_block;
            previous_blank = false;
            continue;
        }
        if (in_code_block) {
            try appendCodeBlockWrapped(&lines, allocator, raw_line, self.padding_x, content_width);
            previous_blank = false;
            continue;
        }
        if (std.mem.trim(u8, raw_line, " \t\r").len == 0) {
            if (!previous_blank and hasRenderedContent(lines.items, self.padding_y)) {
                try appendBlankLine(&lines, allocator, self.padding_x);
            }
            previous_blank = true;
            continue;
        }
        if (raw_line.len > 0 and raw_line[0] == '#') {
            const heading = std.mem.trimLeft(u8, raw_line, "# ");
            try appendSingleStyleWrapped(
                &lines,
                allocator,
                heading,
                .heading,
                self.padding_x,
                content_width,
            );
            previous_blank = false;
            continue;
        }
        try appendInlineMarkdownWrapped(&lines, allocator, raw_line, self.padding_x, content_width);
        previous_blank = false;
    }

    for (0..self.padding_y) |_| {
        try lines.append(allocator, try allocator.dupe(u8, ""));
    }
    return lines.toOwnedSlice(allocator);
}

fn computeContentWidth(width: u16, padding_x: u16) usize {
    if (padding_x == 0) return @as(usize, width);
    const total_padding = @as(u32, padding_x) * 2;
    if (total_padding >= width) return 1;
    return @as(usize, width - @as(u16, @intCast(total_padding)));
}

fn appendSingleStyleWrapped(
    lines: *std.ArrayList([]const u8),
    allocator: Allocator,
    text: []const u8,
    style: TextStyle,
    padding_x: u16,
    width: usize,
) !void {
    var spans: [1]StyledSpan = .{.{ .style = style, .text = text }};
    try appendStyledWrapped(lines, allocator, spans[0..], padding_x, width);
}

fn appendInlineMarkdownWrapped(
    lines: *std.ArrayList([]const u8),
    allocator: Allocator,
    line: []const u8,
    padding_x: u16,
    width: usize,
) !void {
    var spans: std.ArrayList(StyledSpan) = .{};
    defer spans.deinit(allocator);

    var cursor: usize = 0;
    while (cursor < line.len) {
        const open = std.mem.indexOfScalarPos(u8, line, cursor, '`') orelse break;
        const close = std.mem.indexOfScalarPos(u8, line, open + 1, '`') orelse break;
        if (open > cursor) {
            try spans.append(allocator, .{
                .style = .plain,
                .text = line[cursor..open],
            });
        }
        if (close > open + 1) {
            try spans.append(allocator, .{
                .style = .inline_code,
                .text = line[open + 1 .. close],
            });
        }
        cursor = close + 1;
    }
    if (cursor < line.len) {
        try spans.append(allocator, .{
            .style = .plain,
            .text = line[cursor..],
        });
    }
    if (spans.items.len == 0) {
        try spans.append(allocator, .{
            .style = .plain,
            .text = line,
        });
    }
    try appendStyledWrapped(lines, allocator, spans.items, padding_x, width);
}

fn appendStyledWrapped(
    lines: *std.ArrayList([]const u8),
    allocator: Allocator,
    spans: []const StyledSpan,
    padding_x: u16,
    width: usize,
) !void {
    std.debug.assert(width > 0);

    const prefix = try makePadding(allocator, padding_x);
    defer allocator.free(prefix);

    var current: std.ArrayList(u8) = .{};
    defer current.deinit(allocator);
    try current.appendSlice(allocator, prefix);

    var visible_len: usize = 0;
    for (spans) |span| {
        var remaining = span.text;
        while (remaining.len > 0) {
            if (visible_len == width) {
                try lines.append(allocator, try allocator.dupe(u8, current.items));
                current.clearRetainingCapacity();
                try current.appendSlice(allocator, prefix);
                visible_len = 0;
            }

            const room = width - visible_len;
            const take = @min(room, remaining.len);
            try appendStyledChunk(allocator, &current, span.style, remaining[0..take]);
            visible_len += take;
            remaining = remaining[take..];
        }
    }

    if (current.items.len == prefix.len) {
        try lines.append(allocator, try allocator.dupe(u8, prefix));
    } else {
        try lines.append(allocator, try allocator.dupe(u8, current.items));
    }
}

fn appendStyledChunk(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    style: TextStyle,
    chunk: []const u8,
) !void {
    switch (style) {
        .plain => try out.appendSlice(allocator, chunk),
        .heading => {
            const styled = try ansi.boldText(allocator, chunk);
            defer allocator.free(styled);
            try out.appendSlice(allocator, styled);
        },
        .inline_code => {
            const styled = try ansi.colored(allocator, chunk, .cyan);
            defer allocator.free(styled);
            try out.appendSlice(allocator, styled);
        },
    }
}

fn appendCodeBlockWrapped(
    lines: *std.ArrayList([]const u8),
    allocator: Allocator,
    line: []const u8,
    padding_x: u16,
    width: usize,
) !void {
    std.debug.assert(width > 0);

    const prefix = try makePadding(allocator, padding_x);
    defer allocator.free(prefix);

    if (line.len == 0) {
        try appendCodeBlockCell(lines, allocator, prefix, "", width);
        return;
    }

    var start: usize = 0;
    while (start < line.len) {
        const end = @min(start + width, line.len);
        try appendCodeBlockCell(lines, allocator, prefix, line[start..end], width);
        start = end;
    }
}

fn appendCodeBlockCell(
    lines: *std.ArrayList([]const u8),
    allocator: Allocator,
    prefix: []const u8,
    segment: []const u8,
    width: usize,
) !void {
    var padded: std.ArrayList(u8) = .{};
    defer padded.deinit(allocator);

    try padded.appendSlice(allocator, segment);
    if (segment.len < width) {
        const fill = width - segment.len;
        try padded.appendNTimes(allocator, ' ', fill);
    }

    const styled = try ansi.bgGray(allocator, padded.items);
    defer allocator.free(styled);
    const merged = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, styled });
    try lines.append(allocator, merged);
}

fn appendBlankLine(
    lines: *std.ArrayList([]const u8),
    allocator: Allocator,
    padding_x: u16,
) !void {
    const prefix = try makePadding(allocator, padding_x);
    defer allocator.free(prefix);
    try lines.append(allocator, try allocator.dupe(u8, prefix));
}

fn hasRenderedContent(lines: []const []const u8, padding_y: u16) bool {
    return lines.len > padding_y;
}

fn makePadding(allocator: Allocator, count: u16) ![]u8 {
    const out = try allocator.alloc(u8, count);
    @memset(out, ' ');
    return out;
}

test "markdown renders headings and code blocks" {
    var md = Markdown.init(std.testing.allocator, "# Title\n```\nzig\n```", 1, 0);
    defer md.deinit();

    const lines = try md.component().render(40, std.testing.allocator);
    defer {
        for (lines) |line| std.testing.allocator.free(line);
        std.testing.allocator.free(lines);
    }

    try std.testing.expect(lines.len >= 2);
    try std.testing.expect(std.mem.indexOf(u8, lines[0], "Title") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines[1], "\x1b[48;5;236mzig") != null);
}

test "markdown styles inline code spans with color" {
    var md = Markdown.init(std.testing.allocator, "run `echo hi` now", 1, 0);
    defer md.deinit();

    const lines = try md.component().render(80, std.testing.allocator);
    defer {
        for (lines) |line| std.testing.allocator.free(line);
        std.testing.allocator.free(lines);
    }

    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expect(std.mem.indexOf(u8, lines[0], "\x1b[36mecho hi\x1b[0m") != null);
}

test "markdown collapses repeated blank lines outside code blocks" {
    var md = Markdown.init(std.testing.allocator, "one\n\n\n\ntwo", 1, 0);
    defer md.deinit();

    const lines = try md.component().render(80, std.testing.allocator);
    defer {
        for (lines) |line| std.testing.allocator.free(line);
        std.testing.allocator.free(lines);
    }

    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings(" one", lines[0]);
    try std.testing.expectEqualStrings(" ", lines[1]);
    try std.testing.expectEqualStrings(" two", lines[2]);
}
