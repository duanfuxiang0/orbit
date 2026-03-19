const std = @import("std");
const lines_util = @import("lines_util.zig");

const Allocator = std.mem.Allocator;

pub const Component = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        render: *const fn (ptr: *anyopaque, width: u16, allocator: Allocator) anyerror![][]const u8,
        handle_input: ?*const fn (ptr: *anyopaque, data: []const u8) anyerror!bool,
        invalidate: *const fn (ptr: *anyopaque) void,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn render(self: Component, width: u16, allocator: Allocator) ![][]const u8 {
        return self.vtable.render(self.ptr, width, allocator);
    }

    pub fn handleInput(self: Component, data: []const u8) !bool {
        if (self.vtable.handle_input) |handler| {
            return try handler(self.ptr, data);
        }
        return false;
    }

    pub fn invalidate(self: Component) void {
        self.vtable.invalidate(self.ptr);
    }

    pub fn deinit(self: Component) void {
        self.vtable.deinit(self.ptr);
    }
};

pub const Container = struct {
    allocator: Allocator,
    children: std.ArrayList(Component),

    pub fn init(allocator: Allocator) Container {
        return .{
            .allocator = allocator,
            .children = .{},
        };
    }

    pub fn deinit(self: *Container) void {
        for (self.children.items) |child| {
            child.deinit();
        }
        self.children.deinit(self.allocator);
    }

    pub fn addChild(self: *Container, child: Component) !void {
        try self.children.append(self.allocator, child);
    }

    pub fn clear(self: *Container) void {
        for (self.children.items) |child| {
            child.deinit();
        }
        self.children.clearRetainingCapacity();
    }

    pub fn component(self: *Container) Component {
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

    fn renderImpl(ptr: *anyopaque, width: u16, allocator: Allocator) ![][]const u8 {
        const self: *Container = @ptrCast(@alignCast(ptr));
        std.debug.assert(width > 0);

        var output: std.ArrayList([]const u8) = .{};
        errdefer {
            for (output.items) |line| allocator.free(line);
            output.deinit(allocator);
        }

        for (self.children.items) |child| {
            const child_lines = try child.render(width, allocator);
            try lines_util.appendOwnedLines(&output, allocator, child_lines);
        }

        return output.toOwnedSlice(allocator);
    }

    fn invalidateImpl(ptr: *anyopaque) void {
        const self: *Container = @ptrCast(@alignCast(ptr));
        for (self.children.items) |child| {
            child.invalidate();
        }
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *Container = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

pub const Text = struct {
    allocator: Allocator,
    text: []u8,

    pub fn init(allocator: Allocator, text: []const u8) !*Text {
        const self = try allocator.create(Text);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .text = try allocator.dupe(u8, text),
        };
        return self;
    }

    pub fn setText(self: *Text, text: []const u8) !void {
        const next = try self.allocator.dupe(u8, text);
        self.allocator.free(self.text);
        self.text = next;
    }

    pub fn component(self: *Text) Component {
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

    fn renderImpl(ptr: *anyopaque, width: u16, allocator: Allocator) ![][]const u8 {
        const self: *Text = @ptrCast(@alignCast(ptr));
        std.debug.assert(width > 0);

        const lines = try allocator.alloc([]const u8, 1);
        errdefer allocator.free(lines);
        lines[0] = try allocator.dupe(u8, self.text);
        return lines;
    }

    fn invalidateImpl(_: *anyopaque) void {}

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *Text = @ptrCast(@alignCast(ptr));
        self.allocator.free(self.text);
        self.allocator.destroy(self);
    }
};

test "container stacks child lines" {
    var container = Container.init(std.testing.allocator);
    defer container.deinit();

    const first = try Text.init(std.testing.allocator, "alpha");
    const second = try Text.init(std.testing.allocator, "beta");
    try container.addChild(first.component());
    try container.addChild(second.component());

    const lines = try container.component().render(80, std.testing.allocator);
    defer {
        for (lines) |line| std.testing.allocator.free(line);
        std.testing.allocator.free(lines);
    }

    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("alpha", lines[0]);
    try std.testing.expectEqualStrings("beta", lines[1]);
}
