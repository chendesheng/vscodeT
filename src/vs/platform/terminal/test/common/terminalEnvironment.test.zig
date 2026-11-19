// Port of `src/vs/platform/terminal/test/common/terminalEnvironment.test.ts`.

const std = @import("std");
const environment = @import("../../common/terminalEnvironment.zig");
const terminal = @import("../../common/terminal.zig");

fn expectEscape(expected: []const u8, path: []const u8, shell: ?terminal.TerminalShellType) !void {
    const allocator = std.testing.allocator;
    const value = try environment.escapeNonWindowsPath(allocator, path, shell);
    defer allocator.free(value);
    try std.testing.expectEqualStrings(expected, value);
}

test "terminalEnvironment: collapseTildePath" {
    const allocator = std.testing.allocator;

    const empty = try environment.collapseTildePath(allocator, "", "/foo", "/");
    defer allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);

    const null_path = try environment.collapseTildePath(allocator, null, "/foo", "/");
    defer allocator.free(null_path);
    try std.testing.expectEqualStrings("", null_path);

    const no_home = try environment.collapseTildePath(allocator, "/foo", "", "/");
    defer allocator.free(no_home);
    try std.testing.expectEqualStrings("/foo", no_home);

    const no_home_null = try environment.collapseTildePath(allocator, "/foo", null, "/");
    defer allocator.free(no_home_null);
    try std.testing.expectEqualStrings("/foo", no_home_null);

    const other_home = try environment.collapseTildePath(allocator, "/foo", "/bar", "/");
    defer allocator.free(other_home);
    try std.testing.expectEqualStrings("/foo", other_home);

    const windows_other = try environment.collapseTildePath(allocator, "C:\\foo", "C:\\bar", "\\");
    defer allocator.free(windows_other);
    try std.testing.expectEqualStrings("C:\\foo", windows_other);

    const win1 = try environment.collapseTildePath(allocator, "C:\\foo\\bar", "C:\\foo", "\\");
    defer allocator.free(win1);
    try std.testing.expectEqualStrings("~\\bar", win1);

    const win2 = try environment.collapseTildePath(allocator, "C:\\foo\\bar", "C:\\foo\\", "\\");
    defer allocator.free(win2);
    try std.testing.expectEqualStrings("~\\bar", win2);

    const win3 = try environment.collapseTildePath(allocator, "C:\\foo\\bar\\baz", "C:\\foo\\", "\\");
    defer allocator.free(win3);
    try std.testing.expectEqualStrings("~\\bar\\baz", win3);

    const win4 = try environment.collapseTildePath(allocator, "c:\\foo\\bar\\baz", "C:\\foo", "\\");
    defer allocator.free(win4);
    try std.testing.expectEqualStrings("~\\bar\\baz", win4);

    const posix1 = try environment.collapseTildePath(allocator, "/foo/bar", "/foo/", "/");
    defer allocator.free(posix1);
    try std.testing.expectEqualStrings("~/bar", posix1);

    const posix2 = try environment.collapseTildePath(allocator, "/foo/bar/baz", "/foo", "/");
    defer allocator.free(posix2);
    try std.testing.expectEqualStrings("~/bar/baz", posix2);
}

test "terminalEnvironment: sanitizeCwd" {
    const allocator = std.testing.allocator;
    const single = try environment.sanitizeCwd(allocator, "'/foo/bar'");
    defer allocator.free(single);
    try std.testing.expectEqualStrings("/foo/bar", single);

    const double = try environment.sanitizeCwd(allocator, "\"/foo/bar\"");
    defer allocator.free(double);
    try std.testing.expectEqualStrings("/foo/bar", double);

    if (terminal.is_windows) {
        const drive = try environment.sanitizeCwd(allocator, "c:\\foo\\bar");
        defer allocator.free(drive);
        try std.testing.expectEqualStrings("C:\\foo\\bar", drive);
    }
}

test "terminalEnvironment: escapeNonWindowsPath bash/sh/zsh" {
    const bash: terminal.TerminalShellType = .{ .posix = .bash };
    const sh: terminal.TerminalShellType = .{ .posix = .sh };
    const zsh: terminal.TerminalShellType = .{ .posix = .zsh };

    try expectEscape("'/foo/bar'", "/foo/bar", bash);
    try expectEscape("'/foo/bar\\'baz'", "/foo/bar'baz", bash);
    try expectEscape("'/foo/bar\"baz'", "/foo/bar\"baz", bash);
    try expectEscape("$'/foo/bar\\'baz\"qux'", "/foo/bar'baz\"qux", bash);
    try expectEscape("'/foo/bar'", "/foo/bar", sh);
    try expectEscape("'/foo/bar\\'baz'", "/foo/bar'baz", sh);
    try expectEscape("'/foo/bar'", "/foo/bar", zsh);
    try expectEscape("'/foo/bar\\'baz'", "/foo/bar'baz", zsh);
}

test "terminalEnvironment: escapeNonWindowsPath git bash and fish" {
    const git_bash: terminal.TerminalShellType = .{ .windows = .git_bash };
    try expectEscape("'/foo/bar'", "/foo/bar", git_bash);
    try expectEscape("'/foo/bar\\'baz'", "/foo/bar'baz", git_bash);
    try expectEscape("'/foo/bar\"baz'", "/foo/bar\"baz", git_bash);

    const fish: terminal.TerminalShellType = .{ .posix = .fish };
    try expectEscape("'/foo/bar'", "/foo/bar", fish);
    try expectEscape("'/foo/bar\\'baz'", "/foo/bar'baz", fish);
    try expectEscape("'/foo/bar\"baz'", "/foo/bar\"baz", fish);
    try expectEscape("\"/foo/bar'baz\\\"qux\"", "/foo/bar'baz\"qux", fish);
}

test "terminalEnvironment: escapeNonWindowsPath powershell and unknown" {
    const powershell: terminal.TerminalShellType = .{ .general = .power_shell };
    try expectEscape("'/foo/bar'", "/foo/bar", powershell);
    try expectEscape("'/foo/bar''baz'", "/foo/bar'baz", powershell);
    try expectEscape("'/foo/bar\"baz'", "/foo/bar\"baz", powershell);
    try expectEscape("\"/foo/bar'baz`\"qux\"", "/foo/bar'baz\"qux", powershell);

    try expectEscape("'/foo/bar'", "/foo/bar", null);
    try expectEscape("'/foo/bar\\'baz'", "/foo/bar'baz", null);
}

test "terminalEnvironment: escapeNonWindowsPath removes dangerous characters" {
    const bash: terminal.TerminalShellType = .{ .posix = .bash };
    try expectEscape("'/foo/bar(echo evil)'", "/foo/bar$(echo evil)", bash);
    try expectEscape("'/foo/barwhoami'", "/foo/bar`whoami`", bash);
}
