const std = @import("std");
const ArrayList = std.ArrayList;

const ContiguousMultilineTokens = @import("./contiguousMultilineTokens.zig").ContiguousMultilineTokens;

pub const ContiguousMultilineTokensBuilder = struct {
    _tokens: ArrayList(ContiguousMultilineTokens),

    pub fn deserialize(buff: []const u8) ArrayList(ContiguousMultilineTokens) {
        var offset: usize = 0;
        const count = view32.get(offset);
        offset += 4;
        var result = ArrayList(ContiguousMultilineTokens).init(std.heap.page_allocator);
        for (0..count) |i| {
            offset = ContiguousMultilineTokens.deserialize(buff, offset, result.items);
        }
        return result;
    }

    pub fn init() ContiguousMultilineTokensBuilder {
        return ContiguousMultilineTokensBuilder{
            ._tokens = ArrayList(ContiguousMultilineTokens).init(std.heap.page_allocator),
        };
    }

    pub fn add(self: *ContiguousMultilineTokensBuilder, lineNumber: usize, lineTokens: []u32) void {
        if (self._tokens.items.len > 0) {
            const last = self._tokens.items[self._tokens.items.len - 1];
            if (last.getEndLineNumber() + 1 == lineNumber) {
                // append
                last.appendLineTokens(lineTokens.items);
                return;
            }
        }
        self._tokens.append(ContiguousMultilineTokens{
            .startLineNumber = lineNumber,
            .tokens = ArrayList(u32).init(std.heap.page_allocator),
        });
    }

    pub fn finalize(self: *ContiguousMultilineTokensBuilder) []ContiguousMultilineTokens {
        return self._tokens.items;
    }

    pub fn serialize(self: *ContiguousMultilineTokensBuilder) []u8 {
        const size = self._serializeSize();
        var result = std.ArrayList(u8).init(std.heap.page_allocator);
        self._serialize(result.items);
        return result;
    }

    fn _serializeSize(self: *ContiguousMultilineTokensBuilder) usize {
        var result: usize = 0;
        result += 4; // 4 bytes for the count
        for (0..self._tokens.items.len) |i| {
            result += self._tokens.items[i].serializeSize();
        }
        return result;
    }

    fn _serialize(self: *ContiguousMultilineTokensBuilder, destination: []u8) void {
        var offset: usize = 0;
        writeUInt32BE(destination, self._tokens.items.len, offset);
        offset += 4;
        for (0..self._tokens.items.len) |i| {
            offset = self._tokens.items[i].serialize(destination, offset);
        }
    }
};
