// Port of the portable path helpers in `src/vs/base/common/extpath.ts`.
//
// Terminal adaptation: POSIX paths are the primary form; Windows drive/UNC
// handling is kept where it is pure string logic (drive roots, basename rules).
const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn toSlashes(path: []const u8, allocator: Allocator) ![]u8 {
    const result = try allocator.dupe(u8, path);
    for (result) |*ch| if (ch.* == '\\') {
        ch.* = '/';
    };
    return result;
}

pub fn getRoot(path: []const u8) []const u8 {
    if (path.len == 0) return "";
    // Windows drive letter.
    if (path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':') {
        if (path.len == 2) return path[0..2];
        return if (path[2] == '/' or path[2] == '\\') path[0..3] else path[0..2];
    }
    if (path[0] != '/') return "";
    // UNC path: //server/share/
    if (path.len >= 2 and path[1] == '/') {
        var index: usize = 2;
        var slashes: usize = 0;
        while (index < path.len) : (index += 1) {
            if (path[index] == '/') {
                slashes += 1;
                if (slashes == 2) return path[0 .. index + 1];
            }
        }
        return "/";
    }
    return "/";
}

pub fn isWindowsDriveLetter(ch: u8) bool {
    return (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z');
}

pub fn hasDriveLetter(path: []const u8, is_windows: bool) bool {
    if (!is_windows) return false;
    return path.len >= 2 and isWindowsDriveLetter(path[0]) and path[1] == ':';
}

pub fn getDriveLetter(path: []const u8, is_windows: bool) ?u8 {
    if (!hasDriveLetter(path, is_windows)) return null;
    return path[0];
}

fn normalizeSeparators(path: []const u8, allocator: Allocator) ![]u8 {
    return toSlashes(path, allocator);
}

pub fn isRootOrDriveLetter(path: []const u8, is_windows: bool) bool {
    if (is_windows) {
        if (path.len > 3) return false;
        const letter = hasDriveLetter(path, true);
        if (!letter) return false;
        return path.len == 2 or path[2] == '/' or path[2] == '\\';
    }
    return std.mem.eql(u8, path, "/");
}

pub fn removeTrailingPathSeparator(path: []const u8, allocator: Allocator, is_windows: bool) ![]u8 {
    if (path.len == 0) return allocator.dupe(u8, path);
    var end = path.len;
    while (end > 1 and (path[end - 1] == '/' or (is_windows and path[end - 1] == '\\'))) end -= 1;
    if (is_windows and end == 2 and path[1] == ':') end = 2;
    return allocator.dupe(u8, path[0..end]);
}

pub fn isValidBasename(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return false;
    if (std.mem.indexOfScalar(u8, name, 0) != null) return false;
    return true;
}

/// Case-aware substring index; returns -1 when absent.
pub fn indexOfPath(path: []const u8, name: []const u8, ignore_case: bool) isize {
    if (name.len == 0 or name.len > path.len) return -1;
    var index: usize = 0;
    while (index + name.len <= path.len) : (index += 1) {
        var matches = true;
        for (path[index .. index + name.len], name) |left, right| {
            const a = if (ignore_case) std.ascii.toLower(left) else left;
            const b = if (ignore_case) std.ascii.toLower(right) else right;
            if (a != b) {
                matches = false;
                break;
            }
        }
        if (matches) return @intCast(index);
    }
    return -1;
}

pub const LineAndColumn = struct {
    path: []const u8,
    line: ?usize = null,
    column: ?usize = null,
};

pub fn parseLineAndColumnAware(line: []const u8) LineAndColumn {
    var path = line;
    var parsed_line: ?usize = null;
    var parsed_column: ?usize = null;
    if (lastNumber(path)) |last| {
        path = path[0..last.start];
        if (lastNumber(path)) |preceding| {
            parsed_line = preceding.value;
            parsed_column = last.value;
            path = path[0..preceding.start];
        } else {
            parsed_line = last.value;
            parsed_column = 1;
            path = path[0..last.start];
        }
    }
    return .{ .path = path, .line = parsed_line, .column = parsed_column };
}

fn lastNumber(text: []const u8) ?struct { start: usize, value: usize } {
    if (text.len == 0 or text[text.len - 1] < '0' or text[text.len - 1] > '9') return null;
    var index = text.len;
    while (index > 0 and text[index - 1] >= '0' and text[index - 1] <= '9') index -= 1;
    if (index == 0 or text[index - 1] != ':') return null;
    if (index - 1 == 0) return null;
    const value = std.fmt.parseInt(usize, text[index..], 10) catch return null;
    return .{ .start = index - 1, .value = value };
}

test "extpath toSlashes and getRoot" {
    const allocator = std.testing.allocator;
    const slashes = try toSlashes("\\\\server\\share\\some\\path", allocator);
    defer allocator.free(slashes);
    try std.testing.expectEqualStrings("//server/share/some/path", slashes);
    try std.testing.expectEqualStrings("/", getRoot("/user/far"));
    try std.testing.expectEqualStrings("//server/share/", getRoot("//server/share/some/path"));
    try std.testing.expectEqualStrings("c:/", getRoot("c:/user/far"));
    try std.testing.expectEqualStrings("", getRoot("http://www"));
}

test "extpath basename validation and path index" {
    try std.testing.expect(!isValidBasename(""));
    try std.testing.expect(isValidBasename("test.txt"));
    try std.testing.expect(!isValidBasename("/test.txt"));
    try std.testing.expectEqual(@as(isize, -1), indexOfPath("/foo", "/bar", true));
    try std.testing.expectEqual(@as(isize, 0), indexOfPath("/foo", "/FOO", true));
    try std.testing.expectEqual(@as(isize, 10), indexOfPath("/some/long/path", "/PATH", true));
}

test "extpath parseLineAndColumnAware" {
    const plain = parseLineAndColumnAware("/foo/bar");
    try std.testing.expectEqualStrings("/foo/bar", plain.path);
    try std.testing.expect(plain.line == null);
    const line = parseLineAndColumnAware("/foo/bar:33");
    try std.testing.expectEqualStrings("/foo/bar", line.path);
    try std.testing.expectEqual(@as(?usize, 33), line.line);
    try std.testing.expectEqual(@as(?usize, 1), line.column);
    const both = parseLineAndColumnAware("/foo/bar:33:34");
    try std.testing.expectEqualStrings("/foo/bar", both.path);
    try std.testing.expectEqual(@as(?usize, 33), both.line);
    try std.testing.expectEqual(@as(?usize, 34), both.column);
    const invalid = parseLineAndColumnAware("/foo/bar:abb");
    try std.testing.expectEqualStrings("/foo/bar:abb", invalid.path);
    try std.testing.expect(invalid.line == null);
}

test "extpath drive letters and roots" {
    try std.testing.expect(isWindowsDriveLetter('C'));
    try std.testing.expect(isWindowsDriveLetter('z'));
    try std.testing.expect(!isWindowsDriveLetter('1'));
    try std.testing.expect(hasDriveLetter("c:/user", true));
    try std.testing.expect(!hasDriveLetter("c:/user", false));
    try std.testing.expectEqual(@as(?u8, 'c'), getDriveLetter("c:/user", true));
    try std.testing.expect(isRootOrDriveLetter("/", false));
    try std.testing.expect(!isRootOrDriveLetter("/foo", false));
    try std.testing.expect(isRootOrDriveLetter("c:\\", true));
}

test "extpath trailing separators" {
    const allocator = std.testing.allocator;
    const trimmed = try removeTrailingPathSeparator("/foo/", allocator, false);
    defer allocator.free(trimmed);
    try std.testing.expectEqualStrings("/foo", trimmed);
    const root = try removeTrailingPathSeparator("/", allocator, false);
    defer allocator.free(root);
    try std.testing.expectEqualStrings("/", root);
    const drive = try removeTrailingPathSeparator("c:\\", allocator, true);
    defer allocator.free(drive);
    try std.testing.expectEqualStrings("c:", drive);
}
