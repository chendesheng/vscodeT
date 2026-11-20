//! A single one-shot deadline used to adapt browser `setTimeout` calls to the
//! TUI event loop. The host advances the timer with `tick(now)` and uses
//! `nextTimeoutMs(now)` to size its poll timeout, mirroring the hover
//! `DeadlineTimer` adapter.

const std = @import("std");
const time_compat = @import("./timeCompat.zig");

pub const Callback = *const fn (context: *anyopaque) void;

pub const DeadlineTimer = struct {
    pending: ?Pending = null,

    pub const Pending = struct {
        deadline_ms: i64,
        callback: Callback,
        context: *anyopaque,
    };

    pub fn schedule(self: *DeadlineTimer, delay_ms: u64, callback: Callback, context: *anyopaque) void {
        self.pending = .{
            .deadline_ms = time_compat.milliTimestamp() + @as(i64, @intCast(delay_ms)),
            .callback = callback,
            .context = context,
        };
    }

    /// Test/host helper: schedule against an explicit clock.
    pub fn scheduleAt(self: *DeadlineTimer, deadline_ms: i64, callback: Callback, context: *anyopaque) void {
        self.pending = .{ .deadline_ms = deadline_ms, .callback = callback, .context = context };
    }

    pub fn cancel(self: *DeadlineTimer) void {
        self.pending = null;
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
