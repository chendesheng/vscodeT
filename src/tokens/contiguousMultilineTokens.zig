const std = @import("std");
const io = std.io;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Range = @import("../basics/range.zig").Range;
const LineRange = @import("../basics/lineRange.zig").LineRange;
const countEOL = @import("../basics/eolCounter.zig").countEOL;
const Position = @import("../basics/position.zig").Position;
const ContiguousTokensEditing = @import("contiguousTokensEditing.zig").ContiguousTokensEditing;
const TokenPacked = @import("lineTokens.zig").TokenPacked;
const usizeSub = @import("../basics/utils.zig").usizeSub;
const usizeAdd = @import("../basics/utils.zig").usizeAdd;
const LineTokens = @import("lineTokens.zig").LineTokens;

// Represents contiguous tokens over a contiguous range of lines.
pub const ContiguousMultilineTokens = struct {
    // The start line number for this block of tokens.
    _startLineNumber: usize,
    // The tokens are stored in a binary format. There is an element for each line,
    // so `tokens[index]` contains all tokens on line `startLineNumber + index`.
    //
    // On a specific line, each token occupies two array indices. For token i:
    //  - at offset 2*i => endOffset
    //  - at offset 2*i + 1 => metadata
    _tokens: ArrayList(?ArrayList(TokenPacked)),

    pub fn init(startLineNumber: usize, tokens: ArrayList(?ArrayList(TokenPacked))) ContiguousMultilineTokens {
        return .{
            ._startLineNumber = startLineNumber,
            ._tokens = tokens,
        };
    }

    pub fn deinit(self: *const ContiguousMultilineTokens) void {
        for (self._tokens.items) |lineTokens| {
            if (lineTokens) |tokens| {
                tokens.deinit();
            }
        }
        self._tokens.deinit();
    }

    // TODO: avoid copy when deserializing
    pub fn deserialize(buff: io.AnyReader, result: *ArrayList(ContiguousMultilineTokens)) !void {
        const allocator = result.allocator;
        const startLineNumber = try buff.readInt(u32, .big);
        const count = try buff.readInt(u32, .big);

        var multilineTokens = ArrayList(?ArrayList(TokenPacked)).init(allocator);
        for (0..count) |_| {
            const byteCount = try buff.readInt(i32, .big);
            const tokensCount: usize = @intCast(@divFloor(byteCount, @sizeOf(TokenPacked)));
            var tokens = ArrayList(TokenPacked).init(allocator);
            for (0..tokensCount) |_| {
                const offset = try buff.readInt(u32, .big);
                const metadata = try buff.readInt(u32, .big);
                try tokens.append(LineTokens.initTokenPacked(@intCast(offset), @bitCast(metadata)));
            }
            try multilineTokens.append(tokens);
        }
        try result.append(ContiguousMultilineTokens.init(startLineNumber, multilineTokens));
    }

    // (Inclusive) start line number for these tokens.
    pub fn getStartLineNumber(self: *ContiguousMultilineTokens) usize {
        return self._startLineNumber;
    }

    // (Inclusive) end line number for these tokens.
    pub fn getEndLineNumber(self: *ContiguousMultilineTokens) usize {
        return self._startLineNumber + self._tokens.items.len - 1;
    }

    pub fn getLineRange(self: *ContiguousMultilineTokens) LineRange {
        return LineRange.init(self._startLineNumber, self._startLineNumber + self._tokens.items.len);
    }

    // @see {@link _tokens}
    pub fn getLineTokens(self: *const ContiguousMultilineTokens, lineNumber: usize) ?[]TokenPacked {
        if (self._tokens.items[lineNumber - self._startLineNumber]) |lineTokens| {
            return lineTokens.items;
        }
        return null;
    }

    pub fn appendLineTokens(self: *ContiguousMultilineTokens, lineTokens: ArrayList(TokenPacked)) !void {
        try self._tokens.append(lineTokens);
    }

    pub fn serializeSize(self: *ContiguousMultilineTokens) !usize {
        var result: usize = 0;
        result += 4; // 4 bytes for the start line number
        result += 4; // 4 bytes for the line count
        for (0..self._tokens.items.len) |i| {
            const _lineTokens: ?ArrayList(TokenPacked) = self._tokens.items[i];
            if (_lineTokens) |lineTokens| {
                result += 4; // 4 bytes for the byte count
                result += lineTokens.items.len * @sizeOf(TokenPacked);
            } else {
                return error.NotSupported;
            }
        }
        return result;
    }

    pub fn serialize(self: *ContiguousMultilineTokens, destination: io.AnyWriter) !void {
        try destination.writeInt(u32, @intCast(self._startLineNumber), .big);
        try destination.writeInt(u32, @intCast(self._tokens.items.len), .big);
        for (self._tokens.items) |_lineTokens| {
            if (_lineTokens) |lineTokens| {
                const items = lineTokens.items;
                try destination.writeInt(u32, @intCast(items.len * @sizeOf(TokenPacked)), .big);

                for (items) |token| {
                    try destination.writeInt(u32, @intCast(token.endOffset), .big);
                    try destination.writeInt(u32, @bitCast(token.metadata), .big);
                }
            } else {
                return error.NotSupported;
            }
        }
    }

    pub fn applyEdit(self: *ContiguousMultilineTokens, range: Range, text: []const u8) !void {
        const res = countEOL(text);
        const eolCount = res.eolCount;
        const firstLineLength = res.firstLineLength;
        try self._acceptDeleteRange(range);
        try self._acceptInsertText(Position.init(range.startLineNumber, range.startColumn), eolCount, firstLineLength);
    }

    pub fn _acceptDeleteRange(self: *ContiguousMultilineTokens, range: Range) !void {
        if (range.startLineNumber == range.endLineNumber and range.startColumn == range.endColumn) {
            // Nothing to delete
            return;
        }

        const firstLineIndexI = usizeSub(range.startLineNumber, self._startLineNumber);
        const lastLineIndexI = usizeSub(range.endLineNumber, self._startLineNumber);
        const tokenLengthI = @as(isize, @intCast(self._tokens.items.len));

        if (lastLineIndexI < 0) {
            // this deletion occurs entirely before this block, so we only need to adjust line numbers
            const deletedLinesCount: isize = lastLineIndexI - firstLineIndexI;
            self._startLineNumber = usizeAdd(self._startLineNumber, -deletedLinesCount);
            return;
        }

        if (firstLineIndexI >= tokenLengthI) {
            // this deletion occurs entirely after this block, so there is nothing to do
            return;
        }

        if (firstLineIndexI < 0 and lastLineIndexI >= tokenLengthI) {
            // this deletion completely encompasses this block
            self._startLineNumber = 0;
            try self._tokens.resize(0);
            return;
        }

        const firstLineIndex = range.startLineNumber - self._startLineNumber;
        const lastLineIndex = range.endLineNumber - self._startLineNumber;
        const firstLineTokens = &self._tokens.items[firstLineIndex];
        const lastLineTokens = &self._tokens.items[lastLineIndex];

        if (firstLineIndex == lastLineIndex) {
            // a delete on a single line
            try ContiguousTokensEditing.delete(firstLineTokens, range.startColumn - 1, range.endColumn - 1);
            return;
        }

        if (firstLineIndex >= 0) {
            // The first line survives
            try ContiguousTokensEditing.deleteEnding(firstLineTokens, range.startColumn - 1);

            if (lastLineIndex < self._tokens.items.len) {
                // The last line survives
                try ContiguousTokensEditing.deleteBeginning(lastLineTokens, range.endColumn - 1);

                // Take remaining text on last line and append it to remaining text on first line
                try ContiguousTokensEditing.append(firstLineTokens, lastLineTokens);

                // Delete middle lines
                try self._tokens.replaceRange(firstLineIndex + 1, lastLineIndex - firstLineIndex, &[_]?ArrayList(TokenPacked){});
            } else {
                // The last line does not survive

                // Take remaining text on last line and append it to remaining text on first line
                var nullItem: ?ArrayList(TokenPacked) = null;
                try ContiguousTokensEditing.append(firstLineTokens, &nullItem);

                // Delete lines
                try self._tokens.resize(firstLineIndex + 1);
            }
        } else {
            // The first line does not survive

            const deletedBefore = -firstLineIndex;
            self._startLineNumber -= deletedBefore;

            // Remove beginning from last line
            try ContiguousTokensEditing.deleteBeginning(lastLineTokens, range.endColumn - 1);

            // Delete lines
            try self._tokens.replaceRange(0, lastLineIndex, &[_]ArrayList(TokenPacked){});
        }
    }

    fn _acceptInsertText(self: *ContiguousMultilineTokens, position: Position, eolCount: usize, firstLineLength: usize) !void {
        if (eolCount == 0 and firstLineLength == 0) {
            // Nothing to insert
            return;
        }

        if (position.lineNumber < self._startLineNumber) {
            // this insertion occurs before this block, so we only need to adjust line numbers
            self._startLineNumber += eolCount;
            return;
        }

        const lineIndex = position.lineNumber - self._startLineNumber;
        if (lineIndex >= self._tokens.items.len) {
            // this insertion occurs after this block, so there is nothing to do
            return;
        }

        const lineTokens = &self._tokens.items[lineIndex];
        if (eolCount == 0) {
            // Inserting text on one line
            ContiguousTokensEditing.insert(lineTokens, position.column - 1, firstLineLength);
            return;
        }

        try ContiguousTokensEditing.deleteEnding(lineTokens, position.column - 1);
        ContiguousTokensEditing.insert(lineTokens, position.column - 1, firstLineLength);

        try self._insertLines(position.lineNumber, eolCount);
    }

    fn _insertLines(self: *ContiguousMultilineTokens, insertIndex: usize, insertCount: usize) !void {
        if (insertCount == 0) {
            return;
        }
        for (0..insertCount) |i| {
            try self._tokens.insert(insertIndex + i, null);
        }
    }
};

test "ContiguousMultilineTokens/serialize empty" {
    const allocator = std.testing.allocator;
    var tokens = ContiguousMultilineTokens.init(0, ArrayList(?ArrayList(TokenPacked)).init(allocator));
    defer tokens.deinit();
    try std.testing.expectEqual(8, try tokens.serializeSize());

    var destination = ArrayList(u8).init(allocator);
    defer destination.deinit();
    try tokens.serialize(destination.writer().any());
    try std.testing.expectEqualSlices(u8, &[_]u8{0} ** 8, destination.items);
    var stream = io.fixedBufferStream(destination.items);
    var result = ArrayList(ContiguousMultilineTokens).init(allocator);
    defer result.deinit();
    try ContiguousMultilineTokens.deserialize(stream.reader().any(), &result);
    try std.testing.expectEqualDeep(tokens, result.items[0]);
}

test "ContiguousMultilineTokens/serialize nonempty" {
    const allocator = std.testing.allocator;
    var multilineTokens = ContiguousMultilineTokens.init(0, ArrayList(?ArrayList(TokenPacked)).init(allocator));
    defer multilineTokens.deinit();

    var tokens1 = ArrayList(TokenPacked).init(allocator);
    try tokens1.append(TokenPacked{ .endOffset = 0, .metadata = .default });
    try multilineTokens.appendLineTokens(tokens1);

    var tokens2 = ArrayList(TokenPacked).init(allocator);
    try tokens2.append(TokenPacked{ .endOffset = 10, .metadata = .default });
    try multilineTokens.appendLineTokens(tokens2);

    try std.testing.expectEqual(32, try multilineTokens.serializeSize());

    var destination = ArrayList(u8).init(allocator);
    defer destination.deinit();
    try multilineTokens.serialize(destination.writer().any());

    var stream = io.fixedBufferStream(destination.items);
    var result = ArrayList(ContiguousMultilineTokens).init(allocator);
    defer result.deinit();
    defer {
        for (result.items) |item| {
            item.deinit();
        }
    }
    try ContiguousMultilineTokens.deserialize(stream.reader().any(), &result);
    for (multilineTokens._tokens.items, result.items[0]._tokens.items) |token1, token2| {
        try std.testing.expectEqualDeep(token1, token2);
    }
}

test "ContiguousMultilineTokens/applyEdit" {
    const allocator = std.testing.allocator;
    var multilineTokens = ContiguousMultilineTokens.init(0, ArrayList(?ArrayList(TokenPacked)).init(allocator));
    defer multilineTokens.deinit();

    var tokens1 = ArrayList(TokenPacked).init(allocator);
    try tokens1.append(TokenPacked{ .endOffset = 5, .metadata = .default });
    try multilineTokens.appendLineTokens(tokens1);

    try multilineTokens.applyEdit(Range.init(1, 1, 1, 1), "hello");
}
