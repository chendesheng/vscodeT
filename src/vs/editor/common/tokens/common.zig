// Port of `src/vs/editor/common/tokens/common.ts`.
//
// Zig adaptation: there are no closures or default arguments, so
// `runIfNotLimited` takes an explicit context plus callback and `init` takes
// `timesPerSecond` explicitly (upstream defaults it to 5).
const std = @import("std");
const time = @import("../../../base/common/timeCompat.zig");

pub const RateLimiter = struct {
    _lastRun: i64,
    _minimumTimeBetweenRuns: f64, // in ms
    timesPerSecond: f64,

    pub fn init(timesPerSecond: f64) RateLimiter {
        return RateLimiter{
            ._lastRun = 0,
            ._minimumTimeBetweenRuns = 1000.0 / timesPerSecond,
            .timesPerSecond = timesPerSecond,
        };
    }

    pub fn runIfNotLimited(self: *RateLimiter, io: std.Io, context: anytype, callback: fn (@TypeOf(context)) void) void {
        self.runIfNotLimitedAt(time.milliTimestamp(io), context, callback);
    }

    fn runIfNotLimitedAt(self: *RateLimiter, now: i64, context: anytype, callback: fn (@TypeOf(context)) void) void {
        if (@as(f64, @floatFromInt(now - self._lastRun)) >= self._minimumTimeBetweenRuns) {
            self._lastRun = now;
            callback(context);
        }
    }
};

test "RateLimiter" {
    var limiter = RateLimiter.init(100); // once per 10ms
    var count: usize = 0;
    const callback = struct {
        fn run(n: *usize) void {
            n.* += 1;
        }
    }.run;
    // Supply exact wall-clock samples; sleep duration is not guaranteed by
    // the scheduler and can exceed the entire rate limit on Windows.
    for (0..20) |ms| {
        limiter.runIfNotLimitedAt(1000 + @as(i64, @intCast(ms)), &count, callback);
        try std.testing.expectEqual(ms / 10 + 1, count);
    }
    limiter.runIfNotLimitedAt(1020, &count, callback);
    try std.testing.expectEqual(@as(usize, 3), count);
}
