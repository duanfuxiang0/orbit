const std = @import("std");

pub const Route = enum {
    home,
    session,
};

pub const Session = struct {
    id: [64]u8 = undefined,
    id_len: usize = 0,
    title: [128]u8 = undefined,
    title_len: usize = 0,

    pub fn idSlice(self: *const Session) []const u8 {
        return self.id[0..self.id_len];
    }

    pub fn titleSlice(self: *const Session) []const u8 {
        return self.title[0..self.title_len];
    }
};

pub const SessionSeed = struct {
    id: []const u8,
    title: []const u8,
};

pub const MessageRole = enum {
    user,
    assistant,
    thinking,
    tool,
};

pub const Message = struct {
    role: MessageRole = .assistant,
    text: []u8,

    pub fn textSlice(self: *const Message) []const u8 {
        return self.text;
    }

    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub const MessageSeed = struct {
    role: MessageRole,
    text: []const u8,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    route: Route = .home,
    sessions: std.ArrayListUnmanaged(Session) = .{},
    messages: std.ArrayListUnmanaged(Message) = .{},
    message_scroll: usize = 0,
    selected_index: usize = 0,
    next_session_id: u32 = 1,
    status_text: [160]u8 = undefined,
    status_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator) State {
        var self: State = .{
            .allocator = allocator,
        };
        self.setStatus("Tab switch view | Enter create/open | j/k move | n new | r refresh | q quit");
        return self;
    }

    pub fn deinit(self: *State) void {
        self.sessions.deinit(self.allocator);
        self.clearMessages();
        self.messages.deinit(self.allocator);
    }

    pub fn sessionCount(self: *const State) usize {
        return self.sessions.items.len;
    }

    pub fn selectedIndex(self: *const State) ?usize {
        if (self.sessions.items.len == 0) return null;
        return @min(self.selected_index, self.sessions.items.len - 1);
    }

    pub fn selectedSession(self: *const State) ?*const Session {
        const idx = self.selectedIndex() orelse return null;
        return &self.sessions.items[idx];
    }

    pub fn messageCount(self: *const State) usize {
        return self.messages.items.len;
    }

    pub fn messageScroll(self: *const State) usize {
        return self.message_scroll;
    }

    pub fn scrollMessagesUp(self: *State, lines: usize) void {
        self.message_scroll +|= lines;
    }

    pub fn scrollMessagesDown(self: *State, lines: usize) void {
        self.message_scroll -|= lines;
    }

    pub fn resetMessageScroll(self: *State) void {
        self.message_scroll = 0;
    }

    pub fn toggleRoute(self: *State) void {
        self.route = switch (self.route) {
            .home => .session,
            .session => .home,
        };
    }

    pub fn backHome(self: *State) void {
        self.route = .home;
        self.setStatus("Home");
    }

    pub fn createSession(self: *State) !void {
        var id_buf: [32]u8 = undefined;
        const id_text = try std.fmt.bufPrint(&id_buf, "local-{d}", .{self.next_session_id});

        var title_buf: [64]u8 = undefined;
        const title_text = try std.fmt.bufPrint(&title_buf, "Session #{d}", .{self.next_session_id});

        const session = self.makeSession(.{ .id = id_text, .title = title_text });

        try self.sessions.append(self.allocator, session);
        self.next_session_id += 1;
        self.selected_index = self.sessions.items.len - 1;
        self.route = .session;
        self.clearMessages();

        self.setStatusFmt("Created {s}", .{title_text}) catch self.setStatus("Created session");
    }

    pub fn replaceSessions(self: *State, seeds: []const SessionSeed) !void {
        var previous_id: [64]u8 = undefined;
        var previous_id_len: usize = 0;

        if (self.selectedSession()) |selected| {
            previous_id_len = @min(selected.id_len, previous_id.len);
            @memcpy(previous_id[0..previous_id_len], selected.id[0..previous_id_len]);
        }

        self.sessions.items.len = 0;

        for (seeds) |seed| {
            try self.sessions.append(self.allocator, self.makeSession(seed));
        }

        if (self.sessions.items.len == 0) {
            self.selected_index = 0;
            if (self.route == .session) self.route = .home;
            self.clearMessages();
            return;
        }

        self.selected_index = 0;
        if (previous_id_len > 0) {
            for (self.sessions.items, 0..) |session, i| {
                if (std.mem.eql(u8, session.idSlice(), previous_id[0..previous_id_len])) {
                    self.selected_index = i;
                    break;
                }
            }
        }
    }

    pub fn addOrSelectSession(self: *State, seed: SessionSeed) !void {
        for (self.sessions.items, 0..) |*session, i| {
            if (!std.mem.eql(u8, session.idSlice(), seed.id)) continue;
            session.* = self.makeSession(seed);
            self.selected_index = i;
            self.route = .session;
            self.clearMessages();
            return;
        }

        try self.sessions.append(self.allocator, self.makeSession(seed));
        self.selected_index = self.sessions.items.len - 1;
        self.route = .session;
        self.clearMessages();
    }

    pub fn openSelected(self: *State) void {
        const session = self.selectedSession() orelse {
            self.setStatus("No session selected");
            return;
        };

        self.route = .session;
        self.clearMessages();
        self.setStatusFmt("Opened {s}", .{session.titleSlice()}) catch self.setStatus("Opened session");
    }

    pub fn moveUp(self: *State) void {
        if (self.sessions.items.len == 0) return;
        self.selected_index -|= 1;
    }

    pub fn moveDown(self: *State) void {
        if (self.sessions.items.len == 0) return;
        const max = self.sessions.items.len - 1;
        self.selected_index = @min(self.selected_index + 1, max);
    }

    pub fn status(self: *const State) []const u8 {
        return self.status_text[0..self.status_len];
    }

    pub fn replaceMessages(self: *State, seeds: []const MessageSeed) !void {
        self.clearMessagesKeepScroll();

        for (seeds) |seed| {
            var message = try self.makeMessage(seed);
            if (message.text.len == 0) {
                message.deinit(self.allocator);
                continue;
            }
            try self.messages.append(self.allocator, message);
        }
    }

    pub fn clearMessages(self: *State) void {
        self.clearMessagesKeepScroll();
        self.message_scroll = 0;
    }

    fn clearMessagesKeepScroll(self: *State) void {
        for (self.messages.items) |*message| {
            message.deinit(self.allocator);
        }
        self.messages.items.len = 0;
    }

    pub fn setStatus(self: *State, text: []const u8) void {
        const n = @min(text.len, self.status_text.len);
        @memcpy(self.status_text[0..n], text[0..n]);
        self.status_len = n;
    }

    fn makeSession(self: *const State, seed: SessionSeed) Session {
        _ = self;

        var session: Session = .{};

        const id_len = @min(seed.id.len, session.id.len);
        @memcpy(session.id[0..id_len], seed.id[0..id_len]);
        session.id_len = id_len;

        if (seed.title.len == 0) {
            const fallback = "Untitled session";
            const fallback_len = @min(fallback.len, session.title.len);
            @memcpy(session.title[0..fallback_len], fallback[0..fallback_len]);
            session.title_len = fallback_len;
            return session;
        }

        const title_len = @min(seed.title.len, session.title.len);
        @memcpy(session.title[0..title_len], seed.title[0..title_len]);
        session.title_len = title_len;

        return session;
    }

    fn makeMessage(self: *const State, seed: MessageSeed) !Message {
        const trimmed = std.mem.trim(u8, seed.text, " \r\n\t");
        return .{
            .role = seed.role,
            .text = try self.allocator.dupe(u8, trimmed),
        };
    }

    fn setStatusFmt(self: *State, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.bufPrint(&self.status_text, fmt, args);
        self.status_len = text.len;
    }
};

test "create session updates route and selection" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();

    try std.testing.expectEqual(@as(usize, 0), state.sessionCount());
    try state.createSession();

    try std.testing.expectEqual(@as(Route, .session), state.route);
    try std.testing.expectEqual(@as(usize, 1), state.sessionCount());
    try std.testing.expectEqual(@as(?usize, 0), state.selectedIndex());

    const session = state.selectedSession().?;
    try std.testing.expectEqualStrings("Session #1", session.titleSlice());
    try std.testing.expectEqualStrings("local-1", session.idSlice());
}

test "selection movement clamps to bounds" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();

    for (0..3) |_| {
        try state.createSession();
    }

    try std.testing.expectEqual(@as(?usize, 2), state.selectedIndex());

    state.moveDown();
    try std.testing.expectEqual(@as(?usize, 2), state.selectedIndex());

    state.moveUp();
    state.moveUp();
    state.moveUp();
    try std.testing.expectEqual(@as(?usize, 0), state.selectedIndex());
}

test "replace sessions keeps selected id when possible" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();

    try state.replaceSessions(&.{
        .{ .id = "a", .title = "Alpha" },
        .{ .id = "b", .title = "Beta" },
        .{ .id = "c", .title = "Gamma" },
    });
    state.selected_index = 1;

    try state.replaceSessions(&.{
        .{ .id = "x", .title = "X" },
        .{ .id = "b", .title = "Beta 2" },
    });

    try std.testing.expectEqual(@as(?usize, 1), state.selectedIndex());
    try std.testing.expectEqualStrings("b", state.selectedSession().?.idSlice());
    try std.testing.expectEqualStrings("Beta 2", state.selectedSession().?.titleSlice());
}

test "replace messages updates list" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();

    try state.replaceMessages(&.{
        .{ .role = .user, .text = "hello" },
        .{ .role = .assistant, .text = "world" },
    });

    try std.testing.expectEqual(@as(usize, 2), state.messageCount());
    try std.testing.expectEqual(@as(MessageRole, .user), state.messages.items[0].role);
    try std.testing.expectEqualStrings("hello", state.messages.items[0].textSlice());
    try std.testing.expectEqual(@as(MessageRole, .assistant), state.messages.items[1].role);
    try std.testing.expectEqualStrings("world", state.messages.items[1].textSlice());
}

test "message scroll moves and clamps at zero" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();

    try std.testing.expectEqual(@as(usize, 0), state.messageScroll());
    state.scrollMessagesUp(4);
    try std.testing.expectEqual(@as(usize, 4), state.messageScroll());

    state.scrollMessagesDown(2);
    try std.testing.expectEqual(@as(usize, 2), state.messageScroll());

    state.scrollMessagesDown(100);
    try std.testing.expectEqual(@as(usize, 0), state.messageScroll());
}

test "replace messages keeps manual scroll offset" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();

    state.scrollMessagesUp(7);
    try state.replaceMessages(&.{
        .{ .role = .assistant, .text = "one" },
        .{ .role = .assistant, .text = "two" },
    });

    try std.testing.expectEqual(@as(usize, 7), state.messageScroll());
}
