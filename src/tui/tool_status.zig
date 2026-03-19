const std = @import("std");
const ansi = @import("ansi.zig");
const component_mod = @import("component.zig");

const Allocator = std.mem.Allocator;
const Component = component_mod.Component;

pub const ToolStatus = struct {
    allocator: Allocator,
    name: []u8,
    state: State = .running,
    detail: ?[]u8 = null,

    pub const State = enum { running, done, err };

    pub fn init(allocator: Allocator, name: []const u8) !ToolStatus {
        return .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
        };
    }

    pub fn deinit(self: *ToolStatus) void {
        self.allocator.free(self.name);
        if (self.detail) |d| self.allocator.free(d);
        self.* = undefined;
    }

    pub fn setDone(self: *ToolStatus, detail: ?[]const u8) !void {
        if (self.detail) |d| self.allocator.free(d);
        self.detail = if (detail) |d| try self.allocator.dupe(u8, d) else null;
        self.state = .done;
    }

    pub fn setError(self: *ToolStatus, detail: ?[]const u8) !void {
        if (self.detail) |d| self.allocator.free(d);
        self.detail = if (detail) |d| try self.allocator.dupe(u8, d) else null;
        self.state = .err;
    }

    pub fn component(self: *ToolStatus) Component {
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
        const self: *ToolStatus = @ptrCast(@alignCast(ptr));
        _ = width;

        const icon: []const u8 = switch (self.state) {
            .running => "⟳",
            .done => "✓",
            .err => "✗",
        };
        const color: ansi.Color = switch (self.state) {
            .running => .yellow,
            .done => .green,
            .err => .red,
        };

        const label = if (self.detail) |d|
            try std.fmt.allocPrint(allocator, "{s} {s}", .{ self.name, d })
        else
            try allocator.dupe(u8, self.name);
        defer allocator.free(label);

        const styled = try ansi.colored(allocator, label, color);
        errdefer allocator.free(styled);

        const line = try std.fmt.allocPrint(allocator, "{s} {s}", .{ icon, styled });
        errdefer allocator.free(line);
        allocator.free(styled);

        const lines = try allocator.alloc([]const u8, 1);
        lines[0] = line;
        return lines;
    }

    fn invalidateImpl(_: *anyopaque) void {}

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *ToolStatus = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

test "tool status renders running state" {
    const allocator = std.testing.allocator;
    var ts = try ToolStatus.init(allocator, "bash");
    defer ts.deinit();

    const lines = try ts.component().render(80, allocator);
    defer {
        for (lines) |line| allocator.free(line);
        allocator.free(lines);
    }

    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expect(std.mem.indexOf(u8, lines[0], "bash") != null);
}

test "tool status renders done with detail" {
    const allocator = std.testing.allocator;
    var ts = try ToolStatus.init(allocator, "read");
    defer ts.deinit();

    try ts.setDone("src/main.zig");

    const lines = try ts.component().render(80, allocator);
    defer {
        for (lines) |line| allocator.free(line);
        allocator.free(lines);
    }

    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expect(std.mem.indexOf(u8, lines[0], "read") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines[0], "src/main.zig") != null);
}

test "tool status renders error state" {
    const allocator = std.testing.allocator;
    var ts = try ToolStatus.init(allocator, "edit");
    defer ts.deinit();

    try ts.setError("not found");

    const lines = try ts.component().render(80, allocator);
    defer {
        for (lines) |line| allocator.free(line);
        allocator.free(lines);
    }

    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expect(std.mem.indexOf(u8, lines[0], "edit") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines[0], "not found") != null);
}
