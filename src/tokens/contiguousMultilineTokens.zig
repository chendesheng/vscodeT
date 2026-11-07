const std = @import("std");
const Io = std.Io;
const ArrayList = std.array_list.Managed;
const Allocator = std.mem.Allocator;
const Range = @import("../basics/range.zig").Range;
const LineRange = @import("../basics/lineRange.zig").LineRange;
const countEOL = @import("../basics/eolCounter.zig").countEOL;
const Position = @import("../basics/position.zig").Position;
const ContiguousTokensEditing = @import("contiguousTokensEditing.zig").ContiguousTokensEditing;
const TokenPacked = @import("lineTokens.zig").TokenPacked;
const LineTokens = @import("lineTokens.zig").LineTokens;
const usizeAdd = @import("../basics/utils.zig").usizeAdd;

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
            const byteCount: u32 = @bitCast(try buff.takeInt(u32, .big));
            const tokensCount: usize = byteCount / @sizeOf(TokenPacked);
            var tokens = ArrayList(TokenPacked).init(allocator);
            errdefer tokens.deinit();
            var j: usize = 0;
            while (j < tokensCount) : (j += 1) {
                const offset = try buff.takeInt(u32, .big);
                const metadata = try buff.takeInt(u32, .big);
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
        return self._startLineNumber + self._tokens.items.len - 1;
    }

    pub fn getLineRange(self: *const ContiguousMultilineTokens) LineRange {
        return LineRange.init(self._startLineNumber, self._startLineNumber + self._tokens.items.len);
    }

    pub fn getLineTokens(self: *const ContiguousMultilineTokens, lineNumber: usize) ?[]TokenPacked {
        const index = lineNumber - self._startLineNumber;
        if (index >= self._tokens.items.len) return null;
        if (self._tokens.items[index]) |lineTokens| return lineTokens.items;
        return null;
    }

    pub fn appendLineTokens(self: *ContiguousMultilineTokens, lineTokens: []const TokenPacked) !void {
        const allocator = self._tokens.allocator;
        try self._tokens.append(ArrayList(TokenPacked).fromOwnedSlice(allocator, try allocator.dupe(TokenPacked, lineTokens)));
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
                try destination.writeInt(u32, token.endOffset, .big);
                try destination.writeInt(u32, @bitCast(token.metadata), .big);
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
        const insert_index = index + 1;
        var i: usize = 0;
        while (i < eolCount) : (i += 1) {
            try self._tokens.insert(insert_index + i, @as(?ArrayList(TokenPacked), null));
        }
    }
};
