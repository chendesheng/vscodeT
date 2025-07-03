const std = @import("std");
const mem = std.mem;
const ArrayList = std.ArrayList;
const io = std.io;
const safeUtf8Prefix = @import("utf8Helper.zig").safeUtf8Prefix;

pub const UTF8ChunkReader = struct {
    _reader: io.AnyReader,
    _allocator: std.mem.Allocator,
    _tempBytes: [3]u8 = undefined,
    _tempBytesLen: usize = 0,

    pub fn init(allocator: std.mem.Allocator, reader: io.AnyReader) @This() {
        return .{ ._reader = reader, ._allocator = allocator };
    }

    pub fn readAlloc(self: *@This(), maxBytes: usize) !?ArrayList(u8) {
        if (maxBytes < 3) {
            unreachable;
        }

        var chunk = try std.ArrayList(u8).initCapacity(self._allocator, maxBytes);
        if (self._tempBytesLen > 0) {
            try chunk.appendSlice(self._tempBytes[0..self._tempBytesLen]);
            self._tempBytesLen = 0;
        }

        // Read directly into chunk's memory
        const read_len = try self._reader.readAll(chunk.unusedCapacitySlice());
        if (read_len == 0) {
            if (chunk.items.len == 0) {
                chunk.deinit(); // avoid leaking unused chunk
                return null;
            }

            return chunk;
        }

        // Set the actual length of the chunk
        chunk.items.len += read_len;

        const safeUtf8Bytes = safeUtf8Prefix(chunk.items, chunk.items.len);
        if (safeUtf8Bytes.len == chunk.items.len or safeUtf8Bytes.len == 0) {
            return chunk;
        } else if (safeUtf8Bytes.len < chunk.items.len) {
            self._tempBytesLen = chunk.items.len - safeUtf8Bytes.len;
            mem.copyForwards(u8, self._tempBytes[0..self._tempBytesLen], chunk.items[safeUtf8Bytes.len..chunk.items.len]);

            for (0..self._tempBytesLen) |_| {
                _ = chunk.pop();
            }

            return chunk;
        } else {
            unreachable;
        }
    }
};

test "ascii" {
    const allocator = std.testing.allocator;
    var stream = std.io.fixedBufferStream("Hello, world!");
    const reader = stream.reader();
    var chunkReader = UTF8ChunkReader.init(allocator, reader.any());

    const chunk1 = try chunkReader.readAlloc(10);
    defer if (chunk1) |c| c.deinit();

    const chunk2 = try chunkReader.readAlloc(10);
    defer if (chunk2) |c| c.deinit();

    try std.testing.expectEqualStrings("Hello, wor", chunk1.?.items);
    try std.testing.expectEqualStrings("ld!", chunk2.?.items);
}

test "chinese" {
    const allocator = std.testing.allocator;
    // { 72, 105, 44, 32, 228, 189, 160, 229, 165, 189 }
    var stream = std.io.fixedBufferStream("Hi, 你好");
    const reader = stream.reader();
    var chunkReader = UTF8ChunkReader.init(allocator, reader.any());

    const chunk1 = try chunkReader.readAlloc(8);
    defer if (chunk1) |c| c.deinit();
    try std.testing.expectEqualStrings("Hi, 你", chunk1.?.items);

    const chunk2 = try chunkReader.readAlloc(8);
    defer if (chunk2) |c| c.deinit();
    try std.testing.expectEqualStrings("好", chunk2.?.items);

    const chunk3 = try chunkReader.readAlloc(8);
    defer if (chunk3) |c| c.deinit();
    try std.testing.expectEqual(null, chunk3);
}
