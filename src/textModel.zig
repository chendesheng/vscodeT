const std = @import("std");
const Uri = std.Uri;
const unicode = std.unicode;
const Position = @import("position.zig").Position;
const fmt = std.fmt;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Model = @import("model.zig");
const TextModelCreationOptions = Model.TextModelCreationOptions;
const EOL = Model.EOL;
const EndOfLinePreference = Model.EndOfLinePreference;
const TextModelResolvedOptions = Model.TextModelResolvedOptions;
const TextModelUpdateOptions = Model.TextModelUpdateOptions;
const ValidEditOperation = Model.ValidEditOperation;
const IdentifiedSingleEditOperation = Model.IdentifiedSingleEditOperation;
const ValidAnnotatedEditOperation = Model.ValidAnnotatedEditOperation;
const ModelDecoration = Model.ModelDecoration;
const ModelContentChangedEvent = @import("textModelEvents.zig").ModelContentChangedEvent;
const ModelRawContentChangedEvent = @import("textModelEvents.zig").ModelRawContentChangedEvent;
const PieceTreeTextBuffer = @import("pieceTreeTextBuffer.zig").PieceTreeTextBuffer;
const EditStack = @import("editStack.zig").EditStack;
const CursorStateComputer = @import("editStack.zig").CursorStateComputer;
const IntervalTree = @import("IntervalTree.zig").IntervalTree;
const IntervalNode = @import("IntervalTree.zig").IntervalNode;
const recomputeMaxEnd = @import("IntervalTree.zig").recomputeMaxEnd;
const PieceTreeBufferBuilder = @import("pieceTreeBufferBuilder.zig").PieceTreeBufferBuilder;
const PieceTreeTextBufferFactory = @import("pieceTreeBufferBuilder.zig").PieceTreeTextBufferFactory;
const io = std.io;
const Range = @import("range.zig").Range;
const TextChange = @import("textChange.zig").TextChange;
const Selection = @import("selection.zig").Selection;
const SingleEditOperation = @import("editOperation.zig").SingleEditOperation;
const guessIndentation = @import("indentationGuesser.zig").guessIndentation;
const ResourceEditStackSnapshot = @import("undoRedo.zig").ResourceEditStackSnapshot;
const PieceTreeSnapshot = @import("pieceTreeTextBuffer.zig").PieceTreeSnapshot;
const UndoRedoService = @import("undoRedoService.zig").UndoRedoService;
const strings = @import("strings.zig");
const ModelRawChange = @import("textModelEvents.zig").ModelRawChange;
const ModelRawEOLChanged = @import("textModelEvents.zig").ModelRawEOLChanged;
const ModelContentChange = @import("textModelEvents.zig").ModelContentChange;
const UndoRedoGroup = @import("undoRedo.zig").UndoRedoGroup;
const countEOL = @import("eolCounter.zig").countEOL;
const LineInjectedText = @import("textModelEvents.zig").LineInjectedText;
const ModelRawLineChanged = @import("textModelEvents.zig").ModelRawLineChanged;
const ModelRawLinesDeleted = @import("textModelEvents.zig").ModelRawLinesDeleted;
const ModelRawLinesInserted = @import("textModelEvents.zig").ModelRawLinesInserted;
const ArrayQueue = @import("ArrayQueue.zig").ArrayQueue;

const LIMIT_FIND_COUNT = 999;
const LONG_LINE_BOUNDARY = 10000;
const LINE_HEIGHT_CEILING = 300;

const StringOffsetValidationType = enum {
    // Even allowed in surrogate pairs
    Relaxed,
    // Not allowed in surrogate pairs
    SurrogatePairs,
};

pub const TextModelSnapshot = struct {
    _source: PieceTreeSnapshot,
    _eos: bool,
    pub fn init(source: PieceTreeSnapshot) TextModelSnapshot {
        return TextModelSnapshot{ ._source = source, ._eos = false };
    }

    pub fn read(self: *TextModelSnapshot) ?[]const u8 {
        if (self._eos) {
            return null;
        }

        const allocator = self._source.allocator;
        const result: ArrayList(u8) = ArrayList(u8).init(allocator);

        while (true) {
            const tmp = self._source.read();
            if (tmp == null) {
                // end-of-stream
                self._eos = true;
                if (result.items.len == 0) {
                    return null;
                } else {
                    return std.mem.join(allocator, "", result.items);
                }
            }

            if (tmp) |_tmp| {
                if (_tmp.len > 0) {
                    try result.append(_tmp);
                }
            }

            if (result.items.len >= 64 * 1024) {
                return std.mem.join(allocator, "", result.items);
            }
        }
    }
};

pub const TextModel = struct {
    var MODEL_ID: u64 = 0;
    const MODEL_SYNC_LIMIT = 50 * 1024 * 1024; // 50 MB,  // used in tests
    const LARGE_FILE_SIZE_THRESHOLD = 20 * 1024 * 1024; // 20 MB;
    const LARGE_FILE_LINE_COUNT_THRESHOLD = 300 * 1000; // 300K lines
    const LARGE_FILE_HEAP_OPERATION_THRESHOLD = 256 * 1024 * 1024; // 256M characters, usually ~> 512MB memory usage

    id: u64,
    isForSimpleWidget: bool,
    _associatedResource: Uri,
    _attachedEditorCount: usize,
    _buffer: PieceTreeTextBuffer,
    _options: TextModelResolvedOptions,
    // languageSelectionListener: MutableDisposable(IDisposable),

    __isDisposing: bool,
    _versionId: i64,
    _alternativeVersionId: i64,
    _initialUndoRedoSnapshot: ?ResourceEditStackSnapshot,
    _isTooLargeForSyncing: bool,
    _isTooLargeForTokenization: bool,
    _isTooLargeForHeapOperation: bool,

    //#region Editing
    _commandManager: EditStack,
    _isUndoing: bool,
    _isRedoing: bool,
    _trimAutoWhitespaceLines: ?[]const usize,
    //#endregion

    //#region Decorations
    // Used to workaround broken clients that might attempt using a decoration id generated by a different model.
    // It is not globally unique in order to limit it to one character.
    _instanceId: u8,
    _deltaDecorationCallCnt: usize,
    _lastDecorationId: usize,
    _decorations: std.StringHashMap(IntervalNode),
    _decorationsTree: DecorationsTrees,
    // _decorationProvider: ColorizedBracketPairsDecorationProvider,
    //#endregion

    _undoRedoService: *UndoRedoService,

    pub fn init(allocator: Allocator, source: io.AnyReader, creationOptions: TextModelCreationOptions, associatedResource: ?Uri, undoRedoService: *UndoRedoService) !TextModel {
        MODEL_ID += 1;
        const buffer = try createTextBuffer(allocator, source, creationOptions.defaultEOL);
        const bufferLineCount = buffer.getLineCount();
        const bufferTextLength = buffer.getValueLengthInRange(Range.init(1, 1, bufferLineCount, buffer.getLineLength(bufferLineCount) + 1), EndOfLinePreference.TextDefined);

        var tooLargeForTokenization = false;
        var tooLargeForHeapOperation = false;

        // !!! Make a decision in the ctor and permanently respect this decision !!!
        // If a model is too large at construction time, it will never get tokenized,
        // under no circumstances.
        if (creationOptions.largeFileOptimizations) {
            tooLargeForTokenization = ((bufferTextLength > LARGE_FILE_SIZE_THRESHOLD) or (bufferLineCount > LARGE_FILE_LINE_COUNT_THRESHOLD));
            tooLargeForHeapOperation = bufferTextLength > LARGE_FILE_HEAP_OPERATION_THRESHOLD;
        } else {
            tooLargeForTokenization = false;
            tooLargeForHeapOperation = false;
        }

        return TextModel{
            .id = try fmt.allocPrint(allocator, "$model{d}", .{MODEL_ID}),
            .isForSimpleWidget = creationOptions.isForSimpleWidget,
            ._associatedResource = if (associatedResource) |url| url else .{
                .scheme = "inmemory",
                .user = null,
                .password = null,
                .host = "model",
                .port = null,
                .path = try fmt.allocPrint(allocator, "/{d}", .{MODEL_ID}),
                .query = null,
                .fragment = null,
            },
            ._attachedEditorCount = 0,
            ._buffer = buffer,
            ._isTooLargeForSyncing = bufferTextLength > MODEL_SYNC_LIMIT,
            ._isTooLargeForTokenization = tooLargeForTokenization,
            ._isTooLargeForHeapOperation = tooLargeForHeapOperation,
            ._versionId = 1,
            ._alternativeVersionId = 1,
            ._initialUndoRedoSnapshot = null,
            .__isDisposing = false,

            ._instanceId = strings.singleLetterHash(MODEL_ID),
            ._lastDecorationId = 0,
            ._deltaDecorationCallCnt = 0,
            ._decorations = std.StringHashMap(IntervalNode).init(allocator),
            ._decorationsTree = DecorationsTrees.init(),

            ._commandManager = EditStack.init(allocator),
            ._isUndoing = false,
            ._isRedoing = false,
            ._trimAutoWhitespaceLines = null,

            ._undoRedoService = undoRedoService,
        };
    }

    pub fn deinit(self: *TextModel) void {
        const allocator = self._buffer.allocator;
        self._buffer.deinit();
        self._decorations.deinit();
        allocator.free(self.id);
        allocator.free(self._associatedResource.path);
    }

    pub fn equalsTextBuffer(self: *const TextModel, other: *const PieceTreeTextBuffer) bool {
        return self._buffer.equals(other);
    }

    pub fn getTextBuffer(self: *const TextModel) PieceTreeTextBuffer {
        return self._buffer;
    }

    pub fn updateOptions(self: *TextModel, _newOpts: TextModelUpdateOptions) void {
        const newOpts = self._options;
        if (_newOpts.tabSize) |tabSize| {
            newOpts.tabSize = tabSize;
        }
        if (_newOpts.indentSize) |indentSize| {
            newOpts.indentSize = indentSize;
        }
        if (_newOpts.insertSpaces) |insertSpaces| {
            newOpts.insertSpaces = insertSpaces;
        }
        if (_newOpts.trimAutoWhitespace) |trimAutoWhitespace| {
            newOpts.trimAutoWhitespace = trimAutoWhitespace;
        }
        if (_newOpts.bracketColorizationOptions) |bracketColorizationOptions| {
            newOpts.bracketPairColorizationOptions = bracketColorizationOptions;
        }

        if (self._options.equals(newOpts)) {
            return;
        }

        const e = self._options.createChangeEvent(newOpts);
        _ = e;
        self._options = newOpts;

        // this._bracketPairs.handleDidChangeOptions(e);
        // this._decorationProvider.handleDidChangeOptions(e);
        // this._onDidChangeOptions.fire(e);
    }

    pub fn detectIndentation(self: *TextModel, defaultInsertSpaces: bool, defaultTabSize: usize) void {
        const indentation = guessIndentation(self._buffer, defaultTabSize, defaultInsertSpaces);
        self.updateOptions(TextModelUpdateOptions{
            .insertSpaces = indentation.insertSpaces,
            .tabSize = indentation.tabSize,
            .indentSize = indentation.tabSize, // TODO@Alex: guess indentSize independent of tabSize
        });
    }

    pub fn normalizeIndentation(self: *TextModel, str: []const u8) []const u8 {
        return normalizeIndentation(str, self._options.indentSize, self._options.insertSpaces);
    }

    pub fn isAttachedToEditor(self: *const TextModel) bool {
        return self._attachedEditorCount > 0;
    }

    pub fn getAttachedEditorCount(self: *const TextModel) usize {
        return self._attachedEditorCount;
    }

    pub fn isTooLargeForSyncing(self: *const TextModel) bool {
        return self._isTooLargeForSyncing;
    }

    pub fn isTooLargeForTokenization(self: *const TextModel) bool {
        return self._isTooLargeForTokenization;
    }

    pub fn isTooLargeForHeapOperation(self: *const TextModel) bool {
        return self._isTooLargeForHeapOperation;
    }

    pub fn isDominatedByLongLines(self: *const TextModel) bool {
        if (self.isTooLargeForTokenization()) {
            // Cannot word wrap huge files anyways, so it doesn't really matter
            return false;
        }
        var smallLineCharCount: usize = 0;
        var longLineCharCount: usize = 0;

        const lineCount = self._buffer.getLineCount();
        for (1..lineCount) |lineNumber| {
            const lineLength = self._buffer.getLineLength(lineNumber);
            if (lineLength >= LONG_LINE_BOUNDARY) {
                longLineCharCount += lineLength;
            } else {
                smallLineCharCount += lineLength;
            }
        }

        return (longLineCharCount > smallLineCharCount);
    }

    pub fn uri(self: *const TextModel) Uri {
        return self._associatedResource;
    }

    pub fn getVersionId(self: *const TextModel) i64 {
        return self._versionId;
    }

    pub fn mightContainRTL(self: *const TextModel) bool {
        return self._buffer.getMightContainRTL();
    }

    pub fn mightContainUnusualLineTerminators(self: *const TextModel) bool {
        return self._buffer.getMightContainUnusualLineTerminators();
    }

    pub fn removeUnusualLineTerminators(self: *TextModel, selections: ?[]const Selection) void {
        _ = self;
        _ = selections;
        // const matches = self.findMatches(strings.UNUSUAL_LINE_TERMINATORS.source, false, true, false, null, false, Constants.MAX_SAFE_SMALL_INTEGER);
        // self._buffer.resetMightContainUnusualLineTerminators();
        // self.pushEditOperations(selections, matches.map(m => ({ range: m.range, text: null })), () => null);
    }

    pub fn mightContainNonBasicASCII(self: *const TextModel) bool {
        return self._buffer.getMightContainNonBasicASCII();
    }

    pub fn getAlternativeVersionId(self: *const TextModel) i64 {
        return self._alternativeVersionId;
    }

    pub fn getInitialUndoRedoSnapshot(self: *const TextModel) ?ResourceEditStackSnapshot {
        return self._initialUndoRedoSnapshot;
    }

    pub fn getOffsetAt(self: *const TextModel, position: usize) usize {
        return self._buffer.getOffsetAt(position);
    }

    fn _increaseVersionId(self: *TextModel) void {
        self._versionId += 1;
        self._alternativeVersionId = self._versionId;
    }

    pub fn _overwriteVersionId(self: *TextModel, versionId: i64) void {
        self._versionId = versionId;
    }

    pub fn _overwriteAlternativeVersionId(self: *TextModel, versionId: i64) void {
        self._alternativeVersionId = versionId;
    }

    pub fn _overwriteInitialUndoRedoSnapshot(self: *TextModel, snapshot: ResourceEditStackSnapshot) void {
        self._initialUndoRedoSnapshot = snapshot;
    }

    pub fn getValue(self: *TextModel, eol: ?EndOfLinePreference, preserveBOM: bool) ![]const u8 {
        if (self.isTooLargeForHeapOperation()) {
            return error.OperationWouldExceedHeapMemoryLimits;
        }

        const fullModelRange = self.getFullModelRange();
        const fullModelValue = try self.getValueInRange(fullModelRange, eol);

        if (preserveBOM) {
            const allocator = self.getAllocator();
            allocator.free(fullModelValue);
            return try std.fmt.allocPrint(allocator, "{s}{s}", .{ self._buffer.getBOM(), fullModelValue });
        }

        return fullModelValue;
    }

    pub fn createSnapshot(self: *TextModel, preserveBOM: bool) !TextModelSnapshot {
        return TextModelSnapshot.init(try self._buffer.createSnapshot(preserveBOM));
    }

    pub fn getValueLength(self: *TextModel, eol: EndOfLinePreference, preserveBOM: bool) usize {
        const fullModelRange = self.getFullModelRange();
        const fullModelValue = self.getValueLengthInRange(fullModelRange, eol);

        if (preserveBOM) {
            return self._buffer.getBOM().length + fullModelValue;
        }

        return fullModelValue;
    }

    pub fn getValueInRange(self: *TextModel, rawRange: Range, eol: EndOfLinePreference) ![]const u8 {
        return try self._buffer.getValueInRange(self.validateRange(rawRange), eol);
    }

    pub fn getValueLengthInRange(self: *TextModel, rawRange: Range, eol: EndOfLinePreference) usize {
        return self._buffer.getValueLengthInRange(self.validateRange(rawRange), eol);
    }

    pub fn getCharacterCountInRange(self: *TextModel, rawRange: Range, eol: EndOfLinePreference) usize {
        return self._buffer.getCharacterCountInRange(self.validateRange(rawRange), eol);
    }

    pub fn getLineCount(self: *TextModel) usize {
        return self._buffer.getLineCount();
    }

    pub fn getLineContent(self: *TextModel, lineNumber: usize) ![]const u8 {
        if (lineNumber < 1 or lineNumber > self.getLineCount()) {
            return error.IllegalValueForLineNumber;
        }

        return self._buffer.getLineContent(lineNumber);
    }

    pub fn getLineLength(self: *const TextModel, lineNumber: usize) usize {
        if (lineNumber < 1 or lineNumber > self.getLineCount()) {
            return error.IllegalValueForLineNumber;
        }

        return self._buffer.getLineLength(lineNumber);
    }

    pub fn getLinesContent(self: *const TextModel) ![]const []const u8 {
        if (self.isTooLargeForHeapOperation()) {
            return error.OperationWouldExceedHeapMemoryLimits;
        }

        return self._buffer.getLinesContent();
    }

    pub fn getEOL(self: *const TextModel) EOL {
        return self._buffer.getEOL();
    }

    pub fn getLineMinColumn(self: *const TextModel, lineNumber: usize) usize {
        _ = self;
        _ = lineNumber;
        return 1;
    }

    pub fn getLineMaxColumn(self: *const TextModel, lineNumber: usize) usize {
        if (lineNumber < 1 or lineNumber > self.getLineCount()) {
            return error.IllegalValueForLineNumber;
        }
        return self._buffer.getLineLength(lineNumber) + 1;
    }

    pub fn getLineFirstNonWhitespaceColumn(self: *const TextModel, lineNumber: usize) usize {
        if (lineNumber < 1 or lineNumber > self.getLineCount()) {
            return error.IllegalValueForLineNumber;
        }
        return self._buffer.getLineFirstNonWhitespaceColumn(lineNumber);
    }

    pub fn getLineLastNonWhitespaceColumn(self: *const TextModel, lineNumber: usize) usize {
        if (lineNumber < 1 or lineNumber > self.getLineCount()) {
            return error.IllegalValueForLineNumber;
        }
        return self._buffer.getLineLastNonWhitespaceColumn(lineNumber);
    }

    // Validates `range` is within buffer bounds, but allows it to sit in between surrogate pairs, etc.
    // Will try to not allocate if possible.
    pub fn _validateRangeRelaxedNoAllocations(self: *TextModel, range: Range) Range {
        const linesCount = self._buffer.getLineCount();

        const initialStartLineNumber = range.startLineNumber;
        const initialStartColumn = range.startColumn;
        var startLineNumber = @floor((if (initialStartLineNumber > 0) initialStartLineNumber else 1));
        var startColumn = @floor((if (initialStartColumn > 0) initialStartColumn else 1));

        if (startLineNumber < 1) {
            startLineNumber = 1;
            startColumn = 1;
        } else if (startLineNumber > linesCount) {
            startLineNumber = linesCount;
            startColumn = self.getLineMaxColumn(startLineNumber);
        } else {
            if (startColumn <= 1) {
                startColumn = 1;
            } else {
                const maxColumn = self.getLineMaxColumn(startLineNumber);
                if (startColumn >= maxColumn) {
                    startColumn = maxColumn;
                }
            }
        }

        const initialEndLineNumber = range.endLineNumber;
        const initialEndColumn = range.endColumn;
        var endLineNumber = @floor((if (initialEndLineNumber > 0) initialEndLineNumber else 1));
        var endColumn = @floor((if (initialEndColumn > 0) initialEndColumn else 1));

        if (endLineNumber < 1) {
            endLineNumber = 1;
            endColumn = 1;
        } else if (endLineNumber > linesCount) {
            endLineNumber = linesCount;
            endColumn = self.getLineMaxColumn(endLineNumber);
        } else {
            if (endColumn <= 1) {
                endColumn = 1;
            } else {
                const maxColumn = self.getLineMaxColumn(endLineNumber);
                if (endColumn >= maxColumn) {
                    endColumn = maxColumn;
                }
            }
        }

        if (initialStartLineNumber == startLineNumber and initialStartColumn == startColumn and initialEndLineNumber == endLineNumber and initialEndColumn == endColumn and range.startLineNumber == startLineNumber and range.startColumn == startColumn and range.endLineNumber == endLineNumber and range.endColumn == endColumn and !Selection.isSelection(range)) {
            return range;
        }

        return Range.init(startLineNumber, startColumn, endLineNumber, endColumn);
    }

    fn _isValidPosition(self: *TextModel, lineNumber: usize, column: usize, validationType: StringOffsetValidationType) bool {
        if (lineNumber < 1 or column < 1) {
            return false;
        }

        const lineCount = self._buffer.getLineCount();
        if (lineNumber > lineCount) {
            return false;
        }

        if (column == 1) {
            return true;
        }

        const maxColumn = self.getLineMaxColumn(lineNumber);
        if (column > maxColumn) {
            return false;
        }

        if (validationType == StringOffsetValidationType.SurrogatePairs) {
            // !!At this point, column > 1
            const charCodeBefore = self._buffer.getLineCharCode(lineNumber, column - 2);
            unicode.utf8ByteSequenceLength(charCodeBefore) catch {
                return false;
            };
            return true;
        }

        return true;
    }

    fn _validatePosition(self: *TextModel, lineNumber: usize, column: usize, validationType: StringOffsetValidationType) Position {
        const lineCount = self._buffer.getLineCount();

        if (lineNumber < 1) {
            return Position.init(1, 1);
        }

        if (lineNumber > lineCount) {
            return Position.init(lineCount, self.getLineMaxColumn(lineCount));
        }

        if (column <= 1) {
            return Position.init(lineNumber, 1);
        }

        const maxColumn = self.getLineMaxColumn(lineNumber);
        if (column >= maxColumn) {
            return Position.init(lineNumber, maxColumn);
        }

        if (validationType == StringOffsetValidationType.SurrogatePairs) {
            // If the position would end up in the middle of a high-low surrogate pair,
            // we move it to before the pair
            // !!At this point, column > 1
            var i = column - 2;
            while (i > 0) : (i -= 1) {
                const charCodeBefore = self._buffer.getLineCharCode(lineNumber, i);
                _ = unicode.utf8ByteSequenceLength(charCodeBefore) catch {
                    continue;
                };
                return Position.init(lineNumber, i);
            }
        }

        return Position.init(lineNumber, column);
    }

    pub fn validatePosition(self: *TextModel, position: Position) Position {
        const validationType = StringOffsetValidationType.SurrogatePairs;

        // Avoid object allocation and cover most likely case
        if (position == Position) {
            if (self._isValidPosition(position.lineNumber, position.column, validationType)) {
                return position;
            }
        }

        return self._validatePosition(position.lineNumber, position.column, validationType);
    }

    pub fn isValidRange(self: *TextModel, range: Range) bool {
        return self._isValidRange(range, StringOffsetValidationType.SurrogatePairs);
    }

    fn _isValidRange(self: *TextModel, range: Range, validationType: StringOffsetValidationType) bool {
        const startLineNumber = range.startLineNumber;
        const startColumn = range.startColumn;
        const endLineNumber = range.endLineNumber;
        const endColumn = range.endColumn;

        if (!self._isValidPosition(startLineNumber, startColumn, StringOffsetValidationType.Relaxed)) {
            return false;
        }
        if (!self._isValidPosition(endLineNumber, endColumn, StringOffsetValidationType.Relaxed)) {
            return false;
        }

        if (validationType == StringOffsetValidationType.SurrogatePairs) {
            const charCodeBeforeStart = if (startColumn > 1) self._buffer.getLineCharCode(startLineNumber, startColumn - 2) else 0;
            const charCodeBeforeEnd = if (endColumn > 1 and endColumn <= self._buffer.getLineLength(endLineNumber)) self._buffer.getLineCharCode(endLineNumber, endColumn - 2) else 0;

            const startInsideSurrogatePair = unicode.utf8ByteSequenceLength(charCodeBeforeStart) catch 0;
            const endInsideSurrogatePair = unicode.utf8ByteSequenceLength(charCodeBeforeEnd) catch 0;

            if (startInsideSurrogatePair > 0 and endInsideSurrogatePair > 0) {
                return true;
            }
            return false;
        }

        return true;
    }

    pub fn validateRange(self: *TextModel, _range: Range) Range {
        const validationType = StringOffsetValidationType.SurrogatePairs;

        // Avoid object allocation and cover most likely case
        if (self._isValidRange(_range, validationType)) {
            return _range;
        }

        const start = self._validatePosition(_range.startLineNumber, _range.startColumn, StringOffsetValidationType.Relaxed);
        const end = self._validatePosition(_range.endLineNumber, _range.endColumn, StringOffsetValidationType.Relaxed);

        const startLineNumber = start.lineNumber;
        const startColumn = start.column;
        const endLineNumber = end.lineNumber;
        const endColumn = end.column;

        if (validationType == StringOffsetValidationType.SurrogatePairs) {
            const charCodeBeforeStart = if (startColumn > 1) self._buffer.getLineCharCode(startLineNumber, startColumn - 2) else 0;
            const charCodeBeforeEnd = if (endColumn > 1 and endColumn <= self._buffer.getLineLength(endLineNumber)) self._buffer.getLineCharCode(endLineNumber, endColumn - 2) else 0;

            const startInsideSurrogatePair = unicode.utf8ByteSequenceLength(charCodeBeforeStart) catch 0;
            const endInsideSurrogatePair = unicode.utf8ByteSequenceLength(charCodeBeforeEnd) catch 0;

            if (startInsideSurrogatePair > 0 and endInsideSurrogatePair > 0) {
                return Range.init(startLineNumber, startColumn, endLineNumber, endColumn);
            }

            // if (startLineNumber == endLineNumber and startColumn == endColumn) {
            //     // do not expand a collapsed range, simply move it to a valid location
            //     return Range.init(startLineNumber, startColumn - 1, endLineNumber, endColumn - 1);
            // }

            // if (startInsideSurrogatePair and endInsideSurrogatePair) {
            //     // expand range at both ends
            //     return Range.init(startLineNumber, startColumn - 1, endLineNumber, endColumn + 1);
            // }

            // if (startInsideSurrogatePair) {
            //     // only expand range at the start
            //     return Range.init(startLineNumber, startColumn - 1, endLineNumber, endColumn);
            // }

            // only expand range at the end
            return Range.init(startLineNumber, startColumn, endLineNumber, endColumn + 1);
        }

        return Range.init(startLineNumber, startColumn, endLineNumber, endColumn);
    }

    pub fn modifyPosition(self: *TextModel, rawPosition: Position, offset: usize) Position {
        const candidate = self.getOffsetAt(rawPosition) + offset;
        return self.getPositionAt(std.math.min(self._buffer.getLength(), std.math.max(0, candidate)));
    }

    pub fn getFullModelRange(self: *TextModel) Range {
        const lineCount = self.getLineCount();
        return Range.init(1, 1, lineCount, self.getLineMaxColumn(lineCount));
    }

    pub fn pushStackElement(self: *TextModel) void {
        self._commandManager.pushStackElement();
    }

    pub fn popStackElement(self: *TextModel) void {
        self._commandManager.popStackElement();
    }

    pub fn pushEOL(self: *TextModel, eol: EOL) void {
        const currentEOL = self.getEOL();
        if (currentEOL == eol) {
            return;
        }
        self._onDidChangeDecorations.beginDeferredEmit();
        self._eventEmitter.beginDeferredEmit();
        if (self._initialUndoRedoSnapshot == null) {
            self._initialUndoRedoSnapshot = self._undoRedoService.createSnapshot(self.uri());
        }
        self._commandManager.pushEOL(eol);

        self._eventEmitter.endDeferredEmit();
        self._onDidChangeDecorations.endDeferredEmit();
    }

    fn _validateEditOperation(self: *TextModel, rawOperation: IdentifiedSingleEditOperation) ValidAnnotatedEditOperation {
        return ValidAnnotatedEditOperation{
            .identifier = rawOperation.identifier,
            .range = self.validateRange(rawOperation.range),
            .text = rawOperation.text,
            .forceMoveMarkers = rawOperation.forceMoveMarkers,
            .isAutoWhitespaceEdit = rawOperation.isAutoWhitespaceEdit,
            .isTracked = rawOperation.isTracked,
        };
    }

    fn _validateEditOperations(self: *TextModel, rawOperations: []IdentifiedSingleEditOperation) ArrayList(ValidAnnotatedEditOperation) {
        const allocator = self.getAllocator();
        var result = ArrayList(ValidAnnotatedEditOperation).init(allocator);
        for (rawOperations) |rawOperation| {
            try result.append(self._validateEditOperation(rawOperation));
        }
        return result;
    }

    pub fn pushEditOperations(self: *TextModel, beforeCursorState: ?[]Selection, editOperations: []IdentifiedSingleEditOperation, cursorStateComputer: ?CursorStateComputer, group: ?UndoRedoGroup) ?[]Selection {
        self._onDidChangeDecorations.beginDeferredEmit();
        self._eventEmitter.beginDeferredEmit();
        return self._pushEditOperations(beforeCursorState, self._validateEditOperations(editOperations), cursorStateComputer, group);

        //this._eventEmitter.endDeferredEmit();
        //this._onDidChangeDecorations.endDeferredEmit();
    }

    fn _pushEditOperations(self: *TextModel, beforeCursorState: ?[]Selection, editOperations: []ValidAnnotatedEditOperation, cursorStateComputer: ?CursorStateComputer, group: ?UndoRedoGroup) ?[]Selection {
        if (self._options.trimAutoWhitespace and self._trimAutoWhitespaceLines) {
            // Go through each saved line number and insert a trim whitespace edit
            // if it is safe to do so (no conflicts with other edits).

            const allocator = self.getAllocator();
            var incomingEdits = ArrayList(struct {
                range: Range,
                text: ?[]const u8,
            }).init(allocator);
            defer incomingEdits.deinit();

            for (editOperations) |op| {
                try incomingEdits.append(.{
                    .range = self.validateRange(op.range),
                    .text = op.text,
                });
            }

            // Sometimes, auto-formatters change ranges automatically which can cause undesired auto whitespace trimming near the cursor
            // We'll use the following heuristic: if the edits occur near the cursor, then it's ok to trim auto whitespace
            var editsAreNearCursors = true;
            if (beforeCursorState) |beforeCursorStateItems| {
                for (beforeCursorStateItems) |sel| {
                    var foundEditNearSel = false;
                    for (incomingEdits.items) |edit| {
                        const editRange = edit.range;
                        const selIsAbove = editRange.startLineNumber > sel.endLineNumber;
                        const selIsBelow = sel.startLineNumber > editRange.endLineNumber;
                        if (!selIsAbove and !selIsBelow) {
                            foundEditNearSel = true;
                            break;
                        }
                    }
                    if (!foundEditNearSel) {
                        editsAreNearCursors = false;
                        break;
                    }
                }
            }

            if (editsAreNearCursors) {
                for (self._trimAutoWhitespaceLines) |trimLineNumber| {
                    const maxLineColumn = self.getLineMaxColumn(trimLineNumber);

                    var allowTrimLine = true;
                    for (incomingEdits.items) |edit| {
                        const editRange = edit.range;
                        const editText = edit.text;

                        if (trimLineNumber < editRange.startLineNumber or trimLineNumber > editRange.endLineNumber) {
                            // `trimLine` is completely outside this edit
                            continue;
                        }

                        // At this point:
                        //   editRange.startLineNumber <= trimLine <= editRange.endLineNumber

                        if (trimLineNumber == editRange.startLineNumber and editRange.startColumn == maxLineColumn and editRange.isEmpty() and editText and editText.len > 0 and editText[0] == '\n') {
                            // This edit inserts a new line (and maybe other text) after `trimLine`
                            continue;
                        }

                        if (trimLineNumber == editRange.startLineNumber and editRange.startColumn == 1 and editRange.isEmpty() and editText and editText.len > 0 and editText[editText.len - 1] == '\n') {
                            // This edit inserts a new line (and maybe other text) before `trimLine`
                            continue;
                        }

                        // Looks like we can't trim this line as it would interfere with an incoming edit
                        allowTrimLine = false;
                        break;
                    }

                    if (allowTrimLine) {
                        const trimRange = Range.init(trimLineNumber, 1, trimLineNumber, maxLineColumn);
                        try editOperations.append(ValidAnnotatedEditOperation{
                            .range = trimRange,
                            .text = null,
                            .forceMoveMarkers = false,
                            .isAutoWhitespaceEdit = false,
                            .isTracked = false,
                        });
                    }
                }
            }

            self._trimAutoWhitespaceLines = null;
        }
        if (self._initialUndoRedoSnapshot == null) {
            self._initialUndoRedoSnapshot = self._undoRedoService.createSnapshot(self.uri());
        }
        return self._commandManager.pushEditOperation(beforeCursorState, editOperations, cursorStateComputer, group);
    }

    pub fn _applyUndo(self: *TextModel, changes: []TextChange, eol: EOL, resultingAlternativeVersionId: i64, resultingSelection: ?[]Selection) void {
        const edits = ArrayList(TextChange).init(self.getAllocator());
        for (changes) |change| {
            const rangeStart = self.getOffsetAt(change.newPosition);
            const rangeEnd = rangeStart + change.newText.len;
            try edits.append(.{
                .range = Range.init(rangeStart.lineNumber, rangeStart.column, rangeEnd.lineNumber, rangeEnd.column),
                .text = change.oldText,
            });
        }
        self._applyUndoRedoEdits(edits, eol, true, false, resultingAlternativeVersionId, resultingSelection);
    }

    pub fn _applyRedo(self: *TextModel, changes: []TextChange, eol: EOL, resultingAlternativeVersionId: i64, resultingSelection: ?[]Selection) void {
        const edits = ArrayList(SingleEditOperation).init(self.getAllocator());
        for (changes) |change| {
            const rangeStart = self.getOffsetAt(change.oldPosition);
            const rangeEnd = rangeStart + change.oldText.len;
            try edits.append(.{
                .range = Range.init(rangeStart.lineNumber, rangeStart.column, rangeEnd.lineNumber, rangeEnd.column),
                .text = change.newText,
            });
        }
        self._applyUndoRedoEdits(edits, eol, false, true, resultingAlternativeVersionId, resultingSelection);
    }

    fn _applyUndoRedoEdits(self: *TextModel, edits: ArrayList(SingleEditOperation), eol: EOL, isUndoing: bool, isRedoing: bool, resultingAlternativeVersionId: i64, resultingSelection: ?[]Selection) void {
        // this._onDidChangeDecorations.beginDeferredEmit();
        // this._eventEmitter.beginDeferredEmit();
        self._isUndoing = isUndoing;
        self._isRedoing = isRedoing;
        self.applyEdits(edits, false);
        self.setEOL(eol);
        self._overwriteAlternativeVersionId(resultingAlternativeVersionId);
        _ = resultingSelection;
    }

    pub fn getAllocator(self: *const TextModel) Allocator {
        return self._buffer.getAllocator();
    }

    fn _emitContentChangedEvent(self: *TextModel, rawChange: ModelRawContentChangedEvent, change: ModelContentChangedEvent) void {
        if (self.__isDisposing) {
            // Do not confuse listeners by emitting any event after disposing
            return;
        }
        _ = rawChange;
        _ = change;
        // self._tokenizationTextModelPart.handleDidChangeContent(change);
        // self._bracketPairs.handleDidChangeContent(change);
        // self._eventEmitter.fire(new InternalModelContentChangeEvent(rawChange, change));
    }

    fn _createContentChanged2(self: *TextModel, range: Range, rangeOffset: usize, rangeLength: usize, rangeEndPosition: Position, text: []const u8, isUndoing: bool, isRedoing: bool, isFlush: bool, isEolChange: bool) ModelContentChangedEvent {
        _ = rangeEndPosition;
        return ModelContentChangedEvent{
            .changes = &[_]ModelContentChange{.{
                .range = range,
                .rangeOffset = rangeOffset,
                .rangeLength = rangeLength,
                .text = text,
            }},
            .eol = self._buffer.getEOL(),
            .isEolChange = isEolChange,
            .versionId = self.getVersionId(),
            .isUndoing = isUndoing,
            .isRedoing = isRedoing,
            .isFlush = isFlush,
        };
    }

    pub fn setEOL(self: *TextModel, eol: EOL) void {
        if (self._buffer.getEOL() == eol) {
            // Nothing to do
            return;
        }

        const oldFullModelRange = self.getFullModelRange();
        const oldModelValueLength = self.getValueLengthInRange(oldFullModelRange, EndOfLinePreference.TextDefined);
        const endLineNumber = self.getLineCount();
        const endColumn = self.getLineMaxColumn(endLineNumber);

        self._onBeforeEOLChange();
        self._buffer.setEOL(eol);
        self._increaseVersionId();
        self._onAfterEOLChange();

        self._emitContentChangedEvent(ModelRawContentChangedEvent.init(&[_]ModelRawChange{ModelRawChange{ .eolChanged = ModelRawEOLChanged.init() }}, self._versionId, false, false), self._createContentChanged2(Range.init(1, 1, endLineNumber, endColumn), 0, oldModelValueLength, Position.init(endLineNumber, endColumn), self.getValue(), false, false, false, true));
    }

    fn _onBeforeEOLChange(self: *TextModel) void {
        // Ensure all decorations get their `range` set.
        self._decorationsTree.ensureAllNodesHaveRanges(&self);
    }

    fn _onAfterEOLChange(self: *TextModel) void {
        // Transform back `range` to offsets
        const versionId = self.getVersionId();
        const allDecorations = self._decorationsTree.collectNodesPostOrder();
        for (allDecorations) |node| {
            const range = node.range.?; // the range is defined due to `_onBeforeEOLChange`

            const delta = node.cachedAbsoluteStart - node.start;

            const startOffset = self._buffer.getOffsetAt(range.startLineNumber, range.startColumn);
            const endOffset = self._buffer.getOffsetAt(range.endLineNumber, range.endColumn);

            node.cachedAbsoluteStart = startOffset;
            node.cachedAbsoluteEnd = endOffset;
            node.cachedVersionId = versionId;

            node.start = startOffset - delta;
            node.end = endOffset - delta;

            recomputeMaxEnd(node);
        }
    }

    pub fn applyEdits(self: *TextModel, rawOperations: []IdentifiedSingleEditOperation, computeUndoEdits: bool) !ArrayList(ValidEditOperation) {
        const operations = self._validateEditOperations(rawOperations);
        defer operations.deinit();
        return try self._doApplyEdits(operations.items, computeUndoEdits);
    }

    fn _doApplyEdits(self: *TextModel, rawOperations: []ValidAnnotatedEditOperation, computeUndoEdits: bool) !ArrayList(ValidEditOperation) {
        const allocator = self.getAllocator();
        const oldLineCount = self._buffer.getLineCount();
        const result = try self._buffer.applyEdits(rawOperations, self._options.trimAutoWhitespace, computeUndoEdits);
        const newLineCount = self._buffer.getLineCount();

        const contentChanges = result.changes.items;
        self._trimAutoWhitespaceLines = result.trimAutoWhitespaceLineNumbers;

        if (contentChanges.len > 0) {
            // We do a first pass to update decorations
            // because we want to read decorations in the second pass
            // where we will emit content change events
            // and we want to read the final decorations
            for (contentChanges) |change| {
                self._decorationsTree.acceptReplace(change.rangeOffset, change.rangeLength, change.text.len, change.forceMoveMarkers);
            }

            var rawContentChanges = ArrayList(ModelRawChange).init(allocator);
            defer rawContentChanges.deinit();

            self._increaseVersionId();

            var lineCount = oldLineCount;
            for (contentChanges) |change| {
                const res = countEOL(change.text);
                const eolCount = res.eolCount;
                //self._onDidChangeDecorations.fire();

                const startLineNumber = change.range.startLineNumber;
                const endLineNumber = change.range.endLineNumber;

                const deletingLinesCnt: usize = endLineNumber - startLineNumber;
                const insertingLinesCnt = eolCount;
                const editingLinesCnt: usize = @min(deletingLinesCnt, insertingLinesCnt);

                const changeLineCountDelta: usize = (insertingLinesCnt - deletingLinesCnt);

                const currentEditStartLineNumber: usize = newLineCount - lineCount - changeLineCountDelta + startLineNumber;
                const firstEditLineNumber: usize = currentEditStartLineNumber;
                const lastInsertedLineNumber: usize = currentEditStartLineNumber + insertingLinesCnt;

                const decorationsWithInjectedTextInEditedRange = self._decorationsTree.getInjectedTextInInterval(self, self.getOffsetAt(Position.init(firstEditLineNumber, 1)), self.getOffsetAt(Position.init(lastInsertedLineNumber, self.getLineMaxColumn(lastInsertedLineNumber))), 0);

                const injectedTextInEditedRange = try LineInjectedText.fromDecorations(allocator, decorationsWithInjectedTextInEditedRange);
                defer injectedTextInEditedRange.deinit();

                {
                    var injectedTextInEditedRangeQueue = ArrayQueue(LineInjectedText).init(injectedTextInEditedRange.items);

                    var j: usize = editingLinesCnt;
                    while (j >= 0) : (j -= 1) {
                        const editLineNumber = startLineNumber + j;
                        const currentEditLineNumber = currentEditStartLineNumber + j;

                        _ = injectedTextInEditedRangeQueue.takeFromEndWhile(usize, currentEditLineNumber, struct {
                            fn predicate(ctx: usize, r: LineInjectedText) bool {
                                return r.lineNumber > ctx;
                            }
                        }.predicate);
                        const decorationsInCurrentLine = injectedTextInEditedRangeQueue.takeFromEndWhile(usize, currentEditLineNumber, struct {
                            fn predicate(ctx: usize, r: LineInjectedText) bool {
                                return r.lineNumber == ctx;
                            }
                        }.predicate);

                        try rawContentChanges.append(ModelRawLineChanged.init(
                            editLineNumber,
                            self.getLineContent(editLineNumber),
                            decorationsInCurrentLine,
                        ));
                    }
                }

                if (editingLinesCnt < deletingLinesCnt) {
                    // Must delete some lines
                    const spliceStartLineNumber = startLineNumber + editingLinesCnt;
                    try rawContentChanges.append(ModelRawLinesDeleted.init(spliceStartLineNumber + 1, endLineNumber));
                }

                if (editingLinesCnt < insertingLinesCnt) {
                    var injectedTextInEditedRangeQueue = ArrayQueue(LineInjectedText).init(injectedTextInEditedRange.items);
                    // Must insert some lines
                    const spliceLineNumber = startLineNumber + editingLinesCnt;
                    const cnt = insertingLinesCnt - editingLinesCnt;
                    const fromLineNumber = newLineCount - lineCount - cnt + spliceLineNumber + 1;
                    var injectedTexts = ArrayList(?[]LineInjectedText).init(allocator);
                    var newLines = ArrayList([]const u8).init(allocator);
                    var i = 0;
                    while (i < cnt) : (i += 1) {
                        const lineNumber = fromLineNumber + i;
                        try newLines.append(try self.getLineContent(lineNumber));

                        _ = injectedTextInEditedRangeQueue.takeWhile(usize, lineNumber, struct {
                            fn predicate(ctx: usize, r: LineInjectedText) bool {
                                return r.lineNumber < ctx;
                            }
                        }.predicate);
                        try injectedTexts.append(injectedTextInEditedRangeQueue.takeWhile(usize, lineNumber, struct {
                            fn predicate(ctx: usize, r: LineInjectedText) bool {
                                return r.lineNumber == ctx;
                            }
                        }.predicate));
                    }

                    try rawContentChanges.append(ModelRawLinesInserted.init(spliceLineNumber + 1, startLineNumber + insertingLinesCnt, newLines.items, injectedTexts.items));
                }

                lineCount += changeLineCountDelta;
            }

            self._emitContentChangedEvent(
                ModelRawContentChangedEvent.init(rawContentChanges.items, self.getVersionId(), self._isUndoing, self._isRedoing),
                ModelContentChangedEvent{ .changes = contentChanges, .eol = self._buffer.getEOL(), .isEolChange = false, .versionId = self.getVersionId(), .isUndoing = self._isUndoing, .isRedoing = self._isRedoing, .isFlush = false },
            );
        }

        return if (result.reverseEdits == null) null else result.reverseEdits;
    }

    pub fn undo(self: *TextModel) void {
        self._undoRedoService.undo(self.uri());
    }

    pub fn canUndo(self: *TextModel) bool {
        return self._undoRedoService.canUndo(self.uri());
    }

    pub fn redo(self: *TextModel) void {
        self._undoRedoService.redo(self.uri());
    }

    pub fn canRedo(self: *TextModel) bool {
        return self._undoRedoService.canRedo(self.uri());
    }
};

pub fn indentOfLine(line: []const u8) usize {
    var indent: usize = 0;
    for (line) |c| {
        if (c == ' ' or c == '\t') {
            indent += 1;
        } else {
            break;
        }
    }
    return indent;
}

pub const DecorationsTrees = struct {

    // This tree holds decorations that do not show up in the overview ruler.
    _decorationsTree0: IntervalTree,

    // This tree holds decorations that show up in the overview ruler.
    _decorationsTree1: IntervalTree,

    // This tree holds decorations that contain injected text.
    _injectedTextDecorationsTree: IntervalTree,

    pub fn init() DecorationsTrees {
        return DecorationsTrees{
            ._decorationsTree0 = IntervalTree.init(),
            ._decorationsTree1 = IntervalTree.init(),
            ._injectedTextDecorationsTree = IntervalTree.init(),
        };
    }

    fn ensureAllNodesHaveRanges(self: *DecorationsTrees, model: *TextModel) void {
        _ = self;
        _ = model;
    }
    fn collectNodesPostOrder(self: *DecorationsTrees) []IntervalNode {
        _ = self;
        return &[_]IntervalNode{};
    }

    fn acceptReplace(self: *DecorationsTrees, rangeOffset: usize, rangeLength: usize, textLength: usize, forceMoveMarkers: bool) void {
        _ = self;
        _ = rangeOffset;
        _ = rangeLength;
        _ = textLength;
        _ = forceMoveMarkers;
    }

    fn getInjectedTextInInterval(self: *DecorationsTrees, model: *TextModel, start: usize, end: usize, maxLength: usize) []ModelDecoration {
        _ = self;
        _ = model;
        _ = start;
        _ = end;
        _ = maxLength;
        return &[_]ModelDecoration{};
    }
};

pub fn createTextBuffer(allocator: Allocator, source: io.AnyReader, defaultEOL: EOL) !PieceTreeTextBuffer {
    const factory = try createTextBufferFactory(allocator, source);
    return try factory.create(defaultEOL);
}

var readerBuffer: [65535]u8 = undefined;
fn createTextBufferFactory(allocator: Allocator, reader: io.AnyReader) !PieceTreeTextBufferFactory {
    const builder = PieceTreeBufferBuilder.init(allocator);
    while (true) {
        const len = try reader.readAll(&readerBuffer);
        if (len == 0) {
            break;
        }
        try builder.acceptChunk(readerBuffer[0..len]);
    }
    return try builder.finish(false);
}
