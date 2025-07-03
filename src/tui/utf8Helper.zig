const std = @import("std");
const unicode = std.unicode;

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
