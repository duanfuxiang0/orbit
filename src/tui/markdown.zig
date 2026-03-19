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
    var iterator = std.mem.splitScalar(u8, self.text, '\n');

    while (iterator.next()) |raw_line| {
        if (std.mem.startsWith(u8, raw_line, "```")) {
            in_code_block = !in_code_block;
            const boundary = if (in_code_block) "+-- code --" else "+---------";
            const styled = try ansi.dimText(allocator, boundary);
            defer allocator.free(styled);
            try appendWrapped(&lines, allocator, styled, self.padding_x, content_width);
            continue;
        }

        if (in_code_block) {
            const styled = try ansi.bgGray(allocator, raw_line);
            defer allocator.free(styled);
            try appendWrapped(&lines, allocator, styled, self.padding_x, content_width);
            continue;
        }

        if (raw_line.len > 0 and raw_line[0] == '#') {
            const heading = std.mem.trimLeft(u8, raw_line, "# ");
            const styled = try ansi.boldText(allocator, heading);
            defer allocator.free(styled);
            try appendWrapped(&lines, allocator, styled, self.padding_x, content_width);
            continue;
        }

        try appendWrapped(&lines, allocator, raw_line, self.padding_x, content_width);
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

fn appendWrapped(
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
        try lines.append(allocator, try allocator.dupe(u8, prefix));
        return;
    }

    var start: usize = 0;
    while (start < line.len) {
        const end = @min(start + width, line.len);
        const wrapped = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, line[start..end] });
        try lines.append(allocator, wrapped);
        start = end;
    }
}

fn makePadding(allocator: Allocator, count: u16) ![]u8 {
    const out = try allocator.alloc(u8, count);
    @memset(out, ' ');
    return out;
}

test "markdown renders headings and code fences" {
    var md = Markdown.init(std.testing.allocator, "# Title\n```\nzig\n```", 1, 0);
    defer md.deinit();

    const lines = try md.component().render(40, std.testing.allocator);
    defer {
        for (lines) |line| std.testing.allocator.free(line);
        std.testing.allocator.free(lines);
    }

    try std.testing.expect(lines.len >= 4);
    try std.testing.expect(std.mem.indexOf(u8, lines[0], "Title") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines[1], "code") != null);
}
