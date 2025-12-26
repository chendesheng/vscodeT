const std = @import("std");
const ArrayList = std.array_list.Managed;
const Allocator = std.mem.Allocator;
const countEOL = @import("../basics/eolCounter.zig").countEOL;
const StringEOL = @import("../basics/eolCounter.zig").StringEOL;
const strings = @import("../basics/strings.zig");
const PB = @import("pieceTreeBase.zig");
const PieceTreeBase = PB.PieceTreeBase;
const PieceTreeSnapshot = PB.PieceTreeSnapshot;
const Model = @import("../textModel/model.zig");
const SingleEditOperationIdentifier = Model.SingleEditOperationIdentifier;
const EndOfLinePreference = Model.EndOfLinePreference;
const ValidAnnotatedEditOperation = Model.ValidAnnotatedEditOperation;
const ApplyEditsResult = Model.ApplyEditsResult;
const InternalModelContentChange = Model.InternalModelContentChange;
const SearchData = Model.SearchData;
const FindMatch = Model.FindMatch;
const EOL = @import("../basics/eolCounter.zig").EOL;
const Position = @import("../basics/position.zig").Position;
const Rg = @import("../basics/range.zig");
const Range = Rg.Range;
const StringBuffer = PB.StringBuffer;
const usizeSub = @import("../basics/utils.zig").usizeSub;
const usizeAdd = @import("../basics/utils.zig").usizeAdd;
const TextChange = @import("../textModel/textChange.zig").TextChange;
const replaceEOL = @import("../basics/eolCounter.zig").replaceEOL;
const safeUtf8Substring = @import("../basics/utf8Helper.zig").safeUtf8Substring;
const ModelContentChange = @import("../textModel/textModelEvents.zig").ModelContentChange;
const ValidEditOperation = @import("../textModel/model.zig").ValidEditOperation;
const String = @import("../basics/strings.zig").String;

const ValidatedEditOperation = struct {
    sortIndex: i64,
    identifier: ?SingleEditOperationIdentifier,
    range: Range,
    rangeOffset: usize,
    rangeLength: usize,
    text: String,
    eolCount: usize,
    firstLineLength: usize,
    lastLineLength: usize,
    forceMoveMarkers: bool,
    isAutoWhitespaceEdit: bool,

    pub fn deinit(self: *const ValidatedEditOperation) void {
        self.text.deinit();
    }
};

const TrimAutoWhitespaceCandidate = struct {
    lineNumber: usize,
    oldContent: ArrayList(u8),
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
            ._pieceTree = try PieceTreeBase.init(allocator, null, chunks, eol, eolNormalized),
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
        return self._pieceTree._EOL;
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
        return Range.init(startPosition.lineNumber, startPosition.column, endPosition.lineNumber, endPosition.column);
    }

    pub fn getValueInRange(self: *const PieceTreeTextBuffer, range: Range, eol: EndOfLinePreference) !ArrayList(u8) {
        if (range.isEmpty()) {
            return ArrayList(u8).init(self._pieceTree.allocator);
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
        const desiredEOLLength: usize = if (desiredEOL == .CRLF) 2 else 1;
        const actualEOL = self.getEOL();
        const actualEOLLength: usize = if (actualEOL == .CRLF) 2 else 1;

        if (desiredEOLLength != actualEOLLength) {
            const delta = usizeSub(actualEOLLength, desiredEOLLength);
            const eolCount = range.endLineNumber - range.startLineNumber;
            eolOffsetCompensation = delta * @as(isize, @intCast(eolCount));
        }

        return usizeAdd(endOffset - startOffset, eolOffsetCompensation);
    }

    pub fn getCharacterCountInRange(self: *PieceTreeTextBuffer, range: Range, eol: EndOfLinePreference) !usize {
        if (self._mightContainNonBasicASCII) {
            // we must count by iterating
            var result: usize = 0;

            const fromLineNumber = range.startLineNumber;
            const toLineNumber = range.endLineNumber;
            for (fromLineNumber..toLineNumber + 1) |lineNumber| {
                const lineContent = try self.getLineContent(lineNumber);
                defer lineContent.deinit();

                const fromOffset = if (lineNumber == fromLineNumber) range.startColumn - 1 else 0;
                const toOffset = if (lineNumber == toLineNumber) range.endColumn - 1 else lineContent.items.len;
                const utf8View = try std.unicode.Utf8View.init(safeUtf8Substring(lineContent.items, fromOffset, toOffset));
                var iter = utf8View.iterator();
                while (iter.nextCodepointSlice()) |_| {
                    result += 1;
                }
            }

            result += (if (self._getEndOfLine(eol) == .CRLF) @as(usize, @intCast(2)) else 1) * (toLineNumber - fromLineNumber);

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

    pub fn getLinesContent(self: *const PieceTreeTextBuffer) !ArrayList(ArrayList(u8)) {
        return self._pieceTree.getLinesContent();
    }

    pub fn getLineContent(self: *PieceTreeTextBuffer, lineNumber: usize) !ArrayList(u8) {
        return try self._pieceTree.getLineContent(lineNumber);
    }

    pub fn getLineCharCode(self: *const PieceTreeTextBuffer, lineNumber: usize, offset: usize) u8 {
        return self._pieceTree.getLineCharCode(lineNumber, offset);
    }

    pub fn getLineCodepoint(self: *const PieceTreeTextBuffer, lineNumber: usize, offset: usize) u21 {
        return self._pieceTree.getLineCodepoint(lineNumber, offset);
    }

    pub fn getLineCodepointRange(self: *const PieceTreeTextBuffer, lineNumber: usize, offset: usize) [2]usize {
        return self._pieceTree.getLineCodepointRange(lineNumber, offset);
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

    pub fn getLineFirstNonWhitespaceColumn(self: *PieceTreeTextBuffer, lineNumber: usize) !usize {
        const lineContent = try self.getLineContent(lineNumber);
        defer lineContent.deinit();
        const result = strings.firstNonWhitespaceIndex(lineContent.items);
        return if (result) |i| i + 1 else 0;
    }

    pub fn getLineLastNonWhitespaceColumn(self: *PieceTreeTextBuffer, lineNumber: usize) !usize {
        const lineContent = try self.getLineContent(lineNumber);
        defer lineContent.deinit();
        const result = strings.lastNonWhitespaceIndex(lineContent.items);
        return if (result) |i| i + 2 else 0;
    }

    fn _getEndOfLine(self: *const PieceTreeTextBuffer, eol: EndOfLinePreference) EOL {
        return switch (eol) {
            .TextDefined => self.getEOL(),
            .LF => .LF,
            .CRLF => .CRLF,
        };
    }

    pub fn setEOL(self: *PieceTreeTextBuffer, eol: EOL) !void {
        try self._pieceTree.setEOL(eol);
    }

    // TODO: ?? add a "SharedString" (with reference counting) to avoid copying strings
    // TODO: maybe we could add fast path for single operation? could avoid sorting and other stuff
    pub fn applyEdits(self: *PieceTreeTextBuffer, rawOperations: []ValidAnnotatedEditOperation, recordTrimAutoWhitespace: bool, computeUndoEdits: bool) !ApplyEditsResult {
        const allocator = self._pieceTree.allocator;
        var mightContainRTL = self._mightContainRTL;
        var mightContainUnusualLineTerminators = self._mightContainUnusualLineTerminators;
        var mightContainNonBasicASCII = self._mightContainNonBasicASCII;
        var canReduceOperations = true;

        var operations = ArrayList(ValidatedEditOperation).init(allocator);
        defer operations.deinit();
        for (rawOperations, 0..) |*op, i| {
            if (canReduceOperations and op._isTracked) {
                canReduceOperations = false;
            }
            const validatedRange = op.range;
            if (op.text) |*text| {
                var textMightContainNonBasicASCII = true;
                if (!mightContainNonBasicASCII) {
                    textMightContainNonBasicASCII = !text.isBasicASCII_();
                    mightContainNonBasicASCII = textMightContainNonBasicASCII;
                }
                if (!mightContainRTL and textMightContainNonBasicASCII) {
                    // check if the new inserted text contains RTL
                    mightContainRTL = text.containsRTL_();
                }
                if (!mightContainUnusualLineTerminators and textMightContainNonBasicASCII) {
                    // check if the new inserted text contains unusual line terminators
                    mightContainUnusualLineTerminators = text.containsUnusualLineTerminators_();
                }
            }

            var validText: String = String.Empty;
            var eolCount: usize = 0;
            var firstLineLength: usize = 0;
            var lastLineLength: usize = 0;
            if (op.text) |*text| {
                var strEOL: StringEOL = .Unknown;
                const eolResult = countEOL(text.items());
                eolCount = eolResult.eolCount;
                firstLineLength = eolResult.firstLineLength;
                lastLineLength = eolResult.lastLineLength;
                strEOL = eolResult.eol;

                const bufferEOL = self.getEOL();
                const expectedStrEOL = if (bufferEOL == .CRLF) StringEOL.CRLF else StringEOL.LF;
                if (strEOL != .Unknown or strEOL == expectedStrEOL) {
                    validText = text.move();
                } else {
                    var temp = ArrayList(u8).init(allocator);
                    try temp.appendSlice(text.items());
                    try replaceEOL(&temp, bufferEOL);
                    validText = String.initOwned(temp);
                }
            }

            try operations.append(ValidatedEditOperation{
                .sortIndex = @intCast(i),
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
            });
        }

        // Sort operations ascending
        std.sort.heap(ValidatedEditOperation, operations.items, {}, _sortOpsAscending);

        var hasTouchingRanges = false;
        for (operations.items[0 .. operations.items.len - 1], 0..) |op, i| {
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
        var reverseRanges: ArrayList(Range) = undefined;
        if (computeUndoEdits or recordTrimAutoWhitespace) {
            reverseRanges = try _getInverseEditRanges(allocator, operations.items);
        } else {
            reverseRanges = ArrayList(Range).init(allocator);
        }
        defer reverseRanges.deinit();
        var newTrimAutoWhitespaceCandidates = ArrayList(TrimAutoWhitespaceCandidate).init(allocator);
        defer newTrimAutoWhitespaceCandidates.deinit();
        if (recordTrimAutoWhitespace) {
            for (operations.items, 0..) |op, i| {
                const reverseRange = reverseRanges.items[i];
                if (op.isAutoWhitespaceEdit and op.range.isEmpty()) {
                    // Record already the future line numbers that might be auto whitespace removal candidates on next edit
                    for (reverseRange.startLineNumber..reverseRange.endLineNumber + 1) |lineNumber| {
                        var currentLineContent = ArrayList(u8).init(allocator);
                        if (lineNumber == reverseRange.startLineNumber) {
                            currentLineContent = try self.getLineContent(op.range.startLineNumber);
                            if (strings.firstNonWhitespaceIndex(currentLineContent.items) != null) {
                                continue;
                            }
                        }

                        try newTrimAutoWhitespaceCandidates.append(TrimAutoWhitespaceCandidate{
                            .lineNumber = lineNumber,
                            .oldContent = currentLineContent,
                        });
                    }
                }
            }
        }

        var reverseEdits: ?ArrayList(ValidEditOperation) = null;
        if (computeUndoEdits) {
            var reverseRangeDeltaOffset: isize = 0;
            var reverseOperations = ArrayList(ValidEditOperation).init(allocator);
            for (operations.items, 0..) |*op, i| {
                const reverseRange = reverseRanges.items[i];
                const bufferText = try self.getValueInRange(op.range, .TextDefined);
                const reverseRangeOffset = usizeAdd(op.rangeOffset, reverseRangeDeltaOffset);
                reverseRangeDeltaOffset = reverseRangeDeltaOffset + usizeSub(op.text.len(), bufferText.items.len);

                try reverseOperations.append(ValidEditOperation{
                    .sortIndex = op.sortIndex,
                    .identifier = op.identifier,
                    .range = reverseRange,
                    .text = String.initBorrowed(bufferText.items),
                    .textChange = TextChange{
                        .oldPosition = op.rangeOffset,
                        .oldText = String.initOwned(bufferText),
                        .newPosition = reverseRangeOffset,
                        .newText = op.text.move(),
                    },
                });
            }

            // Can only sort reverse operations when the order is not significant
            if (!hasTouchingRanges) {
                std.sort.heap(ValidEditOperation, reverseOperations.items, {}, _sortReverseOpsAscending);
            }

            reverseEdits = reverseOperations;
        }

        self._mightContainRTL = mightContainRTL;
        self._mightContainUnusualLineTerminators = mightContainUnusualLineTerminators;
        self._mightContainNonBasicASCII = mightContainNonBasicASCII;

        const contentChanges = try self._doApplyEdits(operations.items);

        var trimAutoWhitespaceLineNumbers: ?ArrayList(usize) = null;
        if (recordTrimAutoWhitespace and newTrimAutoWhitespaceCandidates.items.len > 0) {
            // sort line numbers auto whitespace removal candidates for next edit descending
            std.sort.heap(TrimAutoWhitespaceCandidate, newTrimAutoWhitespaceCandidates.items, {}, _sortTrimAutoWhitespaceCandidatesDescending);

            var _trimAutoWhitespaceLineNumbers = ArrayList(usize).init(allocator);
            for (newTrimAutoWhitespaceCandidates.items, 0..) |candidate, i| {
                const lineNumber = candidate.lineNumber;
                if (i > 0 and newTrimAutoWhitespaceCandidates.items[i - 1].lineNumber == lineNumber) {
                    // Do not have the same line number twice
                    continue;
                }

                const prevContent = candidate.oldContent;
                const lineContent = try self.getLineContent(lineNumber);
                defer lineContent.deinit();
                defer prevContent.deinit();

                if (lineContent.items.len == 0 or std.mem.eql(u8, lineContent.items, prevContent.items) or strings.firstNonWhitespaceIndex(lineContent.items) != null) {
                    continue;
                }

                try _trimAutoWhitespaceLineNumbers.append(lineNumber);
            }

            trimAutoWhitespaceLineNumbers = _trimAutoWhitespaceLineNumbers;
        }

        return ApplyEditsResult{
            .reverseEdits = reverseEdits,
            .changes = contentChanges,
            .trimAutoWhitespaceLineNumbers = trimAutoWhitespaceLineNumbers,
        };
    }

    // Transform operations such that they represent the same logic edit,
    // but that they also do not cause OOM crashes.
    fn _reduceOperations(self: *PieceTreeTextBuffer, operations: *ArrayList(ValidatedEditOperation)) !void {
        if (operations.items.len < 1000) {
            // We know from empirical testing that a thousand edits work fine regardless of their shape.
            return;
        }

        for (operations.items) |*op| {
            op.text.deinit();
        }

        // At one point, due to how events are emitted and how each operation is handled,
        // some operations can trigger a high amount of temporary string allocations,
        // that will immediately get edited again.
        // e.g. a formatter inserting ridiculous ammounts of \n on a model with a single line
        // Therefore, the strategy is to collapse all the operations into a huge single edit operation
        try operations.resize(1);
        operations.items[0] = try self._toSingleEditOperation(operations.items);
    }

    fn _toSingleEditOperation(self: *PieceTreeTextBuffer, operations: []ValidatedEditOperation) !ValidatedEditOperation {
        const allocator = self._pieceTree.allocator;
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

        var result = ArrayList([]const u8).init(allocator);
        defer result.deinit();

        for (operations) |operation| {
            const range = operation.range;
            forceMoveMarkers = forceMoveMarkers or operation.forceMoveMarkers;

            // (1) -- Push old text
            const oldText = try self.getValueInRange(Range{
                .startLineNumber = lastEndLineNumber,
                .startColumn = lastEndColumn,
                .endLineNumber = lastEndLineNumber,
                .endColumn = lastEndColumn,
            }, .TextDefined);
            defer oldText.deinit();
            try result.append(oldText.items);

            // (2) -- Push new text
            if (!operation.text.isEmpty()) {
                try result.append(operation.text.items());
            }

            // (3) -- Update last end line number and column
            lastEndLineNumber = range.endLineNumber;
            lastEndColumn = range.endColumn;
        }

        const text = String.initOwned(ArrayList(u8){
            .allocator = allocator,
            .capacity = result.items.len,
            .items = try std.mem.join(allocator, "", result.items),
        });
        const eolResult = countEOL(text.items());
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

    fn _doApplyEdits(self: *PieceTreeTextBuffer, operations: []ValidatedEditOperation) !ArrayList(InternalModelContentChange) {
        const allocator = self._pieceTree.allocator;
        const sortedOperations = operations;
        std.sort.heap(ValidatedEditOperation, sortedOperations, {}, _sortOpDescending);
        var contentChanges = ArrayList(InternalModelContentChange).init(allocator);

        // operations are from bottom to top
        for (sortedOperations) |*op| {
            const startLineNumber = op.range.startLineNumber;
            const startColumn = op.range.startColumn;
            const endLineNumber = op.range.endLineNumber;
            const endColumn = op.range.endColumn;

            if (startLineNumber == endLineNumber and startColumn == endColumn and op.text.isEmpty()) {
                // no-op
                continue;
            }

            if (!op.text.isEmpty()) {
                // replacement
                try self._pieceTree.delete(op.rangeOffset, op.rangeLength);
                try self._pieceTree.insert(op.rangeOffset, op.text.items(), true);
            } else {
                // deletion
                try self._pieceTree.delete(op.rangeOffset, op.rangeLength);
            }

            const contentChangeRange = Range{
                .startLineNumber = startLineNumber,
                .startColumn = startColumn,
                .endLineNumber = endLineNumber,
                .endColumn = endColumn,
            };
            try contentChanges.append(InternalModelContentChange{
                .modelContentChange = ModelContentChange{
                    .range = contentChangeRange,
                    .rangeOffset = op.rangeOffset,
                    .rangeLength = op.rangeLength,
                    .text = op.text.move(),
                },
                .forceMoveMarkers = op.forceMoveMarkers,
            });
        }

        return contentChanges;
    }

    pub fn findMatchesLineByLine(self: *PieceTreeTextBuffer, searchRange: Range, searchData: SearchData, captureMatches: bool, limitResultCount: usize) !ArrayList(FindMatch) {
        return self._pieceTree.findMatchesLineByLine(searchRange, searchData, captureMatches, limitResultCount);
    }

    pub fn getAllocator(self: *const PieceTreeTextBuffer) Allocator {
        return self._pieceTree.allocator;
    }
};

// Assumes `operations` are validated and sorted ascending
fn _getInverseEditRanges(allocator: Allocator, operators: []ValidatedEditOperation) !ArrayList(Range) {
    var result = ArrayList(Range).init(allocator);

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

        if (!op.text.isEmpty()) {
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

fn _sortOpsAscending(context: void, a: ValidatedEditOperation, b: ValidatedEditOperation) bool {
    _ = context;

    const r = Rg.compareRangesUsingEnds(&a.range, &b.range);
    if (r == 0) {
        return a.sortIndex < b.sortIndex;
    }
    return r < 0;
}

fn _sortOpDescending(context: void, a: ValidatedEditOperation, b: ValidatedEditOperation) bool {
    return _sortOpsAscending(context, b, a);
}

fn _sortReverseOpsAscending(context: void, a: ValidEditOperation, b: ValidEditOperation) bool {
    _ = context;

    return a.sortIndex.? < b.sortIndex.?;
}

fn _sortTrimAutoWhitespaceCandidatesDescending(context: void, a: TrimAutoWhitespaceCandidate, b: TrimAutoWhitespaceCandidate) bool {
    _ = context;

    return b.lineNumber < a.lineNumber;
}

test "init" {
    const allocator = std.testing.allocator;
    const buffer = try PieceTreeTextBuffer.init(allocator, &[_]StringBuffer{
        try StringBuffer.init(allocator, "Hello\nWorld\r\n"),
    }, "", .LF, false, false, false, false);
    defer buffer.deinit();

    try std.testing.expectEqual(3, buffer.getLineCount());
}

test "insert" {
    const allocator = std.testing.allocator;
    var buffer = try PieceTreeTextBuffer.init(allocator, &[_]StringBuffer{
        try StringBuffer.init(allocator, "Hello\nWorld\r\n"),
    }, "", .LF, false, false, false, false);
    defer buffer.deinit();

    var edits = [_]ValidAnnotatedEditOperation{
        ValidAnnotatedEditOperation{
            .identifier = null,
            .range = Range{
                .startLineNumber = 1,
                .startColumn = 1,
                .endLineNumber = 1,
                .endColumn = 1,
            },
            .text = .initBorrowed("Hello"),
            .forceMoveMarkers = false,
            .isAutoWhitespaceEdit = false,
            ._isTracked = false,
        },
    };
    var result = try buffer.applyEdits(&edits, true, true);
    defer result.deinit();

    const line = try buffer.getLineContent(1);
    defer line.deinit();
    try std.testing.expectEqualStrings("HelloHello", line.items);
}

test "apply two inserts" {
    const allocator = std.testing.allocator;
    var buffer = try PieceTreeTextBuffer.init(allocator, &[_]StringBuffer{
        try StringBuffer.init(allocator, "Hello\nWorld\r\n"),
    }, "", .LF, false, false, true, false);
    defer buffer.deinit();

    var edits = [_]ValidAnnotatedEditOperation{
        ValidAnnotatedEditOperation.fromRangeAndText(Range{
            .startLineNumber = 1,
            .startColumn = 2,
            .endLineNumber = 1,
            .endColumn = 2,
        }, .initBorrowed("Hello")),
        ValidAnnotatedEditOperation.fromRangeAndText(Range{
            .startLineNumber = 2,
            .startColumn = 1,
            .endLineNumber = 2,
            .endColumn = 1,
        }, .initBorrowed("nihao")),
    };
    var result = try buffer.applyEdits(&edits, true, true);
    defer result.deinit();

    const line1 = try buffer.getLineContent(1);
    defer line1.deinit();
    try std.testing.expectEqualStrings("HHelloello", line1.items);

    const line2 = try buffer.getLineContent(2);
    defer line2.deinit();
    try std.testing.expectEqualStrings("nihaoWorld", line2.items);
}

test "delete" {
    const allocator = std.testing.allocator;
    var buffer = try PieceTreeTextBuffer.init(allocator, &[_]StringBuffer{
        try StringBuffer.init(allocator, "Hello\nWorld\r\n"),
    }, "", .LF, false, false, true, false);
    defer buffer.deinit();

    var edits = [_]ValidAnnotatedEditOperation{
        ValidAnnotatedEditOperation.fromRange(Range{
            .startLineNumber = 1,
            .startColumn = 1,
            .endLineNumber = 1,
            .endColumn = 5,
        }),
    };
    var result = try buffer.applyEdits(&edits, true, true);
    defer result.deinit();

    const line = try buffer.getLineContent(1);
    defer line.deinit();
    try std.testing.expectEqualStrings("o", line.items);
}

test "delete cross line" {
    const allocator = std.testing.allocator;
    var buffer = try PieceTreeTextBuffer.init(allocator, &[_]StringBuffer{
        try StringBuffer.init(allocator, "Hello\nWorld\r\n"),
    }, "", .LF, false, false, true, false);
    defer buffer.deinit();

    var edits = [_]ValidAnnotatedEditOperation{
        ValidAnnotatedEditOperation.fromRange(Range{
            .startLineNumber = 1,
            .startColumn = 2,
            .endLineNumber = 2,
            .endColumn = 4,
        }),
    };
    var result = try buffer.applyEdits(&edits, true, true);
    defer result.deinit();

    const line = try buffer.getLineContent(1);
    defer line.deinit();
    try std.testing.expectEqualStrings("Hld", line.items);
}

test "replace" {
    const allocator = std.testing.allocator;
    var buffer = try PieceTreeTextBuffer.init(allocator, &[_]StringBuffer{
        try StringBuffer.init(allocator, "Hello\nWorld\r\n"),
    }, "", .LF, false, false, true, false);
    defer buffer.deinit();

    var edits = [_]ValidAnnotatedEditOperation{
        ValidAnnotatedEditOperation.fromRangeAndText(Range{
            .startLineNumber = 1,
            .startColumn = 1,
            .endLineNumber = 1,
            .endColumn = 6,
        }, .initBorrowed("nihao")),
    };
    var result = try buffer.applyEdits(&edits, true, true);
    defer result.deinit();

    const line = try buffer.getLineContent(1);
    defer line.deinit();
    try std.testing.expectEqualStrings("nihao", line.items);
}

test "getCharacterCountInRange" {
    const allocator = std.testing.allocator;
    var buffer = try PieceTreeTextBuffer.init(allocator, &[_]StringBuffer{
        try StringBuffer.init(allocator, "你好Hello\nWorld\r\n"),
    }, "", .LF, false, false, false, false);
    defer buffer.deinit();

    try std.testing.expectEqual(5, try buffer.getCharacterCountInRange(Range{
        .startLineNumber = 1,
        .startColumn = 1,
        .endLineNumber = 1,
        .endColumn = 10,
    }, .TextDefined));
}
