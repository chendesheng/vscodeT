const std = @import("std");
const io = std.io;
const ArrayList = std.array_list.Managed;
const Range = @import("../basics/range.zig").Range;
const countEOL = @import("../basics/eolCounter.zig").countEOL;
const TextModel = @import("../textModel/textModel.zig").TextModel;
const TokenMetadata = @import("../encodedTokenAttributes.zig").TokenMetadata;
const RateLimiter = @import("common.zig").RateLimiter;
const Position = @import("../basics/position.zig").Position;

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
        return .{
            ._startLineNumber = startLineNumber,
            ._tokens = tokens,
            ._endLineNumber = tokens.addStartLineNumber(startLineNumber),
        };
    }

    pub fn deinit(self: *SparseMultilineTokens) void {
        self._tokens.deinit();
    }

    pub fn toString(self: *SparseMultilineTokens) !ArrayList(u8) {
        return try self._tokens.toString(self._startLineNumber);
    }

    fn _updateEndLineNumber(self: *SparseMultilineTokens) void {
        self._endLineNumber = self._tokens.addStartLineNumber(self._startLineNumber);
    }

    pub fn isEmpty(self: *SparseMultilineTokens) bool {
        return self._tokens.isEmpty();
    }

    pub fn getLineTokens(self: *SparseMultilineTokens, lineNumber: usize) ?SparseLineTokens {
        if (self._startLineNumber <= lineNumber and lineNumber <= self._endLineNumber) {
            return self._tokens.getLineTokens(lineNumber - self._startLineNumber);
        }
        return null;
    }

    pub fn getRange(self: *SparseMultilineTokens) ?Range {
        const deltaRange = self._tokens.getRange();
        if (!deltaRange) {
            return deltaRange;
        }
        return Range.init(
            self._startLineNumber + deltaRange.startLineNumber,
            deltaRange.startColumn,
            self._startLineNumber + deltaRange.endLineNumber,
            deltaRange.endColumn,
        );
    }

    pub fn removeTokens(self: *SparseMultilineTokens, range: Range) void {
        const startLineIndex = range.startLineNumber - self._startLineNumber;
        const endLineIndex = range.endLineNumber - self._startLineNumber;

        self._startLineNumber += self._tokens.removeTokens(startLineIndex, range.startColumn - 1, endLineIndex, range.endColumn - 1);
        self._updateEndLineNumber();
    }

    pub fn split(self: *SparseMultilineTokens, range: Range) [2]SparseMultilineTokens {
        // split tokens to two:
        // a) all the tokens before `range`
        // b) all the tokens after `range`
        const startLineIndex = range.startLineNumber - self._startLineNumber;
        const endLineIndex = range.endLineNumber - self._startLineNumber;

        const result = self._tokens.split(startLineIndex, range.startColumn - 1, endLineIndex, range.endColumn - 1);
        const a = result.a;
        const b = result.b;
        const bDeltaLine = result.destFirstDeltaLine;
        return [_]SparseMultilineTokens{
            SparseMultilineTokens.init(self._startLineNumber, a),
            SparseMultilineTokens.init(self._startLineNumber + bDeltaLine, b),
        };
    }

    pub fn applyEdit(self: *SparseMultilineTokens, range: Range, text: []const u8) void {
        const result = countEOL(text);
        const eolCount = result.eolCount;
        const firstLineLength = result.firstLineLength;
        const lastLineLength = result.lastLineLength;
        self.acceptEdit(range, eolCount, firstLineLength, lastLineLength, if (text.len > 0) text.codePointAt(0) else 0);
    }

    pub fn acceptEdit(self: *SparseMultilineTokens, range: Range, eolCount: usize, firstLineLength: usize, lastLineLength: usize, firstCharCode: u21) void {
        self._acceptDeleteRange(range);
        self._acceptInsertText(Position.init(range.startLineNumber, range.startColumn), eolCount, firstLineLength, lastLineLength, firstCharCode);
        self._updateEndLineNumber();
    }

    fn _acceptDeleteRange(self: *SparseMultilineTokens, range: Range) void {
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

        const tokenMaxDeltaLine = self._tokens.addStartLineNumber(0);

        if (firstLineIndex >= tokenMaxDeltaLine + 1) {
            // this deletion occurs entirely after this block, so there is nothing to do
            return;
        }

        if (firstLineIndex < 0 and lastLineIndex >= tokenMaxDeltaLine + 1) {
            // this deletion completely encompasses this block
            self._startLineNumber = 0;
            self._tokens.clear();
            return;
        }

        if (firstLineIndex < 0) {
            const deletedBefore = -firstLineIndex;
            self._startLineNumber -= deletedBefore;

            self._tokens.acceptDeleteRange(range.startColumn - 1, 0, 0, lastLineIndex, range.endColumn - 1);
        } else {
            self._tokens.acceptDeleteRange(0, firstLineIndex, range.startColumn - 1, lastLineIndex, range.endColumn - 1);
        }
    }

    fn _acceptInsertText(self: *SparseMultilineTokens, position: Position, eolCount: usize, firstLineLength: usize, lastLineLength: usize, firstCharCode: u21) void {
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

        const tokenMaxDeltaLine = self._tokens.addStartLineNumber(0);

        if (lineIndex >= tokenMaxDeltaLine + 1) {
            // this insertion occurs after this block, so there is nothing to do
            return;
        }

        self._tokens.acceptInsertText(lineIndex, position.column - 1, eolCount, firstLineLength, lastLineLength, firstCharCode);
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

    pub fn toString(self: *const SparseMultilineTokensStorage, writer: io.AnyWriter, startLineNumber: usize) !void {
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

    pub fn addStartLineNumber(self: *const SparseMultilineTokensStorage, startLineNumber: usize) usize {
        if (self.getMaxDeltaLine()) |maxDeltaLine| {
            return startLineNumber + maxDeltaLine + 1;
        }
        return startLineNumber;
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
        var hasDeletedTokens = false;
        var firstDeltaLine: usize = 0;
        for (tokens) |*token| {
            const tokenDeltaLine = token.deltaLine;
            const tokenStartCharacter = token.startCharacter;
            const tokenEndCharacter = token.endCharacter;

            if ((tokenDeltaLine > startDeltaLine or (tokenDeltaLine == startDeltaLine and tokenEndCharacter >= startChar)) and (tokenDeltaLine < endDeltaLine or (tokenDeltaLine == endDeltaLine and tokenStartCharacter <= endChar))) {
                hasDeletedTokens = true;
            } else {
                if (newTokenCount == 0) {
                    firstDeltaLine = tokenDeltaLine;
                }
                if (hasDeletedTokens) {
                    // must move the token to the left
                    token.deltaLine = tokenDeltaLine - firstDeltaLine;
                    token.startCharacter = tokenStartCharacter;
                    token.endCharacter = tokenEndCharacter;
                }
                newTokenCount += 1;
            }
        }

        return firstDeltaLine;
    }

    pub fn split(self: *SparseMultilineTokensStorage, startDeltaLine: usize, startChar: usize, endDeltaLine: usize, endChar: usize) struct { a: SparseMultilineTokensStorage, b: SparseMultilineTokensStorage, destFirstDeltaLine: usize } {
        const tokens = self._tokens.items;
        const allocator = self._tokens.allocator;
        var aTokens = ArrayList(SparseToken).init(allocator);
        var bTokens = ArrayList(SparseToken).init(allocator);
        var destTokens = &aTokens;
        var destFirstDeltaLine: usize = 0;
        for (tokens) |*token| {
            const tokenDeltaLine = token.deltaLine;
            const tokenStartCharacter = token.startCharacter;
            const tokenEndCharacter = token.endCharacter;
            const tokenMetadata = token.metadata;

            if ((tokenDeltaLine > startDeltaLine or (tokenDeltaLine == startDeltaLine and tokenEndCharacter >= startChar))) {
                if ((tokenDeltaLine < endDeltaLine or (tokenDeltaLine == endDeltaLine and tokenStartCharacter <= endChar))) {
                    // this token is touching the range
                    continue;
                } else {
                    // this token is after the range
                    if (destTokens != bTokens) {
                        // this token is the first token after the range
                        destTokens = &bTokens;
                        destFirstDeltaLine = tokenDeltaLine;
                    }
                }
            }

            destTokens.append(SparseToken{
                .deltaLine = tokenDeltaLine - destFirstDeltaLine,
                .startCharacter = tokenStartCharacter,
                .endCharacter = tokenEndCharacter,
                .metadata = tokenMetadata,
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
                    tokenEndCharacter -= (endCharacter - startCharacter);
                } else {
                    // 1b. The token starts before, the deletion range ends after the token
                    // 1c. The token starts before, the deletion range ends precisely with the token
                    // => the token shrinks its ending to the deletion start
                    tokenEndCharacter = startCharacter;
                }
            } else if (tokenDeltaLine == startDeltaLine and tokenStartCharacter == startCharacter) {
                // 2a, 2b, 2c
                if (tokenDeltaLine == endDeltaLine and tokenEndCharacter > endCharacter) {
                    // 2c. The token starts at the same position, and ends after the deletion range
                    // => the token shrinks by the deletion character count
                    tokenEndCharacter -= (endCharacter - startCharacter);
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
                    tokenDeltaLine = startDeltaLine;
                    tokenStartCharacter = startCharacter;
                    tokenEndCharacter = tokenStartCharacter + (tokenEndCharacter - endCharacter);
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
                tokenDeltaLine -= deletedLineCount;
            } else if (tokenDeltaLine == endDeltaLine and tokenStartCharacter >= endCharacter) {
                // 4. (continued) The token starts after the deletion range, on the last line where a deletion occurs
                if (horizontalShiftForFirstLineTokens and tokenDeltaLine == 0) {
                    tokenStartCharacter += horizontalShiftForFirstLineTokens;
                    tokenEndCharacter += horizontalShiftForFirstLineTokens;
                }
                tokenDeltaLine -= deletedLineCount;
                tokenStartCharacter -= (endCharacter - startCharacter);
                tokenEndCharacter -= (endCharacter - startCharacter);
            } else {
                unreachable;
            }

            token.deltaLine = tokenDeltaLine;
            token.startCharacter = tokenStartCharacter;
            token.endCharacter = tokenEndCharacter;
            newTokenCount += 1;
        }
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
                    tokenEndCharacter += firstLineLength;
                } else {
                    // => cut off the token
                    tokenEndCharacter = character;
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
                    tokenDeltaLine += eolCount;
                    // this token is on the line where the insertion is taking place
                    if (eolCount == 0) {
                        tokenStartCharacter += firstLineLength;
                        tokenEndCharacter += firstLineLength;
                    } else {
                        const tokenLength = tokenEndCharacter - tokenStartCharacter;
                        tokenStartCharacter = lastLineLength + (tokenStartCharacter - character);
                        tokenEndCharacter = tokenStartCharacter + tokenLength;
                    }
                } else {
                    tokenDeltaLine += eolCount;
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

            if (lineNumber > model.getLineCount()) {
                _rateLimiter.runIfNotLimited({}, struct {
                    fn run(_: void) void {
                        std.debug.print("Invalid Semantic Tokens Data From Extension: lineNumber > model.getLineCount()\n", .{});
                    }
                }.run);
            }

            if (self._getEndCharacter(i) > model.getLineLength(lineNumber)) {
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
