//! Explicit clock and sleep helpers for Zig 0.17. The caller owns the Io.
const std = @import("std");

/// Current wall-clock time in milliseconds since the Unix epoch.
pub fn milliTimestamp(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

pub fn sleepMillis(io: std.Io, ms: i64) void {
    io.sleep(.fromMilliseconds(ms), .awake) catch {};
}
