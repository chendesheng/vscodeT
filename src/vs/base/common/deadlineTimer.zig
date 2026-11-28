//! A single one-shot deadline used to adapt browser `setTimeout` calls to the
//! window event loop. Tests can advance an unattached timer with an explicit clock.

const std = @import("std");
const time_compat = @import("./timeCompat.zig");

pub const Callback = *const fn (context: *anyopaque) void;

pub const DeadlineTimer = struct {
    pending: ?Pending = null,
    task: @import("windowDispatch.zig").Task = .{},

    pub fn attachWindow(self: *DeadlineTimer, window: *@import("windowDispatch.zig").Queue) void {
        if (self.task.queue == window) return;
        self.task.schedule(null);
        self.task = .{ .queue = window, .context = self, .run = fire };
        if (self.pending) |pending| self.task.schedule(pending.deadline_ms);
    }

    fn fire(context: *anyopaque, now: i64, _: bool) bool {
        const self: *DeadlineTimer = @ptrCast(@alignCast(context));
        return self.tick(now);
    }

    pub const Pending = struct {
        deadline_ms: i64,
        callback: Callback,
        context: *anyopaque,
    };

    pub fn schedule(self: *DeadlineTimer, io: std.Io, delay_ms: u64, callback: Callback, context: *anyopaque) void {
        self.scheduleAt(time_compat.milliTimestamp(io) + @as(i64, @intCast(delay_ms)), callback, context);
    }

    /// Test/host helper: schedule against an explicit clock.
    pub fn scheduleAt(self: *DeadlineTimer, deadline_ms: i64, callback: Callback, context: *anyopaque) void {
        self.pending = .{ .deadline_ms = deadline_ms, .callback = callback, .context = context };
        self.task.schedule(deadline_ms);
    }

    pub fn cancel(self: *DeadlineTimer) void {
        self.pending = null;
        self.task.schedule(null);
    }

    pub fn isScheduled(self: *const DeadlineTimer) bool {
        return self.pending != null;
    }

    pub fn nextTimeoutMs(self: *const DeadlineTimer, now_ms: i64) ?u32 {
        const pending = self.pending orelse return null;
        const remaining = pending.deadline_ms - now_ms;
        return @intCast(@max(remaining, 0));
    }

    /// Fires the deadline when due. Returns whether a callback ran.
    pub fn tick(self: *DeadlineTimer, now_ms: i64) bool {
        const pending = self.pending orelse return false;
        if (now_ms < pending.deadline_ms) return false;
        self.pending = null;
        self.task.schedule(null);
        pending.callback(pending.context);
        return true;
    }
};

test "deadlineTimer: schedules and fires once" {
    const Counter = struct {
        count: usize = 0,
        fn fire(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
        }
    };
    var counter = Counter{};
    var timer = DeadlineTimer{};
    timer.scheduleAt(100, Counter.fire, &counter);
    try std.testing.expectEqual(@as(?u32, 20), timer.nextTimeoutMs(80));
    try std.testing.expect(!timer.tick(90));
    try std.testing.expect(timer.tick(100));
    try std.testing.expectEqual(@as(usize, 1), counter.count);
    try std.testing.expect(!timer.tick(110));
}
