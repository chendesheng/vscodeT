// Port of the timer-backed helpers in `src/vs/base/common/async.ts` that the
// file watcher needs.
//
// Terminal adaptation: there is no hidden `setTimeout` in the library. Every
// scheduler stores a deadline and is advanced by an explicit `poll(now_ms)`
// call from the host event loop. This keeps the watcher deterministic and
// testable while preserving upstream's chunk sizes, delays and cancellation
// rules.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn nowMs() i64 {
    return std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real).toMilliseconds();
}

pub const Continuation = struct {
    context: *anyopaque,
    run: *const fn (*anyopaque) anyerror!void,

    pub fn call(self: Continuation) !void {
        try self.run(self.context);
    }
};

/// Port of Barrier from async.ts. Callers waiting on the UI thread register a
/// continuation, including after the barrier has opened.
pub const Barrier = struct {
    is_open: bool = false,
    pending: std.ArrayList(Continuation) = .empty,

    pub fn deinit(self: *Barrier, allocator: Allocator) void {
        self.pending.deinit(allocator);
    }

    pub fn wait(self: *Barrier, allocator: Allocator, callback: Continuation) !void {
        if (self.is_open) return callback.call();
        try self.pending.append(allocator, callback);
    }

    pub fn open(self: *Barrier, allocator: Allocator) !void {
        if (self.is_open) return;
        self.is_open = true;
        var callbacks = self.pending;
        self.pending = .empty;
        defer callbacks.deinit(allocator);
        var first_error: ?anyerror = null;
        for (callbacks.items) |callback| callback.call() catch |err| {
            if (first_error == null) first_error = err;
        };
        if (first_error) |err| return err;
    }
};

/// A single outstanding timeout or idle callback, driven by the native host.
/// Callbacks can replace the timer, including from within a running callback.
pub const WindowTimer = struct {
    clock: struct { context: *anyopaque, now: *const fn (*anyopaque) i64 },
    callback: ?Continuation = null,
    deadline: i64 = 0,
    idle: bool = false,

    pub fn setTimeout(self: *WindowTimer, delay: i64, callback: Continuation) void {
        self.deadline = self.clock.now(self.clock.context) + delay;
        self.callback = callback;
        self.idle = false;
    }

    pub fn runWhenIdle(self: *WindowTimer, timeout: i64, callback: Continuation) void {
        self.setTimeout(timeout, callback);
        self.idle = true;
    }

    pub fn nextTimeout(self: *const WindowTimer, maximum: i32) i32 {
        if (self.callback == null) return maximum;
        if (self.idle) return 0;
        return @intCast(std.math.clamp(self.deadline - self.clock.now(self.clock.context), 0, maximum));
    }

    pub fn dispatch(self: *WindowTimer, idle: bool) !void {
        const callback = self.callback orelse return;
        if (!(self.idle and idle) and self.clock.now(self.clock.context) < self.deadline) return;
        self.callback = null;
        try callback.call();
    }
};

/// Runs `runner` once after a delay. Scheduling again cancels the previous run.
pub fn RunOnceScheduler(comptime Context: type) type {
    return struct {
        const Self = @This();

        context: Context,
        runner: *const fn (Context) void,
        delay_ms: i64,
        deadline_ms: ?i64 = null,

        pub fn init(context: Context, runner: *const fn (Context) void, delay_ms: i64) Self {
            return .{ .context = context, .runner = runner, .delay_ms = delay_ms };
        }

        pub fn schedule(self: *Self, now_ms: i64, delay_ms: ?i64) void {
            self.deadline_ms = now_ms + (delay_ms orelse self.delay_ms);
        }

        pub fn cancel(self: *Self) void {
            self.deadline_ms = null;
        }

        pub fn isScheduled(self: *const Self) bool {
            return self.deadline_ms != null;
        }

        pub fn flush(self: *Self, now_ms: i64) bool {
            if (self.deadline_ms == null) return false;
            self.deadline_ms = null;
            self.runner(self.context);
            _ = now_ms;
            return true;
        }

        pub fn poll(self: *Self, now_ms: i64) bool {
            const deadline = self.deadline_ms orelse return false;
            if (now_ms < deadline) return false;
            return self.flush(now_ms);
        }

        pub fn nextTimeout(self: *const Self, now_ms: i64) ?u32 {
            const deadline = self.deadline_ms orelse return null;
            return secondsUntil(now_ms, deadline);
        }
    };
}

/// Collects work units and flushes them to the runner in one batch after a
/// delay, resetting the delay on every new unit.
pub fn RunOnceWorker(comptime T: type, comptime Context: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        units: std.array_list.Managed(T),
        runner_context: Context,
        runner: *const fn (Context, []T) void,
        delay_ms: i64,
        deadline_ms: ?i64 = null,

        pub fn init(
            allocator: Allocator,
            runner_context: Context,
            runner: *const fn (Context, []T) void,
            delay_ms: i64,
        ) Self {
            return .{
                .allocator = allocator,
                .units = std.array_list.Managed(T).init(allocator),
                .runner_context = runner_context,
                .runner = runner,
                .delay_ms = delay_ms,
            };
        }

        pub fn deinit(self: *Self) void {
            self.units.deinit();
        }

        pub fn work(self: *Self, now_ms: i64, unit: T) !void {
            try self.units.append(unit);
            if (self.deadline_ms == null) {
                self.deadline_ms = now_ms + self.delay_ms;
            }
        }

        pub fn flush(self: *Self, now_ms: i64) bool {
            _ = now_ms;
            if (self.deadline_ms == null) return false;
            self.deadline_ms = null;
            if (self.units.items.len == 0) return false;
            const batch = self.units.toOwnedSlice() catch return false;
            defer self.allocator.free(batch);
            self.runner(self.runner_context, batch);
            return true;
        }

        pub fn poll(self: *Self, now_ms: i64) bool {
            const deadline = self.deadline_ms orelse return false;
            if (now_ms < deadline) return false;
            return self.flush(now_ms);
        }

        pub fn nextTimeout(self: *const Self, now_ms: i64) ?u32 {
            const deadline = self.deadline_ms orelse return null;
            return secondsUntil(now_ms, deadline);
        }
    };
}

pub const ThrottledWorkerOptions = struct {
    max_work_chunk_size: usize,
    max_buffered_work: ?usize = null,
    throttle_delay_ms: i64,
    wait_throttle_delay_between_work_units: bool = false,
};

/// Port of upstream `ThrottledWorker`: accepts units, processes at most
/// `max_work_chunk_size` per round, then rests for `throttle_delay_ms`.
pub fn ThrottledWorker(comptime T: type, comptime Context: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        options: ThrottledWorkerOptions,
        pending: std.array_list.Managed(T),
        handler_context: Context,
        handler: *const fn (Context, []T) void,
        deadline_ms: ?i64 = null,
        last_execution_ms: i64 = 0,
        disposed: bool = false,

        pub fn init(
            allocator: Allocator,
            options: ThrottledWorkerOptions,
            handler_context: Context,
            handler: *const fn (Context, []T) void,
        ) Self {
            return .{
                .allocator = allocator,
                .options = options,
                .pending = std.array_list.Managed(T).init(allocator),
                .handler_context = handler_context,
                .handler = handler,
            };
        }

        pub fn deinit(self: *Self) void {
            self.pending.deinit();
        }

        pub fn pendingCount(self: *const Self) usize {
            return self.pending.items.len;
        }

        pub fn work(self: *Self, now_ms: i64, units: []const T) bool {
            if (self.disposed) return false;

            if (self.options.max_buffered_work) |max| {
                if (self.deadline_ms != null) {
                    if (self.pending.items.len + units.len > max) return false;
                } else if (self.pending.items.len + units.len -| self.options.max_work_chunk_size > max) {
                    return false;
                }
            }

            self.pending.appendSlice(units) catch return false;

            const time_since_last = now_ms - self.last_execution_ms;
            if (self.deadline_ms == null and
                (!self.options.wait_throttle_delay_between_work_units or
                    time_since_last >= self.options.throttle_delay_ms))
            {
                self.doWork(now_ms);
            } else if (self.deadline_ms == null and self.options.wait_throttle_delay_between_work_units) {
                self.schedule(now_ms, @max(self.options.throttle_delay_ms - time_since_last, 0));
            }
            return true;
        }

        fn schedule(self: *Self, now_ms: i64, delay_ms: i64) void {
            self.deadline_ms = now_ms + delay_ms;
        }

        fn doWork(self: *Self, now_ms: i64) void {
            self.last_execution_ms = now_ms;
            const chunk_len = @min(self.pending.items.len, self.options.max_work_chunk_size);
            if (chunk_len == 0) return;
            const chunk = self.pending.items[0..chunk_len];
            self.handler(self.handler_context, chunk);
            // The handler may use the slice only during the call.
            std.mem.copyForwards(T, self.pending.items[0 .. self.pending.items.len - chunk_len], self.pending.items[chunk_len..]);
            self.pending.items.len -= chunk_len;

            if (self.pending.items.len > 0) {
                self.schedule(now_ms, self.options.throttle_delay_ms);
            }
        }

        pub fn poll(self: *Self, now_ms: i64) bool {
            const deadline = self.deadline_ms orelse return false;
            if (now_ms < deadline) return false;
            self.deadline_ms = null;
            self.doWork(now_ms);
            return true;
        }

        pub fn nextTimeout(self: *const Self, now_ms: i64) ?u32 {
            const deadline = self.deadline_ms orelse return null;
            return secondsUntil(now_ms, deadline);
        }

        pub fn dispose(self: *Self) void {
            self.disposed = true;
            self.pending.clearRetainingCapacity();
            self.deadline_ms = null;
        }
    };
}

/// Delays a task and makes sure two tasks do not overlap. The terminal port is
/// synchronous, so only the delay/coalescing behavior is needed.
pub const ThrottledDelayer = struct {
    context: *anyopaque,
    task: *const fn (*anyopaque) void,
    delay_ms: i64,
    deadline_ms: ?i64 = null,

    pub fn init(context: *anyopaque, task: *const fn (*anyopaque) void, delay_ms: i64) ThrottledDelayer {
        return .{ .context = context, .task = task, .delay_ms = delay_ms };
    }

    pub fn trigger(self: *ThrottledDelayer, now_ms: i64, delay_ms: ?i64) void {
        self.deadline_ms = now_ms + (delay_ms orelse self.delay_ms);
    }

    pub fn isTriggered(self: *const ThrottledDelayer) bool {
        return self.deadline_ms != null;
    }

    pub fn cancel(self: *ThrottledDelayer) void {
        self.deadline_ms = null;
    }

    pub fn poll(self: *ThrottledDelayer, now_ms: i64) bool {
        const deadline = self.deadline_ms orelse return false;
        if (now_ms < deadline) return false;
        self.deadline_ms = null;
        self.task(self.context);
        return true;
    }

    pub fn nextTimeout(self: *const ThrottledDelayer, now_ms: i64) ?u32 {
        const deadline = self.deadline_ms orelse return null;
        return secondsUntil(now_ms, deadline);
    }
};

fn secondsUntil(now_ms: i64, deadline_ms: i64) u32 {
    if (deadline_ms <= now_ms) return 0;
    const remaining = deadline_ms - now_ms;
    if (remaining > std.math.maxInt(u32)) return std.math.maxInt(u32);
    return @intCast(remaining);
}

test "RunOnceScheduler: schedule, poll and cancel" {
    var ran: usize = 0;
    const context = struct {
        fn run(value: *usize) void {
            value.* += 1;
        }
    };
    var scheduler = RunOnceScheduler(*usize).init(&ran, context.run, 100);
    scheduler.schedule(1000, null);
    try std.testing.expect(!scheduler.poll(1050));
    try std.testing.expect(scheduler.poll(1100));
    try std.testing.expectEqual(@as(usize, 1), ran);

    scheduler.schedule(2000, 10);
    scheduler.cancel();
    try std.testing.expect(!scheduler.poll(5000));
    try std.testing.expectEqual(@as(usize, 1), ran);
}

test "RunOnceWorker: batches units" {
    var total: usize = 0;
    const context = struct {
        fn run(value: *usize, units: []u32) void {
            value.* += units.len;
        }
    };
    var worker = RunOnceWorker(u32, *usize).init(std.testing.allocator, &total, context.run, 75);
    defer worker.deinit();
    try worker.work(0, 1);
    try worker.work(10, 2);
    try std.testing.expect(!worker.poll(50));
    try std.testing.expect(worker.poll(75));
    try std.testing.expectEqual(@as(usize, 2), total);
}

test "ThrottledWorker: chunk then throttle" {
    const Context = struct {
        total: usize,
        chunks: usize,
    };
    const context = struct {
        fn run(state: *Context, units: []u32) void {
            state.total += units.len;
            state.chunks += 1;
        }
    };
    var state = Context{ .total = 0, .chunks = 0 };
    var worker = ThrottledWorker(u32, *Context).init(std.testing.allocator, .{
        .max_work_chunk_size = 2,
        .max_buffered_work = 10,
        .throttle_delay_ms = 200,
    }, &state, context.run);
    defer worker.deinit();

    try std.testing.expect(worker.work(0, &.{ 1, 2, 3 }));
    try std.testing.expectEqual(@as(usize, 2), state.total);
    try std.testing.expectEqual(@as(usize, 1), worker.pendingCount());
    try std.testing.expect(worker.poll(199) == false);
    try std.testing.expect(worker.poll(200));
    try std.testing.expectEqual(@as(usize, 3), state.total);
    try std.testing.expectEqual(@as(usize, 2), state.chunks);
}
