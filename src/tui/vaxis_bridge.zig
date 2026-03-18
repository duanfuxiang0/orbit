const std = @import("std");
const runtime_renderer = @import("../runtime/renderer.zig");

pub const VaxisBridge = struct {
    renderer: *runtime_renderer.Renderer,
    active: bool = false,

    pub fn init(renderer: *runtime_renderer.Renderer) VaxisBridge {
        return .{ .renderer = renderer };
    }

    pub fn enterFullscreen(self: *VaxisBridge) !void {
        if (self.active) return;
        try self.renderer.enterAltScreen();
        self.active = true;
    }

    pub fn exitFullscreen(self: *VaxisBridge) !void {
        if (!self.active) return;
        try self.renderer.exitAltScreen();
        self.active = false;
    }

    pub fn render(self: *VaxisBridge, draw_fn: anytype) !void {
        std.debug.assert(self.active);
        draw_fn(self.renderer.window());
        try self.renderer.render();
    }
};
