const vaxis = @import("vaxis");
const state_mod = @import("../state.zig");
const legacy_ui = @import("../ui.zig");

pub fn draw(win: vaxis.Window, state: *const state_mod.State, input: *vaxis.widgets.TextInput) void {
    legacy_ui.draw(win, state, input);
}
