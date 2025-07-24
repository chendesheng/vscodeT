const std = @import("std");
const unicode = std.unicode;

pub fn safeUtf8Substring(str: []const u8, start: usize, end: usize) []const u8 {
    const range = safeUtf8Range(str, start, end);
    return str[range[0]..range[1]];
}

pub fn safeUtf8Range(str: []const u8, start: usize, end: usize) [2]usize {
    if (start == end) {
        return [2]usize{ start, end };
    }

    std.debug.assert(start < end);

    const safeStart = if (start > 0) safeUtf8Prefix(str, start).len else 0;
    const safeEnd = safeStart + safeUtf8Prefix(str[safeStart..], end - safeStart).len;
    return [2]usize{ safeStart, safeEnd };
}

pub fn lastCodepoint(str: []const u8, limit: usize) !u21 {
    if (limit == 0 or limit > str.len) {
        unreachable;
    }

    const last = safeUtf8Substring(str, limit - 1, limit);
    if (last.len == 0) {
        return 0;
    }
    return try unicode.utf8Decode(last);
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

pub fn Utf8StreamIterator(comptime bufSize: usize) type {
    return struct {
        const Self = @This();

        bytes: [bufSize]u8,
        bytesLen: usize,
        i: usize,
        reader: std.io.AnyReader,

        pub fn init(reader: std.io.AnyReader) Self {
            return Self{
                .bytes = undefined,
                .bytesLen = 0,
                .i = 0,
                .reader = reader,
            };
        }

        pub fn nextCodepointSlice(self: *Self) !?[]const u8 {
            if (self.tryNextCodepointSlice()) |res| {
                return res;
            } else {
                try self.read();
                return self.tryNextCodepointSlice();
            }
        }

        fn tryNextCodepointSlice(self: *Self) ?[]const u8 {
            if (self.i >= self.bytesLen) {
                return null;
            }

            const cp_len = unicode.utf8ByteSequenceLength(self.bytes[self.i]) catch {
                return null;
            };

            if (self.i + cp_len > self.bytesLen) {
                return null;
            }

            self.i += cp_len;
            return self.bytes[self.i - cp_len .. self.i];
        }

        fn read(self: *Self) !void {
            self.resetRemainingBytes();

            const n = try self.reader.readAll(self.bytes[self.bytesLen..]);
            if (n == 0) return;
            self.bytesLen += n;
        }

        // move remaining bytes to start of buffer
        fn resetRemainingBytes(self: *Self) void {
            if (self.i == 0) return;
            if (self.i >= self.bytesLen) {
                self.i = 0;
                self.bytesLen = 0;
                return;
            }

            const remaining = self.bytes[self.i..self.bytesLen];
            std.mem.copyForwards(u8, &self.bytes, remaining);
            self.bytesLen = remaining.len;
            self.i = 0;
        }
    };
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
    try std.testing.expectEqualStrings("吗", safeUtf8Substring("你好吗", "你好吗".len - 1, "你好吗".len));
}

test "Utf8StreamIterator" {
    const bytes = "flatMap() 方法对数组中的每个元素应用给定的回调函数，然后将结果展开一级，返回一个新数组。它等价于在调用 map() 方法后再调用深度为 1 的 flat() 方法（arr.map(...args).flat()），但比分别调用这两个方法稍微更高效一些。";
    var fbs = std.io.fixedBufferStream(bytes);
    var iter = Utf8StreamIterator(16).init(fbs.reader().any());

    var utf8Iter = std.unicode.Utf8Iterator{
        .bytes = bytes,
        .i = 0,
    };

    while (utf8Iter.nextCodepointSlice()) |str| {
        if (try iter.nextCodepointSlice()) |str2| {
            try std.testing.expectEqualSlices(u8, str, str2);
        } else {
            try std.testing.expect(false);
        }
    }
}
