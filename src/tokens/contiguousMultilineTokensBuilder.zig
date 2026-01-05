const std = @import("std");
const io = std.io;
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const TokenPacked = @import("lineTokens.zig").TokenPacked;

const ContiguousMultilineTokens = @import("./contiguousMultilineTokens.zig").ContiguousMultilineTokens;

pub const ContiguousMultilineTokensBuilder = struct {
    _tokens: ArrayList(ContiguousMultilineTokens),

    pub fn deserialize(allocator: Allocator, buff: io.AnyReader) !ArrayList(ContiguousMultilineTokens) {
        const count = try buff.readInt(u32, .big);
        var result = ArrayList(ContiguousMultilineTokens).init(allocator);
        for (0..count) |_| {
            try ContiguousMultilineTokens.deserialize(allocator, buff, &result);
        }
        return result;
    }

    pub fn init(allocator: Allocator) ContiguousMultilineTokensBuilder {
        return ContiguousMultilineTokensBuilder{
            ._tokens = ArrayList(ContiguousMultilineTokens).init(allocator),
        };
    }

    pub fn deinit(self: *ContiguousMultilineTokensBuilder) void {
        for (self._tokens.items) |item| {
            item.deinit();
        }
        self._tokens.deinit();
    }

    pub fn add(self: *ContiguousMultilineTokensBuilder, lineNumber: usize, lineTokens: []const TokenPacked) !void {
        var arrLineTokens = ArrayList(TokenPacked).init(self._tokens.allocator);
        try arrLineTokens.appendSlice(lineTokens);

        if (self._tokens.items.len > 0) {
            var last = &self._tokens.items[self._tokens.items.len - 1];
            if (last.getEndLineNumber() + 1 == lineNumber) {
                // append
                try last.appendLineTokens(arrLineTokens);
                return;
            }
        }
        var multilineTokens = ArrayList(?ArrayList(TokenPacked)).init(self._tokens.allocator);
        try multilineTokens.append(arrLineTokens);
        try self._tokens.append(ContiguousMultilineTokens.init(lineNumber, multilineTokens));
    }

    pub fn finalize(self: *ContiguousMultilineTokensBuilder) ArrayList(ContiguousMultilineTokens) {
        return self._tokens;
    }

    pub fn serialize(self: *ContiguousMultilineTokensBuilder) !ArrayList(u8) {
        const size = try self._serializeSize();
        var result = ArrayList(u8).init(self._tokens.allocator);
        try result.resize(size);
        try self._serialize(result.items);
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

test "ContiguousMultilineTokensBuilder/add" {
    const allocator = std.testing.allocator;
    var builder = ContiguousMultilineTokensBuilder.init(allocator);
    defer builder.deinit();
    try builder.add(1, &[_]TokenPacked{});
    const result = builder.finalize();
    try std.testing.expectEqual(1, result.items.len);
}
