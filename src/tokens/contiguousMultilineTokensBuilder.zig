const std = @import("std");
const io = std.io;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const ContiguousMultilineTokens = @import("./contiguousMultilineTokens.zig").ContiguousMultilineTokens;

pub const ContiguousMultilineTokensBuilder = struct {
    _tokens: ArrayList(ContiguousMultilineTokens),

    pub fn deserialize(allocator: Allocator, buff: []const u8) !ArrayList(ContiguousMultilineTokens) {
        const stream = io.fixedBufferStream(buff);
        const reader = stream.reader();
        const count = try reader.readInt(u32, .big);
        var result = ArrayList(ContiguousMultilineTokens).init(allocator);
        for (0..count) |_| {
            try ContiguousMultilineTokens.deserialize(allocator, reader, &result);
        }
        return result;
    }

    pub fn init(allocator: Allocator) ContiguousMultilineTokensBuilder {
        return ContiguousMultilineTokensBuilder{
            ._tokens = ArrayList(ContiguousMultilineTokens).init(allocator),
        };
    }

    pub fn add(self: *ContiguousMultilineTokensBuilder, lineNumber: usize, lineTokens: []u32) !void {
        if (self._tokens.getLastOrNull()) |last| {
            if (last.getEndLineNumber() + 1 == lineNumber) {
                // append
                try last.appendLineTokens(lineTokens.items);
                return;
            }
        }
        try self._tokens.append(ContiguousMultilineTokens{
            ._startLineNumber = lineNumber,
            ._tokens = ArrayList(u32).init(self._tokens.allocator),
        });
    }

    pub fn finalize(self: *ContiguousMultilineTokensBuilder) ![]ContiguousMultilineTokens {
        return self._tokens.items;
    }

    pub fn serialize(self: *ContiguousMultilineTokensBuilder) !ArrayList(u8) {
        const size = try self._serializeSize();
        var result = std.ArrayList(u8).init(self._tokens.allocator);
        try result.resize(size);
        try self._serialize(result.items, size);
        return result;
    }

    fn _serializeSize(self: *ContiguousMultilineTokensBuilder) !usize {
        var result: usize = 0;
        result += 4; // 4 bytes for the count
        for (self._tokens.items) |item| {
            result += try item.serializeSize();
        }
        return result;
    }

    fn _serialize(self: *ContiguousMultilineTokensBuilder, destination: []u8) !void {
        var w = io.fixedBufferStream(destination).writer();
        try w.writeInt(u32, self._tokens.items.len, .big);
        for (self._tokens.items) |item| {
            try item.serialize(w);
        }
    }
};
