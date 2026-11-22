// Port of `src/vs/editor/common/tokens/contiguousMultilineTokensBuilder.ts`.
//
// Zig adaptation: `deserialize` takes an allocator plus `Io.Reader` and
// `finalize` returns a borrowed slice owned by the builder.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const TokenPacked = @import("./lineTokens.zig").TokenPacked;

const ContiguousMultilineTokens = @import("./contiguousMultilineTokens.zig").ContiguousMultilineTokens;

pub const ContiguousMultilineTokensBuilder = struct {
    _tokens: ArrayList(ContiguousMultilineTokens),

    pub fn deserialize(allocator: Allocator, buff: *Io.Reader) !ArrayList(ContiguousMultilineTokens) {
        const count = try buff.takeInt(u32, .big);
        var result = ArrayList(ContiguousMultilineTokens).init(allocator);
        errdefer {
            for (result.items) |*item| item.deinit();
            result.deinit();
        }
        var i: usize = 0;
        while (i < count) : (i += 1) {
            try ContiguousMultilineTokens.deserialize(buff, &result);
        }
        return result;
    }

    pub fn init(allocator: Allocator) ContiguousMultilineTokensBuilder {
        return .{ ._tokens = ArrayList(ContiguousMultilineTokens).init(allocator) };
    }

    pub fn deinit(self: *ContiguousMultilineTokensBuilder) void {
        for (self._tokens.items) |*item| item.deinit();
        self._tokens.deinit();
    }

    pub fn add(self: *ContiguousMultilineTokensBuilder, lineNumber: usize, lineTokens: []const TokenPacked) !void {
        if (self._tokens.items.len > 0) {
            const last = &self._tokens.items[self._tokens.items.len - 1];
            if (last.getEndLineNumber() + 1 == lineNumber) {
                try last.appendLineTokens(lineTokens);
                return;
            }
        }
        var block = ContiguousMultilineTokens.init(lineNumber, ArrayList(?ArrayList(TokenPacked)).init(self._tokens.allocator));
        errdefer block.deinit();
        try block.appendLineTokens(lineTokens);
        try self._tokens.append(block);
    }

    /// Borrowed view; the builder remains the owner and must outlive use.
    pub fn finalize(self: *ContiguousMultilineTokensBuilder) []ContiguousMultilineTokens {
        return self._tokens.items;
    }

    pub fn serialize(self: *const ContiguousMultilineTokensBuilder) !ArrayList(u8) {
        const size = try self._serializeSize();
        var result = ArrayList(u8).init(self._tokens.allocator);
        errdefer result.deinit();
        try result.resize(size);
        try self._serialize(result.items);
        return result;
    }

    fn _serializeSize(self: *const ContiguousMultilineTokensBuilder) !usize {
        var result: usize = 4;
        for (self._tokens.items) |*item| result += try item.serializeSize();
        return result;
    }

    fn _serialize(self: *const ContiguousMultilineTokensBuilder, destination: []u8) !void {
        var w = Io.Writer.fixed(destination);
        try w.writeInt(u32, @intCast(self._tokens.items.len), .big);
        for (self._tokens.items) |*item| try item.serialize(&w);
    }
};

test "ContiguousMultilineTokensBuilder/add" {
    const allocator = std.testing.allocator;
    var builder = ContiguousMultilineTokensBuilder.init(allocator);
    defer builder.deinit();
    try builder.add(1, &.{});
    const result = builder.finalize();
    try std.testing.expectEqual(1, result.len);
}
