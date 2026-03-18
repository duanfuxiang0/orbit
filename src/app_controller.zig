const std = @import("std");
const vaxis = @import("vaxis");
const state_mod = @import("state.zig");
const api = @import("api.zig");
const app_types = @import("app_types.zig");

pub const ApiClient = struct {
    client: api.Client,

    pub fn init(client: api.Client) ApiClient {
        return .{ .client = client };
    }

    pub fn listSessions(self: *ApiClient, allocator: std.mem.Allocator) ![]state_mod.SessionSeed {
        const remote = try self.client.listSessions();
        defer api.freeSessionSummaries(allocator, remote);

        var seeds = try allocator.alloc(state_mod.SessionSeed, remote.len);
        var i: usize = 0;
        errdefer {
            var j: usize = 0;
            while (j < i) : (j += 1) {
                allocator.free(seeds[j].id);
                allocator.free(seeds[j].title);
            }
            allocator.free(seeds);
        }

        for (remote, 0..) |session, idx| {
            seeds[idx] = .{
                .id = try allocator.dupe(u8, session.id),
                .title = try allocator.dupe(u8, session.title),
            };
            i += 1;
        }

        return seeds;
    }

    pub fn freeSessions(self: *ApiClient, allocator: std.mem.Allocator, seeds: []state_mod.SessionSeed) void {
        _ = self;
        for (seeds) |seed| {
            allocator.free(seed.id);
            allocator.free(seed.title);
        }
        allocator.free(seeds);
    }

    pub fn createSession(self: *ApiClient, allocator: std.mem.Allocator) !state_mod.SessionSeed {
        var created = try self.client.createSession();
        defer created.deinit(allocator);

        return .{
            .id = try allocator.dupe(u8, created.id),
            .title = try allocator.dupe(u8, created.title),
        };
    }

    pub fn freeSession(self: *ApiClient, allocator: std.mem.Allocator, seed: state_mod.SessionSeed) void {
        _ = self;
        allocator.free(seed.id);
        allocator.free(seed.title);
    }

    pub fn getSessionMessages(
        self: *ApiClient,
        allocator: std.mem.Allocator,
        session_id: []const u8,
    ) ![]state_mod.MessageSeed {
        const remote = try self.client.getSessionMessages(session_id);
        defer api.freeMessageLines(allocator, remote);

        var seeds = try allocator.alloc(state_mod.MessageSeed, remote.len);
        var i: usize = 0;
        errdefer {
            var j: usize = 0;
            while (j < i) : (j += 1) {
                allocator.free(seeds[j].text);
            }
            allocator.free(seeds);
        }

        for (remote, 0..) |message, idx| {
            seeds[idx] = .{
                .role = switch (message.role) {
                    .user => .user,
                    .assistant => .assistant,
                    .thinking => .thinking,
                    .tool => .tool,
                },
                .text = try allocator.dupe(u8, message.text),
            };
            i += 1;
        }

        return seeds;
    }

    pub fn freeMessages(self: *ApiClient, allocator: std.mem.Allocator, seeds: []state_mod.MessageSeed) void {
        _ = self;
        for (seeds) |seed| {
            allocator.free(seed.text);
        }
        allocator.free(seeds);
    }

    pub fn sendPrompt(self: *ApiClient, session_id: []const u8, text: []const u8) !void {
        try self.client.sendPrompt(session_id, text);
    }
};

pub fn initialize(
    comptime ApiType: type,
    state: *state_mod.State,
    maybe_api: ?*ApiType,
    offline: bool,
) !void {
    if (offline) {
        state.setStatus("Offline mode: API disabled");
        return;
    }

    if (maybe_api) |client| {
        refreshSessionsFromApi(ApiType, state, client) catch {
            state.setStatus("API unavailable; using local session mode");
        };
    }
}

pub fn handleIntent(
    comptime ApiType: type,
    state: *state_mod.State,
    text_input: *vaxis.widgets.TextInput,
    maybe_api: ?*ApiType,
    intent: app_types.AppIntent,
) !bool {
    switch (intent) {
        .quit => {
            return true;
        },
        .resize => {
            return false;
        },
        .tick => |policy| {
            switch (policy) {
                .refresh_session_messages => {
                    if (maybe_api) |client| {
                        refreshMessagesForSelected(ApiType, state, client, false) catch {};
                    }
                },
            }
            return false;
        },
        .input_key => |key| {
            text_input.update(.{ .key_press = key }) catch {
                state.setStatus("Input error");
            };
            return false;
        },
        .action => |action| {
            try handleAction(ApiType, state, text_input, maybe_api, action);
            return false;
        },
    }
}

fn handleAction(
    comptime ApiType: type,
    state: *state_mod.State,
    text_input: *vaxis.widgets.TextInput,
    maybe_api: ?*ApiType,
    action: app_types.Action,
) !void {
    switch (action) {
        .toggle_route => {
            state.toggleRoute();
            if (state.route == .session) {
                text_input.clearRetainingCapacity();
                if (maybe_api) |client| {
                    refreshMessagesForSelected(ApiType, state, client, false) catch {
                        state.setStatus("Failed to load messages");
                    };
                }
            } else {
                text_input.clearRetainingCapacity();
            }
        },
        .home_move_up => {
            state.moveUp();
        },
        .home_move_down => {
            state.moveDown();
        },
        .home_refresh_sessions => {
            if (maybe_api) |client| {
                refreshSessionsFromApi(ApiType, state, client) catch {
                    state.setStatus("Refresh failed");
                };
            } else {
                state.setStatus("Offline mode: no API to refresh");
            }
        },
        .home_create_session => {
            createSession(ApiType, state, maybe_api) catch {
                state.setStatus("Failed to create session");
            };
            text_input.clearRetainingCapacity();
            if (maybe_api) |client| {
                refreshMessagesForSelected(ApiType, state, client, false) catch {
                    state.setStatus("Failed to load messages");
                };
            }
        },
        .home_open_or_create_session => {
            if (state.sessionCount() == 0) {
                createSession(ApiType, state, maybe_api) catch {
                    state.setStatus("Failed to create session");
                };
            } else {
                state.openSelected();
            }

            if (state.route == .session) {
                text_input.clearRetainingCapacity();
                if (maybe_api) |client| {
                    refreshMessagesForSelected(ApiType, state, client, false) catch {
                        state.setStatus("Failed to load messages");
                    };
                }
            }
        },
        .session_scroll_up_page => {
            state.scrollMessagesUp(10);
        },
        .session_scroll_down_page => {
            state.scrollMessagesDown(10);
        },
        .session_back_home => {
            state.backHome();
            text_input.clearRetainingCapacity();
        },
        .session_refresh_messages_manual => {
            if (maybe_api) |client| {
                refreshMessagesForSelected(ApiType, state, client, true) catch {
                    state.setStatus("Failed to refresh messages");
                };
            } else {
                state.setStatus("Offline mode: no API to refresh");
            }
        },
        .session_submit_prompt => {
            const sent = submitPrompt(ApiType, state, text_input, maybe_api) catch blk: {
                state.setStatus("Failed to send prompt");
                break :blk false;
            };

            if (sent) {
                if (maybe_api) |client| {
                    refreshMessagesForSelected(ApiType, state, client, false) catch {};
                }
            }
        },
    }
}

fn refreshSessionsFromApi(comptime ApiType: type, state: *state_mod.State, client: *ApiType) !void {
    const remote = try client.listSessions(state.allocator);
    defer client.freeSessions(state.allocator, remote);

    try state.replaceSessions(remote);

    if (remote.len == 0) {
        state.setStatus("Synced: 0 sessions");
    } else {
        state.setStatus("Synced sessions from API");
    }
}

fn createSession(comptime ApiType: type, state: *state_mod.State, maybe_api: ?*ApiType) !void {
    if (maybe_api) |client| {
        const created = try client.createSession(state.allocator);
        defer client.freeSession(state.allocator, created);

        try state.addOrSelectSession(.{
            .id = created.id,
            .title = created.title,
        });
        state.setStatus("Created session via API");
        return;
    }

    try state.createSession();
}

fn refreshMessagesForSelected(
    comptime ApiType: type,
    state: *state_mod.State,
    client: *ApiType,
    announce: bool,
) !void {
    const session = state.selectedSession() orelse {
        state.clearMessages();
        return;
    };

    try refreshMessagesFromApi(ApiType, state, client, session.idSlice(), announce);
}

fn refreshMessagesFromApi(
    comptime ApiType: type,
    state: *state_mod.State,
    client: *ApiType,
    session_id: []const u8,
    announce: bool,
) !void {
    const remote = try client.getSessionMessages(state.allocator, session_id);
    defer client.freeMessages(state.allocator, remote);

    try state.replaceMessages(remote);

    if (announce) {
        if (remote.len == 0) {
            state.setStatus("No messages yet");
        } else {
            state.setStatus("Messages synced");
        }
    }
}

fn submitPrompt(
    comptime ApiType: type,
    state: *state_mod.State,
    text_input: *vaxis.widgets.TextInput,
    maybe_api: ?*ApiType,
) !bool {
    const raw = try text_input.toOwnedSlice();
    defer state.allocator.free(raw);

    const text = std.mem.trim(u8, raw, " \r\n\t");
    if (text.len == 0) {
        state.setStatus("Type a message first");
        return false;
    }

    const session = state.selectedSession() orelse {
        state.setStatus("No session selected");
        return false;
    };

    if (maybe_api) |client| {
        try client.sendPrompt(session.idSlice(), text);
        state.resetMessageScroll();
        state.setStatus("Prompt sent");
        return true;
    }

    state.setStatus("Offline mode: API disabled");
    return false;
}

const FakeApi = struct {
    create_calls: usize = 0,
    list_calls: usize = 0,
    message_calls: usize = 0,
    send_prompt_calls: usize = 0,

    pub fn listSessions(self: *FakeApi, allocator: std.mem.Allocator) ![]state_mod.SessionSeed {
        self.list_calls += 1;
        var out = try allocator.alloc(state_mod.SessionSeed, 1);
        out[0] = .{
            .id = try allocator.dupe(u8, "s-1"),
            .title = try allocator.dupe(u8, "Session Remote"),
        };
        return out;
    }

    pub fn freeSessions(self: *FakeApi, allocator: std.mem.Allocator, seeds: []state_mod.SessionSeed) void {
        _ = self;
        for (seeds) |seed| {
            allocator.free(seed.id);
            allocator.free(seed.title);
        }
        allocator.free(seeds);
    }

    pub fn createSession(self: *FakeApi, allocator: std.mem.Allocator) !state_mod.SessionSeed {
        self.create_calls += 1;
        return .{
            .id = try allocator.dupe(u8, "remote-new"),
            .title = try allocator.dupe(u8, "Remote New"),
        };
    }

    pub fn freeSession(self: *FakeApi, allocator: std.mem.Allocator, seed: state_mod.SessionSeed) void {
        _ = self;
        allocator.free(seed.id);
        allocator.free(seed.title);
    }

    pub fn getSessionMessages(
        self: *FakeApi,
        allocator: std.mem.Allocator,
        session_id: []const u8,
    ) ![]state_mod.MessageSeed {
        _ = session_id;
        self.message_calls += 1;
        var out = try allocator.alloc(state_mod.MessageSeed, 1);
        out[0] = .{
            .role = .assistant,
            .text = try allocator.dupe(u8, "remote message"),
        };
        return out;
    }

    pub fn freeMessages(self: *FakeApi, allocator: std.mem.Allocator, seeds: []state_mod.MessageSeed) void {
        _ = self;
        for (seeds) |seed| {
            allocator.free(seed.text);
        }
        allocator.free(seeds);
    }

    pub fn sendPrompt(self: *FakeApi, session_id: []const u8, text: []const u8) !void {
        _ = session_id;
        _ = text;
        self.send_prompt_calls += 1;
    }
};

fn makeSessionState(allocator: std.mem.Allocator) !state_mod.State {
    var state = state_mod.State.init(allocator);
    try state.replaceSessions(&.{.{ .id = "s-1", .title = "Local" }});
    state.openSelected();
    return state;
}

test "toggle route and local create session behavior" {
    var state = state_mod.State.init(std.testing.allocator);
    defer state.deinit();

    var input = vaxis.widgets.TextInput.init(std.testing.allocator);
    defer input.deinit();

    _ = try handleIntent(FakeApi, &state, &input, null, .{ .action = .home_create_session });
    try std.testing.expectEqual(@as(usize, 1), state.sessionCount());
    try std.testing.expectEqual(@as(state_mod.Route, .session), state.route);

    _ = try handleIntent(FakeApi, &state, &input, null, .{ .action = .toggle_route });
    try std.testing.expectEqual(@as(state_mod.Route, .home), state.route);
}

test "manual refresh messages through fake api" {
    var fake: FakeApi = .{};
    var state = try makeSessionState(std.testing.allocator);
    defer state.deinit();

    var input = vaxis.widgets.TextInput.init(std.testing.allocator);
    defer input.deinit();

    _ = try handleIntent(FakeApi, &state, &input, &fake, .{ .action = .session_refresh_messages_manual });

    try std.testing.expectEqual(@as(usize, 1), fake.message_calls);
    try std.testing.expectEqual(@as(usize, 1), state.messageCount());
    try std.testing.expectEqualStrings("remote message", state.messages.items[0].textSlice());
    try std.testing.expectEqualStrings("Messages synced", state.status());
}

test "submit prompt with empty input is rejected" {
    var fake: FakeApi = .{};
    var state = try makeSessionState(std.testing.allocator);
    defer state.deinit();

    var input = vaxis.widgets.TextInput.init(std.testing.allocator);
    defer input.deinit();

    _ = try handleIntent(FakeApi, &state, &input, &fake, .{ .action = .session_submit_prompt });

    try std.testing.expectEqual(@as(usize, 0), fake.send_prompt_calls);
    try std.testing.expectEqualStrings("Type a message first", state.status());
}

test "offline initialize sets status" {
    var state = state_mod.State.init(std.testing.allocator);
    defer state.deinit();

    try initialize(FakeApi, &state, null, true);
    try std.testing.expectEqualStrings("Offline mode: API disabled", state.status());
}

test "api create session and refresh list are invoked" {
    var fake: FakeApi = .{};
    var state = state_mod.State.init(std.testing.allocator);
    defer state.deinit();

    var input = vaxis.widgets.TextInput.init(std.testing.allocator);
    defer input.deinit();

    try initialize(FakeApi, &state, &fake, false);
    try std.testing.expectEqual(@as(usize, 1), fake.list_calls);

    _ = try handleIntent(FakeApi, &state, &input, &fake, .{ .action = .home_create_session });
    try std.testing.expectEqual(@as(usize, 1), fake.create_calls);
    try std.testing.expectEqual(@as(state_mod.Route, .session), state.route);
}
