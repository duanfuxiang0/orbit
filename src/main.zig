const std = @import("std");
const vaxis = @import("vaxis");
const state_mod = @import("state.zig");
const api = @import("api.zig");
const app_controller = @import("app_controller.zig");
const ui_root = @import("ui/root.zig");
const runtime_renderer = @import("runtime/renderer.zig");
const event_router = @import("runtime/event_router.zig");

const log = std.log.scoped(.opencode_zig);

const CliOptions = struct {
    url: []u8,
    offline: bool = false,

    pub fn deinit(self: CliOptions, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        if (gpa.deinit() == .leak) {
            log.err("memory leak detected", .{});
        }
    }
    const alloc = gpa.allocator();

    const options = try parseCliOptions(alloc);
    defer options.deinit(alloc);

    const cwd = try std.fs.cwd().realpathAlloc(alloc, ".");
    defer alloc.free(cwd);

    var renderer = try runtime_renderer.Renderer.init(alloc);
    defer renderer.deinit();
    try renderer.run();

    var state = state_mod.State.init(alloc);
    defer state.deinit();

    var text_input = vaxis.widgets.TextInput.init(alloc);
    defer text_input.deinit();

    var maybe_api: ?app_controller.ApiClient = null;
    if (!options.offline) {
        maybe_api = app_controller.ApiClient.init(api.Client.init(alloc, options.url, cwd));
    }

    try app_controller.initialize(
        app_controller.ApiClient,
        &state,
        maybeApiPtr(&maybe_api),
        options.offline,
    );

    var poll_stop = std.atomic.Value(bool).init(false);
    var poll_ctx = PollContext{
        .renderer = &renderer,
        .stop = &poll_stop,
    };
    const poll_thread = try std.Thread.spawn(.{}, pollLoop, .{&poll_ctx});
    defer {
        poll_stop.store(true, .release);
        _ = renderer.tryPostEvent(.tick);
        poll_thread.join();
    }

    try renderFrame(&renderer, &state, &text_input);

    while (true) {
        const event = renderer.nextEvent();
        const dispatch_result = event_router.dispatch(state.route, event);

        var should_quit = false;
        for (dispatch_result.items()) |intent| {
            switch (intent) {
                .resize => |ws| {
                    try renderer.resize(ws);
                },
                else => {
                    if (try app_controller.handleIntent(
                        app_controller.ApiClient,
                        &state,
                        &text_input,
                        maybeApiPtr(&maybe_api),
                        intent,
                    )) {
                        should_quit = true;
                        break;
                    }
                },
            }
        }

        if (should_quit) break;

        try renderFrame(&renderer, &state, &text_input);
    }
}

fn maybeApiPtr(maybe_api: *?app_controller.ApiClient) ?*app_controller.ApiClient {
    return if (maybe_api.*) |*client| client else null;
}

fn parseCliOptions(allocator: std.mem.Allocator) !CliOptions {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var options: CliOptions = .{
        .url = try allocator.dupe(u8, "http://127.0.0.1:4096"),
    };
    errdefer allocator.free(options.url);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--offline")) {
            options.offline = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--url") and i + 1 < args.len) {
            allocator.free(options.url);
            options.url = try allocator.dupe(u8, args[i + 1]);
            i += 1;
            continue;
        }
    }

    return options;
}

const PollContext = struct {
    renderer: *runtime_renderer.Renderer,
    stop: *std.atomic.Value(bool),
};

fn pollLoop(ctx: *PollContext) void {
    while (!ctx.stop.load(.acquire)) {
        std.Thread.sleep(150 * std.time.ns_per_ms);
        if (ctx.stop.load(.acquire)) break;
        _ = ctx.renderer.tryPostEvent(.tick);
    }
}

fn renderFrame(
    renderer: *runtime_renderer.Renderer,
    state: *const state_mod.State,
    text_input: *vaxis.widgets.TextInput,
) !void {
    const win = renderer.window();
    ui_root.draw(win, state, text_input);
    try renderer.render();
}
