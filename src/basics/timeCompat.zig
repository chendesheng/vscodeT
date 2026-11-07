//! Convenience wrappers around the `std.Io` clock APIs introduced in Zig 0.17.
//! Library code that has no `Io` instance threaded through it uses the global
//! single-threaded implementation, which is sufficient for timing helpers.
const std = @import("std");

pub const io = std.Io.Threaded.global_single_threaded.io();

/// Current wall-clock time in milliseconds since the Unix epoch.
pub fn milliTimestamp() i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

/// Sleeps for `ms` milliseconds.
pub fn sleepMillis(ms: i64) void {
    io.sleep(.fromMilliseconds(ms), .awake) catch {};
}
