const std = @import("std");
const vaxis = @import("vaxis");
const state_mod = @import("../state.zig");
const runtime_renderer = @import("../runtime/renderer.zig");
const fullscreen_ui = @import("../ui/root.zig");
const vaxis_bridge = @import("vaxis_bridge.zig");

const Allocator = std.mem.Allocator;

pub const Mode = enum {
    inline_mode,
    fullscreen,
};

const Cursor = struct {
    visible: bool,
    row: u16,
    col: u16,
};

const InlineFrame = struct {
    lines: [][]const u8,
    cursor: Cursor,

    fn deinit(self: *InlineFrame, allocator: Allocator) void {
        for (self.lines) |line| {
            allocator.free(line);
        }
        allocator.free(self.lines);
    }
};

const ChangeRange = struct {
    first: usize,
    last: usize,
};

pub const Tui = struct {
    allocator: Allocator,
    renderer: *runtime_renderer.Renderer,
    bridge: vaxis_bridge.VaxisBridge,
    mode: Mode = .inline_mode,
    backbuffer: std.ArrayList([]u8),
    previous_width: u16 = 0,
    previous_height: u16 = 0,
    last_cursor: Cursor = .{ .visible = false, .row = 0, .col = 0 },

    pub fn init(allocator: Allocator, renderer: *runtime_renderer.Renderer) Tui {
        return .{
            .allocator = allocator,
            .renderer = renderer,
            .bridge = vaxis_bridge.VaxisBridge.init(renderer),
            .backbuffer = .{},
        };
    }

    pub fn deinit(self: *Tui) void {
        self.exitFullscreen() catch {};
        self.clearBackbuffer();
        self.backbuffer.deinit(self.allocator);
        self.renderer.showCursor() catch {};
    }

    pub fn modeName(self: *const Tui) []const u8 {
        return switch (self.mode) {
            .inline_mode => "inline",
            .fullscreen => "fullscreen",
        };
    }

    pub fn toggleMode(self: *Tui) !void {
        switch (self.mode) {
            .inline_mode => try self.enterFullscreen(),
            .fullscreen => try self.exitFullscreen(),
        }
    }

    pub fn enterFullscreen(self: *Tui) !void {
        if (self.mode == .fullscreen) return;
        try self.bridge.enterFullscreen();
        self.mode = .fullscreen;
    }

    pub fn exitFullscreen(self: *Tui) !void {
        if (self.mode == .inline_mode) return;
        try self.bridge.exitFullscreen();
        self.mode = .inline_mode;
        self.previous_width = 0;
        self.previous_height = 0;
    }

    pub fn render(
        self: *Tui,
        state: *const state_mod.State,
        input: *vaxis.widgets.TextInput,
    ) !void {
        switch (self.mode) {
            .fullscreen => {
                const win = self.renderer.window();
                fullscreen_ui.draw(win, state, input);
                try self.renderer.render();
            },
            .inline_mode => {
                try self.renderInline(state, input);
            },
        }
    }

    fn renderInline(self: *Tui, state: *const state_mod.State, input: *vaxis.widgets.TextInput) !void {
        const size = self.renderer.size();
        const frame = try buildInlineFrame(self.allocator, state, input, size.width, size.height);
        defer {
            var owned = frame;
            owned.deinit(self.allocator);
        }

        const width_changed = self.previous_width != size.width;
        const height_changed = self.previous_height != size.height;
        const should_full_redraw = width_changed or height_changed or self.backbuffer.items.len == 0;

        if (should_full_redraw) {
            try self.fullRender(frame);
        } else {
            try self.diffRender(frame);
        }

        try self.updateBackbuffer(frame.lines);
        self.previous_width = size.width;
        self.previous_height = size.height;
        self.last_cursor = frame.cursor;
    }

    fn fullRender(self: *Tui, frame: InlineFrame) !void {
        var out: std.ArrayList(u8) = .{};
        defer out.deinit(self.allocator);

        try out.appendSlice(self.allocator, "\x1b[?2026h");
        try moveToTop(&out, self.allocator, self.last_cursor.row);

        const clear_rows = @max(self.backbuffer.items.len, frame.lines.len);
        try clearRows(&out, self.allocator, clear_rows);
        try moveToTop(
            &out,
            self.allocator,
            if (clear_rows > 0) @as(u16, @intCast(clear_rows - 1)) else 0,
        );

        try drawRows(&out, self.allocator, frame.lines);
        try applyCursor(&out, self.allocator, frame.cursor, frame.lines.len);
        try out.appendSlice(self.allocator, "\x1b[?2026l");

        try self.renderer.writeRaw(out.items);
    }

    fn diffRender(self: *Tui, frame: InlineFrame) !void {
        const range = changedRange(self.backbuffer.items, frame.lines);
        if (range == null and sameCursor(self.last_cursor, frame.cursor)) {
            return;
        }

        var out: std.ArrayList(u8) = .{};
        defer out.deinit(self.allocator);

        try out.appendSlice(self.allocator, "\x1b[?2026h");
        try moveToTop(&out, self.allocator, self.last_cursor.row);

        if (range) |span| {
            var current_row: usize = 0;
            var row = span.first;
            while (row <= span.last) : (row += 1) {
                if (row > current_row) {
                    try moveDown(&out, self.allocator, row - current_row);
                    current_row = row;
                }
                try out.appendSlice(self.allocator, "\r");
                if (row < frame.lines.len) {
                    try out.appendSlice(self.allocator, frame.lines[row]);
                    try out.appendSlice(self.allocator, "\x1b[K");
                } else {
                    try out.appendSlice(self.allocator, "\x1b[2K");
                }
            }
        }

        try applyCursor(&out, self.allocator, frame.cursor, frame.lines.len);
        try out.appendSlice(self.allocator, "\x1b[?2026l");
        try self.renderer.writeRaw(out.items);
    }

    fn updateBackbuffer(self: *Tui, lines: [][]const u8) !void {
        self.clearBackbuffer();
        try self.backbuffer.ensureTotalCapacity(self.allocator, lines.len);

        for (lines) |line| {
            try self.backbuffer.append(self.allocator, try self.allocator.dupe(u8, line));
        }
    }

    fn clearBackbuffer(self: *Tui) void {
        for (self.backbuffer.items) |line| {
            self.allocator.free(line);
        }
        self.backbuffer.clearRetainingCapacity();
    }
};

fn buildInlineFrame(
    allocator: Allocator,
    state: *const state_mod.State,
    input: *vaxis.widgets.TextInput,
    width: u16,
    height: u16,
) !InlineFrame {
    const frame_height: usize = if (height == 0) 1 else height;
    const frame_width: usize = if (width == 0) 1 else width;

    var rows: std.ArrayList([]const u8) = .{};
    errdefer {
        for (rows.items) |line| allocator.free(line);
        rows.deinit(allocator);
    }

    try appendRow(&rows, allocator, "Orbit", frame_width);
    try appendRouteRow(&rows, allocator, state, frame_width);

    var cursor: Cursor = .{ .visible = false, .row = 0, .col = 0 };

    switch (state.route) {
        .home => {
            try appendHomeRows(&rows, allocator, state, frame_width, frame_height);
        },
        .session => {
            cursor = try appendSessionRows(&rows, allocator, state, input, frame_width, frame_height);
        },
    }

    try appendStatusRow(&rows, allocator, state, frame_width);

    if (rows.items.len > frame_height) {
        const extra = rows.items.len - frame_height;
        var i: usize = 0;
        while (i < extra) : (i += 1) {
            allocator.free(rows.items[i]);
        }
        std.mem.copyForwards([]const u8, rows.items[0 .. rows.items.len - extra], rows.items[extra..]);
        rows.items.len -= extra;

        if (cursor.row >= frame_height) {
            cursor.row = @intCast(frame_height - 1);
        }
    }

    while (rows.items.len < frame_height) {
        try rows.append(allocator, try allocator.dupe(u8, ""));
    }

    if (cursor.visible) {
        cursor.row = @min(cursor.row, @as(u16, @intCast(frame_height - 1)));
        cursor.col = @min(cursor.col, @as(u16, @intCast(frame_width - 1)));
    }

    return .{
        .lines = try rows.toOwnedSlice(allocator),
        .cursor = cursor,
    };
}

fn appendHomeRows(
    rows: *std.ArrayList([]const u8),
    allocator: Allocator,
    state: *const state_mod.State,
    width: usize,
    height: usize,
) !void {
    _ = height;
    try appendRow(rows, allocator, "Home", width);

    if (state.sessionCount() == 0) {
        try appendRow(rows, allocator, "No sessions. Press Enter or n.", width);
        return;
    }

    try appendRow(rows, allocator, "Sessions:", width);
    for (state.sessions.items, 0..) |session, idx| {
        const marker = if (state.selectedIndex()) |selected| selected == idx else false;
        const line = if (marker)
            try std.fmt.allocPrint(allocator, "> {s}", .{session.titleSlice()})
        else
            try std.fmt.allocPrint(allocator, "  {s}", .{session.titleSlice()});
        defer allocator.free(line);
        try appendRow(rows, allocator, line, width);
    }
}

fn appendSessionRows(
    rows: *std.ArrayList([]const u8),
    allocator: Allocator,
    state: *const state_mod.State,
    input: *vaxis.widgets.TextInput,
    width: usize,
    height: usize,
) !Cursor {
    if (state.selectedSession()) |session| {
        const header = try std.fmt.allocPrint(allocator, "Session: {s}", .{session.titleSlice()});
        defer allocator.free(header);
        try appendRow(rows, allocator, header, width);
    } else {
        try appendRow(rows, allocator, "No session selected", width);
        return .{ .visible = false, .row = 0, .col = 0 };
    }

    try appendRow(rows, allocator, "Messages:", width);

    const reserve_for_input: usize = 3;
    const used = rows.items.len;
    const budget = if (height > used + reserve_for_input) height - used - reserve_for_input else 0;

    const all_lines = try collectMessageRows(allocator, state);
    defer {
        for (all_lines) |line| allocator.free(line);
        allocator.free(all_lines);
    }

    const visible = @min(all_lines.len, budget);
    const max_scroll = all_lines.len -| visible;
    const scroll = @min(state.messageScroll(), max_scroll);
    const start = max_scroll -| scroll;
    const end = start + visible;

    for (all_lines[start..end]) |line| {
        try appendRow(rows, allocator, line, width);
    }

    const input_text = try snapshotInputText(allocator, input);
    defer allocator.free(input_text);

    const prompt = try std.fmt.allocPrint(allocator, "> {s}", .{input_text});
    defer allocator.free(prompt);

    const row = @as(u16, @intCast(rows.items.len));
    try appendRow(rows, allocator, prompt, width);
    try appendRow(rows, allocator, "Ctrl+L toggle fullscreen | Enter send", width);

    const cursor_col = @as(u16, @intCast(2 + input.byteOffsetToCursor()));
    return .{ .visible = true, .row = row, .col = cursor_col };
}

fn collectMessageRows(allocator: Allocator, state: *const state_mod.State) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .{};
    errdefer {
        for (out.items) |line| allocator.free(line);
        out.deinit(allocator);
    }

    for (state.messages.items) |message| {
        const prefix = switch (message.role) {
            .user => "user",
            .assistant => "assistant",
            .thinking => "thinking",
            .tool => "tool",
        };

        var iter = std.mem.splitScalar(u8, message.textSlice(), '\n');
        while (iter.next()) |part| {
            const line = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ prefix, part });
            try out.append(allocator, line);
        }
        try out.append(allocator, try allocator.dupe(u8, ""));
    }

    return out.toOwnedSlice(allocator);
}

fn appendStatusRow(
    rows: *std.ArrayList([]const u8),
    allocator: Allocator,
    state: *const state_mod.State,
    width: usize,
) !void {
    const text = try std.fmt.allocPrint(allocator, "Status: {s}", .{state.status()});
    defer allocator.free(text);
    try appendRow(rows, allocator, text, width);
}

fn appendRouteRow(
    rows: *std.ArrayList([]const u8),
    allocator: Allocator,
    state: *const state_mod.State,
    width: usize,
) !void {
    const route_text = switch (state.route) {
        .home => "Route: HOME",
        .session => "Route: SESSION",
    };
    try appendRow(rows, allocator, route_text, width);
}

fn appendRow(
    rows: *std.ArrayList([]const u8),
    allocator: Allocator,
    text: []const u8,
    width: usize,
) !void {
    const clean = try sanitizeText(allocator, text, width);
    errdefer allocator.free(clean);
    try rows.append(allocator, clean);
}

fn sanitizeText(allocator: Allocator, text: []const u8, width: usize) ![]u8 {
    var tmp: std.ArrayList(u8) = .{};
    defer tmp.deinit(allocator);

    for (text) |ch| {
        if (ch == 0x1b) {
            try tmp.append(allocator, '?');
            continue;
        }

        if (ch < 32 and ch != '\t') {
            try tmp.append(allocator, ' ');
            continue;
        }

        try tmp.append(allocator, ch);
    }

    const slice = if (tmp.items.len > width) tmp.items[0..width] else tmp.items;
    return allocator.dupe(u8, slice);
}

fn snapshotInputText(allocator: Allocator, input: *vaxis.widgets.TextInput) ![]u8 {
    const first = input.buf.firstHalf();
    const second = input.buf.secondHalf();
    const out = try allocator.alloc(u8, first.len + second.len);
    @memcpy(out[0..first.len], first);
    @memcpy(out[first.len..], second);
    return out;
}

fn changedRange(old: []const []const u8, new: []const []const u8) ?ChangeRange {
    const max_len = @max(old.len, new.len);
    var first: ?usize = null;
    var last: usize = 0;

    var i: usize = 0;
    while (i < max_len) : (i += 1) {
        const old_line = if (i < old.len) old[i] else "";
        const new_line = if (i < new.len) new[i] else "";
        if (!std.mem.eql(u8, old_line, new_line)) {
            if (first == null) first = i;
            last = i;
        }
    }

    if (first == null) return null;
    return .{ .first = first.?, .last = last };
}

fn sameCursor(a: Cursor, b: Cursor) bool {
    if (a.visible != b.visible) return false;
    if (a.row != b.row) return false;
    return a.col == b.col;
}

fn moveToTop(out: *std.ArrayList(u8), allocator: Allocator, row: u16) !void {
    if (row == 0) {
        try out.appendSlice(allocator, "\r");
        return;
    }
    try out.writer(allocator).print("\x1b[{d}A\r", .{row});
}

fn moveDown(out: *std.ArrayList(u8), allocator: Allocator, count: usize) !void {
    if (count == 0) return;
    try out.writer(allocator).print("\x1b[{d}B", .{count});
}

fn clearRows(out: *std.ArrayList(u8), allocator: Allocator, count: usize) !void {
    if (count == 0) return;

    var i: usize = 0;
    while (i < count) : (i += 1) {
        try out.appendSlice(allocator, "\x1b[2K");
        if (i + 1 < count) {
            try out.appendSlice(allocator, "\x1b[1B\r");
        }
    }
}

fn drawRows(out: *std.ArrayList(u8), allocator: Allocator, rows: [][]const u8) !void {
    if (rows.len == 0) return;

    for (rows, 0..) |line, idx| {
        try out.appendSlice(allocator, "\r");
        try out.appendSlice(allocator, line);
        try out.appendSlice(allocator, "\x1b[K");

        if (idx + 1 < rows.len) {
            try out.appendSlice(allocator, "\x1b[1B");
        }
    }
}

fn applyCursor(
    out: *std.ArrayList(u8),
    allocator: Allocator,
    cursor: Cursor,
    rows_len: usize,
) !void {
    const bottom = if (rows_len == 0) 0 else rows_len - 1;

    if (cursor.visible) {
        if (bottom > cursor.row) {
            const up = bottom - cursor.row;
            try out.writer(allocator).print("\x1b[{d}A", .{up});
        }
        try out.writer(allocator).print("\x1b[{d}G", .{cursor.col + 1});
        try out.appendSlice(allocator, "\x1b[?25h");
        return;
    }

    try out.appendSlice(allocator, "\x1b[?25l");
}

test "changed range detects single line mutation" {
    const old = [_][]const u8{ "a", "b", "c" };
    const new = [_][]const u8{ "a", "x", "c" };
    const span = changedRange(&old, &new).?;

    try std.testing.expectEqual(@as(usize, 1), span.first);
    try std.testing.expectEqual(@as(usize, 1), span.last);
}

test "changed range handles append" {
    const old = [_][]const u8{"a"};
    const new = [_][]const u8{ "a", "b" };
    const span = changedRange(&old, &new).?;

    try std.testing.expectEqual(@as(usize, 1), span.first);
    try std.testing.expectEqual(@as(usize, 1), span.last);
}
