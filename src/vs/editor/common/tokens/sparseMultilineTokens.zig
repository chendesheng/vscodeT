// Port of `src/vs/editor/common/tokens/sparseMultilineTokens.ts`.
//
// Zig adaptation: the storage keeps `SparseToken` structs instead of a flat
// `Uint32Array`, and line numbers are `usize` (upstream's empty piece has
// `endLineNumber === startLineNumber - 1`, which saturates at 0 here).
const std = @import("std");
const Io = std.Io;
const ArrayList = std.array_list.Managed;
const Range = @import("../core/range.zig").Range;
const countEOL = @import("../core/misc/eolCounter.zig").countEOL;
const TextModel = @import("../model/textModel.zig").TextModel;
const TokenMetadata = @import("../encodedTokenAttributes.zig").TokenMetadata;
const RateLimiter = @import("./common.zig").RateLimiter;
const Position = @import("../core/position.zig").Position;

fn subtractCharacterDelta(value: u32, startCharacter: usize, endCharacter: usize) u32 {
    const delta: isize = @as(isize, @intCast(endCharacter)) - @as(isize, @intCast(startCharacter));
    return @intCast(@as(isize, @intCast(value)) - delta);
}

fn firstCodepoint(text: []const u8) u21 {
    if (text.len == 0) return 0;
    const len = std.unicode.utf8ByteSequenceLength(text[0]) catch return text[0];
    if (len > text.len) return text[0];
    return std.unicode.utf8Decode(text[0..len]) catch text[0];
}

// Represents sparse tokens over a contiguous range of lines.
pub const SparseMultilineTokens = struct {
    _startLineNumber: usize,
    _endLineNumber: usize,
    _tokens: SparseMultilineTokensStorage,

    pub fn create(startLineNumber: usize, tokens: ArrayList(SparseToken)) SparseMultilineTokens {
        return SparseMultilineTokens.init(startLineNumber, SparseMultilineTokensStorage.init(tokens));
    }

    // (Inclusive) start line number for these tokens.
    pub fn getStartLineNumber(self: *const SparseMultilineTokens) usize {
        return self._startLineNumber;
    }

    // (Inclusive) end line number for these tokens.
    pub fn getEndLineNumber(self: *const SparseMultilineTokens) usize {
        return self._endLineNumber;
    }

    pub fn init(startLineNumber: usize, tokens: SparseMultilineTokensStorage) SparseMultilineTokens {
        var self = SparseMultilineTokens{
            ._startLineNumber = startLineNumber,
            ._endLineNumber = startLineNumber -| 1,
            ._tokens = tokens,
        };
        self._updateEndLineNumber();
        return self;
    }

    pub fn deinit(self: *SparseMultilineTokens) void {
        self._tokens.deinit();
    }

    pub fn toString(self: *SparseMultilineTokens) !ArrayList(u8) {
        var out: Io.Writer.Allocating = .init(self._tokens._tokens.allocator);
        errdefer out.deinit();
        try self._tokens.toString(&out.writer, self._startLineNumber);
        return ArrayList(u8).fromOwnedSlice(self._tokens._tokens.allocator, try out.toOwnedSlice());
    }

    fn _updateEndLineNumber(self: *SparseMultilineTokens) void {
        self._endLineNumber = if (self._tokens.getMaxDeltaLine()) |maxDeltaLine|
            self._startLineNumber + maxDeltaLine
        else
            self._startLineNumber -| 1;
    }

    pub fn isEmpty(self: *SparseMultilineTokens) bool {
        return self._tokens.isEmpty();
    }

    pub fn getLineTokens(self: *SparseMultilineTokens, lineNumber: usize) ?SparseLineTokens {
        if (self.isEmpty()) return null;
        if (self._startLineNumber <= lineNumber and lineNumber <= self._endLineNumber) {
            return self._tokens.getLineTokens(lineNumber - self._startLineNumber);
        }
        return null;
    }

    pub fn getRange(self: *SparseMultilineTokens) ?Range {
        const deltaRange = self._tokens.getRange() orelse return null;
        return Range.init(
            self._startLineNumber + deltaRange.startLineNumber,
            deltaRange.startColumn,
            self._startLineNumber + deltaRange.endLineNumber,
            deltaRange.endColumn,
        );
    }

    const ClampedRange = struct {
        startLineIndex: usize,
        startCharacter: usize,
        endLineIndex: usize,
        endCharacter: usize,
    };

    fn clampRange(self: *const SparseMultilineTokens, range: Range) ?ClampedRange {
        if (range.endLineNumber < self._startLineNumber or range.startLineNumber > self._endLineNumber) {
            return null;
        }
        // Only a range starting on an earlier line makes the character clamp
        // irrelevant. A range starting on the piece's first line keeps its
        // column: upstream passes `range.startColumn - 1` even when it is
        // greater than 0, and tokens ending before it must survive.
        const startsBefore = range.startLineNumber < self._startLineNumber;
        const endsAfter = range.endLineNumber > self._endLineNumber;
        return .{
            .startLineIndex = if (startsBefore) 0 else range.startLineNumber - self._startLineNumber,
            .startCharacter = if (startsBefore) 0 else range.startColumn - 1,
            .endLineIndex = if (endsAfter) self._endLineNumber - self._startLineNumber else range.endLineNumber - self._startLineNumber,
            .endCharacter = if (endsAfter) std.math.maxInt(usize) else range.endColumn - 1,
        };
    }

    pub fn removeTokens(self: *SparseMultilineTokens, range: Range) void {
        const clamped = self.clampRange(range) orelse return;
        self._startLineNumber += self._tokens.removeTokens(clamped.startLineIndex, clamped.startCharacter, clamped.endLineIndex, clamped.endCharacter);
        self._updateEndLineNumber();
    }

    pub fn split(self: *SparseMultilineTokens, range: Range) ![2]SparseMultilineTokens {
        // split tokens to two:
        // a) all the tokens before `range`
        // b) all the tokens after `range`
        const clamped = self.clampRange(range) orelse return error.NoIntersection;

        const result = try self._tokens.split(clamped.startLineIndex, clamped.startCharacter, clamped.endLineIndex, clamped.endCharacter);
        return [_]SparseMultilineTokens{
            SparseMultilineTokens.init(self._startLineNumber, result.a),
            SparseMultilineTokens.init(self._startLineNumber + result.destFirstDeltaLine, result.b),
        };
    }

    pub fn applyEdit(self: *SparseMultilineTokens, range: Range, text: []const u8) void {
        const result = countEOL(text);
        const eolCount = result.eolCount;
        const firstLineLength = result.firstLineLength;
        const lastLineLength = result.lastLineLength;
        self.acceptEdit(range, eolCount, firstLineLength, lastLineLength, firstCodepoint(text));
    }

    pub fn acceptEdit(self: *SparseMultilineTokens, range: Range, eolCount: usize, firstLineLength: usize, lastLineLength: usize, firstCharCode: u21) void {
        self._acceptDeleteRange(range);
        self._acceptInsertText(Position.init(range.startLineNumber, range.startColumn), eolCount, firstLineLength, lastLineLength, firstCharCode);
        self._updateEndLineNumber();
    }

    fn _acceptDeleteRange(self: *SparseMultilineTokens, range: Range) void {
        if (range.startLineNumber == range.endLineNumber and range.startColumn == range.endColumn) return;

        const firstLineIndex: isize = @as(isize, @intCast(range.startLineNumber)) - @as(isize, @intCast(self._startLineNumber));
        const lastLineIndex: isize = @as(isize, @intCast(range.endLineNumber)) - @as(isize, @intCast(self._startLineNumber));

        if (lastLineIndex < 0) {
            // This deletion occurs entirely before this block.
            const deletedLinesCount = lastLineIndex - firstLineIndex;
            self._startLineNumber = @intCast(@as(isize, @intCast(self._startLineNumber)) - deletedLinesCount);
            return;
        }

        const tokenMaxDeltaLine: isize = if (self._tokens.getMaxDeltaLine()) |maxDeltaLine| @intCast(maxDeltaLine) else -1;

        if (firstLineIndex >= tokenMaxDeltaLine + 1) return;

        if (firstLineIndex < 0 and lastLineIndex >= tokenMaxDeltaLine + 1) {
            self._startLineNumber = 0;
            self._tokens.clear();
            return;
        }

        if (firstLineIndex < 0) {
            const deletedBefore: usize = @intCast(-firstLineIndex);
            self._startLineNumber -= deletedBefore;
            self._tokens.acceptDeleteRange(range.startColumn - 1, 0, 0, @intCast(lastLineIndex), range.endColumn - 1);
        } else {
            self._tokens.acceptDeleteRange(0, @intCast(firstLineIndex), range.startColumn - 1, @intCast(lastLineIndex), range.endColumn - 1);
        }
    }

    fn _acceptInsertText(self: *SparseMultilineTokens, position: Position, eolCount: usize, firstLineLength: usize, lastLineLength: usize, firstCharCode: u21) void {
        if (eolCount == 0 and firstLineLength == 0) return;

        const lineIndex: isize = @as(isize, @intCast(position.lineNumber)) - @as(isize, @intCast(self._startLineNumber));
        if (lineIndex < 0) {
            self._startLineNumber += eolCount;
            return;
        }

        const tokenMaxDeltaLine: isize = if (self._tokens.getMaxDeltaLine()) |maxDeltaLine| @intCast(maxDeltaLine) else -1;
        if (lineIndex >= tokenMaxDeltaLine + 1) return;

        self._tokens.acceptInsertText(@intCast(lineIndex), position.column - 1, eolCount, firstLineLength, lastLineLength, firstCharCode);
    }

    pub fn reportIfInvalid(self: *const SparseMultilineTokens, model: *const TextModel) void {
        self._tokens.reportIfInvalid(model, self._startLineNumber);
    }
};

pub const SparseToken = packed struct {
    deltaLine: u32,
    startCharacter: u32,
    endCharacter: u32,
    metadata: TokenMetadata,

    pub fn init(deltaLine: u32, startCharacter: u32, endCharacter: u32, metadata: TokenMetadata) SparseToken {
        return .{
            .deltaLine = deltaLine,
            .startCharacter = startCharacter,
            .endCharacter = endCharacter,
            .metadata = metadata,
        };
    }
};

pub const SparseMultilineTokensStorage = struct {
    // The encoding of tokens is:
    //  4*i    deltaLine (from `startLineNumber`)
    //  4*i+1  startCharacter (from the line start)
    //  4*i+2  endCharacter (from the line start)
    //  4*i+3  metadata
    _tokens: ArrayList(SparseToken),

    pub fn init(tokens: ArrayList(SparseToken)) SparseMultilineTokensStorage {
        return .{ ._tokens = tokens };
    }

    pub fn deinit(self: *SparseMultilineTokensStorage) void {
        self._tokens.deinit();
    }

    pub fn toString(self: *const SparseMultilineTokensStorage, writer: *Io.Writer, startLineNumber: usize) !void {
        try writer.writeAll("[");
        for (0..self._tokens.len) |i| {
            try writer.print("({d},{d}-{d})", .{
                self._getDeltaLine(i) + startLineNumber,
                self._getStartCharacter(i),
                self._getEndCharacter(i),
            });
            if (i < self._tokens.len - 1) {
                try writer.writeAll(",");
            }
        }
        try writer.writeAll("]");
    }

    pub fn getMaxDeltaLine(self: *const SparseMultilineTokensStorage) ?usize {
        const tokenCount = self._getTokenCount();
        if (tokenCount == 0) {
            return null;
        }
        return self._getDeltaLine(tokenCount - 1);
    }

    pub fn getRange(self: *const SparseMultilineTokensStorage) ?Range {
        const tokenCount = self._getTokenCount();
        if (tokenCount == 0) {
            return null;
        }
        const startChar = self._getStartCharacter(0);
        const maxDeltaLine = self._getDeltaLine(tokenCount - 1);
        const endChar = self._getEndCharacter(tokenCount - 1);
        return Range.init(
            0,
            startChar + 1,
            maxDeltaLine,
            endChar + 1,
        );
    }

    fn _getTokenCount(self: *const SparseMultilineTokensStorage) usize {
        return self._tokens.items.len;
    }

    fn _getDeltaLine(self: *const SparseMultilineTokensStorage, tokenIndex: usize) usize {
        return self._tokens.items[tokenIndex].deltaLine;
    }

    fn _getStartCharacter(self: *const SparseMultilineTokensStorage, tokenIndex: usize) usize {
        return self._tokens.items[tokenIndex].startCharacter;
    }

    fn _getEndCharacter(self: *const SparseMultilineTokensStorage, tokenIndex: usize) usize {
        return self._tokens.items[tokenIndex].endCharacter;
    }

    pub fn isEmpty(self: *const SparseMultilineTokensStorage) bool {
        return self._getTokenCount() == 0;
    }

    pub fn getLineTokens(self: *const SparseMultilineTokensStorage, deltaLine: usize) ?SparseLineTokens {
        if (self._getTokenCount() == 0) return null;
        var low: usize = 0;
        var high = self._getTokenCount() - 1;

        while (low < high) {
            const mid = low + @divFloor(high - low, 2);
            const midDeltaLine = self._getDeltaLine(mid);

            if (midDeltaLine < deltaLine) {
                low = mid + 1;
            } else if (midDeltaLine > deltaLine) {
                high = mid - 1;
            } else {
                var min = mid;
                while (min > low and self._getDeltaLine(min - 1) == deltaLine) {
                    min -= 1;
                }
                var max = mid;
                while (max < high and self._getDeltaLine(max + 1) == deltaLine) {
                    max += 1;
                }
                return SparseLineTokens.init(self._tokens.items[min .. max + 1]);
            }
        }

        if (self._getDeltaLine(low) == deltaLine) {
            return SparseLineTokens.init(self._tokens.items[low .. low + 1]);
        }

        return null;
    }

    pub fn clear(self: *SparseMultilineTokensStorage) void {
        self._tokens.clearRetainingCapacity();
    }

    pub fn removeTokens(self: *SparseMultilineTokensStorage, startDeltaLine: usize, startChar: usize, endDeltaLine: usize, endChar: usize) usize {
        const tokens = self._tokens.items;
        var newTokenCount: usize = 0;
        var firstDeltaLine: usize = 0;
        for (tokens) |*token| {
            const tokenDeltaLine = token.deltaLine;
            const tokenStartCharacter = token.startCharacter;
            const tokenEndCharacter = token.endCharacter;

            if ((tokenDeltaLine > startDeltaLine or (tokenDeltaLine == startDeltaLine and tokenEndCharacter >= startChar)) and (tokenDeltaLine < endDeltaLine or (tokenDeltaLine == endDeltaLine and tokenStartCharacter <= endChar))) {
                // This token is deleted.
                continue;
            }

            if (newTokenCount == 0) {
                firstDeltaLine = tokenDeltaLine;
            }
            // Compact kept tokens to the left, like upstream's
            // `destOffset = 4 * newTokenCount` write.
            tokens[newTokenCount] = .{
                .deltaLine = @intCast(tokenDeltaLine - firstDeltaLine),
                .startCharacter = tokenStartCharacter,
                .endCharacter = tokenEndCharacter,
                .metadata = token.metadata,
            };
            newTokenCount += 1;
        }

        self._tokens.items.len = newTokenCount;
        return firstDeltaLine;
    }

    pub fn split(self: *SparseMultilineTokensStorage, startDeltaLine: usize, startChar: usize, endDeltaLine: usize, endChar: usize) !struct { a: SparseMultilineTokensStorage, b: SparseMultilineTokensStorage, destFirstDeltaLine: usize } {
        const tokens = self._tokens.items;
        const allocator = self._tokens.allocator;
        var aTokens = ArrayList(SparseToken).init(allocator);
        errdefer aTokens.deinit();
        var bTokens = ArrayList(SparseToken).init(allocator);
        errdefer bTokens.deinit();
        var inB = false;
        var destFirstDeltaLine: usize = 0;

        for (tokens) |token| {
            if (token.deltaLine > startDeltaLine or (token.deltaLine == startDeltaLine and token.endCharacter >= startChar)) {
                if (token.deltaLine < endDeltaLine or (token.deltaLine == endDeltaLine and token.startCharacter <= endChar)) {
                    // This token touches the range.
                    continue;
                }
                if (!inB) {
                    inB = true;
                    destFirstDeltaLine = token.deltaLine;
                }
            }

            const dest = if (inB) &bTokens else &aTokens;
            try dest.append(.{
                .deltaLine = @intCast(token.deltaLine - destFirstDeltaLine),
                .startCharacter = token.startCharacter,
                .endCharacter = token.endCharacter,
                .metadata = token.metadata,
            });
        }

        return .{
            .a = SparseMultilineTokensStorage.init(aTokens),
            .b = SparseMultilineTokensStorage.init(bTokens),
            .destFirstDeltaLine = destFirstDeltaLine,
        };
    }

    pub fn acceptDeleteRange(self: *SparseMultilineTokensStorage, horizontalShiftForFirstLineTokens: usize, startDeltaLine: usize, startCharacter: usize, endDeltaLine: usize, endCharacter: usize) void {
        // This is a bit complex, here are the cases I used to think about this:
        //
        // 1. The token starts before the deletion range
        // 1a. The token is completely before the deletion range
        //               -----------
        //                          xxxxxxxxxxx
        // 1b. The token starts before, the deletion range ends after the token
        //               -----------
        //                      xxxxxxxxxxx
        // 1c. The token starts before, the deletion range ends precisely with the token
        //               ---------------
        //                      xxxxxxxx
        // 1d. The token starts before, the deletion range is inside the token
        //               ---------------
        //                    xxxxx
        //
        // 2. The token starts at the same position with the deletion range
        // 2a. The token starts at the same position, and ends inside the deletion range
        //               -------
        //               xxxxxxxxxxx
        // 2b. The token starts at the same position, and ends at the same position as the deletion range
        //               ----------
        //               xxxxxxxxxx
        // 2c. The token starts at the same position, and ends after the deletion range
        //               -------------
        //               xxxxxxx
        //
        // 3. The token starts inside the deletion range
        // 3a. The token is inside the deletion range
        //                -------
        //             xxxxxxxxxxxxx
        // 3b. The token starts inside the deletion range, and ends at the same position as the deletion range
        //                ----------
        //             xxxxxxxxxxxxx
        // 3c. The token starts inside the deletion range, and ends after the deletion range
        //                ------------
        //             xxxxxxxxxxx
        //
        // 4. The token starts after the deletion range
        //                  -----------
        //          xxxxxxxx
        //
        const tokens = self._tokens.items;
        const tokenCount = tokens.len;
        const deletedLineCount = (endDeltaLine - startDeltaLine);
        var newTokenCount: usize = 0;
        var hasDeletedTokens = false;
        for (tokens) |*token| {
            var tokenDeltaLine = token.deltaLine;
            var tokenStartCharacter = token.startCharacter;
            var tokenEndCharacter = token.endCharacter;

            if (tokenDeltaLine < startDeltaLine or (tokenDeltaLine == startDeltaLine and tokenEndCharacter <= startCharacter)) {
                // 1a. The token is completely before the deletion range
                // => nothing to do
                newTokenCount += 1;
                continue;
            } else if (tokenDeltaLine == startDeltaLine and tokenStartCharacter < startCharacter) {
                // 1b, 1c, 1d
                // => the token survives, but it needs to shrink
                if (tokenDeltaLine == endDeltaLine and tokenEndCharacter > endCharacter) {
                    // 1d. The token starts before, the deletion range is inside the token
                    // => the token shrinks by the deletion character count
                    tokenEndCharacter = subtractCharacterDelta(tokenEndCharacter, startCharacter, endCharacter);
                } else {
                    // 1b. The token starts before, the deletion range ends after the token
                    // 1c. The token starts before, the deletion range ends precisely with the token
                    // => the token shrinks its ending to the deletion start
                    tokenEndCharacter = @intCast(startCharacter);
                }
            } else if (tokenDeltaLine == startDeltaLine and tokenStartCharacter == startCharacter) {
                // 2a, 2b, 2c
                if (tokenDeltaLine == endDeltaLine and tokenEndCharacter > endCharacter) {
                    // 2c. The token starts at the same position, and ends after the deletion range
                    // => the token shrinks by the deletion character count
                    tokenEndCharacter = subtractCharacterDelta(tokenEndCharacter, startCharacter, endCharacter);
                } else {
                    // 2a. The token starts at the same position, and ends inside the deletion range
                    // 2b. The token starts at the same position, and ends at the same position as the deletion range
                    // => the token is deleted
                    hasDeletedTokens = true;
                    continue;
                }
            } else if (tokenDeltaLine < endDeltaLine or (tokenDeltaLine == endDeltaLine and tokenStartCharacter < endCharacter)) {
                // 3a, 3b, 3c
                if (tokenDeltaLine == endDeltaLine and tokenEndCharacter > endCharacter) {
                    // 3c. The token starts inside the deletion range, and ends after the deletion range
                    // => the token moves to continue right after the deletion
                    tokenDeltaLine = @intCast(startDeltaLine);
                    tokenStartCharacter = @intCast(startCharacter);
                    tokenEndCharacter = tokenStartCharacter + @as(u32, @intCast(tokenEndCharacter - endCharacter));
                } else {
                    // 3a. The token is inside the deletion range
                    // 3b. The token starts inside the deletion range, and ends at the same position as the deletion range
                    // => the token is deleted
                    hasDeletedTokens = true;
                    continue;
                }
            } else if (tokenDeltaLine > endDeltaLine) {
                // 4. (partial) The token starts after the deletion range, on a line below...
                if (deletedLineCount == 0 and !hasDeletedTokens) {
                    // early stop, there is no need to walk all the tokens and do nothing...
                    newTokenCount = tokenCount;
                    break;
                }
                tokenDeltaLine -= @intCast(deletedLineCount);
            } else if (tokenDeltaLine == endDeltaLine and tokenStartCharacter >= endCharacter) {
                // 4. (continued) The token starts after the deletion range, on the last line where a deletion occurs
                if (horizontalShiftForFirstLineTokens != 0 and tokenDeltaLine == 0) {
                    tokenStartCharacter += @intCast(horizontalShiftForFirstLineTokens);
                    tokenEndCharacter += @intCast(horizontalShiftForFirstLineTokens);
                }
                tokenDeltaLine -= @intCast(deletedLineCount);
                tokenStartCharacter = subtractCharacterDelta(tokenStartCharacter, startCharacter, endCharacter);
                tokenEndCharacter = subtractCharacterDelta(tokenEndCharacter, startCharacter, endCharacter);
            } else {
                unreachable;
            }

            tokens[newTokenCount] = .{
                .deltaLine = tokenDeltaLine,
                .startCharacter = tokenStartCharacter,
                .endCharacter = tokenEndCharacter,
                .metadata = token.metadata,
            };
            newTokenCount += 1;
        }

        self._tokens.items.len = newTokenCount;
    }

    pub fn acceptInsertText(self: *SparseMultilineTokensStorage, deltaLine: usize, character: usize, eolCount: usize, firstLineLength: usize, lastLineLength: usize, firstCharCode: usize) void {
        // Here are the cases I used to think about this:
        //
        // 1. The token is completely before the insertion point
        //            -----------   |
        // 2. The token ends precisely at the insertion point
        //            -----------|
        // 3. The token contains the insertion point
        //            -----|------
        // 4. The token starts precisely at the insertion point
        //            |-----------
        // 5. The token is completely after the insertion point
        //            |   -----------
        //
        const isInsertingPreciselyOneWordCharacter = (eolCount == 0 and
            firstLineLength == 1 and ((firstCharCode >= '0' and firstCharCode <= '9') or (firstCharCode >= 'A' and firstCharCode <= 'Z') or (firstCharCode >= 'a' and firstCharCode <= 'z')));
        const tokens = self._tokens.items;
        for (tokens) |*token| {
            var tokenDeltaLine = token.deltaLine;
            var tokenStartCharacter = token.startCharacter;
            var tokenEndCharacter = token.endCharacter;

            if (tokenDeltaLine < deltaLine or (tokenDeltaLine == deltaLine and tokenEndCharacter < character)) {
                // 1. The token is completely before the insertion point
                // => nothing to do
                continue;
            } else if (tokenDeltaLine == deltaLine and tokenEndCharacter == character) {
                // 2. The token ends precisely at the insertion point
                // => expand the end character only if inserting precisely one character that is a word character
                if (isInsertingPreciselyOneWordCharacter) {
                    tokenEndCharacter += 1;
                } else {
                    continue;
                }
            } else if (tokenDeltaLine == deltaLine and tokenStartCharacter < character and character < tokenEndCharacter) {
                // 3. The token contains the insertion point
                if (eolCount == 0) {
                    // => just expand the end character
                    tokenEndCharacter += @intCast(firstLineLength);
                } else {
                    // => cut off the token
                    tokenEndCharacter = @intCast(character);
                }
            } else {
                // 4. or 5.
                if (tokenDeltaLine == deltaLine and tokenStartCharacter == character) {
                    // 4. The token starts precisely at the insertion point
                    // => grow the token (by keeping its start constant) only if inserting precisely one character that is a word character
                    // => otherwise behave as in case 5.
                    if (isInsertingPreciselyOneWordCharacter) {
                        continue;
                    }
                }
                // => the token must move and keep its size constant
                if (tokenDeltaLine == deltaLine) {
                    tokenDeltaLine += @intCast(eolCount);
                    // this token is on the line where the insertion is taking place
                    if (eolCount == 0) {
                        tokenStartCharacter += @intCast(firstLineLength);
                        tokenEndCharacter += @intCast(firstLineLength);
                    } else {
                        const tokenLength = tokenEndCharacter - tokenStartCharacter;
                        tokenStartCharacter = @as(u32, @intCast(lastLineLength)) + (tokenStartCharacter - @as(u32, @intCast(character)));
                        tokenEndCharacter = tokenStartCharacter + tokenLength;
                    }
                } else {
                    tokenDeltaLine += @intCast(eolCount);
                }
            }

            token.deltaLine = tokenDeltaLine;
            token.startCharacter = tokenStartCharacter;
            token.endCharacter = tokenEndCharacter;
        }
    }

    var _rateLimiter = RateLimiter.init(10.0 / 60.0);

    pub fn reportIfInvalid(self: *const SparseMultilineTokensStorage, model: *const TextModel, startLineNumber: usize) void {
        for (0..self._tokens.items.len) |i| {
            const lineNumber = self._getDeltaLine(i) + startLineNumber;

            if (lineNumber < 1) {
                _rateLimiter.runIfNotLimited({}, struct {
                    fn run(_: void) void {
                        std.debug.print("Invalid Semantic Tokens Data From Extension: lineNumber < 1\n", .{});
                    }
                }.run);
            } else if (lineNumber > model.getLineCount()) {
                _rateLimiter.runIfNotLimited({}, struct {
                    fn run(_: void) void {
                        std.debug.print("Invalid Semantic Tokens Data From Extension: lineNumber > model.getLineCount()\n", .{});
                    }
                }.run);
            } else if (self._getEndCharacter(i) > model.getLineLength(lineNumber)) {
                _rateLimiter.runIfNotLimited({}, struct {
                    fn run(_: void) void {
                        std.debug.print("Invalid Semantic Tokens Data From Extension: end character > model.getLineLength(lineNumber)\n", .{});
                    }
                }.run);
            }
        }
    }
};

// test "SparseMultilineTokensStorage/init" {
//     var tokens = ArrayList(SparseToken).init(std.testing.allocator);
//     defer tokens.deinit();

//     var storage = SparseMultilineTokensStorage.init(tokens);
//     defer storage.deinit();

//     try storage.acceptInsertText(0, 10, 0, 10, 10, 0);

//     try storage.toString(std.io.getStdOut().writer(), 0);
// }

pub const SparseLineTokens = struct {
    _tokens: []SparseToken,

    pub fn init(tokens: []SparseToken) SparseLineTokens {
        return SparseLineTokens{ ._tokens = tokens };
    }

    pub fn getDeltaLine(self: *const SparseLineTokens, tokenIndex: usize) usize {
        return self._tokens[tokenIndex].deltaLine;
    }

    pub fn getCount(self: *const SparseLineTokens) usize {
        return self._tokens.len;
    }

    pub fn getStartCharacter(self: *const SparseLineTokens, tokenIndex: usize) u32 {
        return self._tokens[tokenIndex].startCharacter;
    }

    pub fn getEndCharacter(self: *const SparseLineTokens, tokenIndex: usize) u32 {
        return self._tokens[tokenIndex].endCharacter;
    }

    pub fn getMetadata(self: *const SparseLineTokens, tokenIndex: usize) TokenMetadata {
        return self._tokens[tokenIndex].metadata;
    }
};
