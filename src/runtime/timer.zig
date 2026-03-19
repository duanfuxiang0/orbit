/// Timer re-export from event_loop.
/// TODO: Move Timer definition here once the API stabilizes (RFC Phase 2+).
const event_loop = @import("event_loop.zig");

pub const Timer = event_loop.Timer;
