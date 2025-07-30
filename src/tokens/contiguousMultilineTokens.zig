const std = @import("std");
const io = std.io;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Range = @import("../basics/range.zig").Range;
const LineRange = @import("../basics/lineRange.zig").LineRange;
const countEOL = @import("../basics/eolCounter.zig").countEOL;
const Position = @import("../basics/position.zig").Position;
const ContiguousTokensEditing = @import("contiguousTokensEditing.zig").ContiguousTokensEditing;

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
    _tokens: ArrayList([]u32),

    pub fn init(startLineNumber: usize, tokens: ArrayList([]u32)) ContiguousMultilineTokens {
        return .{
            ._startLineNumber = startLineNumber,
            ._tokens = tokens,
        };
    }

    pub fn deinit(self: *ContiguousMultilineTokens) void {
        self._tokens.deinit();
    }

    pub fn deserialize(buff: []const u8, offset: usize, result: ArrayList(ContiguousMultilineTokens)) !usize {
        const allocator = result.allocator;
        const stream = io.fixedBufferStream(buff[offset..]);
        const view32 = stream.reader();
        const seekable = stream.seekableStream();
        const startLineNumber = try view32.readInt(u32, .big);
        const count = try view32.readInt(u32, .big);

        var tokens = ArrayList([]u32).init(allocator);
        for (0..count) |_| {
            const byteCount = try view32.readInt(i32, .big);
            const u32Count = @divFloor(byteCount, 4);
            const target = buff[@divFloor(offset, 4) .. @divFloor(offset, 4) + u32Count];
            const targetU32: [*]u32 = @ptrCast(target.ptr);
            try tokens.append(targetU32[0..u32Count]);
            try seekable.seekBy(byteCount);
        }
        try result.append(ContiguousMultilineTokens.init(startLineNumber, tokens));
        return offset;
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
    pub fn getLineTokens(self: *ContiguousMultilineTokens, lineNumber: usize) ?[]u32 {
        return self._tokens.items[lineNumber - self._startLineNumber];
    }

    pub fn appendLineTokens(self: *ContiguousMultilineTokens, lineTokens: []u32) !void {
        try self._tokens.append(lineTokens);
    }

    pub fn serializeSize(self: *ContiguousMultilineTokens) !usize {
        var result: usize = 0;
        result += 4; // 4 bytes for the start line number
        result += 4; // 4 bytes for the line count
        for (0..self._tokens.items.len) |i| {
            const lineTokens = self._tokens.items[i];
            if (lineTokens.len == 0) {
                return error.NotSupported;
            }
            result += 4; // 4 bytes for the byte count
            result += lineTokens.len * 4;
        }
        return result;
    }

    pub fn serialize(self: *ContiguousMultilineTokens, destination: []u8, offset: usize) !usize {
        var stream = io.fixedBufferStream(destination[offset..]);
        const writer = stream.writer();
        try writer.writeInt(u32, self._startLineNumber, .big);
        try writer.writeInt(u32, self._tokens.items.len, .big);
        for (self._tokens.items) |lineTokens| {
            try writer.writeInt(u32, @intCast(lineTokens.len), .big);

            const lineTokensBytes: [*]u8 = @ptrCast(lineTokens.ptr);
            try writer.writeAll(lineTokensBytes[0 .. lineTokens.len * 4]);
        }
        return offset + stream.pos;
    }

    pub fn applyEdit(self: *ContiguousMultilineTokens, range: Range, text: []const u8) void {
        const res = countEOL(text);
        const eolCount = res.eolCount;
        const firstLineLength = res.firstLineLength;
        self._acceptDeleteRange(range);
        self._acceptInsertText(Position.init(range.startLineNumber, range.startColumn), eolCount, firstLineLength);
    }

    pub fn _acceptDeleteRange(self: *ContiguousMultilineTokens, range: Range) !void {
        if (range.startLineNumber == range.endLineNumber and range.startColumn == range.endColumn) {
            // Nothing to delete
            return;
        }

        const firstLineIndex = range.startLineNumber - self._startLineNumber;
        const lastLineIndex = range.endLineNumber - self._startLineNumber;

        if (lastLineIndex < 0) {
            // this deletion occurs entirely before this block, so we only need to adjust line numbers
            const deletedLinesCount = lastLineIndex - firstLineIndex;
            self._startLineNumber -= deletedLinesCount;
            return;
        }

        if (firstLineIndex >= self._tokens.items.len) {
            // this deletion occurs entirely after this block, so there is nothing to do
            return;
        }

        if (firstLineIndex < 0 and lastLineIndex >= self._tokens.items.len) {
            // this deletion completely encompasses this block
            self._startLineNumber = 0;
            self._tokens.resize(0);
            return;
        }

        if (firstLineIndex == lastLineIndex) {
            // a delete on a single line
            self._tokens[firstLineIndex] = try ContiguousTokensEditing.delete(self._tokens[firstLineIndex], range.startColumn - 1, range.endColumn - 1);
            return;
        }

        if (firstLineIndex >= 0) {
            // The first line survives
            self._tokens[firstLineIndex] = try ContiguousTokensEditing.deleteEnding(self._tokens[firstLineIndex], range.startColumn - 1);

            if (lastLineIndex < self._tokens.items.len) {
                // The last line survives
                const lastLineTokens = try ContiguousTokensEditing.deleteBeginning(self._tokens[lastLineIndex], range.endColumn - 1);

                // Take remaining text on last line and append it to remaining text on first line
                self._tokens[firstLineIndex] = try ContiguousTokensEditing.append(self._tokens[firstLineIndex], lastLineTokens);

                // Delete middle lines
                try self._tokens.splice(firstLineIndex + 1, lastLineIndex - firstLineIndex);
            } else {
                // The last line does not survive

                // Take remaining text on last line and append it to remaining text on first line
                self._tokens[firstLineIndex] = try ContiguousTokensEditing.append(self._tokens[firstLineIndex], null);

                // Delete lines
                self._tokens = self._tokens.slice(0, firstLineIndex + 1);
            }
        } else {
            // The first line does not survive

            const deletedBefore = -firstLineIndex;
            self._startLineNumber -= deletedBefore;

            // Remove beginning from last line
            self._tokens[lastLineIndex] = try ContiguousTokensEditing.deleteBeginning(self._tokens[lastLineIndex], range.endColumn - 1);

            // Delete lines
            self._tokens = self._tokens.slice(lastLineIndex);
        }
    }

    fn _acceptInsertText(self: *ContiguousMultilineTokens, position: Position, eolCount: usize, firstLineLength: usize) void {
        if (eolCount == 0 and firstLineLength == 0) {
            // Nothing to insert
            return;
        }

        const lineIndex = position.lineNumber - self._startLineNumber;

        if (lineIndex < 0) {
            // this insertion occurs before this block, so we only need to adjust line numbers
            self._startLineNumber += eolCount;
            return;
        }

        if (lineIndex >= self._tokens.items.len) {
            // this insertion occurs after this block, so there is nothing to do
            return;
        }

        if (eolCount == 0) {
            // Inserting text on one line
            self._tokens[lineIndex] = ContiguousTokensEditing.insert(self._tokens[lineIndex], position.column - 1, firstLineLength);
            return;
        }

        self._tokens[lineIndex] = ContiguousTokensEditing.deleteEnding(self._tokens[lineIndex], position.column - 1);
        self._tokens[lineIndex] = ContiguousTokensEditing.insert(self._tokens[lineIndex], position.column - 1, firstLineLength);

        self._insertLines(position.lineNumber, eolCount);
    }

    fn _insertLines(self: *ContiguousMultilineTokens, insertIndex: usize, insertCount: usize) !void {
        if (insertCount == 0) {
            return;
        }
        var lineTokens = ArrayList(?u32).init(self._tokens.allocator);
        defer lineTokens.deinit();
        for (0..insertCount) |_| {
            try lineTokens.append(null);
        }
        self._tokens = try self._tokens.insertSlice(insertIndex, lineTokens.items);
    }
};
