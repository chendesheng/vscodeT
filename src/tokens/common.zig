const std = @import("std");

pub const RateLimiter = struct {
    _lastRun: i64,
    _minimumTimeBetweenRuns: f64,
    timesPerSecond: f64,

    pub fn init(timesPerSecond: i64) RateLimiter {
        return RateLimiter{
            ._lastRun = 0,
            ._minimumTimeBetweenRuns = 1000.0 / @as(f64, @floatFromInt(timesPerSecond)),
            .timesPerSecond = timesPerSecond,
        };
    }

    pub fn runIfNotLimited(self: RateLimiter, callback: fn () void) void {
        const now = std.time.timestamp();
        if (now - self._lastRun >= @as(i64, @intFromFloat(self._minimumTimeBetweenRuns))) {
            self._lastRun = now;
            callback();
        }
    }
};
