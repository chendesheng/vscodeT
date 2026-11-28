const std = @import("std");
const time = @import("./timeCompat.zig");

pub const StopWatch = struct {
    io: std.Io,
    _startTime: i64,
    _stopTime: i64,

    pub fn init(io: std.Io) StopWatch {
        return StopWatch{
            .io = io,
            ._startTime = std.Io.Timestamp.now(io, .awake).toMilliseconds(),
            ._stopTime = -1,
        };
    }

    pub fn stop(self: *StopWatch) void {
        self._stopTime = std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
    }

    pub fn reset(self: *StopWatch) void {
        self._startTime = std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
        self._stopTime = -1;
    }

    pub fn elapsed(self: StopWatch) i64 {
        if (self._stopTime != -1) {
            return self._stopTime - self._startTime;
        }
        return std.Io.Timestamp.now(self.io, .awake).toMilliseconds() - self._startTime;
    }
};
