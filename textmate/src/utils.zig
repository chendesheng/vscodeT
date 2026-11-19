// Port of `vscode-textmate/src/utils.ts` (microsoft/vscode-textmate
// v9.3.2).
const std = @import("std");
const onigLib = @import("onigLib.zig");
const Allocator = std.mem.Allocator;

pub const OrMask = u32;

pub fn strcmp(a: []const u8, b: []const u8) i32 {
    return switch (std.mem.order(u8, a, b)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

pub fn strArrCmp(a: ?[]const []const u8, b: ?[]const []const u8) i32 {
    if (a == null and b == null) return 0;
    if (a == null) return -1;
    if (b == null) return 1;
    const left = a.?;
    const right = b.?;
    if (left.len == right.len) {
        for (left, right) |left_item, right_item| {
            const result = strcmp(left_item, right_item);
            if (result != 0) return result;
        }
        return 0;
    }
    return @intCast(@as(isize, @intCast(left.len)) - @as(isize, @intCast(right.len)));
}

pub fn basename(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and (path[end - 1] == '/' or path[end - 1] == '\\')) end -= 1;
    var start = end;
    while (start > 0 and path[start - 1] != '/' and path[start - 1] != '\\') start -= 1;
    return path[start..end];
}

pub fn isValidHexColor(hex: []const u8) bool {
    if (hex.len < 4 or hex.len > 9 or hex[0] != '#') return false;
    if (hex.len != 4 and hex.len != 5 and hex.len != 7 and hex.len != 9) return false;
    for (hex[1..]) |ch| {
        if (!std.ascii.isHex(ch)) return false;
    }
    return true;
}

/// Escapes regular expression characters in a given string. Mirrors
/// `/[\\|([{}\]).?*+^$]/g`.
pub fn escapeRegExpCharacters(allocator: Allocator, value: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    for (value) |ch| {
        switch (ch) {
            '\\', '|', '(', '[', '{', '}', ']', ')', '.', '?', '*', '+', '^', '$' => {
                try result.append(allocator, '\\');
                try result.append(allocator, ch);
            },
            else => try result.append(allocator, ch),
        }
    }
    return result.toOwnedSlice(allocator);
}

/// Port of `RegexSource.hasCaptures`.
pub fn hasCaptures(regex_source: ?[]const u8) bool {
    const source = regex_source orelse return false;
    var index: usize = 0;
    while (index < source.len) : (index += 1) {
        if (source[index] != '$') continue;
        var cursor = index + 1;
        if (cursor < source.len and source[cursor] == '{') {
            cursor += 1;
            const digits_start = cursor;
            while (cursor < source.len and std.ascii.isDigit(source[cursor])) cursor += 1;
            if (cursor == digits_start) continue;
            if (cursor < source.len and source[cursor] == ':' and
                cursor + 1 < source.len and source[cursor + 1] == '/' and
                cursor + 2 < source.len and
                (source[cursor + 2] == 'd' or source[cursor + 2] == 'u'))
            {
                return true;
            }
        } else {
            const digits_start = cursor;
            while (cursor < source.len and std.ascii.isDigit(source[cursor])) cursor += 1;
            if (cursor > digits_start) return true;
        }
    }
    return false;
}

/// Port of `RegexSource.replaceCaptures`. The replacement is written to
/// `out`; the returned slice is owned by `out`.
pub fn replaceCaptures(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    regex_source: []const u8,
    capture_source: []const u8,
    capture_indices: []const onigLib.CaptureIndex,
) !void {
    var index: usize = 0;
    while (index < regex_source.len) {
        if (regex_source[index] != '$') {
            try out.append(allocator, regex_source[index]);
            index += 1;
            continue;
        }

        var cursor = index + 1;
        var capture_number: ?usize = null;
        var command: ?[]const u8 = null;

        if (cursor < regex_source.len and regex_source[cursor] == '{') {
            cursor += 1;
            const digits_start = cursor;
            while (cursor < regex_source.len and std.ascii.isDigit(regex_source[cursor])) cursor += 1;
            if (cursor > digits_start) {
                capture_number = std.fmt.parseInt(usize, regex_source[digits_start..cursor], 10) catch null;
                if (cursor < regex_source.len and regex_source[cursor] == ':' and
                    cursor + 2 < regex_source.len and regex_source[cursor + 1] == '/' and
                    (regex_source[cursor + 2] == 'd' or regex_source[cursor + 2] == 'u'))
                {
                    const command_start = cursor + 2;
                    const command_end = command_start + 1;
                    command = regex_source[command_start..command_end];
                    cursor = command_end + 1;
                }
            }
        } else {
            const digits_start = cursor;
            while (cursor < regex_source.len and std.ascii.isDigit(regex_source[cursor])) cursor += 1;
            if (cursor > digits_start) {
                capture_number = std.fmt.parseInt(usize, regex_source[digits_start..cursor], 10) catch null;
            }
        }

        if (capture_number) |number| {
            if (number < capture_indices.len) {
                const capture = capture_indices[number];
                var value = capture_source[capture.start..capture.end];
                while (value.len > 0 and value[0] == '.') value = value[1..];
                if (command) |name| {
                    if (std.mem.eql(u8, name, "d")) {
                        for (value) |ch| try out.append(allocator, std.ascii.toLower(ch));
                    } else {
                        for (value) |ch| try out.append(allocator, std.ascii.toUpper(ch));
                    }
                } else {
                    try out.appendSlice(allocator, value);
                }
                index = cursor;
                continue;
            }
        }

        try out.append(allocator, regex_source[index]);
        index += 1;
    }
}

pub fn containsRTL(text: []const u8) bool {
    var index: usize = 0;
    while (index < text.len) {
        const sequence_length = std.unicode.utf8ByteSequenceLength(text[index]) catch return false;
        if (index + sequence_length > text.len) return false;
        const codepoint = std.unicode.utf8Decode(text[index .. index + sequence_length]) catch return false;
        if (isRtl(codepoint)) return true;
        index += sequence_length;
    }
    return false;
}

/// Compact version of the `CONTAINS_RTL` expression in `utils.ts`.
fn isRtl(codepoint: u21) bool {
    return switch (codepoint) {
        0x05BE,
        0x05C0,
        0x05C3,
        0x05C6,
        0x05D0...0x05F4,
        0x0608,
        0x060B,
        0x060D,
        0x061B...0x064A,
        0x066D...0x066F,
        0x0671...0x06D5,
        0x06E5,
        0x06E6,
        0x06EE,
        0x06EF,
        0x06FA...0x0710,
        0x0712...0x072F,
        0x074D...0x07A5,
        0x07B1,
        0x07EA,
        0x07F4,
        0x07F5,
        0x07FA,
        0x07FE...0x0815,
        0x081A,
        0x0824,
        0x0828,
        0x0830...0x0858,
        0x085E...0x088E,
        0x08A0...0x08C9,
        0x200F,
        0xFB1D,
        0xFB1F...0xFB28,
        0xFB2A...0xFD3D,
        0xFD50...0xFDC7,
        0xFDF0...0xFDFC,
        0xFE70...0xFEFC,
        0x10800...0x10FFF,
        0x1E800...0x1EFFF,
        => true,
        else => false,
    };
}

test "utils mirrors upstream helpers" {
    try std.testing.expectEqual(@as(i32, -1), strcmp("a", "b"));
    try std.testing.expectEqual(@as(i32, 0), strcmp("a", "a"));
    try std.testing.expectEqualStrings("b.txt", basename("/a/b.txt"));
    try std.testing.expect(isValidHexColor("#abc"));
    try std.testing.expect(isValidHexColor("#abcdef12"));
    try std.testing.expect(!isValidHexColor("#abcde"));
    try std.testing.expect(hasCaptures("foo ${1:/downcase}"));
    try std.testing.expect(hasCaptures("foo $1"));
    try std.testing.expect(!hasCaptures("foo"));
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try replaceCaptures(std.testing.allocator, &out, "x$1", "abc", &.{ .{ .start = 0, .end = 3, .length = 3 }, .{ .start = 1, .end = 2, .length = 1 } });
    try std.testing.expectEqualStrings("xb", out.items);
}
