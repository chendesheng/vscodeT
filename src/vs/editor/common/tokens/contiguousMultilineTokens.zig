// Port of `src/vs/editor/common/tokens/contiguousMultilineTokens.ts`.
//
// Zig adaptation: each line is an `ArrayList(TokenPacked)` instead of a raw
// `Uint32Array`, and serialization goes through `Io.Reader`/`Io.Writer`.
const std = @import("std");
const Io = std.Io;
const native_endian = @import("builtin").cpu.arch.endian();
const ArrayList = std.array_list.Managed;
const Allocator = std.mem.Allocator;
const Range = @import("../core/range.zig").Range;
const LineRange = @import("../core/ranges/lineRange.zig").LineRange;
const countEOL = @import("../core/misc/eolCounter.zig").countEOL;
const Position = @import("../core/position.zig").Position;
const ContiguousTokensEditing = @import("./contiguousTokensEditing.zig").ContiguousTokensEditing;
const TokenPacked = @import("./lineTokens.zig").TokenPacked;
const LineTokens = @import("./lineTokens.zig").LineTokens;

pub const ContiguousMultilineTokens = struct {
    _startLineNumber: usize,
    _tokens: ArrayList(?ArrayList(TokenPacked)),

    pub fn init(startLineNumber: usize, tokens: ArrayList(?ArrayList(TokenPacked))) ContiguousMultilineTokens {
        return .{ ._startLineNumber = startLineNumber, ._tokens = tokens };
    }

    pub fn deinit(self: *ContiguousMultilineTokens) void {
        for (self._tokens.items) |*entry| deinitEntry(entry);
        self._tokens.deinit();
    }

    fn deinitEntry(entry: *?ArrayList(TokenPacked)) void {
        if (entry.*) |*tokens| {
            tokens.deinit();
            entry.* = null;
        }
    }

    pub fn deserialize(buff: *Io.Reader, result: *ArrayList(ContiguousMultilineTokens)) !void {
        const allocator = result.allocator;
        const startLineNumber = try buff.takeInt(u32, .big);
        const count = try buff.takeInt(u32, .big);

        var multilineTokens = ArrayList(?ArrayList(TokenPacked)).init(allocator);
        errdefer {
            for (multilineTokens.items) |*entry| deinitEntry(entry);
            multilineTokens.deinit();
        }
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const byteCount = try buff.takeInt(u32, .big);
            const tokensCount: usize = byteCount / @sizeOf(TokenPacked);
            var tokens = ArrayList(TokenPacked).init(allocator);
            errdefer tokens.deinit();
            var j: usize = 0;
            while (j < tokensCount) : (j += 1) {
                // Upstream copies the `Uint32Array` bytes verbatim, so the
                // token payload uses the host endianness (headers stay BE).
                const offset = try buff.takeInt(u32, native_endian);
                const metadata = try buff.takeInt(u32, native_endian);
                try tokens.append(LineTokens.initTokenPacked(offset, @bitCast(metadata)));
            }
            try multilineTokens.append(tokens);
        }
        try result.append(ContiguousMultilineTokens.init(startLineNumber, multilineTokens));
    }

    pub fn getStartLineNumber(self: *const ContiguousMultilineTokens) usize {
        return self._startLineNumber;
    }

    pub fn getEndLineNumber(self: *const ContiguousMultilineTokens) usize {
        if (self._tokens.items.len == 0) return self._startLineNumber -| 1;
        return self._startLineNumber + self._tokens.items.len - 1;
    }

    pub fn getLineRange(self: *const ContiguousMultilineTokens) LineRange {
        return LineRange.init(self._startLineNumber, self._startLineNumber + self._tokens.items.len);
    }

    pub fn getLineTokens(self: *const ContiguousMultilineTokens, lineNumber: usize) ?[]TokenPacked {
        if (lineNumber < self._startLineNumber) return null;
        const index = lineNumber - self._startLineNumber;
        if (index >= self._tokens.items.len) return null;
        if (self._tokens.items[index]) |lineTokens| return lineTokens.items;
        return null;
    }

    pub fn appendLineTokens(self: *ContiguousMultilineTokens, lineTokens: []const TokenPacked) !void {
        const allocator = self._tokens.allocator;
        var owned = ArrayList(TokenPacked).fromOwnedSlice(allocator, try allocator.dupe(TokenPacked, lineTokens));
        errdefer owned.deinit();
        try self._tokens.append(owned);
    }

    pub fn serializeSize(self: *const ContiguousMultilineTokens) !usize {
        var result: usize = 8;
        for (self._tokens.items) |entry| {
            const lineTokens = entry orelse return error.NotSupported;
            result += 4 + lineTokens.items.len * @sizeOf(TokenPacked);
        }
        return result;
    }

    pub fn serialize(self: *const ContiguousMultilineTokens, destination: *Io.Writer) !void {
        try destination.writeInt(u32, @intCast(self._startLineNumber), .big);
        try destination.writeInt(u32, @intCast(self._tokens.items.len), .big);
        for (self._tokens.items) |entry| {
            const lineTokens = entry orelse return error.NotSupported;
            try destination.writeInt(u32, @intCast(lineTokens.items.len * @sizeOf(TokenPacked)), .big);
            for (lineTokens.items) |token| {
                // See `deserialize`: upstream serializes raw `Uint32Array`
                // bytes, which are host-endian.
                try destination.writeInt(u32, token.endOffset, native_endian);
                try destination.writeInt(u32, @bitCast(token.metadata), native_endian);
            }
        }
    }

    pub fn applyEdit(self: *ContiguousMultilineTokens, range: Range, text: []const u8) !void {
        const res = countEOL(text);
        try self._acceptDeleteRange(range);
        try self._acceptInsertText(Position.init(range.startLineNumber, range.startColumn), res.eolCount, res.firstLineLength);
    }

    fn _acceptDeleteRange(self: *ContiguousMultilineTokens, range: Range) !void {
        if (range.startLineNumber == range.endLineNumber and range.startColumn == range.endColumn) return;

        const start = self._startLineNumber;
        const first_rel: isize = @as(isize, @intCast(range.startLineNumber)) - @as(isize, @intCast(start));
        const last_rel: isize = @as(isize, @intCast(range.endLineNumber)) - @as(isize, @intCast(start));
        const count: isize = @intCast(self._tokens.items.len);

        if (last_rel < 0) {
            const deletedLinesCount = last_rel - first_rel;
            self._startLineNumber = @intCast(@as(isize, @intCast(self._startLineNumber)) - deletedLinesCount);
            return;
        }

        if (first_rel >= count) return;

        if (first_rel < 0 and last_rel >= count) {
            for (self._tokens.items) |*entry| deinitEntry(entry);
            self._startLineNumber = 0;
            self._tokens.clearRetainingCapacity();
            return;
        }

        if (first_rel == last_rel) {
            const index: usize = @intCast(first_rel);
            try ContiguousTokensEditing.delete(&self._tokens.items[index], range.startColumn - 1, range.endColumn - 1);
            return;
        }

        if (first_rel >= 0) {
            const first: usize = @intCast(first_rel);
            try ContiguousTokensEditing.deleteEnding(&self._tokens.items[first], range.startColumn - 1);

            if (last_rel < count) {
                const last: usize = @intCast(last_rel);
                try ContiguousTokensEditing.deleteBeginning(&self._tokens.items[last], range.endColumn - 1);
                try ContiguousTokensEditing.append(&self._tokens.items[first], &self._tokens.items[last]);
                // The last line is merged into the first line.
                var i = first + 1;
                while (i <= last) : (i += 1) deinitEntry(&self._tokens.items[i]);
                try self._tokens.replaceRange(first + 1, last - first, &[_]?ArrayList(TokenPacked){});
            } else {
                var null_item: ?ArrayList(TokenPacked) = null;
                try ContiguousTokensEditing.append(&self._tokens.items[first], &null_item);
                var i = first + 1;
                while (i < self._tokens.items.len) : (i += 1) deinitEntry(&self._tokens.items[i]);
                try self._tokens.resize(first + 1);
            }
        } else {
            // The first line does not survive.
            const deletedBefore: usize = @intCast(-first_rel);
            self._startLineNumber -= deletedBefore;
            const last: usize = @intCast(last_rel);
            try ContiguousTokensEditing.deleteBeginning(&self._tokens.items[last], range.endColumn - 1);
            var i: usize = 0;
            while (i < last) : (i += 1) deinitEntry(&self._tokens.items[i]);
            try self._tokens.replaceRange(0, last, &[_]?ArrayList(TokenPacked){});
        }
    }

    fn _acceptInsertText(self: *ContiguousMultilineTokens, position: Position, eolCount: usize, firstLineLength: usize) !void {
        if (eolCount == 0 and firstLineLength == 0) return;

        if (position.lineNumber < self._startLineNumber) {
            self._startLineNumber += eolCount;
            return;
        }

        const index = position.lineNumber - self._startLineNumber;
        if (index >= self._tokens.items.len) return;

        if (eolCount == 0) {
            ContiguousTokensEditing.insert(&self._tokens.items[index], position.column - 1, firstLineLength);
            return;
        }

        try ContiguousTokensEditing.deleteEnding(&self._tokens.items[index], position.column - 1);
        ContiguousTokensEditing.insert(&self._tokens.items[index], position.column - 1, firstLineLength);
        // Upstream calls `_insertLines(position.lineNumber, eolCount)`; its
        // `arrayInsert` appends when the index is past the end, so clamp to
        // the list length here.
        const insert_index = @min(position.lineNumber, self._tokens.items.len);
        var i: usize = 0;
        while (i < eolCount) : (i += 1) {
            try self._tokens.insert(insert_index + i, @as(?ArrayList(TokenPacked), null));
        }
    }
};
