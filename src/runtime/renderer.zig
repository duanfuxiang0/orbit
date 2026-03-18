const std = @import("std");
const vaxis = @import("vaxis");
const event_mod = @import("event.zig");

pub const Event = event_mod.Event;

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    tty_buffer: [4096]u8 = undefined,
    tty: vaxis.Tty,
    vx: vaxis.Vaxis,
    loop: vaxis.Loop(Event),
    loop_started: bool = false,

    pub fn init(allocator: std.mem.Allocator) !Renderer {
        var self: Renderer = undefined;
        self.allocator = allocator;

        self.tty = try vaxis.Tty.init(&self.tty_buffer);
        errdefer self.tty.deinit();

        self.vx = try vaxis.init(allocator, .{
            .kitty_keyboard_flags = .{ .report_events = true },
        });
        errdefer self.vx.deinit(allocator, self.tty.writer());

        self.loop = undefined;
        return self;
    }

    pub fn deinit(self: *Renderer) void {
        if (self.loop_started) {
            self.loop.stop();
            self.loop_started = false;
        }
        self.vx.deinit(self.allocator, self.tty.writer());
        self.tty.deinit();
    }

    pub fn run(self: *Renderer) !void {
        // Bind loop pointers only after Renderer has reached its final storage.
        self.loop = .{ .tty = &self.tty, .vaxis = &self.vx };
        try self.loop.init();
        try self.loop.start();
        self.loop_started = true;
        try self.vx.enterAltScreen(self.tty.writer());
        try self.vx.queryTerminal(self.tty.writer(), 1 * std.time.ns_per_s);
    }

    pub fn stop(self: *Renderer) void {
        if (self.loop_started) {
            self.loop.stop();
            self.loop_started = false;
        }
    }

    pub fn window(self: *Renderer) vaxis.Window {
        return self.vx.window();
    }

    pub fn render(self: *Renderer) !void {
        try self.vx.render(self.tty.writer());
    }

    pub fn resize(self: *Renderer, ws: vaxis.Winsize) !void {
        try self.vx.resize(self.allocator, self.tty.writer(), ws);
    }

    pub fn nextEvent(self: *Renderer) Event {
        std.debug.assert(self.loop_started);
        return self.loop.nextEvent();
    }

    pub fn tryPostEvent(self: *Renderer, event: Event) bool {
        if (!self.loop_started) return false;
        return self.loop.tryPostEvent(event);
    }
};
