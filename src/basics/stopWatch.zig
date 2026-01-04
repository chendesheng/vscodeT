const std = @import("std");
const time = std.time;

pub const StopWatch = struct {
    _startTime: i64,
    _stopTime: i64,

    pub fn init() StopWatch {
        return StopWatch{
            ._startTime = time.milliTimestamp(),
            ._stopTime = -1,
        };
    }

    pub fn stop(self: *StopWatch) void {
        self._stopTime = time.milliTimestamp();
    }

    pub fn reset(self: *StopWatch) void {
        self._startTime = time.milliTimestamp();
        self._stopTime = -1;
    }

    pub fn elapsed(self: StopWatch) i64 {
        if (self._stopTime != -1) {
            return self._stopTime - self._startTime;
        }
        return time.milliTimestamp() - self._startTime;
    }
};
