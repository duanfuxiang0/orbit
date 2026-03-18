const vaxis = @import("vaxis");
const state_mod = @import("../state.zig");
const app_types = @import("../app_types.zig");

pub fn match(route: state_mod.Route, key: vaxis.Key) ?app_types.Action {
    switch (route) {
        .home => {
            if (key.matches(vaxis.Key.tab, .{})) return .toggle_route;
            if (key.matchesAny(&.{ vaxis.Key.up, 'k' }, .{})) return .home_move_up;
            if (key.matchesAny(&.{ vaxis.Key.down, 'j' }, .{})) return .home_move_down;
            if (key.matches('r', .{})) return .home_refresh_sessions;
            if (key.matches('n', .{})) return .home_create_session;
            if (key.matches(vaxis.Key.enter, .{})) return .home_open_or_create_session;
        },
        .session => {
            if (key.matches(vaxis.Key.page_up, .{})) return .session_scroll_up_page;
            if (key.matches(vaxis.Key.page_down, .{})) return .session_scroll_down_page;
            if (key.matches(vaxis.Key.escape, .{})) return .session_back_home;
            if (key.matches(vaxis.Key.tab, .{})) return .toggle_route;
            if (key.matches('r', .{ .ctrl = true })) return .session_refresh_messages_manual;
            if (key.matches(vaxis.Key.enter, .{})) return .session_submit_prompt;
        },
    }

    return null;
}
