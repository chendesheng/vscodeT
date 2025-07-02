const std = @import("std");
const mem = std.mem;
const ArrayList = std.ArrayList;
const io = std.io;
const safeUtf8Prefix = @import("../utf8Helper.zig").safeUtf8Prefix;

pub const UTF8ChunkReader = struct {
    _reader: std.io.Reader,
    _allocator: std.mem.Allocator,
    _tempBytes: [3]u8,
    _tempBytesLen: usize,

    pub fn init(allocator: std.mem.Allocator, reader: io.Reader) !UTF8ChunkReader {
        return .{ ._reader = reader, ._allocator = allocator, ._tempBytesLen = 0, ._tempBytes = undefined };
    }

    pub fn readAlloc(self: *UTF8ChunkReader, maxBytes: usize) !?ArrayList(u8) {
        if (maxBytes < 3) {
            unreachable;
        }

        var chunk = try std.ArrayList(u8).initCapacity(self._allocator, maxBytes);
        if (self._tempBytesLen > 0) {
            chunk.appendSlice(self._tempBytes[0..self._tempBytesLen]);
            self._tempBytesLen = 0;
        }

        // Read directly into chunk's memory
        const read_len = try self._reader.read(chunk.unusedCapacitySlice());
        if (read_len == 0) {
            if (chunk.items.len == 0) {
                chunk.deinit(); // avoid leaking unused chunk
                return null;
            }

            return chunk;
        }

        // Set the actual length of the chunk
        chunk.items.len = read_len;

        const safeUtf8Bytes = safeUtf8Prefix(chunk.items, chunk.items.len);
        if (safeUtf8Bytes.len == chunk.items.len) {
            chunk.deinit();
            return null;
        } else if (safeUtf8Bytes.len < chunk.items.len) {
            self._tempBytesLen = chunk.items.len - safeUtf8Bytes.len;
            mem.copyForwards(u8, self._tempBytes[0..self._tempBytesLen], chunk.items[safeUtf8Bytes.len..chunk.items.len]);

            for (0..self._tempBytesLen) |_| {
                chunk.pop();
            }

            return chunk;
        } else {
            unreachable;
        }
    }
};
