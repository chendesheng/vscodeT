// Port of the portable subset of
// `src/vs/platform/terminal/common/terminalProfiles.ts`.
//
// Profile icons, extension terminal profiles and schema enum descriptions are
// browser/extension concerns and are not part of the terminal panel slice.

const std = @import("std");
const terminal = @import("terminal.zig");

pub fn profileArgsMatch(
    args1: ?[]const []const u8,
    args2: ?[]const []const u8,
) bool {
    const a = args1 orelse &.{};
    const b = args2 orelse &.{};
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    return true;
}

/// The shell name upstream shows in `${process}` and uses as the generated
/// profile name: the basename without an `.exe` suffix.
pub fn shellName(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (terminal.is_windows and std.mem.endsWith(u8, base, ".exe")) {
        return base[0 .. base.len - 4];
    }
    return base;
}

/// Maps a shell executable to the shell family used by path escaping.
pub fn shellType(path: []const u8) terminal.TerminalShellType {
    const name = shellName(path);
    if (std.mem.eql(u8, name, "bash")) return .{ .posix = .bash };
    if (std.mem.eql(u8, name, "sh")) return .{ .posix = .sh };
    if (std.mem.eql(u8, name, "zsh")) return .{ .posix = .zsh };
    if (std.mem.eql(u8, name, "fish")) return .{ .posix = .fish };
    if (std.mem.eql(u8, name, "git-bash") or std.mem.eql(u8, name, "gitbash")) {
        return .{ .windows = .git_bash };
    }
    if (std.mem.eql(u8, name, "pwsh") or std.mem.eql(u8, name, "powershell")) {
        return .{ .general = .power_shell };
    }
    return .unknown;
}

pub fn isPowerShell(path: []const u8) bool {
    return switch (shellType(path)) {
        .general => true,
        else => false,
    };
}

test "terminalProfiles: args matching" {
    const a = [_][]const u8{ "--login", "-i" };
    const b = [_][]const u8{ "--login", "-i" };
    try std.testing.expect(profileArgsMatch(&a, &b));
    try std.testing.expect(profileArgsMatch(null, &.{}));
    const c = [_][]const u8{"--login"};
    try std.testing.expect(!profileArgsMatch(&a, &c));
}

test "terminalProfiles: shell names and types" {
    try std.testing.expectEqualStrings("zsh", shellName("/bin/zsh"));
    try std.testing.expectEqualStrings("bash", shellName("/usr/local/bin/bash"));
    try std.testing.expectEqual(terminal.TerminalShellType{ .posix = .zsh }, shellType("/bin/zsh"));
    try std.testing.expectEqual(terminal.TerminalShellType{ .posix = .fish }, shellType("/opt/homebrew/bin/fish"));
    try std.testing.expectEqual(terminal.TerminalShellType.unknown, shellType("/usr/bin/custom"));
}
