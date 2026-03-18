const std = @import("std");
const vaxis = @import("vaxis");
const state_mod = @import("../state.zig");
const app_types = @import("../app_types.zig");
const event_mod = @import("event.zig");
const keymap = @import("../input/keymap.zig");

pub const Event = event_mod.Event;
pub const AppIntent = app_types.AppIntent;

pub const DispatchResult = struct {
    intents: [4]AppIntent = undefined,
    len: usize = 0,

    fn append(self: *DispatchResult, intent: AppIntent) void {
        std.debug.assert(self.len < self.intents.len);
        self.intents[self.len] = intent;
        self.len += 1;
    }

    pub fn items(self: *const DispatchResult) []const AppIntent {
        return self.intents[0..self.len];
    }
};

pub fn dispatch(route: state_mod.Route, event: Event) DispatchResult {
    var out: DispatchResult = .{};

    switch (event) {
        .key_press => |key| {
            if (key.matches('c', .{ .ctrl = true })) {
                out.append(.quit);
                return out;
            }
            if (route == .home and key.matches('q', .{})) {
                out.append(.quit);
                return out;
            }

            if (keymap.match(route, key)) |action| {
                out.append(.{ .action = action });
            } else if (route == .session) {
                out.append(.{ .input_key = key });
            }
        },
        .winsize => |ws| {
            out.append(.{ .resize = ws });
        },
        .tick => {
            if (route == .session) {
                out.append(.{ .tick = .refresh_session_messages });
            }
        },
        else => {},
    }

    return out;
}

fn makeKey(codepoint: u21, mods: vaxis.Key.Modifiers) vaxis.Key {
    return .{
        .codepoint = codepoint,
        .mods = mods,
    };
}

test "dispatch maps home shortcuts to actions" {
    const e: Event = .{ .key_press = makeKey('j', .{}) };
    const result = dispatch(.home, e);

    try std.testing.expectEqual(@as(usize, 1), result.items().len);
    switch (result.items()[0]) {
        .action => |action| try std.testing.expectEqual(@as(app_types.Action, .home_move_down), action),
        else => try std.testing.expect(false),
    }
}

test "dispatch maps session shortcuts to actions" {
    const e: Event = .{ .key_press = makeKey(vaxis.Key.page_up, .{}) };
    const result = dispatch(.session, e);

    try std.testing.expectEqual(@as(usize, 1), result.items().len);
    switch (result.items()[0]) {
        .action => |action| {
            try std.testing.expectEqual(@as(app_types.Action, .session_scroll_up_page), action);
        },
        else => try std.testing.expect(false),
    }
}

test "dispatch quit matches ctrl+c and home q" {
    const ctrl_c: Event = .{ .key_press = makeKey('c', .{ .ctrl = true }) };
    const home_q: Event = .{ .key_press = makeKey('q', .{}) };

    const ctrl_result = dispatch(.session, ctrl_c);
    const home_result = dispatch(.home, home_q);

    try std.testing.expectEqual(@as(usize, 1), ctrl_result.items().len);
    try std.testing.expectEqual(@as(usize, 1), home_result.items().len);

    try std.testing.expect(ctrl_result.items()[0] == .quit);
    try std.testing.expect(home_result.items()[0] == .quit);
}

test "dispatch sends unmatched session key to text input" {
    const e: Event = .{ .key_press = makeKey('x', .{}) };
    const result = dispatch(.session, e);

    try std.testing.expectEqual(@as(usize, 1), result.items().len);
    switch (result.items()[0]) {
        .input_key => |key| {
            try std.testing.expectEqual(@as(u21, 'x'), key.codepoint);
        },
        else => try std.testing.expect(false),
    }
}

test "dispatch covers enter tab esc page and ctrl+r mappings" {
    const cases = [_]struct {
        route: state_mod.Route,
        key: vaxis.Key,
        expect: app_types.Action,
    }{
        .{ .route = .home, .key = makeKey(vaxis.Key.tab, .{}), .expect = .toggle_route },
        .{ .route = .home, .key = makeKey(vaxis.Key.enter, .{}), .expect = .home_open_or_create_session },
        .{ .route = .home, .key = makeKey('k', .{}), .expect = .home_move_up },
        .{ .route = .home, .key = makeKey(vaxis.Key.up, .{}), .expect = .home_move_up },
        .{ .route = .home, .key = makeKey(vaxis.Key.down, .{}), .expect = .home_move_down },
        .{ .route = .home, .key = makeKey('r', .{}), .expect = .home_refresh_sessions },
        .{ .route = .home, .key = makeKey('n', .{}), .expect = .home_create_session },
        .{ .route = .session, .key = makeKey(vaxis.Key.escape, .{}), .expect = .session_back_home },
        .{ .route = .session, .key = makeKey(vaxis.Key.page_down, .{}), .expect = .session_scroll_down_page },
        .{ .route = .session, .key = makeKey('r', .{ .ctrl = true }), .expect = .session_refresh_messages_manual },
        .{ .route = .session, .key = makeKey(vaxis.Key.enter, .{}), .expect = .session_submit_prompt },
    };

    for (cases) |case| {
        const result = dispatch(case.route, .{ .key_press = case.key });
        try std.testing.expectEqual(@as(usize, 1), result.items().len);
        switch (result.items()[0]) {
            .action => |action| try std.testing.expectEqual(case.expect, action),
            else => try std.testing.expect(false),
        }
    }
}

test "dispatch tick policy refreshes only in session route" {
    const home_result = dispatch(.home, .tick);
    const session_result = dispatch(.session, .tick);

    try std.testing.expectEqual(@as(usize, 0), home_result.items().len);
    try std.testing.expectEqual(@as(usize, 1), session_result.items().len);

    switch (session_result.items()[0]) {
        .tick => |policy| {
            try std.testing.expectEqual(@as(app_types.TickPolicy, .refresh_session_messages), policy);
        },
        else => try std.testing.expect(false),
    }
}
