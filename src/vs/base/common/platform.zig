// Port of the `OperatingSystem` subset of `src/vs/base/common/platform.ts`.
//
// Upstream detects the host from `process.platform` or the user agent. The
// terminal build has a native target, so the OS comes from `builtin.os.tag`;
// the browser/service-worker flags are not part of this port.
const std = @import("std");
const builtin = @import("builtin");

pub const OperatingSystem = enum(u8) {
    Windows = 1,
    Macintosh = 2,
    Linux = 3,
};

pub const OS: OperatingSystem = switch (builtin.os.tag) {
    .windows => .Windows,
    .macos, .ios, .tvos, .watchos, .visionos => .Macintosh,
    else => .Linux,
};

pub fn isWindows() bool {
    return OS == .Windows;
}

pub fn isMacintosh() bool {
    return OS == .Macintosh;
}

pub fn isLinux() bool {
    return OS == .Linux;
}

test "OS is one of the upstream values" {
    try std.testing.expect(@backingInt(OS) >= 1 and @backingInt(OS) <= 3);
}
