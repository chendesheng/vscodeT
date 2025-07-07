const std = @import("std");
const unicode = std.unicode;

pub fn safeUtf8Substring(str: []const u8, start: usize, end: usize) []const u8 {
    if (start == end) {
        return "";
    }

    std.debug.assert(start < end);

    const safeStart = if (start > 0) safeUtf8Prefix(str, start).len else 0;
    return safeUtf8Prefix(str[safeStart..], end - safeStart);
}

pub fn safeUtf8Prefix(str: []const u8, limit: usize) []const u8 {
    const n = @min(limit, str.len);

    var i: u3 = 0;
    while (i < 4) {
        if (n < i + 1) {
            break;
        }

        const len = unicode.utf8ByteSequenceLength(str[n - i - 1]) catch {
            i += 1;
            continue;
        };

        i += 1;

        if (i == len) {
            i = 0;
            break;
        }

        if (i < len) {
            break;
        }

        unreachable;
    }

    return str[0 .. n - i];
}

test "empty" {
    try std.testing.expectEqualStrings("", safeUtf8Prefix("", 1));
}

test "chinese" {
    for (0..("你".len)) |i| {
        try std.testing.expectEqualStrings("", safeUtf8Prefix("你好", i));
    }

    for (("你".len)..("你好".len - 1)) |i| {
        try std.testing.expectEqualStrings("你", safeUtf8Prefix("你好", i));
    }

    try std.testing.expectEqualStrings("你好", safeUtf8Prefix("你好", "你好".len));
    try std.testing.expectEqualStrings("你好", safeUtf8Prefix("你好", "你好".len + 1));
}

test "ascii" {
    const str = "How are you?";
    for (0..str.len) |i| {
        try std.testing.expectEqualStrings(str[0..i], safeUtf8Prefix(str, i));
    }
}

test "safeUtf8Substring" {
    try std.testing.expectEqualStrings("", safeUtf8Substring("你好", 0, 2));
    try std.testing.expectEqualStrings("你", safeUtf8Substring("你好", 0, 3));
    try std.testing.expectEqualStrings("你", safeUtf8Substring("你好", 0, 4));
    try std.testing.expectEqualStrings("你", safeUtf8Substring("你好", 0, 5));
    try std.testing.expectEqualStrings("你好", safeUtf8Substring("你好", 0, 6));
    try std.testing.expectEqualStrings("你好", safeUtf8Substring("你好吗", 0, 7));
    try std.testing.expectEqualStrings("你好", safeUtf8Substring("你好吗", 1, 7));
    try std.testing.expectEqualStrings("你好", safeUtf8Substring("你好吗", 2, 7));
    try std.testing.expectEqualStrings("好", safeUtf8Substring("你好吗", 3, 7));
}
