const vaxis = @import("vaxis");

pub const Action = enum {
    toggle_route,
    home_move_up,
    home_move_down,
    home_refresh_sessions,
    home_create_session,
    home_open_or_create_session,
    session_scroll_up_page,
    session_scroll_down_page,
    session_back_home,
    session_refresh_messages_manual,
    session_submit_prompt,
};

pub const TickPolicy = enum {
    refresh_session_messages,
};

pub const AppIntent = union(enum) {
    quit,
    resize: vaxis.Winsize,
    action: Action,
    input_key: vaxis.Key,
    tick: TickPolicy,
};
