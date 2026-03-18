const std = @import("std");
const component_mod = @import("component.zig");
const lines_util = @import("lines_util.zig");

const Allocator = std.mem.Allocator;
const Component = component_mod.Component;

pub const Editor = struct {
    allocator: Allocator,
    buffer: std.ArrayList(u8),
    cursor_pos: usize = 0,
    prompt: []const u8,
    history: std.ArrayList([]u8),
    history_index: ?usize = null,
    cached_width: ?u16 = null,
    cached_lines: ?[][]const u8 = null,

    pub fn init(allocator: Allocator, prompt: []const u8) Editor {
        return .{
            .allocator = allocator,
            .buffer = .{},
            .prompt = prompt,
            .history = .{},
        };
    }

    pub fn deinit(self: *Editor) void {
        self.buffer.deinit(self.allocator);
        for (self.history.items) |entry| {
            self.allocator.free(entry);
        }
        self.history.deinit(self.allocator);
        freeCached(self);
    }

    pub fn component(self: *Editor) Component {
        return .{
            .ptr = self,
            .vtable = &.{
                .render = renderImpl,
                .handle_input = handleInputImpl,
                .invalidate = invalidateImpl,
                .deinit = deinitImpl,
            },
        };
    }

    pub fn getText(self: *const Editor) []const u8 {
        return self.buffer.items;
    }

    pub fn clear(self: *Editor) void {
        self.buffer.clearRetainingCapacity();
        self.cursor_pos = 0;
        self.history_index = null;
        self.invalidate();
    }

    pub fn pushHistory(self: *Editor) !void {
        if (self.buffer.items.len == 0) return;
        const item = try self.allocator.dupe(u8, self.buffer.items);
        try self.history.append(self.allocator, item);
        self.history_index = null;
    }

    pub fn setText(self: *Editor, text: []const u8) !void {
        self.buffer.clearRetainingCapacity();
        try self.buffer.appendSlice(self.allocator, text);
        self.cursor_pos = self.buffer.items.len;
        self.history_index = null;
        self.invalidate();
    }

    pub fn invalidate(self: *Editor) void {
        freeCached(self);
        self.cached_width = null;
    }

    fn renderImpl(ptr: *anyopaque, width: u16, allocator: Allocator) ![][]const u8 {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        std.debug.assert(width > 0);

        if (self.cached_width) |cached_width| {
            if (cached_width == width) {
                if (self.cached_lines) |lines| {
                    return lines_util.cloneLines(allocator, lines);
                }
            }
        }

        const rendered = try allocator.alloc([]const u8, 1);
        errdefer allocator.free(rendered);
        rendered[0] = try std.fmt.allocPrint(allocator, "{s}{s}", .{ self.prompt, self.buffer.items });

        freeCached(self);
        self.cached_lines = try lines_util.cloneLines(self.allocator, rendered);
        self.cached_width = width;
        return rendered;
    }

    fn handleInputImpl(ptr: *anyopaque, data: []const u8) !bool {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        return try self.handleInput(data);
    }

    fn handleInput(self: *Editor, data: []const u8) !bool {
        if (std.mem.eql(u8, data, "\x7f")) {
            if (self.cursor_pos == 0) return true;
            _ = self.buffer.orderedRemove(self.cursor_pos - 1);
            self.cursor_pos -= 1;
            self.invalidate();
            return true;
        }

        if (std.mem.eql(u8, data, "\x01")) {
            self.cursor_pos = 0;
            self.invalidate();
            return true;
        }

        if (std.mem.eql(u8, data, "\x05")) {
            self.cursor_pos = self.buffer.items.len;
            self.invalidate();
            return true;
        }

        if (std.mem.eql(u8, data, "\x1b[A")) {
            try self.moveHistoryUp();
            return true;
        }

        if (std.mem.eql(u8, data, "\x1b[B")) {
            try self.moveHistoryDown();
            return true;
        }

        if (!isPrintable(data)) return false;

        try self.buffer.insertSlice(self.allocator, self.cursor_pos, data);
        self.cursor_pos += data.len;
        self.invalidate();
        return true;
    }

    fn moveHistoryUp(self: *Editor) !void {
        if (self.history.items.len == 0) return;

        if (self.history_index) |idx| {
            if (idx == 0) return;
            self.history_index = idx - 1;
        } else {
            self.history_index = self.history.items.len - 1;
        }

        try self.loadHistoryAt(self.history_index.?);
    }

    fn moveHistoryDown(self: *Editor) !void {
        const idx = self.history_index orelse return;
        if (idx + 1 >= self.history.items.len) {
            self.history_index = null;
            self.clear();
            return;
        }

        self.history_index = idx + 1;
        try self.loadHistoryAt(self.history_index.?);
    }

    fn loadHistoryAt(self: *Editor, idx: usize) !void {
        std.debug.assert(idx < self.history.items.len);
        self.buffer.clearRetainingCapacity();
        try self.buffer.appendSlice(self.allocator, self.history.items[idx]);
        self.cursor_pos = self.buffer.items.len;
        self.invalidate();
    }

    fn invalidateImpl(ptr: *anyopaque) void {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        self.invalidate();
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

fn isPrintable(data: []const u8) bool {
    if (data.len == 0) return false;
    for (data) |ch| {
        if (ch < 32) return false;
    }
    return true;
}

fn freeCached(self: *Editor) void {
    lines_util.freeOptionalLines(self.allocator, self.cached_lines);
    self.cached_lines = null;
}

test "editor inserts and removes text" {
    var editor = Editor.init(std.testing.allocator, "> ");
    defer editor.deinit();

    try std.testing.expect(try editor.handleInput("abc"));
    try std.testing.expectEqualStrings("abc", editor.getText());

    try std.testing.expect(try editor.handleInput("\x7f"));
    try std.testing.expectEqualStrings("ab", editor.getText());
}

test "editor history load propagates allocator failure" {
    var storage: [256]u8 = [_]u8{0} ** 256;
    var backing = std.heap.FixedBufferAllocator.init(&storage);
    var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = 2 });

    var editor = Editor.init(failing.allocator(), "> ");
    defer editor.deinit();

    try editor.history.append(editor.allocator, try editor.allocator.dupe(u8, "saved"));
    try std.testing.expectError(error.OutOfMemory, editor.moveHistoryUp());
}
