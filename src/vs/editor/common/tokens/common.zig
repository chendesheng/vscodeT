const std = @import("std");
const time = @import("../../../base/common/timeCompat.zig");

pub const RateLimiter = struct {
    _lastRun: i64,
    _minimumTimeBetweenRuns: i64, // in ms
    timesPerSecond: f64,

    pub fn init(timesPerSecond: f64) RateLimiter {
        return RateLimiter{
            ._lastRun = 0,
            ._minimumTimeBetweenRuns = @intFromFloat(std.time.ms_per_s / timesPerSecond),
            .timesPerSecond = timesPerSecond,
        };
    }

    pub fn runIfNotLimited(self: *RateLimiter, context: anytype, callback: fn (@TypeOf(context)) void) void {
        const now = time.milliTimestamp();
        if (now - self._lastRun >= self._minimumTimeBetweenRuns) {
            self._lastRun = now;
            callback(context);
        }
    }
};

test "RateLimiter" {
    var limiter = RateLimiter.init(100); // once per 10ms
    var count: usize = 0;
    for (0..20) |_| { // 20ms total
        limiter.runIfNotLimited(&count, struct {
            fn run(n: *usize) void {
                n.* += 1;
            }
        }.run);
        time.sleepMillis(1);
    }
    try std.testing.expect(count >= 2 and count < 20);
}
