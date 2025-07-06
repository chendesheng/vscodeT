const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const countEOL = @import("eolCounter.zig").countEOL;
const StringEOL = @import("eolCounter.zig").StringEOL;
const strings = @import("strings.zig");
const PB = @import("pieceTreeBase.zig");
const PieceTreeBase = PB.PieceTreeBase;
const PieceTreeSnapshot = PB.PieceTreeSnapshot;
const Model = @import("model.zig");
const replaceEOL = PB.replaceEOL;
const SingleEditOperationIdentifier = Model.SingleEditOperationIdentifier;
const EndOfLinePreference = Model.EndOfLinePreference;
const ValidAnnotatedEditOperation = Model.ValidAnnotatedEditOperation;
const ApplyEditsResult = Model.ApplyEditsResult;
const InternalModelContentChange = Model.InternalModelContentChange;
const Position = @import("position.zig").Position;
const Rg = @import("range.zig");
const Range = Rg.Range;
const StringBuffer = PB.StringBuffer;
const EOL = PB.EOL;
const usizeDiff = PB.usizeDiff;
const usizeAdd = PB.usizeAdd;
const TextChange = @import("textChange.zig").TextChange;

const ValidatedEditOperation = struct {
    sortIndex: i64,
    identifier: ?SingleEditOperationIdentifier,
    range: Range,
    rangeOffset: usize,
    rangeLength: usize,
    text: []const u8,
    eolCount: usize,
    firstLineLength: usize,
    lastLineLength: usize,
    forceMoveMarkers: bool,
    isAutoWhitespaceEdit: bool,
};

const ReverseSingleEditOperation = struct {
    sortIndex: i64,
    identifier: ?SingleEditOperationIdentifier,
    range: Range,
    text: []const u8,
    textChange: TextChange,
};

pub const PieceTreeTextBuffer = struct {
    _pieceTree: PieceTreeBase,
    _mightContainRTL: bool,
    _mightContainUnusualLineTerminators: bool,
    _mightContainNonBasicASCII: bool,
    _BOM: []const u8,

    pub fn init(allocator: std.mem.Allocator, chunks: []const StringBuffer, BOM: []const u8, eol: EOL, containsRTL: bool, containsUnusualLineTerminators: bool, isBasicASCII: bool, eolNormalized: bool) !PieceTreeTextBuffer {
        return PieceTreeTextBuffer{
            ._BOM = BOM,
            ._mightContainNonBasicASCII = !isBasicASCII,
            ._mightContainRTL = containsRTL,
            ._mightContainUnusualLineTerminators = containsUnusualLineTerminators,
            ._pieceTree = try PieceTreeBase.init(allocator, chunks, eol, eolNormalized),
        };
    }

    pub fn deinit(self: *const PieceTreeTextBuffer) void {
        self._pieceTree.deinit();
    }

    pub fn equals(self: *const PieceTreeTextBuffer, other: *const PieceTreeTextBuffer) bool {
        if (!std.mem.eql(self._BOM, other._BOM)) {
            return false;
        }

        if (self.getEOL() != other.getEOL()) {
            return false;
        }

        return self._pieceTree.equal(other._pieceTree);
    }

    pub fn getMightContainRTL(self: *const PieceTreeTextBuffer) bool {
        return self._mightContainRTL;
    }

    pub fn getMightContainUnusualLineTerminators(self: *const PieceTreeTextBuffer) bool {
        return self._mightContainUnusualLineTerminators;
    }

    pub fn resetMightContainUnusualLineTerminators(self: *PieceTreeTextBuffer) void {
        self._mightContainUnusualLineTerminators = false;
    }

    pub fn getMightContainNonBasicASCII(self: *const PieceTreeTextBuffer) bool {
        return self._mightContainNonBasicASCII;
    }

    pub fn getBOM(self: *const PieceTreeTextBuffer) []const u8 {
        return self._BOM;
    }

    pub fn getEOL(self: *const PieceTreeTextBuffer) EOL {
        return self._pieceTree.getEOL();
    }

    pub fn createSnapshot(self: *const PieceTreeTextBuffer, preserveBOM: bool) !PieceTreeSnapshot {
        return try self._pieceTree.createSnapshot(if (preserveBOM) self._BOM else "");
    }

    pub fn getOffsetAt(self: *const PieceTreeTextBuffer, line: usize, column: usize) usize {
        return self._pieceTree.getOffsetAt(line, column);
    }

    pub fn getPositionAt(self: *const PieceTreeTextBuffer, offset: usize) Position {
        return self._pieceTree.getPositionAt(offset);
    }

    pub fn getRangeAt(self: *const PieceTreeTextBuffer, start: usize, length: usize) Range {
        const end = start + length;
        const startPosition = self.getPositionAt(start);
        const endPosition = self.getPositionAt(end);
        return Range{ .start = startPosition, .end = endPosition };
    }

    pub fn getValueInRange(self: *const PieceTreeTextBuffer, range: Range, eol: EndOfLinePreference) ![]const u8 {
        if (range.isEmpty()) {
            return "";
        }

        const lineEnding = self._getEndOfLine(eol);
        return try self._pieceTree.getValueInRange(range, lineEnding);
    }

    pub fn getValueLengthInRange(self: *const PieceTreeTextBuffer, range: Range, eol: EndOfLinePreference) usize {
        if (range.isEmpty()) {
            return 0;
        }

        if (range.startLineNumber == range.endLineNumber) {
            return range.endColumn - range.startColumn;
        }

        const startOffset = self.getOffsetAt(range.startLineNumber, range.startColumn);
        const endOffset = self.getOffsetAt(range.endLineNumber, range.endColumn);

        // offsets use the text EOL, so we need to compensate for length differences
        // if the requested EOL doesn't match the text EOL
        var eolOffsetCompensation: isize = 0;
        const desiredEOL = self._getEndOfLine(eol);
        const desiredEOLLength = switch (desiredEOL) {
            .CRLF => 2,
            else => 1,
        };
        const actualEOL = self.getEOL();
        const actualEOLLength = switch (actualEOL) {
            .CRLF => 2,
            else => 1,
        };

        if (desiredEOLLength != actualEOLLength) {
            const delta = usizeDiff(actualEOLLength, desiredEOLLength);
            const eolCount = range.endLineNumber - range.startLineNumber;
            eolOffsetCompensation = delta * @as(isize, @intCast(eolCount));
        }

        return usizeAdd(endOffset - startOffset, eolOffsetCompensation);
    }

    pub fn getCharacterCountInRange(self: *const PieceTreeTextBuffer, range: Range, eol: EndOfLinePreference) usize {
        if (self._mightContainNonBasicASCII) {
            // we must count by iterating
            var result = 0;

            const fromLineNumber = range.startLineNumber;
            const toLineNumber = range.endLineNumber;
            for (fromLineNumber..toLineNumber + 1) |lineNumber| {
                const lineContent = self.getLineContent(lineNumber);
                const fromOffset = if (lineNumber == fromLineNumber) range.startColumn - 1 else 0;
                const toOffset = if (lineNumber == toLineNumber) range.endColumn - 1 else lineContent.len;
                for (fromOffset..toOffset) |offset| {
                    result += 1;
                    offset += 1;
                }
            }

            result += (switch (self._getEndOfLine(eol)) {
                .LF => 1,
                .CRLF => 2,
            }) * (toLineNumber - fromLineNumber);

            return result;
        }

        return self.getValueLengthInRange(range, eol);
    }

    pub fn getNearestChunk(self: *const PieceTreeTextBuffer, offset: usize) ![]const u8 {
        return self._pieceTree.getNearestChunk(offset);
    }

    pub fn getLength(self: *const PieceTreeTextBuffer) usize {
        return self._pieceTree.getLength();
    }

    pub fn getLineCount(self: *const PieceTreeTextBuffer) usize {
        return self._pieceTree.getLineCount();
    }

    pub fn getLinesContent(self: *const PieceTreeTextBuffer) ![]const []const u8 {
        return self._pieceTree.getLinesContent();
    }

    pub fn getLineContent(self: *const PieceTreeTextBuffer, lineNumber: usize) ![]const u8 {
        return self._pieceTree.getLineContent(lineNumber);
    }

    // FIXME: utf8
    pub fn getLineCharCode(self: *const PieceTreeTextBuffer, lineNumber: usize, index: usize) u8 {
        return self._pieceTree.getLineCharCode(lineNumber, index);
    }

    pub fn getCharCode(self: *const PieceTreeTextBuffer, offset: usize) u8 {
        return self._pieceTree.getCharCode(offset);
    }

    pub fn getLineLength(self: *const PieceTreeTextBuffer, lineNumber: usize) usize {
        return self._pieceTree.getLineLength(lineNumber);
    }

    pub fn getLineMinColumn(self: *const PieceTreeTextBuffer) usize {
        _ = self;
        return 1;
    }

    pub fn getLineMaxColumn(self: *const PieceTreeTextBuffer, lineNumber: usize) usize {
        return self._pieceTree.getLineLength(lineNumber) + 1;
    }

    pub fn getLineFirstNonWhitespaceColumn(self: *const PieceTreeTextBuffer, lineNumber: usize) usize {
        const lineContent = self.getLineContent(lineNumber);
        const result = strings.firstNonWhitespaceIndex(lineContent);
        return if (result) |i| i + 1 else 0;
    }

    pub fn getLineLastNonWhitespaceColumn(self: *const PieceTreeTextBuffer, lineNumber: usize) usize {
        const lineContent = self.getLineContent(lineNumber);
        const result = strings.lastNonWhitespaceIndex(lineContent);
        return if (result) |i| i + 2 else 0;
    }

    fn _getEndOfLine(self: *const PieceTreeTextBuffer, eol: EndOfLinePreference) EOL {
        return switch (eol) {
            .TextDefined => self.getEOL(),
            .LF => .LF,
            .CRLF => .CRLF,
        };
    }

    pub fn setEOL(self: *PieceTreeTextBuffer, eol: EOL) void {
        self._pieceTree.setEOL(eol);
    }

    pub fn applyEdits(self: *PieceTreeTextBuffer, rawOperations: []const ValidAnnotatedEditOperation, recordTrimAutoWhitespace: bool, computeUndoEdits: bool) !ApplyEditsResult {
        var mightContainRTL = self._mightContainRTL;
        var mightContainUnusualLineTerminators = self._mightContainUnusualLineTerminators;
        var mightContainNonBasicASCII = self._mightContainNonBasicASCII;
        var canReduceOperations = true;

        var operations = std.ArrayList(ValidatedEditOperation).init(self.allocator);
        for (rawOperations, 0..) |op, i| {
            if (canReduceOperations and op._isTracked) {
                canReduceOperations = false;
            }
            const validatedRange = op.range;
            if (op.text) |text| {
                var textMightContainNonBasicASCII = true;
                if (!mightContainNonBasicASCII) {
                    textMightContainNonBasicASCII = !strings.isBasicASCII(text);
                    mightContainNonBasicASCII = textMightContainNonBasicASCII;
                }
                if (!mightContainRTL and textMightContainNonBasicASCII) {
                    // check if the new inserted text contains RTL
                    mightContainRTL = strings.containsRTL(text);
                }
                if (!mightContainUnusualLineTerminators and textMightContainNonBasicASCII) {
                    // check if the new inserted text contains unusual line terminators
                    mightContainUnusualLineTerminators = strings.containsUnusualLineTerminators(text);
                }
            }

            var validText = "";
            var eolCount: usize = 0;
            var firstLineLength: usize = 0;
            var lastLineLength: usize = 0;
            if (op.text) |text| {
                var strEOL: StringEOL = .Unknown;
                const eolResult = countEOL(text);
                eolCount = eolResult.eolCount;
                firstLineLength = eolResult.firstLineLength;
                lastLineLength = eolResult.lastLineLength;
                strEOL = eolResult.eol;

                const bufferEOL = self.getEOL();
                const expectedStrEOL = if (bufferEOL == .CRLF) StringEOL.CRLF else StringEOL.LF;
                if (strEOL != .Unknown or strEOL == expectedStrEOL) {
                    validText = text;
                } else {
                    validText = replaceEOL(text, bufferEOL);
                }
            }

            operations[i] = ValidatedEditOperation{
                .sortIndex = i,
                .identifier = op.identifier,
                .range = validatedRange,
                .rangeOffset = self.getOffsetAt(validatedRange.startLineNumber, validatedRange.startColumn),
                .rangeLength = self.getValueLengthInRange(validatedRange, .TextDefined),
                .text = validText,
                .eolCount = eolCount,
                .firstLineLength = firstLineLength,
                .lastLineLength = lastLineLength,
                .forceMoveMarkers = op.forceMoveMarkers,
                .isAutoWhitespaceEdit = op.isAutoWhitespaceEdit,
            };
        }

        // Sort operations ascending
        std.sort.heap(ValidatedEditOperation, operations.items, {}, _sortOpsAscending);

        var hasTouchingRanges = false;
        for (operations.items, 0..) |op, i| {
            const rangeEnd = op.range.getEndPosition();
            const nextRangeStart = operations.items[i + 1].range.getStartPosition();

            if (nextRangeStart.isBeforeOrEqual(rangeEnd)) {
                if (nextRangeStart.isBefore(rangeEnd)) {
                    // overlapping ranges
                    return error.OverlappingRanges;
                }
                hasTouchingRanges = true;
            }
        }

        if (canReduceOperations) {
            try self._reduceOperations(&operations);
        }

        // Delta encode operations
        const reverseRanges: ArrayList(Range) = if (computeUndoEdits or recordTrimAutoWhitespace) {
            try _getInverseEditRanges(self._pieceTree.allocator, operations.items);
        } else {
            ArrayList(Range).init(self._pieceTree.allocator);
        };
        defer reverseRanges.deinit();
        var newTrimAutoWhitespaceCandidates = ArrayList(struct { lineNumber: usize, oldContent: []const u8 }).init(self._pieceTree.allocator);
        if (recordTrimAutoWhitespace) {
            for (operations.items, 0..) |op, i| {
                const reverseRange = reverseRanges.items[i];
                if (op.isAutoWhitespaceEdit and op.range.isEmpty()) {
                    // Record already the future line numbers that might be auto whitespace removal candidates on next edit
                    for (reverseRange.startLineNumber..reverseRange.endLineNumber + 1) |lineNumber| {
                        var currentLineContent = "";
                        if (lineNumber == reverseRange.startLineNumber) {
                            currentLineContent = self.getLineContent(op.range.startLineNumber);
                            if (strings.firstNonWhitespaceIndex(currentLineContent) != -1) {
                                continue;
                            }
                        }

                        newTrimAutoWhitespaceCandidates.append(.{
                            .lineNumber = lineNumber,
                            .oldContent = currentLineContent,
                        });
                    }
                }
            }
        }

        var reverseOperations: ?ArrayList(ReverseSingleEditOperation) = null;
        if (computeUndoEdits) {
            var reverseRangeDeltaOffset: usize = 0;
            reverseOperations = ArrayList(ValidatedEditOperation).init(self._pieceTree.allocator);
            for (operations.items, 0..) |op, i| {
                const reverseRange = reverseRanges.items[i];
                const bufferText = try self.getValueInRange(op.range, .TextDefined);
                const reverseRangeOffset = op.rangeOffset + reverseRangeDeltaOffset;
                reverseRangeDeltaOffset = usizeAdd(reverseRangeDeltaOffset, usizeDiff(op.text.len, bufferText.len));

                reverseOperations[i] = ValidatedEditOperation{
                    .sortIndex = op.sortIndex,
                    .identifier = op.identifier,
                    .range = reverseRange,
                    .text = bufferText,
                    .textChange = TextChange{
                        .oldPosition = op.rangeOffset,
                        .oldText = bufferText,
                        .newPosition = reverseRangeOffset,
                        .newText = op.text,
                    },
                };
            }

            // Can only sort reverse operations when the order is not significant
            if (!hasTouchingRanges) {
                std.sort.heap(ReverseSingleEditOperation, reverseOperations.items, {}, _sortReverseOpsAscending);
            }
        }

        self._mightContainRTL = mightContainRTL;
        self._mightContainUnusualLineTerminators = mightContainUnusualLineTerminators;
        self._mightContainNonBasicASCII = mightContainNonBasicASCII;

        const contentChanges = try self._doApplyEdits(operations.items);

        var trimAutoWhitespaceLineNumbers: ?ArrayList(usize) = null;
        if (recordTrimAutoWhitespace and newTrimAutoWhitespaceCandidates.len > 0) {
            // sort line numbers auto whitespace removal candidates for next edit descending
            std.sort.heap(struct { lineNumber: usize, oldContent: []const u8 }, newTrimAutoWhitespaceCandidates.items, {}, _sortTrimAutoWhitespaceCandidatesDescending);

            trimAutoWhitespaceLineNumbers = ArrayList(usize).init(self._pieceTree.allocator);
            for (newTrimAutoWhitespaceCandidates.items, 0..) |candidate, i| {
                const lineNumber = candidate.lineNumber;
                if (i > 0 and newTrimAutoWhitespaceCandidates.items[i - 1].lineNumber == lineNumber) {
                    // Do not have the same line number twice
                    continue;
                }

                const prevContent = candidate.oldContent;
                const lineContent = self.getLineContent(lineNumber);

                if (lineContent.len == 0 or std.mem.eql(lineContent, prevContent) or strings.firstNonWhitespaceIndex(lineContent) != null) {
                    continue;
                }

                try trimAutoWhitespaceLineNumbers.append(lineNumber);
            }
        }

        return ApplyEditsResult{
            .reverseEdits = reverseOperations,
            .changes = contentChanges,
            .trimAutoWhitespaceLineNumbers = trimAutoWhitespaceLineNumbers,
        };
    }

    // Transform operations such that they represent the same logic edit,
    // but that they also do not cause OOM crashes.
    fn _reduceOperations(self: *PieceTreeTextBuffer, operations: *ArrayList(ValidatedEditOperation)) !void {
        if (operations.len < 1000) {
            // We know from empirical testing that a thousand edits work fine regardless of their shape.
            return;
        }

        // At one point, due to how events are emitted and how each operation is handled,
        // some operations can trigger a high amount of temporary string allocations,
        // that will immediately get edited again.
        // e.g. a formatter inserting ridiculous ammounts of \n on a model with a single line
        // Therefore, the strategy is to collapse all the operations into a huge single edit operation
        try operations.resize(1);
        operations.items[0] = try self._toSingleEditOperation(operations.items);
    }

    fn _toSingleEditOperation(self: *PieceTreeTextBuffer, operations: []const ValidatedEditOperation) !ValidatedEditOperation {
        var forceMoveMarkers = false;
        const firstEditRange = operations[0].range;
        const lastEditRange = operations[operations.len - 1].range;
        const entireEditRange = Range{
            .startLineNumber = firstEditRange.startLineNumber,
            .startColumn = firstEditRange.startColumn,
            .endLineNumber = lastEditRange.endLineNumber,
            .endColumn = lastEditRange.endColumn,
        };

        var lastEndLineNumber = firstEditRange.endLineNumber;
        var lastEndColumn = firstEditRange.endColumn;

        var result = ArrayList([]const u8).init(self.allocator);

        for (operations) |operation| {
            const range = operation.range;
            forceMoveMarkers = forceMoveMarkers or operation.forceMoveMarkers;

            // (1) -- Push old text
            try result.append(self.getValueInRange(Range{
                .startLineNumber = lastEndLineNumber,
                .startColumn = lastEndColumn,
                .endLineNumber = lastEndLineNumber,
                .endColumn = lastEndColumn,
            }, .TextDefined));

            // (2) -- Push new text
            if (operation.text.len > 0) {
                try result.append(operation);
            }

            // (3) -- Update last end line number and column
            lastEndLineNumber = range.endLineNumber;
            lastEndColumn = range.endColumn;
        }

        const text = std.mem.join(self._pieceTree.allocator, "", result);
        const eolResult = countEOL(text);
        return ValidatedEditOperation{
            .sortIndex = 0,
            .identifier = operations[0].identifier,
            .range = entireEditRange,
            .rangeOffset = self.getOffsetAt(firstEditRange.startLineNumber, firstEditRange.startColumn),
            .rangeLength = self.getValueLengthInRange(entireEditRange, .TextDefined),
            .text = text,
            .eolCount = eolResult.eolCount,
            .firstLineLength = eolResult.firstLineLength,
            .lastLineLength = eolResult.lastLineLength,
            .forceMoveMarkers = forceMoveMarkers,
            .isAutoWhitespaceEdit = false,
        };
    }

    fn _doApplyEdits(self: *PieceTreeTextBuffer, operations: []const ValidatedEditOperation) !ArrayList(InternalModelContentChange) {
        const sortedOperations = operations;
        std.sort.heap(ValidatedEditOperation, sortedOperations, {}, _sortOpDescending);
        var contentChanges = ArrayList(InternalModelContentChange).init(self.allocator);

        // operations are from bottom to top
        for (sortedOperations) |op| {
            const startLineNumber = op.range.startLineNumber;
            const startColumn = op.range.startColumn;
            const endLineNumber = op.range.endLineNumber;
            const endColumn = op.range.endColumn;

            if (startLineNumber == endLineNumber and startColumn == endColumn and op.text.len == 0) {
                // no-op
                continue;
            }

            if (op.text.len > 0) {
                // replacement
                self._pieceTree.delete(op.rangeOffset, op.rangeLength);
                self._pieceTree.insert(op.rangeOffset, op.text);
            } else {
                // deletion
                self._pieceTree.delete(op.rangeOffset, op.rangeLength);
            }

            const contentChangeRange = Range{
                .startLineNumber = startLineNumber,
                .startColumn = startColumn,
                .endLineNumber = endLineNumber,
                .endColumn = endColumn,
            };
            contentChanges.append(InternalModelContentChange{
                .range = contentChangeRange,
                .rangeLength = op.rangeLength,
                .text = op.text,
                .rangeOffset = op.rangeOffset,
                .forceMoveMarkers = op.forceMoveMarkers,
            });
        }

        return contentChanges;
    }
};

// Assumes `operations` are validated and sorted ascending
fn _getInverseEditRanges(allocator: Allocator, operators: []const ValidatedEditOperation) !ArrayList(Range) {
    var result = std.ArrayList(Range).init(allocator);

    var prevOpEndLineNumber: usize = 0;
    var prevOpEndColumn: usize = 0;
    var prevOp: ?ValidatedEditOperation = null;
    for (operators) |op| {
        var startLineNumber: usize = undefined;
        var startColumn: usize = undefined;

        if (prevOp) |prev| {
            if (prev.range.endLineNumber == op.range.startLineNumber) {
                startLineNumber = prevOpEndLineNumber;
                startColumn = prevOpEndColumn + (op.range.startLineNumber - prev.range.endLineNumber);
            } else {
                startLineNumber = prevOpEndLineNumber + (op.range.startLineNumber - prev.range.endLineNumber);
                startColumn = op.range.startColumn;
            }
        } else {
            startLineNumber = op.range.startLineNumber;
            startColumn = op.range.startColumn;
        }

        var resultRange: Range = undefined;

        if (!strings.isNullOrEmpty(op.text)) {
            // the operation inserts something
            const lineCount = op.eolCount + 1;
            if (lineCount == 1) {
                // single line insert
                resultRange = Range{
                    .startLineNumber = startLineNumber,
                    .startColumn = startColumn,
                    .endLineNumber = startLineNumber,
                    .endColumn = startColumn + op.firstLineLength,
                };
            } else {
                // multi line insert
                resultRange = Range{
                    .startLineNumber = startLineNumber,
                    .startColumn = startColumn,
                    .endLineNumber = startLineNumber + lineCount - 1,
                    .endColumn = startColumn + op.lastLineLength,
                };
            }
        } else {
            // There is nothing to insert
            resultRange = Range{
                .startLineNumber = startLineNumber,
                .startColumn = startColumn,
                .endLineNumber = startLineNumber,
                .endColumn = startColumn,
            };
        }

        prevOpEndLineNumber = resultRange.endLineNumber;
        prevOpEndColumn = resultRange.endColumn;
        try result.append(resultRange);
        prevOp = op;
    }

    return result;
}

fn _sortOpsAscending(a: *const ValidatedEditOperation, b: *const ValidatedEditOperation) bool {
    const r = Rg.compareRangesUsingEnds(&a.range, &b.range);
    if (r == 0) {
        return a.sortIndex < b.sortIndex;
    }
    return r < 0;
}

fn _sortOpDescending(a: *const ValidatedEditOperation, b: *const ValidatedEditOperation) bool {
    const r = Rg.compareRangesUsingEnds(&a.range, &b.range);
    if (r == 0) {
        return b.sortIndex < a.sortIndex;
    }
    return r < 0;
}

fn _sortReverseOpsAscending(a: *const ReverseSingleEditOperation, b: *const ReverseSingleEditOperation) bool {
    return a.sortIndex < b.sortIndex;
}

fn _sortTrimAutoWhitespaceCandidatesDescending(a: *const struct { lineNumber: usize, oldContent: []const u8 }, b: *const struct { lineNumber: usize, oldContent: []const u8 }) bool {
    return b.lineNumber < a.lineNumber;
}

test "pieceTreeTextBuffer" {
    const allocator = std.testing.allocator;
    var stringBuffers = ArrayList(StringBuffer).init(allocator);
    defer stringBuffers.deinit();
    try stringBuffers.append(try StringBuffer.init(allocator, "Hello\nWorld\r\n"));

    const buffer = try PieceTreeTextBuffer.init(allocator, stringBuffers.items, "", .LF, false, false, false, false);
    defer buffer.deinit();
}
