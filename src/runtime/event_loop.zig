const std = @import("std");
const xev = @import("xev");

/// Orbit runtime event loop. Wraps xev.Loop on a dedicated worker thread.
/// Cross-thread timer operations are communicated via xev.Async wakeup.
///
/// Lifecycle: cli creates and owns the single instance. All Timer instances
/// must be deinited before EventLoop.deinit is called.
pub const EventLoop = struct {
    allocator: std.mem.Allocator,
    loop: xev.Loop,
    wakeup: xev.Async,
    wakeup_c: xev.Completion = .{},
    worker: ?std.Thread = null,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    loop_error: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    worker_thread_id: std.atomic.Value(std.Thread.Id) = std.atomic.Value(std.Thread.Id).init(0),
    worker_started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mutex: std.Thread.Mutex = .{},
    timers: std.ArrayListUnmanaged(*Timer) = .empty,

    pub fn init(self: *EventLoop, allocator: std.mem.Allocator) !void {
        var loop = try xev.Loop.init(.{});
        errdefer loop.deinit();

        var wakeup = try xev.Async.init();
        errdefer wakeup.deinit();

        self.* = .{
            .allocator = allocator,
            .loop = loop,
            .wakeup = wakeup,
        };

        // Register async wakeup on the loop before spawning the worker.
        self.wakeup.wait(
            &self.loop,
            &self.wakeup_c,
            EventLoop,
            self,
            onWakeup,
        );

        self.worker = try std.Thread.spawn(.{}, workerMain, .{self});
    }

    pub fn deinit(self: *EventLoop) void {
        self.stop();
        if (self.worker) |thread| {
            thread.join();
            self.worker = null;
        }

        self.wakeup.deinit();
        self.loop.deinit();

        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.timers.items.len == 0);
        self.timers.deinit(self.allocator);
    }

    pub fn stop(self: *EventLoop) void {
        self.stop_requested.store(true, .release);
        self.wakeup.notify() catch {};
    }

    /// Returns true if the worker thread exited due to an error.
    pub fn hasError(self: *const EventLoop) bool {
        return self.loop_error.load(.acquire);
    }

    fn isOnWorkerThread(self: *const EventLoop) bool {
        if (!self.worker_started.load(.acquire)) return false;
        return self.worker_thread_id.load(.acquire) == std.Thread.getCurrentId();
    }

    fn workerMain(self: *EventLoop) void {
        self.worker_thread_id.store(std.Thread.getCurrentId(), .release);
        self.worker_started.store(true, .release);
        self.loop.run(.until_done) catch |err| {
            std.log.err("runtime event loop error: {s}", .{@errorName(err)});
            self.loop_error.store(true, .release);
        };
        self.worker_started.store(false, .release);
    }

    // -- Async wakeup callback (runs on loop thread) --

    fn onWakeup(
        raw_self: ?*EventLoop,
        loop: *xev.Loop,
        _: *xev.Completion,
        r: xev.Async.WaitError!void,
    ) xev.CallbackAction {
        _ = r catch return .rearm;

        const self = raw_self orelse return .disarm;

        if (self.stop_requested.load(.acquire)) {
            loop.stop();
            return .disarm;
        }

        self.processPendingOps();
        return .rearm;
    }

    /// Process pending arm requests from timers.
    /// Called on the loop thread after an Async wakeup.
    fn processPendingOps(self: *EventLoop) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.timers.items) |timer| {
            if (timer.pending_disarm) {
                timer.pending_disarm = false;
                timer.needs_arm = false;
                timer.callback = null;
                timer.callback_ctx = null;
                timer.pending_ms = 1;

                // Force a short disarm cycle so any active xev completion reaches
                // .dead before timer memory can be reclaimed by deinit().
                timer.xev_timer.reset(
                    &self.loop,
                    &timer.run_c,
                    &timer.reset_c,
                    timer.pending_ms,
                    Timer,
                    timer,
                    Timer.onXevFire,
                );
                timer.armed = true;
                continue;
            }

            if (!timer.needs_arm) continue;
            timer.needs_arm = false;

            // reset() safely handles both first-arm and re-arm cases.
            timer.xev_timer.reset(
                &self.loop,
                &timer.run_c,
                &timer.reset_c,
                timer.pending_ms,
                Timer,
                timer,
                Timer.onXevFire,
            );
            timer.armed = true;
        }
    }

    fn registerTimerLocked(self: *EventLoop, timer: *Timer) !void {
        std.debug.assert(!timer.registered);
        try self.timers.append(self.allocator, timer);
        timer.registered = true;
    }

    fn removeTimerLocked(self: *EventLoop, timer: *Timer) void {
        std.debug.assert(timer.registered);
        for (self.timers.items, 0..) |item, i| {
            if (item == timer) {
                _ = self.timers.swapRemove(i);
                timer.registered = false;
                return;
            }
        }
        unreachable;
    }
};

pub const Timer = struct {
    loop: *EventLoop,
    xev_timer: xev.Timer,
    run_c: xev.Completion = .{},
    reset_c: xev.Completion = .{},

    // Shared state (protected by loop.mutex).
    callback: ?*const fn (*anyopaque) void = null,
    callback_ctx: ?*anyopaque = null,
    pending_ms: u64 = 0,
    needs_arm: bool = false,
    pending_disarm: bool = false,
    registered: bool = false,
    armed: bool = false,
    firing: bool = false,
    firing_cond: std.Thread.Condition = .{},

    /// Create a timer bound to the given event loop.
    /// The loop must already be running (worker != null).
    pub fn init(loop: *EventLoop) Timer {
        std.debug.assert(loop.worker != null);
        const xev_timer = xev.Timer.init() catch |err| {
            std.debug.panic("xev.Timer.init failed: {s}", .{@errorName(err)});
        };
        return .{ .loop = loop, .xev_timer = xev_timer };
    }

    pub fn deinit(self: *Timer) void {
        self.cancel();

        const el = self.loop;
        el.mutex.lock();

        if (!self.registered) {
            el.mutex.unlock();
            self.xev_timer.deinit();
            self.* = undefined;
            return;
        }

        std.debug.assert(!self.firing);
        std.debug.assert(!self.armed);
        std.debug.assert(!self.pending_disarm);
        std.debug.assert(!self.needs_arm);
        el.removeTimerLocked(self);
        el.mutex.unlock();

        self.xev_timer.deinit();
        self.* = undefined;
    }

    /// Arm (or re-arm) the timer to fire after `ns` nanoseconds.
    /// Safe to call from any thread.
    pub fn armAfter(
        self: *Timer,
        ns: u64,
        cb: *const fn (*anyopaque) void,
        ctx: *anyopaque,
    ) !void {
        // Convert ns to ms with ceiling so timer never fires earlier than requested.
        const ms = nsToMsCeil(ns);

        const el = self.loop;
        el.mutex.lock();
        defer el.mutex.unlock();

        try self.ensureRegisteredLocked();

        self.pending_disarm = false;
        self.callback = cb;
        self.callback_ctx = ctx;
        self.pending_ms = ms;
        self.needs_arm = true;

        // Wake the loop thread to process this arm request.
        el.wakeup.notify() catch {};
    }

    /// Cancel a pending timer. The callback will not fire after this returns.
    /// Safe to call from any thread.
    pub fn cancel(self: *Timer) void {
        const el = self.loop;
        el.mutex.lock();
        defer el.mutex.unlock();

        self.needs_arm = false;
        self.callback = null;
        self.callback_ctx = null;
        if (self.armed) {
            self.pending_disarm = true;
            el.wakeup.notify() catch {};
        }

        // If cancellation races with an in-flight callback on another thread,
        // wait until it finishes to guarantee postcondition on return.
        if (el.isOnWorkerThread()) return;
        while (self.firing or self.armed or self.pending_disarm or self.needs_arm) {
            self.firing_cond.wait(&el.mutex);
        }
    }

    fn ensureRegisteredLocked(self: *Timer) !void {
        if (self.registered) return;
        try self.loop.registerTimerLocked(self);
    }

    // -- xev callback (runs on loop thread) --

    fn onXevFire(
        raw_self: ?*Timer,
        _: *xev.Loop,
        _: *xev.Completion,
        r: xev.Timer.RunError!void,
    ) xev.CallbackAction {
        _ = r catch return .disarm;

        const self = raw_self orelse return .disarm;
        const el = self.loop;

        el.mutex.lock();
        const cb = self.callback;
        const cb_ctx = self.callback_ctx;

        // Clear armed state. If callback was cancelled, cb will be null.
        self.callback = null;
        self.callback_ctx = null;
        self.needs_arm = false;
        self.pending_disarm = false;
        self.armed = false;

        if (cb == null or cb_ctx == null) {
            self.firing_cond.broadcast();
            el.mutex.unlock();
            return .disarm;
        }

        self.firing = true;
        el.mutex.unlock();

        cb.?(cb_ctx.?);

        el.mutex.lock();
        self.firing = false;
        self.firing_cond.broadcast();
        el.mutex.unlock();

        return .disarm;
    }
};

fn nsToMsCeil(ns: u64) u64 {
    if (ns <= std.time.ns_per_ms) return 1;
    return 1 + ((ns - 1) / std.time.ns_per_ms);
}

// -- Test helpers --

fn waitForCounter(
    counter: *const std.atomic.Value(u32),
    expected: u32,
    timeout_ms: u32,
) bool {
    const start_ns = std.time.nanoTimestamp();
    const timeout_ns = @as(i128, timeout_ms) * std.time.ns_per_ms;

    while (true) {
        if (counter.load(.acquire) >= expected) return true;
        const now_ns = std.time.nanoTimestamp();
        if (now_ns - start_ns >= timeout_ns) return false;
        std.Thread.sleep(std.time.ns_per_ms);
    }
}

fn waitForBoolTrue(
    flag: *const std.atomic.Value(bool),
    timeout_ms: u32,
) bool {
    const start_ns = std.time.nanoTimestamp();
    const timeout_ns = @as(i128, timeout_ms) * std.time.ns_per_ms;

    while (true) {
        if (flag.load(.acquire)) return true;
        const now_ns = std.time.nanoTimestamp();
        if (now_ns - start_ns >= timeout_ns) return false;
        std.Thread.sleep(std.time.ns_per_ms);
    }
}

test "nsToMsCeil rounds up" {
    try std.testing.expectEqual(@as(u64, 1), nsToMsCeil(0));
    try std.testing.expectEqual(@as(u64, 1), nsToMsCeil(1));
    try std.testing.expectEqual(@as(u64, 1), nsToMsCeil(std.time.ns_per_ms));
    try std.testing.expectEqual(@as(u64, 2), nsToMsCeil(std.time.ns_per_ms + 1));
    try std.testing.expectEqual(@as(u64, 2), nsToMsCeil(2 * std.time.ns_per_ms));
}

test "event loop timer arm/cancel/rearm" {
    const CounterCtx = struct {
        counter: *std.atomic.Value(u32),

        fn onFire(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            _ = self.counter.fetchAdd(1, .acq_rel);
        }
    };

    var event_loop: EventLoop = undefined;
    try event_loop.init(std.testing.allocator);
    defer event_loop.deinit();

    var timer = Timer.init(&event_loop);
    defer timer.deinit();

    var counter = std.atomic.Value(u32).init(0);
    var ctx = CounterCtx{ .counter = &counter };

    // Arm and wait for fire.
    try timer.armAfter(5 * std.time.ns_per_ms, CounterCtx.onFire, &ctx);
    try std.testing.expect(waitForCounter(&counter, 1, 500));
    try std.testing.expectEqual(@as(u32, 1), counter.load(.acquire));

    // Arm then cancel — should not fire.
    try timer.armAfter(20 * std.time.ns_per_ms, CounterCtx.onFire, &ctx);
    timer.cancel();
    std.Thread.sleep(50 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u32, 1), counter.load(.acquire));

    // Re-arm overwrites previous deadline.
    try timer.armAfter(50 * std.time.ns_per_ms, CounterCtx.onFire, &ctx);
    try timer.armAfter(5 * std.time.ns_per_ms, CounterCtx.onFire, &ctx);
    try std.testing.expect(waitForCounter(&counter, 2, 500));
    try std.testing.expectEqual(@as(u32, 2), counter.load(.acquire));
}

test "timer cancel waits for in-flight callback" {
    const Ctx = struct {
        started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        counter: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

        fn onFire(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.started.store(true, .release);
            std.Thread.sleep(30 * std.time.ns_per_ms);
            _ = self.counter.fetchAdd(1, .acq_rel);
            self.finished.store(true, .release);
        }
    };

    var event_loop: EventLoop = undefined;
    try event_loop.init(std.testing.allocator);
    defer event_loop.deinit();

    var timer = Timer.init(&event_loop);
    defer timer.deinit();

    var ctx = Ctx{};
    try timer.armAfter(1, Ctx.onFire, &ctx);
    try std.testing.expect(waitForBoolTrue(&ctx.started, 500));

    timer.cancel();
    try std.testing.expect(ctx.finished.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), ctx.counter.load(.acquire));
}

test "timer deinit drains pending xev completion" {
    const Ctx = struct {
        fired: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

        fn onFire(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            _ = self.fired.fetchAdd(1, .acq_rel);
        }
    };

    var event_loop: EventLoop = undefined;
    try event_loop.init(std.testing.allocator);
    defer event_loop.deinit();

    var ctx = Ctx{};
    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        var timer = Timer.init(&event_loop);
        try timer.armAfter(50 * std.time.ns_per_ms, Ctx.onFire, &ctx);
        timer.deinit();
    }

    std.Thread.sleep(100 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u32, 0), ctx.fired.load(.acquire));
    try std.testing.expect(!event_loop.hasError());
}
