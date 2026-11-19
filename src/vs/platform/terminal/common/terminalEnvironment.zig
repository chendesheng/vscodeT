// Port of `src/vs/platform/terminal/common/terminalEnvironment.ts` and its
// tests. Only the path helpers are portable here; shell/profile resolution
// lives in `node/terminalProfiles.zig` and the workbench environment helpers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const terminal = @import("terminal.zig");

/// Aggressively escape non-Windows paths before they are handed to a shell.
/// Mirrors upstream: backslashes are doubled, a fixed set of shell-dangerous
/// characters is removed, then the result is quoted according to the shell.
pub fn escapeNonWindowsPath(
    allocator: Allocator,
    path: []const u8,
    shell_type: ?terminal.TerminalShellType,
) ![]u8 {
    var escaped: std.array_list.Managed(u8) = .init(allocator);
    defer escaped.deinit();
    for (path) |ch| {
        switch (ch) {
            '\\' => try escaped.appendSlice("\\\\"),
            '`', '$', '|', '&', '>', '~', '#', '!', '^', '*', ';', '<' => {},
            else => try escaped.append(ch),
        }
    }
    const value = escaped.items;

    const mode: terminal.TerminalShellType = shell_type orelse .unknown;
    switch (mode) {
        .posix => |shell| switch (shell) {
            .bash, .sh, .zsh => return quotePosix(allocator, value),
            .fish => return quoteFish(allocator, value),
        },
        .windows => return quotePosix(allocator, value),
        .general => return quotePowerShell(allocator, value),
        .unknown => return quotePosix(allocator, value),
    }
}

fn quotePosix(allocator: Allocator, value: []const u8) ![]u8 {
    const has_single = std.mem.indexOfScalar(u8, value, '\'') != null;
    const has_double = std.mem.indexOfScalar(u8, value, '"') != null;
    var out: std.array_list.Managed(u8) = .init(allocator);
    defer out.deinit();
    if (has_single and has_double) {
        try out.appendSlice("$'");
        for (value) |ch| {
            if (ch == '\'') try out.append('\\');
            try out.append(ch);
        }
        try out.append('\'');
    } else {
        try out.append('\'');
        if (has_single) {
            for (value) |ch| {
                if (ch == '\'') try out.append('\\');
                try out.append(ch);
            }
        } else {
            try out.appendSlice(value);
        }
        try out.append('\'');
    }
    return out.toOwnedSlice();
}

fn quoteFish(allocator: Allocator, value: []const u8) ![]u8 {
    const has_single = std.mem.indexOfScalar(u8, value, '\'') != null;
    const has_double = std.mem.indexOfScalar(u8, value, '"') != null;
    var out: std.array_list.Managed(u8) = .init(allocator);
    defer out.deinit();
    if (has_single and has_double) {
        try out.append('"');
        for (value) |ch| {
            if (ch == '"') try out.append('\\');
            try out.append(ch);
        }
        try out.append('"');
    } else if (has_single) {
        try out.append('\'');
        for (value) |ch| {
            if (ch == '\'') try out.append('\\');
            try out.append(ch);
        }
        try out.append('\'');
    } else {
        try out.append('\'');
        try out.appendSlice(value);
        try out.append('\'');
    }
    return out.toOwnedSlice();
}

fn quotePowerShell(allocator: Allocator, value: []const u8) ![]u8 {
    const has_single = std.mem.indexOfScalar(u8, value, '\'') != null;
    const has_double = std.mem.indexOfScalar(u8, value, '"') != null;
    var out: std.array_list.Managed(u8) = .init(allocator);
    defer out.deinit();
    if (has_single and has_double) {
        try out.append('"');
        for (value) |ch| {
            if (ch == '"') try out.append('`');
            try out.append(ch);
        }
        try out.append('"');
    } else if (has_single) {
        try out.append('\'');
        for (value) |ch| {
            if (ch == '\'') try out.append('\'');
            try out.append(ch);
        }
        try out.append('\'');
    } else {
        try out.append('\'');
        try out.appendSlice(value);
        try out.append('\'');
    }
    return out.toOwnedSlice();
}

/// Collapses the user's home directory into `~` for a shorter terminal title.
/// The comparison follows upstream: case-insensitive after normalizing
/// backslashes to forward slashes.
pub fn collapseTildePath(
    allocator: Allocator,
    path: ?[]const u8,
    user_home: ?[]const u8,
    separator: []const u8,
) ![]u8 {
    const path_value = path orelse "";
    const home_value = user_home orelse "";
    if (path_value.len == 0) return allocator.dupe(u8, "");
    if (home_value.len == 0) return allocator.dupe(u8, path_value);

    var home = home_value;
    while (home.len > 0 and isSeparator(home[home.len - 1])) home = home[0 .. home.len - 1];
    if (home.len == 0) return allocator.dupe(u8, path_value);

    const match = indexOfNormalized(path_value, home) orelse
        return allocator.dupe(u8, path_value);
    var out: std.array_list.Managed(u8) = .init(allocator);
    defer out.deinit();
    try out.append('~');
    try out.appendSlice(separator);
    const rest = if (match + home.len < path_value.len)
        path_value[match + home.len + 1 ..]
    else
        "";
    try out.appendSlice(rest);
    return out.toOwnedSlice();
}

fn isSeparator(ch: u8) bool {
    return ch == '/' or ch == '\\';
}

fn normalizedEqual(a: u8, b: u8) bool {
    if (a == b) return true;
    if (isSeparator(a) and isSeparator(b)) return true;
    return std.ascii.toLower(a) == std.ascii.toLower(b);
}

fn indexOfNormalized(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var matches = true;
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (!normalizedEqual(haystack[i + j], needle[j])) {
                matches = false;
                break;
            }
        }
        if (matches) return i;
    }
    return null;
}

/// Strips wrapping quotes from a cwd and, on Windows, normalizes the drive
/// letter to uppercase.
pub fn sanitizeCwd(allocator: Allocator, cwd: []const u8) ![]u8 {
    var value = cwd;
    if (value.len >= 2 and
        ((value[0] == '\'' and value[value.len - 1] == '\'') or
            (value[0] == '"' and value[value.len - 1] == '"')))
    {
        value = value[1 .. value.len - 1];
    }
    const result = try allocator.dupe(u8, value);
    if (terminal.is_windows and result.len >= 2 and result[1] == ':') {
        result[0] = std.ascii.toUpper(result[0]);
    }
    return result;
}

/// Determines whether an environment-variable collection should be applied to
/// this launch config.
pub fn shouldUseEnvironmentVariableCollection(strict_env: bool) bool {
    return !strict_env;
}

test "terminalEnvironment: collapse and sanitize ports" {
    const allocator = std.testing.allocator;
    {
        const v = try collapseTildePath(allocator, "", "/foo", "/");
        defer allocator.free(v);
        try std.testing.expectEqualStrings("", v);
    }
    {
        const v = try collapseTildePath(allocator, null, "/foo", "/");
        defer allocator.free(v);
        try std.testing.expectEqualStrings("", v);
    }
    {
        const v = try collapseTildePath(allocator, "/foo", "", "/");
        defer allocator.free(v);
        try std.testing.expectEqualStrings("/foo", v);
    }
    {
        const v = try collapseTildePath(allocator, "/foo/bar", "/foo/", "/");
        defer allocator.free(v);
        try std.testing.expectEqualStrings("~/bar", v);
    }
    {
        const v = try collapseTildePath(allocator, "c:\\foo\\bar", "C:\\foo", "\\");
        defer allocator.free(v);
        try std.testing.expectEqualStrings("~\\bar", v);
    }
    {
        const v = try sanitizeCwd(allocator, "'/foo/bar'");
        defer allocator.free(v);
        try std.testing.expectEqualStrings("/foo/bar", v);
    }
    {
        const v = try sanitizeCwd(allocator, "\"/foo/bar\"");
        defer allocator.free(v);
        try std.testing.expectEqualStrings("/foo/bar", v);
    }
}
