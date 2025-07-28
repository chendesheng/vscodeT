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
const ModelDecorationOptions = Model.ModelDecorationOptions;
const ModelDeltaDecoration = Model.ModelDeltaDecoration;
const SearchData = Model.SearchData;
const FindMatch = Model.FindMatch;
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
const guessIndentation = @import("indentationGuesser.zig").guessIndentation;
const GuessedIndentation = @import("indentationGuesser.zig").GuessedIndentation;
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
const ModelDecorationsChangedEvent = @import("textModelEvents.zig").ModelDecorationsChangedEvent;
const InternalModelContentChangeEvent = @import("textModelEvents.zig").InternalModelContentChangeEvent;
const ModelOptionsChangedEvent = @import("textModelEvents.zig").ModelOptionsChangedEvent;
const ModelInjectedTextChangedEvent = @import("textModelEvents.zig").ModelInjectedTextChangedEvent;
const ModelLineHeightChangedEvent = @import("textModelEvents.zig").ModelLineHeightChangedEvent;
const ModelLineHeightChanged = @import("textModelEvents.zig").ModelLineHeightChanged;
const ArrayQueue = @import("ArrayQueue.zig").ArrayQueue;
const Set = @import("Set.zig").Set;
const SetWithKey = @import("Set.zig").SetWithKey;
const Emitter = @import("event.zig").Emitter;
const IndentSize = Model.IndentSize;
const TrackedRangeStickiness = Model.TrackedRangeStickiness;
const cleanClassName = Model.cleanClassName;
const ModelDecorationOverviewRulerOptions = Model.ModelDecorationOverviewRulerOptions;
const ModelDecorationMinimapOptions = Model.ModelDecorationMinimapOptions;
const ModelDecorationGlyphMarginOptions = Model.ModelDecorationGlyphMarginOptions;
const InjectedTextOptions = Model.InjectedTextOptions;
const InjectedTextCursorStops = Model.InjectedTextCursorStops;
const utils = @import("utils.zig");
const Rg = @import("range.zig");
const SearchParams = @import("textModelSearch.zig").SearchParams;
const TextModelSearch = @import("textModelSearch.zig").TextModelSearch;
const String = @import("strings.zig").String;

const LIMIT_FIND_COUNT = 999;
const LONG_LINE_BOUNDARY = 10000;
const LINE_HEIGHT_CEILING = 300;

const StringOffsetValidationType = enum {
    // Even allowed in utf8 codepoint
    Relaxed,
    // Not allowed in utf8 codepoint
    Strict,
};

const TRACKED_RANGE_OPTIONS = [_]*const ModelDecorationOptions{
    &ModelDecorationOptions.init("tracked-range-always-grows-when-typing-at-edges", TrackedRangeStickiness.AlwaysGrowsWhenTypingAtEdges),
    &ModelDecorationOptions.init("tracked-range-never-grows-when-typing-at-edges", TrackedRangeStickiness.NeverGrowsWhenTypingAtEdges),
    &ModelDecorationOptions.init("tracked-range-grows-only-when-typing-before", TrackedRangeStickiness.GrowsOnlyWhenTypingBefore),
    &ModelDecorationOptions.init("tracked-range-grows-only-when-typing-after", TrackedRangeStickiness.GrowsOnlyWhenTypingAfter),
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
        defer result.deinit();

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

    id: []const u8,
    isForSimpleWidget: bool,
    _associatedResource: Uri,
    _attachedEditorCount: usize,
    _buffer: PieceTreeTextBuffer,
    _options: TextModelResolvedOptions,
    // languageSelectionListener: MutableDisposable(IDisposable),

    __isDisposing: bool,
    _versionId: u32,
    _alternativeVersionId: u32,
    _initialUndoRedoSnapshot: ?ResourceEditStackSnapshot,
    _isTooLargeForSyncing: bool,
    _isTooLargeForTokenization: bool,
    _isTooLargeForHeapOperation: bool,

    //#region Editing
    _commandManager: EditStack,
    _isUndoing: bool,
    _isRedoing: bool,
    _trimAutoWhitespaceLines: ?ArrayList(usize),
    //#endregion

    //#region Decorations
    // Used to workaround broken clients that might attempt using a decoration id generated by a different model.
    // It is not globally unique in order to limit it to one character.
    _instanceId: u8,
    _deltaDecorationCallCnt: usize,
    _lastDecorationId: u32,
    _decorations: std.AutoHashMap(u64, *IntervalNode),
    _decorationsTree: DecorationsTrees,
    // _decorationProvider: ColorizedBracketPairsDecorationProvider,
    //#endregion

    _undoRedoService: *UndoRedoService,
    //#region Events
    _onWillDispose: Emitter(void),
    _onDidChangeDecorations: DidChangeDecorationsEmitter,
    _onDidChangeOptions: Emitter(ModelOptionsChangedEvent),
    _onDidChangeAttached: Emitter(void),
    _onDidChangeInjectedText: Emitter(ModelInjectedTextChangedEvent),
    _onDidChangeLineHeight: Emitter(ModelLineHeightChangedEvent),
    _eventEmitter: DidChangeContentEmitter,
    //#endregion

    pub fn resolveOptions(textBuffer: *PieceTreeTextBuffer, options: TextModelCreationOptions) TextModelResolvedOptions {
        if (options.detectIndentation) {
            const guessedIndentation = guessIndentation(textBuffer, options.tabSize, options.insertSpaces) catch GuessedIndentation{
                .tabSize = options.tabSize,
                .insertSpaces = options.insertSpaces,
            };
            return TextModelResolvedOptions.init(
                guessedIndentation.tabSize,
                .{ .tabSize = 1 }, // TODO@Alex: guess indentSize independent of tabSize
                guessedIndentation.insertSpaces,
                options.defaultEOL,
                options.trimAutoWhitespace,
                options.bracketPairColorizationOptions,
            );
        }

        return TextModelResolvedOptions.init(
            options.tabSize,
            options.indentSize,
            options.insertSpaces,
            options.defaultEOL,
            options.trimAutoWhitespace,
            options.bracketPairColorizationOptions,
        );
    }

    pub fn onWillDispose(self: *TextModel, callback: fn () void) !void {
        try self._onWillDispose.event(callback);
    }

    pub fn onDidChangeOptions(self: *TextModel, callback: fn (ModelOptionsChangedEvent) void) !void {
        try self._onDidChangeOptions.event(callback);
    }

    pub fn onDidChangeAttached(self: *TextModel, callback: fn () void) !void {
        try self._onDidChangeAttached.event(callback);
    }

    pub fn onDidChangeInjectedText(self: *TextModel, callback: fn (ModelInjectedTextChangedEvent) void) !void {
        try self._onDidChangeInjectedText.event(callback);
    }

    pub fn onDidChangeLineHeight(self: *TextModel, callback: fn (ModelLineHeightChangedEvent) void) !void {
        try self._onDidChangeLineHeight.event(callback);
    }

    pub fn onDidChangeContent(self: *TextModel, callback: fn (ModelContentChangedEvent) void) !void {
        try self._eventEmitter.slowEvent({}, struct {
            fn cb(evt: InternalModelContentChangeEvent, ctx: void) void {
                _ = ctx;
                callback(evt.contentChangedEvent);
            }
        }.cb);
    }

    pub fn init(allocator: Allocator, source: io.AnyReader, creationOptions: TextModelCreationOptions, associatedResource: ?Uri, undoRedoService: *UndoRedoService) !*TextModel {
        MODEL_ID += 1;
        var buffer = try createTextBuffer(allocator, source, creationOptions.defaultEOL);
        const bufferLineCount = buffer.getLineCount();
        const bufferTextLength = buffer.getValueLengthInRange(Range.init(1, 1, bufferLineCount, buffer.getLineLength(bufferLineCount) + 1), .TextDefined);

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

        const model = try allocator.create(TextModel);
        model.* = TextModel{
            .id = try fmt.allocPrint(allocator, "$model{d}", .{MODEL_ID}),
            .isForSimpleWidget = creationOptions.isForSimpleWidget,
            ._associatedResource = if (associatedResource) |url| url else .{
                .scheme = "inmemory",
                .user = null,
                .password = null,
                .host = .{ .raw = "model" },
                .port = null,
                .path = .{ .raw = try fmt.allocPrint(allocator, "/{d}", .{MODEL_ID}) },
                .query = null,
                .fragment = null,
            },
            ._attachedEditorCount = 0,
            ._buffer = buffer,
            ._options = resolveOptions(&buffer, creationOptions),
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
            ._decorations = std.AutoHashMap(u64, *IntervalNode).init(allocator),
            ._decorationsTree = DecorationsTrees.init(allocator),
            ._commandManager = EditStack.init(model, undoRedoService),
            ._isUndoing = false,
            ._isRedoing = false,
            ._trimAutoWhitespaceLines = null,

            ._undoRedoService = undoRedoService,

            ._onWillDispose = Emitter(void).init(allocator),
            ._onDidChangeDecorations = DidChangeDecorationsEmitter.init(allocator, model, struct {
                fn handle(m: *anyopaque, affectedInjectedTextLines: ?Set(usize), affectedLineHeights: ?SetWithKey(LineHeightChangingDecoration)) !void {
                    const m1: *TextModel = @ptrCast(@alignCast(m));
                    try m1.handleBeforeFireDecorationsChangedEvent(affectedInjectedTextLines, affectedLineHeights);
                }
            }.handle),
            ._onDidChangeOptions = Emitter(ModelOptionsChangedEvent).init(allocator),
            ._onDidChangeAttached = Emitter(void).init(allocator),
            ._onDidChangeInjectedText = Emitter(ModelInjectedTextChangedEvent).init(allocator),
            ._onDidChangeLineHeight = Emitter(ModelLineHeightChangedEvent).init(allocator),
            ._eventEmitter = DidChangeContentEmitter.init(allocator),
        };
        return model;
    }

    pub fn deinit(self: *TextModel) void {
        const allocator = self._buffer.getAllocator();
        self._buffer.deinit();
        self._decorations.deinit();
        if (self._initialUndoRedoSnapshot) |*snapshot| {
            snapshot.deinit();
        }
        allocator.free(self.id);
        switch (self._associatedResource.path) {
            .raw => |raw| allocator.free(raw),
            .percent_encoded => |percent_encoded| allocator.free(percent_encoded),
        }
        self._onWillDispose.deinit();
        self._onDidChangeDecorations.deinit();
        self._onDidChangeInjectedText.deinit();
        self._onDidChangeLineHeight.deinit();
        self._eventEmitter.deinit();
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
        self._options = newOpts;

        // this._bracketPairs.handleDidChangeOptions(e);
        // this._decorationProvider.handleDidChangeOptions(e);
        self._onDidChangeOptions.fire(e);
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

    pub fn getVersionId(self: *const TextModel) u32 {
        return self._versionId;
    }

    pub fn mightContainRTL(self: *const TextModel) bool {
        return self._buffer.getMightContainRTL();
    }

    pub fn mightContainUnusualLineTerminators(self: *const TextModel) bool {
        return self._buffer.getMightContainUnusualLineTerminators();
    }

    pub fn removeUnusualLineTerminators(self: *TextModel, selections: ?[]const Selection) !void {
        const matches = try self.findMatches(strings.UNUSUAL_LINE_TERMINATORS, null, true, false, null, false, std.math.maxInt(usize));
        defer matches.deinit();

        self._buffer.resetMightContainUnusualLineTerminators();

        var editOperations = ArrayList(IdentifiedSingleEditOperation).init(self.getAllocator());
        defer editOperations.deinit();
        for (matches.items) |match| {
            try editOperations.append(IdentifiedSingleEditOperation.init(match.range, null));
        }
        try self.pushEditOperations(selections, editOperations.items, null, null);
    }

    pub fn mightContainNonBasicASCII(self: *const TextModel) bool {
        return self._buffer.getMightContainNonBasicASCII();
    }

    pub fn getAlternativeVersionId(self: *const TextModel) u32 {
        return self._alternativeVersionId;
    }

    pub fn getInitialUndoRedoSnapshot(self: *const TextModel) ?ResourceEditStackSnapshot {
        return self._initialUndoRedoSnapshot;
    }

    pub fn getOffsetAt(self: *const TextModel, position: Position) usize {
        return self._buffer.getOffsetAt(position.lineNumber, position.column);
    }

    pub fn getPositionAt(self: *const TextModel, rawOffset: usize) Position {
        const offset = utils.clamp(rawOffset, 0, self._buffer.getLength());
        return self._buffer.getPositionAt(offset);
    }

    fn _increaseVersionId(self: *TextModel) void {
        self._versionId += 1;
        self._alternativeVersionId = self._versionId;
    }

    pub fn _overwriteVersionId(self: *TextModel, versionId: u32) void {
        self._versionId = versionId;
    }

    pub fn _overwriteAlternativeVersionId(self: *TextModel, versionId: u32) void {
        self._alternativeVersionId = versionId;
    }

    pub fn _overwriteInitialUndoRedoSnapshot(self: *TextModel, snapshot: ResourceEditStackSnapshot) void {
        self._initialUndoRedoSnapshot = snapshot;
    }

    pub fn getValue(self: *TextModel, eol: ?EndOfLinePreference, preserveBOM: bool) !ArrayList(u8) {
        if (self.isTooLargeForHeapOperation()) {
            return error.OperationWouldExceedHeapMemoryLimits;
        }

        const fullModelRange = self.getFullModelRange();
        var fullModelValue = try self.getValueInRange(fullModelRange, eol);

        if (preserveBOM) {
            try fullModelValue.insertSlice(0, self._buffer.getBOM());
        }

        return fullModelValue;
    }

    pub fn createSnapshot(self: *TextModel, preserveBOM: bool) !TextModelSnapshot {
        return TextModelSnapshot.init(try self._buffer.createSnapshot(preserveBOM));
    }

    pub fn getValueLength(self: *TextModel, eol: ?EndOfLinePreference, preserveBOM: bool) usize {
        const fullModelRange = self.getFullModelRange();
        const fullModelValue = self.getValueLengthInRange(fullModelRange, eol);

        if (preserveBOM) {
            return self._buffer.getBOM().length + fullModelValue;
        }

        return fullModelValue;
    }

    pub fn getValueInRange(self: *TextModel, rawRange: Range, eol: ?EndOfLinePreference) !ArrayList(u8) {
        return try self._buffer.getValueInRange(self.validateRange(rawRange), eol orelse EndOfLinePreference.TextDefined);
    }

    pub fn getValueLengthInRange(self: *TextModel, rawRange: Range, eol: ?EndOfLinePreference) usize {
        return self._buffer.getValueLengthInRange(self.validateRange(rawRange), eol orelse EndOfLinePreference.TextDefined);
    }

    pub fn getCharacterCountInRange(self: *TextModel, rawRange: Range, eol: ?EndOfLinePreference) usize {
        return self._buffer.getCharacterCountInRange(self.validateRange(rawRange), eol orelse EndOfLinePreference.TextDefined);
    }

    pub fn getLineCount(self: *const TextModel) usize {
        return self._buffer.getLineCount();
    }

    pub fn getLineContent(self: *TextModel, lineNumber: usize) !ArrayList(u8) {
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

    pub fn getLinesContent(self: *const TextModel) !ArrayList(ArrayList(u8)) {
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
            unreachable;
        }
        return self._buffer.getLineLength(lineNumber) + 1; // add 1 for the line break
    }

    pub fn getLineFirstNonWhitespaceColumn(self: *const TextModel, lineNumber: usize) usize {
        if (lineNumber < 1 or lineNumber > self.getLineCount()) {
            unreachable;
        }
        return self._buffer.getLineFirstNonWhitespaceColumn(lineNumber);
    }

    pub fn getLineLastNonWhitespaceColumn(self: *const TextModel, lineNumber: usize) usize {
        if (lineNumber < 1 or lineNumber > self.getLineCount()) {
            unreachable;
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

        if (validationType == StringOffsetValidationType.Strict) {
            // !!At this point, column > 1
            const rangeBefore = self._buffer.getLineCodepointRange(lineNumber, column - 2);
            return rangeBefore[1] < column;
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

        if (validationType == StringOffsetValidationType.Strict) {
            // If the position would end up in the middle of a high-low surrogate pair,
            // we move it to before the pair
            // !!At this point, column > 1
            const range = self._buffer.getLineCodepointRange(lineNumber, column - 1);
            return Position.init(lineNumber, range[0] + 1);
        }

        return Position.init(lineNumber, column);
    }

    pub fn validatePosition(self: *TextModel, position: Position) Position {
        const validationType = StringOffsetValidationType.Strict;

        // most likely case
        if (self._isValidPosition(position.lineNumber, position.column, validationType)) {
            return position;
        }

        return self._validatePosition(position.lineNumber, position.column, validationType);
    }

    pub fn isValidRange(self: *TextModel, range: Range) bool {
        return self._isValidRange(range, StringOffsetValidationType.Strict);
    }

    fn _isValidRange(self: *TextModel, range: Range, validationType: StringOffsetValidationType) bool {
        const startLineNumber = range.startLineNumber;
        const startColumn = range.startColumn;
        const endLineNumber = range.endLineNumber;
        const endColumn = range.endColumn;

        if (!self._isValidPosition(startLineNumber, startColumn, validationType)) {
            return false;
        }
        if (!self._isValidPosition(endLineNumber, endColumn, validationType)) {
            return false;
        }

        return true;
    }

    pub fn validateRange(self: *TextModel, _range: Range) Range {
        const validationType = StringOffsetValidationType.Strict;

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

        if (validationType == StringOffsetValidationType.Strict) {
            const startCodepointRange = self._buffer.getLineCodepointRange(startLineNumber, startColumn - 1);
            const endCodepointRange = self._buffer.getLineCodepointRange(endLineNumber, endColumn - 1);
            return Range.init(startLineNumber, startCodepointRange[0] + 1, endLineNumber, endCodepointRange[1] + 1);
        }

        return Range.init(startLineNumber, startColumn, endLineNumber, endColumn);
    }

    pub fn modifyPosition(self: *TextModel, rawPosition: Position, offset: usize) Position {
        const candidate = self.getOffsetAt(rawPosition) + offset;
        return self.getPositionAt(candidate);
    }

    pub fn getFullModelRange(self: *TextModel) Range {
        const lineCount = self.getLineCount();
        return Range.init(1, 1, lineCount, self.getLineMaxColumn(lineCount));
    }

    pub fn findMatchesLineByLine(self: *TextModel, searchRange: Range, searchData: SearchData, captureMatches: bool, limitResultCount: usize) !ArrayList(FindMatch) {
        return self._buffer.findMatchesLineByLine(searchRange, searchData, captureMatches, limitResultCount);
    }

    pub fn findMatches(self: *TextModel, searchString: []const u8, rawSearchScope: ?[]Range, isRegex: bool, matchCase: bool, wordSeparators: ?[]u8, captureMatches: bool, limitResultCount: usize) !ArrayList(FindMatch) {
        const allocator = self.getAllocator();
        var searchRanges = ArrayList(Range).init(allocator);
        defer searchRanges.deinit();

        if (rawSearchScope) |rawSearchRanges| {
            for (rawSearchRanges) |rawSearchRange| {
                const searchRange = self.validateRange(rawSearchRange);
                try searchRanges.append(searchRange);
            }
        }

        if (searchRanges.items.len == 0) {
            try searchRanges.append(self.getFullModelRange());
        }

        std.sort.heap(Range, searchRanges.items, struct {
            fn lessThan(d1: Range, d2: Range) bool {
                return d1.lessThan(&d2);
            }
        }.lessThan);

        const uniqueSearchRanges = ArrayList(Range).init(allocator);
        defer uniqueSearchRanges.deinit();

        for (searchRanges.items) |searchRange| {
            if (uniqueSearchRanges.items.len > 0) {
                const lastUnique = &uniqueSearchRanges.items[uniqueSearchRanges.items.len - 1];
                if (Rg.areIntersecting(lastUnique, &searchRange)) {
                    lastUnique.* = lastUnique.plusRange(&searchRange);
                    continue;
                }
            }

            try uniqueSearchRanges.append(searchRange);
        }

        var result = ArrayList(FindMatch).init(allocator);
        if (!isRegex and !strings.containsLF(searchString)) {
            // not regex, not multi line
            const searchParams = SearchParams.init(searchString, isRegex, matchCase, wordSeparators);
            const searchData = try searchParams.parseSearchRequest(allocator);

            if (!searchData) {
                return result;
            }

            for (uniqueSearchRanges.items) |searchRange| {
                // FIXME: limitResultCount seems wrong here
                const tmp = try self.findMatchesLineByLine(searchRange, searchData, captureMatches, limitResultCount);
                defer tmp.deinit();
                try result.appendSlice(tmp.items);
            }
        } else {
            for (uniqueSearchRanges.items) |searchRange| {
                const searchParams = SearchParams.init(searchString, isRegex, matchCase, wordSeparators);
                // FIXME: limitResultCount seems wrong here
                const tmp = try TextModelSearch.findMatches(self, searchParams, searchRange, captureMatches, limitResultCount);
                defer tmp.deinit();
                try result.appendSlice(tmp.items);
            }
        }

        return result;
    }

    pub fn findNextMatch(self: *TextModel, searchString: []const u8, rawSearchStart: Position, isRegex: bool, matchCase: bool, wordSeparators: ?[]u8, captureMatches: bool) !?FindMatch {
        const searchStart = self.validatePosition(rawSearchStart);

        if (!isRegex and !strings.containsLF(searchString)) {
            const searchParams = SearchParams.init(searchString, isRegex, matchCase, wordSeparators);
            if (try searchParams.parseSearchRequest(self.getAllocator())) |searchData| {
                defer searchData.regex.deinit();

                const lineCount = self.getLineCount();
                const searchRange = Range.init(searchStart.lineNumber, searchStart.column, lineCount, self.getLineMaxColumn(lineCount));
                const ret = try self.findMatchesLineByLine(searchRange, searchData, captureMatches, 1);
                defer ret.deinit();
                // FIXME: what is this for?
                _ = try TextModelSearch.findNextMatch(self, SearchParams.init(searchString, isRegex, matchCase, wordSeparators), searchStart, captureMatches);
                if (ret.items.len > 0) {
                    return ret.items[0];
                }

                const searchRange2 = Range.init(1, 1, searchStart.lineNumber, self.getLineMaxColumn(searchStart.lineNumber));
                const ret2 = try self.findMatchesLineByLine(searchRange2, searchData, captureMatches, 1);
                defer ret2.deinit();

                if (ret2.items.len > 0) {
                    return ret2.items[0];
                }
            } else {
                return null;
            }
        }

        return try TextModelSearch.findNextMatch(self, SearchParams.init(searchString, isRegex, matchCase, wordSeparators), searchStart, captureMatches);
    }

    pub fn findPreviousMatch(self: *TextModel, searchString: []const u8, rawSearchStart: Position, isRegex: bool, matchCase: bool, wordSeparators: ?[]u8, captureMatches: bool) !?FindMatch {
        const searchStart = self.validatePosition(rawSearchStart);
        return try TextModelSearch.findPreviousMatch(self, SearchParams.init(searchString, isRegex, matchCase, wordSeparators), searchStart, captureMatches);
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

    fn _validateEditOperation(self: *TextModel, rawOperation: *IdentifiedSingleEditOperation) ValidAnnotatedEditOperation {
        return ValidAnnotatedEditOperation{
            .identifier = rawOperation.identifier,
            .range = self.validateRange(rawOperation.range),
            .text = if (rawOperation.text) |*text| text.move() else null,
            .forceMoveMarkers = rawOperation.forceMoveMarkers,
            .isAutoWhitespaceEdit = rawOperation.isAutoWhitespaceEdit orelse false,
            ._isTracked = rawOperation._isTracked orelse false,
        };
    }

    fn _validateEditOperations(self: *TextModel, rawOperations: []IdentifiedSingleEditOperation) !ArrayList(ValidAnnotatedEditOperation) {
        const allocator = self.getAllocator();
        var result = ArrayList(ValidAnnotatedEditOperation).init(allocator);
        for (rawOperations) |*rawOperation| {
            try result.append(self._validateEditOperation(rawOperation));
        }
        return result;
    }

    pub fn pushEditOperations(self: *TextModel, beforeCursorState: ?[]Selection, editOperations: []IdentifiedSingleEditOperation, cursorStateComputer: ?CursorStateComputer, group: ?UndoRedoGroup) !?[]Selection {
        self._onDidChangeDecorations.beginDeferredEmit();
        defer self._onDidChangeDecorations.endDeferredEmit();

        self._eventEmitter.beginDeferredEmit();
        defer self._eventEmitter.endDeferredEmit(null);

        const ops = try self._validateEditOperations(editOperations);
        defer ops.deinit();
        return try self._pushEditOperations(beforeCursorState, ops, cursorStateComputer, group);
    }

    fn _pushEditOperations(self: *TextModel, beforeCursorState: ?[]Selection, editOperations_: ArrayList(ValidAnnotatedEditOperation), cursorStateComputer: ?CursorStateComputer, group: ?UndoRedoGroup) !?[]Selection {
        var editOperations = editOperations_;
        if (self._options.trimAutoWhitespace and self._trimAutoWhitespaceLines != null) {
            // Go through each saved line number and insert a trim whitespace edit
            // if it is safe to do so (no conflicts with other edits).

            const allocator = self.getAllocator();
            var incomingEdits = ArrayList(struct {
                range: Range,
                text: ?[]const u8,
            }).init(allocator);
            defer incomingEdits.deinit();

            for (editOperations.items) |*op| {
                try incomingEdits.append(.{
                    .range = self.validateRange(op.range),
                    .text = if (op.text) |*text| text.items() else null,
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
                for (self._trimAutoWhitespaceLines.?.items) |trimLineNumber| {
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

                        if (trimLineNumber == editRange.startLineNumber and editRange.startColumn == maxLineColumn and editRange.isEmpty() and editText != null and editText.?.len > 0 and editText.?[0] == '\n') {
                            // This edit inserts a new line (and maybe other text) after `trimLine`
                            continue;
                        }

                        if (trimLineNumber == editRange.startLineNumber and editRange.startColumn == 1 and editRange.isEmpty() and editText != null and editText.?.len > 0 and editText.?[editText.?.len - 1] == '\n') {
                            // This edit inserts a new line (and maybe other text) before `trimLine`
                            continue;
                        }

                        // Looks like we can't trim this line as it would interfere with an incoming edit
                        allowTrimLine = false;
                        break;
                    }

                    if (allowTrimLine) {
                        const trimRange = Range.init(trimLineNumber, 1, trimLineNumber, maxLineColumn);
                        try editOperations.append(ValidAnnotatedEditOperation.fromRange(trimRange));
                    }
                }
            }

            self._trimAutoWhitespaceLines = null;
        }
        if (self._initialUndoRedoSnapshot == null) {
            self._initialUndoRedoSnapshot = try self._undoRedoService.createSnapshot(self.uri());
        }
        return try self._commandManager.pushEditOperation(beforeCursorState, editOperations.items, cursorStateComputer, group);
    }

    pub fn _applyUndo(self: *TextModel, changes: ArrayList(TextChange), eol: EOL, resultingAlternativeVersionId: u32, resultingSelection: ?[]Selection) !void {
        var edits = ArrayList(IdentifiedSingleEditOperation).init(self.getAllocator());
        defer edits.deinit();
        for (changes.items) |change| {
            const rangeStart = self.getPositionAt(change.newPosition);
            const rangeEnd = self.getPositionAt(change.newEnd());
            try edits.append(.{
                .range = Range.init(rangeStart.lineNumber, rangeStart.column, rangeEnd.lineNumber, rangeEnd.column),
                .text = change.oldText,
                .forceMoveMarkers = false,
                .identifier = null,
                .isAutoWhitespaceEdit = null,
                ._isTracked = null,
            });
        }
        try self._applyUndoRedoEdits(edits, eol, true, false, resultingAlternativeVersionId, resultingSelection);
    }

    pub fn _applyRedo(self: *TextModel, changes: ArrayList(TextChange), eol: EOL, resultingAlternativeVersionId: u32, resultingSelection: ?[]Selection) !void {
        var edits = ArrayList(IdentifiedSingleEditOperation).init(self.getAllocator());
        defer edits.deinit();
        for (changes.items) |change| {
            const rangeStart = self.getPositionAt(change.oldPosition);
            const rangeEnd = self.getPositionAt(change.oldEnd());
            try edits.append(.{
                .range = Range.init(rangeStart.lineNumber, rangeStart.column, rangeEnd.lineNumber, rangeEnd.column),
                .text = change.newText,
                .forceMoveMarkers = false,
                .identifier = null,
                .isAutoWhitespaceEdit = null,
                ._isTracked = null,
            });
        }
        try self._applyUndoRedoEdits(edits, eol, false, true, resultingAlternativeVersionId, resultingSelection);
    }

    fn _applyUndoRedoEdits(self: *TextModel, edits: ArrayList(IdentifiedSingleEditOperation), eol: EOL, isUndoing: bool, isRedoing: bool, resultingAlternativeVersionId: u32, resultingSelection: ?[]Selection) !void {
        self._onDidChangeDecorations.beginDeferredEmit();
        defer self._onDidChangeDecorations.endDeferredEmit();

        self._eventEmitter.beginDeferredEmit();
        defer self._eventEmitter.endDeferredEmit(null);

        self._isUndoing = isUndoing;
        defer self._isUndoing = false;

        self._isRedoing = isRedoing;
        defer self._isRedoing = false;

        _ = try self.applyEdits(edits.items, false);
        try self.setEOL(eol);
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
        // self._tokenizationTextModelPart.handleDidChangeContent(change);
        // self._bracketPairs.handleDidChangeContent(change);
        self._eventEmitter.fire(InternalModelContentChangeEvent.init(rawChange, change));
    }

    fn _createContentChanged2(self: *TextModel, range: Range, rangeOffset: usize, rangeLength: usize, rangeEndPosition: Position, text: String, isUndoing: bool, isRedoing: bool, isFlush: bool, isEolChange: bool) !ModelContentChangedEvent {
        _ = rangeEndPosition;
        var changes = ArrayList(ModelContentChange).init(self.getAllocator());
        try changes.append(.{
            .range = range,
            .rangeOffset = rangeOffset,
            .rangeLength = rangeLength,
            .text = text,
        });
        return ModelContentChangedEvent{
            .changes = changes,
            .eol = self._buffer.getEOL(),
            .isEolChange = isEolChange,
            .versionId = self.getVersionId(),
            .isUndoing = isUndoing,
            .isRedoing = isRedoing,
            .isFlush = isFlush,
        };
    }

    pub fn setEOL(self: *TextModel, eol: EOL) !void {
        if (self._buffer.getEOL() == eol) {
            // Nothing to do
            return;
        }

        const oldFullModelRange = self.getFullModelRange();
        const oldModelValueLength = self.getValueLengthInRange(oldFullModelRange, null);
        const endLineNumber = self.getLineCount();
        const endColumn = self.getLineMaxColumn(endLineNumber);

        try self._onBeforeEOLChange();
        try self._buffer.setEOL(eol);
        self._increaseVersionId();
        try self._onAfterEOLChange();

        var rawChanges = ArrayList(ModelRawChange).init(self.getAllocator());
        try rawChanges.append(.{ .eolChanged = ModelRawEOLChanged.init() });

        var contentChanged = try self._createContentChanged2(
            Range.init(1, 1, endLineNumber, endColumn),
            0,
            oldModelValueLength,
            Position.init(endLineNumber, endColumn),
            String.initOwned(try self.getValue(null, false)),
            false,
            false,
            false,
            true,
        );
        defer contentChanged.deinit();
        self._emitContentChangedEvent(ModelRawContentChangedEvent.init(rawChanges, self._versionId, false, false), contentChanged);
    }

    fn _onBeforeEOLChange(self: *TextModel) !void {
        // Ensure all decorations get their `range` set.
        try self._decorationsTree.ensureAllNodesHaveRanges(self);
    }

    fn _onAfterEOLChange(self: *TextModel) !void {
        // Transform back `range` to offsets
        const versionId = self.getVersionId();
        var allDecorations = try self._decorationsTree.collectNodesPostOrder();
        defer allDecorations.deinit();
        for (allDecorations.items) |node| {
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

    pub fn applyValidatedEdits(self: *TextModel, editOperations: []ValidAnnotatedEditOperation, computeUndoEdits: bool) !?ArrayList(ValidEditOperation) {
        self._onDidChangeDecorations.beginDeferredEmit();
        defer self._onDidChangeDecorations.endDeferredEmit();

        self._eventEmitter.beginDeferredEmit();
        defer self._eventEmitter.endDeferredEmit(null);

        const result = try self._doApplyEdits(editOperations, computeUndoEdits);
        return if (computeUndoEdits) result else null;
    }

    pub fn applyEdits(self: *TextModel, rawOperations: []IdentifiedSingleEditOperation, computeUndoEdits: bool) !?ArrayList(ValidEditOperation) {
        self._onDidChangeDecorations.beginDeferredEmit();
        defer self._onDidChangeDecorations.endDeferredEmit();

        self._eventEmitter.beginDeferredEmit();
        defer self._eventEmitter.endDeferredEmit(null);

        const operations = try self._validateEditOperations(rawOperations);
        defer operations.deinit();
        const result = try self._doApplyEdits(operations.items, computeUndoEdits);
        return if (computeUndoEdits) result else null;
    }

    fn _doApplyEdits(self: *TextModel, rawOperations: []ValidAnnotatedEditOperation, computeUndoEdits: bool) !?ArrayList(ValidEditOperation) {
        const allocator = self.getAllocator();
        const oldLineCount = self._buffer.getLineCount();
        var result = try self._buffer.applyEdits(rawOperations, self._options.trimAutoWhitespace, computeUndoEdits);
        defer result.deinit();

        const newLineCount = self._buffer.getLineCount();

        const contentChanges = result.changes.items;
        self._trimAutoWhitespaceLines = result.trimAutoWhitespaceLineNumbers;
        result.trimAutoWhitespaceLineNumbers = null;

        if (contentChanges.len > 0) {
            // We do a first pass to update decorations
            // because we want to read decorations in the second pass
            // where we will emit content change events
            // and we want to read the final decorations
            for (contentChanges) |change| {
                try self._decorationsTree.acceptReplace(change.modelContentChange.rangeOffset, change.modelContentChange.rangeLength, change.modelContentChange.text.len(), change.forceMoveMarkers);
            }

            var rawContentChanges = ArrayList(ModelRawChange).init(allocator);
            defer rawContentChanges.deinit();
            defer {
                for (rawContentChanges.items) |change| {
                    change.deinit();
                }
            }

            self._increaseVersionId();

            var lineCount = oldLineCount;
            for (contentChanges) |change| {
                const res = countEOL(change.modelContentChange.text.items());
                const eolCount = res.eolCount;
                self._onDidChangeDecorations.fire();

                const startLineNumber = change.modelContentChange.range.startLineNumber;
                const endLineNumber = change.modelContentChange.range.endLineNumber;

                const deletingLinesCnt: usize = endLineNumber - startLineNumber;
                const insertingLinesCnt = eolCount;
                const editingLinesCnt: usize = @min(deletingLinesCnt, insertingLinesCnt);

                const changeLineCountDelta: usize = (insertingLinesCnt - deletingLinesCnt);

                const currentEditStartLineNumber: usize = newLineCount - lineCount - changeLineCountDelta + startLineNumber;
                const firstEditLineNumber: usize = currentEditStartLineNumber;
                const lastInsertedLineNumber: usize = currentEditStartLineNumber + insertingLinesCnt;

                const decorationsWithInjectedTextInEditedRange = try self._decorationsTree.getInjectedTextInInterval(self, self.getOffsetAt(Position.init(firstEditLineNumber, 1)), self.getOffsetAt(Position.init(lastInsertedLineNumber, self.getLineMaxColumn(lastInsertedLineNumber))), 0);

                const injectedTextInEditedRange = try LineInjectedText.fromDecorations(allocator, decorationsWithInjectedTextInEditedRange.items);
                defer injectedTextInEditedRange.deinit();

                {
                    var injectedTextInEditedRangeQueue = ArrayQueue(LineInjectedText).init(injectedTextInEditedRange.items);

                    var j: usize = editingLinesCnt;
                    while (j >= 0) {
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

                        try rawContentChanges.append(.{
                            .lineChanged = ModelRawLineChanged.init(
                                editLineNumber,
                                try self.getLineContent(editLineNumber),
                                decorationsInCurrentLine,
                            ),
                        });

                        if (j == 0) break;
                        j -= 1;
                    }
                }

                if (editingLinesCnt < deletingLinesCnt) {
                    // Must delete some lines
                    const spliceStartLineNumber = startLineNumber + editingLinesCnt;
                    try rawContentChanges.append(.{ .linesDeleted = ModelRawLinesDeleted.init(spliceStartLineNumber + 1, endLineNumber) });
                }

                if (editingLinesCnt < insertingLinesCnt) {
                    var injectedTextInEditedRangeQueue = ArrayQueue(LineInjectedText).init(injectedTextInEditedRange.items);
                    // Must insert some lines
                    const spliceLineNumber = startLineNumber + editingLinesCnt;
                    const cnt = insertingLinesCnt - editingLinesCnt;
                    const fromLineNumber = newLineCount - lineCount - cnt + spliceLineNumber + 1;
                    var injectedTexts = ArrayList(?[]const LineInjectedText).init(allocator);
                    var newLines = ArrayList(ArrayList(u8)).init(allocator);
                    var i: usize = 0;
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

                    try rawContentChanges.append(.{ .linesInserted = ModelRawLinesInserted.init(spliceLineNumber + 1, startLineNumber + insertingLinesCnt, newLines, injectedTexts) });
                }

                lineCount += changeLineCountDelta;
            }

            var changes = ArrayList(ModelContentChange).init(allocator);
            for (contentChanges) |change| {
                try changes.append(change.modelContentChange);
            }

            var changedEvent = ModelContentChangedEvent{
                .changes = changes,
                .eol = self._buffer.getEOL(),
                .isEolChange = false,
                .versionId = self.getVersionId(),
                .isUndoing = self._isUndoing,
                .isRedoing = self._isRedoing,
                .isFlush = false,
            };
            defer changedEvent.deinit();
            self._emitContentChangedEvent(
                ModelRawContentChangedEvent.init(rawContentChanges, self.getVersionId(), self._isUndoing, self._isRedoing),
                changedEvent,
            );
        }

        const reverseEdits = result.reverseEdits;
        result.reverseEdits = null;
        return reverseEdits;
    }

    pub fn undo(self: *TextModel) !void {
        try self._undoRedoService.undo(.{ .uri = self.uri() });
    }

    pub fn canUndo(self: *TextModel) !bool {
        return try self._undoRedoService.canUndo(.{ .uri = self.uri() });
    }

    pub fn redo(self: *TextModel) !void {
        try self._undoRedoService.redo(.{ .uri = self.uri() });
    }

    pub fn canRedo(self: *TextModel) !bool {
        return try self._undoRedoService.canRedo(.{ .uri = self.uri() });
    }

    //#region Decorations

    fn handleBeforeFireDecorationsChangedEvent(self: *TextModel, affectedInjectedTextLines: ?Set(usize), affectedLineHeights: ?SetWithKey(LineHeightChangingDecoration)) !void {
        // This is called before the decoration changed event is fired.

        if (affectedInjectedTextLines) |lines| {
            if (lines.count() > 0) {
                const affectedLines = lines.list;

                var lineChangeEvents = ArrayList(ModelRawLineChanged).init(self.getAllocator());
                defer lineChangeEvents.deinit();

                for (affectedLines.items) |lineNumber| {
                    try lineChangeEvents.append(ModelRawLineChanged.init(lineNumber, try self.getLineContent(lineNumber), try self._getInjectedTextInLine(lineNumber)));
                }
                self._onDidChangeInjectedText.fire(ModelInjectedTextChangedEvent.init(lineChangeEvents.items));
            }
        }
        if (affectedLineHeights) |items| {
            var heights = items;
            if (heights.count() > 0) {
                var affectedLines = heights.map.valueIterator();
                var lineHeightChangeEvent = ArrayList(ModelLineHeightChanged).init(self.getAllocator());
                defer lineHeightChangeEvent.deinit();

                while (affectedLines.next()) |specialLineHeightChange| {
                    try lineHeightChangeEvent.append(ModelLineHeightChanged.init(specialLineHeightChange.ownerId, specialLineHeightChange.decorationId, specialLineHeightChange.lineNumber, specialLineHeightChange.lineHeight));
                }
                self._onDidChangeLineHeight.fire(ModelLineHeightChangedEvent.init(lineHeightChangeEvent.items));
            }
        }
    }

    pub fn changeDecorations(self: *TextModel, comptime T: type, callback: fn (changeAccessor: ModelDecorationsChangeAccessor) T, ownerId: usize) ?T {
        self._onDidChangeDecorations.beginDeferredEmit();
        defer self._onDidChangeDecorations.endDeferredEmit();
        return self._changeDecorations(T, ownerId, callback);
    }

    fn _changeDecorations(comptime T: type, self: *TextModel, ownerId: usize, callback: fn (changeAccessor: ModelDecorationsChangeAccessor) anyerror!T) !?T {
        const changeAccessor = ModelDecorationsChangeAccessor.init(self, ownerId);
        var result: ?T = null;
        result = try callback(changeAccessor);
        return result;
    }

    pub fn deltaDecorations(self: *TextModel, oldDecorations: [][]u8, newDecorations: []ModelDeltaDecoration, ownerId: usize) ![][]u8 {
        if (oldDecorations.len == 0 and newDecorations.len == 0) {
            // nothing to do
            return &[_][]u8{};
        }

        self._deltaDecorationCallCnt += 1;
        defer self._deltaDecorationCallCnt -= 1;
        if (self._deltaDecorationCallCnt > 1) {
            std.debug.print("Invoking deltaDecorations recursively could lead to leaking decorations.\n", .{});
            // onUnexpectedError(new Error(`Invoking deltaDecorations recursively could lead to leaking decorations.`));
        }
        self._onDidChangeDecorations.beginDeferredEmit();
        defer self._onDidChangeDecorations.endDeferredEmit();
        return try self._deltaDecorationsImpl(ownerId, oldDecorations, newDecorations);
    }

    fn _getTrackedRange(self: *TextModel, id: []const u8) ?Range {
        return self.getDecorationRange(id);
    }

    fn _setTrackedRange(self: *TextModel, id: ?[]const u8, newRange: ?Range, newStickiness: TrackedRangeStickiness) !?[]const u8 {
        const node = (if (id) |id_| self._decorations.get(id_) else null);

        if (node == null) {
            if (newRange == null) {
                // node doesn't exist, the request is to delete => nothing to do
                return null;
            }
            // node doesn't exist, the request is to set => add the tracked range
            return try self._deltaDecorationsImpl(0, &[_][]const u8{}, &[_]ModelDeltaDecoration{.{ .range = newRange, .options = TRACKED_RANGE_OPTIONS[@intFromEnum(newStickiness)] }}, true);
        }

        if (newRange == null) {
            // node exists, the request is to delete => delete node
            self._decorationsTree.delete(node);
            self._decorations.remove(node.id);
            return null;
        }

        var node_ = node.?;
        const newRange_ = newRange.?;

        // node exists, the request is to set => change the tracked range and its options
        const range = self._validateRangeRelaxedNoAllocations(newRange_);
        const startOffset = self._buffer.getOffsetAt(range.startLineNumber, range.startColumn);
        const endOffset = self._buffer.getOffsetAt(range.endLineNumber, range.endColumn);

        self._decorationsTree.delete(node_);
        node_.reset(self.getVersionId(), startOffset, endOffset, range);
        node_.setOptions(TRACKED_RANGE_OPTIONS[@intFromEnum(newStickiness)]);
        self._decorationsTree.insert(node_);
        return node_.id;
    }

    pub fn removeAllDecorationsWithOwnerId(self: *TextModel, ownerId: usize) void {
        if (self._isDisposed) {
            return;
        }
        const nodes = try self._decorationsTree.collectNodesFromOwner(ownerId);
        defer nodes.deinit();
        for (nodes.items) |node| {
            self._decorationsTree.delete(node);
            self._decorations.remove(node.id);
        }
    }

    pub fn getDecorationOptions(self: *TextModel, decorationId: []const u8) ?ModelDecorationOptions {
        const node = self._decorations.get(decorationId);
        if (node == null) {
            return null;
        }
        return node.options;
    }

    pub fn getDecorationRange(self: *TextModel, decorationId: []const u8) ?Range {
        const node = self._decorations.get(decorationId);
        if (node == null) {
            return null;
        }
        return self._decorationsTree.getNodeRange(self, node);
    }

    pub fn getLineDecorations(self: *TextModel, lineNumber: usize, ownerId: usize, filterOutValidation: bool) ![]ModelDecoration {
        if (lineNumber < 1 or lineNumber > self.getLineCount()) {
            return &[_]ModelDecoration{};
        }
        return try self.getLinesDecorations(lineNumber, lineNumber, ownerId, filterOutValidation);
    }

    pub fn getLinesDecorations(self: *TextModel, startLineNumber: usize, endLineNumber: usize, ownerId: usize, filterOutValidation: bool, onlyMarginDecorations: bool) ![]ModelDecoration {
        const lineCount = self.getLineCount();
        const startLineNumber_ = @min(lineCount, @max(1, startLineNumber));
        const endLineNumber_ = @min(lineCount, @max(1, endLineNumber));
        const endColumn = self.getLineMaxColumn(endLineNumber);
        const range = Range.init(startLineNumber_, 1, endLineNumber_, endColumn);

        var decorations = try self._getDecorationsInRange(range, ownerId, filterOutValidation, onlyMarginDecorations);
        try decorations.appendSlice(try self._decorationProvider.getDecorationsInRange(range, ownerId, filterOutValidation));
        return decorations.toOwnedSlice();
    }

    pub fn getDecorationsInRange(self: *TextModel, range: Range, ownerId: usize, filterOutValidation: bool, onlyMinimapDecorations: bool, onlyMarginDecorations: bool) ![]ModelDecoration {
        const validatedRange = self.validateRange(range);

        var decorations = try self._getDecorationsInRange(validatedRange, ownerId, filterOutValidation, onlyMarginDecorations);
        try decorations.appendSlice(try self._decorationProvider.getDecorationsInRange(validatedRange, ownerId, filterOutValidation, onlyMinimapDecorations));
        return decorations.toOwnedSlice();
    }

    pub fn getOverviewRulerDecorations(self: *TextModel, ownerId: usize, filterOutValidation: bool) ![]ModelDecoration {
        var decorations = try self._decorationsTree.getAll(self, ownerId, filterOutValidation, true, false);
        return decorations.toOwnedSlice();
    }

    pub fn getInjectedTextDecorations(self: *TextModel, ownerId: usize) ![]ModelDecoration {
        var decorations = try self._decorationsTree.getAllInjectedText(self, ownerId);
        return decorations.toOwnedSlice();
    }

    pub fn getCustomLineHeightsDecorations(self: *TextModel, ownerId: usize) ![]ModelDecoration {
        var decorations = try self._decorationsTree.getAllCustomLineHeights(self, ownerId);
        return decorations.toOwnedSlice();
    }

    fn _getInjectedTextInLine(self: *TextModel, lineNumber: usize) ![]LineInjectedText {
        const startOffset = self._buffer.getOffsetAt(lineNumber, 1);
        const endOffset = startOffset + self._buffer.getLineLength(lineNumber);

        const result = try self._decorationsTree.getInjectedTextInInterval(self, startOffset, endOffset, 0);
        defer result.deinit();
        var res = try LineInjectedText.fromDecorations(self.getAllocator(), result.items);
        return try res.toOwnedSlice();
    }

    pub fn getAllDecorations(self: *TextModel, ownerId: usize, filterOutValidation: bool) ![]ModelDecoration {
        var result = try self._decorationsTree.getAll(self, ownerId, filterOutValidation, false, false);
        try result.appendSlice(try self._decorationProvider.getAllDecorations(ownerId, filterOutValidation));
        return result.toOwnedSlice();
    }

    pub fn getAllMarginDecorations(self: *TextModel, ownerId: usize) ![]ModelDecoration {
        var result = try self._decorationsTree.getAll(self, ownerId, false, false, true);
        return result.toOwnedSlice();
    }

    fn _getDecorationsInRange(self: *TextModel, filterRange: Range, filterOwnerId: usize, filterOutValidation: bool, onlyMarginDecorations: bool) !ArrayList(*IntervalNode) {
        const startOffset = self._buffer.getOffsetAt(filterRange.startLineNumber, filterRange.startColumn);
        const endOffset = self._buffer.getOffsetAt(filterRange.endLineNumber, filterRange.endColumn);
        return try self._decorationsTree.getAllInInterval(self, startOffset, endOffset, filterOwnerId, filterOutValidation, onlyMarginDecorations);
    }

    pub fn getRangeAt(self: *TextModel, start: usize, end: usize) Range {
        return self._buffer.getRangeAt(start, end - start);
    }

    fn _changeDecorationImpl(self: *TextModel, ownerId: usize, decorationId: []const u8, _range: Range) void {
        if (self._decorations.get(decorationId)) |node| {
            if (node.options.after) {
                const oldRange = self.getDecorationRange(decorationId);
                self._onDidChangeDecorations.recordLineAffectedByInjectedText(oldRange.?.endLineNumber);
            }

            if (node.options.before) {
                const oldRange = self.getDecorationRange(decorationId);
                self._onDidChangeDecorations.recordLineAffectedByInjectedText(oldRange.?.startLineNumber);
            }
            if (node.options.lineHeight != null) {
                const oldRange = self.getDecorationRange(decorationId);
                self._onDidChangeDecorations.recordLineAffectedByLineHeightChange(ownerId, decorationId, oldRange.?.startLineNumber, null);
            }

            const range = self._validateRangeRelaxedNoAllocations(_range);
            const startOffset = self._buffer.getOffsetAt(range.startLineNumber, range.startColumn);
            const endOffset = self._buffer.getOffsetAt(range.endLineNumber, range.endColumn);

            self._decorationsTree.delete(node);
            node.reset(self.getVersionId(), startOffset, endOffset, range);
            self._decorationsTree.insert(node);
            self._onDidChangeDecorations.checkAffectedAndFire(node.options);

            if (node.options.after) {
                self._onDidChangeDecorations.recordLineAffectedByInjectedText(range.endLineNumber);
            }
            if (node.options.before) {
                self._onDidChangeDecorations.recordLineAffectedByInjectedText(range.startLineNumber);
            }
            if (node.options.lineHeight != null) {
                self._onDidChangeDecorations.recordLineAffectedByLineHeightChange(ownerId, decorationId, range.startLineNumber, node.options.lineHeight);
            }
        }
    }

    fn _changeDecorationOptionsImpl(self: *TextModel, ownerId: usize, decorationId: []const u8, options: *ModelDecorationOptions) void {
        if (self._decorations.get(decorationId)) |node| {
            const nodeWasInOverviewRuler = (node.options.overviewRuler != null and node.options.overviewRuler.?.color != null);
            const nodeIsInOverviewRuler = (options.overviewRuler != null and options.overviewRuler.?.color != null);

            self._onDidChangeDecorations.checkAffectedAndFire(node.options);
            self._onDidChangeDecorations.checkAffectedAndFire(options);

            if (node.options.after or options.after) {
                const nodeRange = self._decorationsTree.getNodeRange(self, node);
                self._onDidChangeDecorations.recordLineAffectedByInjectedText(nodeRange.endLineNumber);
            }
            if (node.options.before or options.before) {
                const nodeRange = self._decorationsTree.getNodeRange(self, node);
                self._onDidChangeDecorations.recordLineAffectedByInjectedText(nodeRange.startLineNumber);
            }
            if (node.options.lineHeight != null or options.lineHeight != null) {
                const nodeRange = self._decorationsTree.getNodeRange(self, node);
                self._onDidChangeDecorations.recordLineAffectedByLineHeightChange(ownerId, decorationId, nodeRange.startLineNumber, options.lineHeight);
            }

            const movedInOverviewRuler = nodeWasInOverviewRuler != nodeIsInOverviewRuler;
            const changedWhetherInjectedText = isOptionsInjectedText(options) != isNodeInjectedText(node);
            if (movedInOverviewRuler or changedWhetherInjectedText) {
                self._decorationsTree.delete(node);
                node.setOptions(options);
                self._decorationsTree.insert(node);
            } else {
                node.setOptions(options);
            }
        }
    }

    fn _deltaDecorationsImpl(self: *TextModel, ownerId: usize, oldDecorationsIds: []const u64, newDecorations: []ModelDeltaDecoration, suppressEvents: bool) ![]const u64 {
        const versionId = self.getVersionId();

        const oldDecorationsLen = oldDecorationsIds.len;
        var oldDecorationIndex: usize = 0;

        const newDecorationsLen = newDecorations.len;
        var newDecorationIndex: usize = 0;

        self._onDidChangeDecorations.beginDeferredEmit();
        defer self._onDidChangeDecorations.endDeferredEmit();

        const result = ArrayList([]const u8).initCapacity(self.getAllocator(), newDecorationsLen);
        while (oldDecorationIndex < oldDecorationsLen or newDecorationIndex < newDecorationsLen) {
            var node: ?*IntervalNode = null;

            if (oldDecorationIndex < oldDecorationsLen) {
                // (1) get ourselves an old node
                var decorationId: []const u8 = undefined;
                while (true) {
                    decorationId = oldDecorationsIds[oldDecorationIndex];
                    oldDecorationIndex += 1;
                    node = self._decorations.get(decorationId);

                    if (node != null and oldDecorationIndex < oldDecorationsLen) {
                        continue;
                    } else {
                        break;
                    }
                }

                // (2) remove the node from the tree (if it exists)
                if (node) |node_| {
                    if (node_.options.after) {
                        const nodeRange = self._decorationsTree.getNodeRange(self, node_);
                        self._onDidChangeDecorations.recordLineAffectedByInjectedText(nodeRange.endLineNumber);
                    }
                    if (node_.options.before) {
                        const nodeRange = self._decorationsTree.getNodeRange(self, node_);
                        self._onDidChangeDecorations.recordLineAffectedByInjectedText(nodeRange.startLineNumber);
                    }
                    if (node_.options.lineHeight != null) {
                        const nodeRange = self._decorationsTree.getNodeRange(self, node_);
                        self._onDidChangeDecorations.recordLineAffectedByLineHeightChange(ownerId, decorationId, nodeRange.startLineNumber, null);
                    }
                    self._decorationsTree.delete(node_);

                    if (!suppressEvents) {
                        self._onDidChangeDecorations.checkAffectedAndFire(node_.options);
                    }
                }
            }

            if (newDecorationIndex < newDecorationsLen) {
                // (3) create a new node if necessary
                if (node == null) {
                    self._lastDecorationId += 1;
                    const internalDecorationId = self._lastDecorationId;
                    const decorationId: u64 = @as(u64, @intCast(self._instanceId)) << 32 | @as(u64, @intCast(internalDecorationId));
                    node = try IntervalNode.init(self.getAllocator(), decorationId, 0, 0);
                    try self._decorations.put(decorationId, node);
                }

                // (4) initialize node
                var node_ = node.?;
                const newDecoration = newDecorations[newDecorationIndex];
                const range = self._validateRangeRelaxedNoAllocations(newDecoration.range);
                const options = newDecoration.options; // TODO: normalize options ??
                const startOffset = self._buffer.getOffsetAt(range.startLineNumber, range.startColumn);
                const endOffset = self._buffer.getOffsetAt(range.endLineNumber, range.endColumn);

                node_.ownerId = ownerId;
                node_.reset(versionId, startOffset, endOffset, range);
                node_.setOptions(options);

                if (node_.options.after) {
                    self._onDidChangeDecorations.recordLineAffectedByInjectedText(range.endLineNumber);
                }
                if (node_.options.before) {
                    self._onDidChangeDecorations.recordLineAffectedByInjectedText(range.startLineNumber);
                }
                if (node_.options.lineHeight != null) {
                    self._onDidChangeDecorations.recordLineAffectedByLineHeightChange(ownerId, node_.id, range.startLineNumber, node_.options.lineHeight);
                }
                if (!suppressEvents) {
                    self._onDidChangeDecorations.checkAffectedAndFire(options);
                }

                self._decorationsTree.insert(node_);

                result[newDecorationIndex] = node_.id;

                newDecorationIndex += 1;
            } else {
                if (node) |node_| {
                    self._decorations.remove(node_.id);
                }
            }
        }

        return result.toOwnedSlice();
    }

    //#endregion
};

fn createTestTextModel(allocator: Allocator, text: []const u8, undoRedoService: *UndoRedoService) !*TextModel {
    var source = io.fixedBufferStream(text);
    const reader = source.reader().any();

    return try TextModel.init(allocator, reader, TextModelCreationOptions{
        .tabSize = 4,
        .indentSize = .{ .number = 4 },
        .insertSpaces = true,
        .detectIndentation = true,
        .trimAutoWhitespace = true,
        .defaultEOL = .LF,
        .isForSimpleWidget = false,
        .largeFileOptimizations = false,
        .bracketPairColorizationOptions = .{
            .enabled = false,
            .independentColorPoolPerBracketType = false,
        },
    }, null, undoRedoService);
}

test "TextModel.init" {
    const allocator = std.testing.allocator;
    const text = "Hello, world!";
    var undoRedoService = UndoRedoService.init(allocator);
    defer undoRedoService.deinit();
    var textModel = try createTestTextModel(allocator, text, &undoRedoService);
    defer allocator.destroy(textModel);
    defer textModel.deinit();
}

test "TextModel._isValidPosition" {
    const allocator = std.testing.allocator;
    const text = "你好, world!";
    var undoRedoService = UndoRedoService.init(allocator);
    defer undoRedoService.deinit();
    var textModel = try createTestTextModel(allocator, text, &undoRedoService);
    defer allocator.destroy(textModel);
    defer textModel.deinit();
    try std.testing.expect(!textModel._isValidPosition(0, 1, .Relaxed));
    try std.testing.expect(textModel._isValidPosition(1, 2, .Relaxed));
    try std.testing.expect(textModel._isValidPosition(1, text.len + 1, .Relaxed));
    try std.testing.expect(!textModel._isValidPosition(1, text.len + 2, .Relaxed));
    try std.testing.expect(!textModel._isValidPosition(1, 2, .Strict));
    try std.testing.expect(!textModel._isValidPosition(1, 3, .Strict));
    try std.testing.expect(textModel._isValidPosition(1, 4, .Strict));
    try std.testing.expect(!textModel._isValidPosition(1, 5, .Strict));
    try std.testing.expect(!textModel._isValidPosition(1, 6, .Strict));
    try std.testing.expect(textModel._isValidPosition(1, 7, .Strict));
    try std.testing.expect(textModel._isValidPosition(1, 8, .Strict));
}

test "TextModel.validatePosition" {
    const allocator = std.testing.allocator;
    const text = "你好, world!";
    var undoRedoService = UndoRedoService.init(allocator);
    defer undoRedoService.deinit();
    var textModel = try createTestTextModel(allocator, text, &undoRedoService);
    defer allocator.destroy(textModel);
    defer textModel.deinit();

    try std.testing.expectEqual(Position.init(1, 1), textModel.validatePosition(Position.init(1, 0)));
    try std.testing.expectEqual(Position.init(1, 1), textModel.validatePosition(Position.init(1, 1)));
    try std.testing.expectEqual(Position.init(1, 1), textModel.validatePosition(Position.init(1, 2)));
    try std.testing.expectEqual(Position.init(1, 1), textModel.validatePosition(Position.init(1, 3)));
    try std.testing.expectEqual(Position.init(1, 4), textModel.validatePosition(Position.init(1, 4)));
    try std.testing.expectEqual(Position.init(1, 4), textModel.validatePosition(Position.init(1, 5)));
    try std.testing.expectEqual(Position.init(1, 4), textModel.validatePosition(Position.init(1, 6)));
    try std.testing.expectEqual(Position.init(1, 7), textModel.validatePosition(Position.init(1, 7)));
    try std.testing.expectEqual(Position.init(1, 8), textModel.validatePosition(Position.init(1, 8)));
    try std.testing.expectEqual(Position.init(1, 9), textModel.validatePosition(Position.init(1, 9)));
    try std.testing.expectEqual(Position.init(1, text.len + 1), textModel.validatePosition(Position.init(1, 100)));
}

test "TextModel.validateRange" {
    const allocator = std.testing.allocator;
    const text = "你好, world!";
    var undoRedoService = UndoRedoService.init(allocator);
    defer undoRedoService.deinit();
    var textModel = try createTestTextModel(allocator, text, &undoRedoService);
    defer allocator.destroy(textModel);
    defer textModel.deinit();

    try std.testing.expectEqualDeep(Range.init(1, 1, 1, text.len + 1), textModel.validateRange(Range.init(1, 1, 1, 100)));
    try std.testing.expectEqualDeep(Range.init(1, 1, 1, 4), textModel.validateRange(Range.init(1, 1, 1, 2)));
    try std.testing.expectEqualDeep(Range.init(1, 1, 1, 7), textModel.validateRange(Range.init(1, 2, 1, 5)));
}

test "TextModel.applyEdits" {
    const allocator = std.testing.allocator;
    var undoRedoService = UndoRedoService.init(allocator);
    defer undoRedoService.deinit();
    var textModel = try createTestTextModel(allocator, "Hello, world!", &undoRedoService);
    defer allocator.destroy(textModel);
    defer textModel.deinit();

    var ops = [_]IdentifiedSingleEditOperation{
        .init(Range.init(1, 1, 1, 6), .initBorrowed("yo")),
    };
    _ = try textModel.applyEdits(&ops, false);

    const line = try textModel.getLineContent(1);
    defer line.deinit();
    try std.testing.expectEqualStrings("yo, world!", line.items);
}

test "TextModel.pushEditOperations" {
    const allocator = std.testing.allocator;
    var undoRedoService = UndoRedoService.init(allocator);
    defer undoRedoService.deinit();
    var textModel = try createTestTextModel(allocator, "Hello, world!", &undoRedoService);
    defer allocator.destroy(textModel);
    defer textModel.deinit();

    var opts = [_]IdentifiedSingleEditOperation{
        .init(Range.init(1, 1, 1, 6), String.initBorrowed("yo")),
    };
    _ = try textModel.pushEditOperations(null, &opts, null, UndoRedoGroup.init());

    const line = try textModel.getLineContent(1);
    defer line.deinit();
    try std.testing.expectEqualStrings("yo, world!", line.items);
    try textModel.undo();
    const line1 = try textModel.getLineContent(1);
    defer line1.deinit();
    try std.testing.expectEqualStrings("Hello, world!", line1.items);

    try textModel.redo();
    const line2 = try textModel.getLineContent(1);
    defer line2.deinit();
    try std.testing.expectEqualStrings("yo, world!", line2.items);
}

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

fn isNodeInOverviewRuler(node: *IntervalNode) bool {
    return (node.options.overviewRuler != null and node.options.overviewRuler.?.color != null);
}

fn isOptionsInjectedText(options: *const ModelDecorationOptions) bool {
    return options.after != null or options.before != null;
}

fn isNodeInjectedText(node: *IntervalNode) bool {
    return node.options.after != null or node.options.before != null;
}

pub const DecorationsTrees = struct {

    // This tree holds decorations that do not show up in the overview ruler.
    _decorationsTree0: IntervalTree,

    // This tree holds decorations that show up in the overview ruler.
    _decorationsTree1: IntervalTree,

    // This tree holds decorations that contain injected text.
    _injectedTextDecorationsTree: IntervalTree,

    allocator: Allocator,

    pub fn init(allocator: Allocator) DecorationsTrees {
        return DecorationsTrees{
            .allocator = allocator,
            ._decorationsTree0 = IntervalTree.init(allocator),
            ._decorationsTree1 = IntervalTree.init(allocator),
            ._injectedTextDecorationsTree = IntervalTree.init(allocator),
        };
    }

    fn ensureAllNodesHaveRanges(self: *DecorationsTrees, host: *TextModel) !void {
        _ = try self.getAll(host, 0, false, false, false);
    }

    fn _ensureNodesHaveRanges(host: *TextModel, nodes: ArrayList(*IntervalNode)) !ArrayList(ModelDecoration) {
        for (nodes.items) |node| {
            if (node.range == null) {
                node.range = host.getRangeAt(node.cachedAbsoluteStart, node.cachedAbsoluteEnd);
            }
        }

        var result = ArrayList(ModelDecoration).init(nodes.allocator);
        for (nodes.items) |node| {
            try result.append(ModelDecoration{
                .id = node.id,
                .ownerId = node.ownerId,
                .range = node.range.?,
                .options = node.options,
            });
        }
        return result;
    }

    pub fn getAllInInterval(self: *DecorationsTrees, host: *TextModel, start: usize, end: usize, filterOwnerId: usize, filterOutValidation: bool, onlyMarginDecorations: bool) !ArrayList(ModelDecoration) {
        const versionId = host.getVersionId();
        const result = try self._intervalSearch(start, end, filterOwnerId, filterOutValidation, versionId, onlyMarginDecorations);
        return try _ensureNodesHaveRanges(host, result);
    }

    fn _intervalSearch(self: *DecorationsTrees, start: usize, end: usize, filterOwnerId: usize, filterOutValidation: bool, cachedVersionId: usize, onlyMarginDecorations: bool) !ArrayList(*IntervalNode) {
        const r0 = self._decorationsTree0.intervalSearch(start, end, filterOwnerId, filterOutValidation, cachedVersionId, onlyMarginDecorations);
        defer r0.deinit();
        const r1 = self._decorationsTree1.intervalSearch(start, end, filterOwnerId, filterOutValidation, cachedVersionId, onlyMarginDecorations);
        defer r1.deinit();
        const r2 = self._injectedTextDecorationsTree.intervalSearch(start, end, filterOwnerId, filterOutValidation, cachedVersionId, onlyMarginDecorations);
        defer r2.deinit();

        var result = ArrayList(*IntervalNode).init(self.allocator);
        defer result.deinit();
        try result.appendSlice(r0.items);
        try result.appendSlice(r1.items);
        try result.appendSlice(r2.items);
        return result;
    }

    pub fn getInjectedTextInInterval(self: *DecorationsTrees, host: *TextModel, start: usize, end: usize, filterOwnerId: usize) !ArrayList(ModelDecoration) {
        const versionId = host.getVersionId();
        const result = try self._injectedTextDecorationsTree.intervalSearch(start, end, filterOwnerId, false, versionId, false);
        return try _ensureNodesHaveRanges(host, result);
    }

    pub fn getAllInjectedText(self: *DecorationsTrees, host: *TextModel, filterOwnerId: usize) !ArrayList(ModelDecoration) {
        const versionId = host.getVersionId();
        const searchResult = self._injectedTextDecorationsTree.search(filterOwnerId, false, versionId, false);
        defer searchResult.deinit();
        const result = try _ensureNodesHaveRanges(host, searchResult);
        var write_index = 0;
        for (result) |i| {
            if (i.options.showIfCollapsed or !i.range.isEmpty()) {
                result.items[write_index] = i;
                write_index += 1;
            }
        }
        result.resize(write_index);
        return result;
    }

    pub fn getAllCustomLineHeights(self: *DecorationsTrees, host: *TextModel, filterOwnerId: usize) !ArrayList(ModelDecoration) {
        const versionId = host.getVersionId();
        const searchResult = try self._search(filterOwnerId, false, false, versionId, false);
        defer searchResult.deinit();
        const result = try _ensureNodesHaveRanges(host, searchResult);
        var write_index = 0;
        for (result.items) |node| {
            if (node.options.lineHeight != null) {
                result.items[write_index] = node;
                write_index += 1;
            }
        }
        result.resize(write_index);
        return result;
    }

    pub fn getAll(self: *DecorationsTrees, host: *TextModel, filterOwnerId: usize, filterOutValidation: bool, overviewRulerOnly: bool, onlyMarginDecorations: bool) !ArrayList(ModelDecoration) {
        const versionId = host.getVersionId();
        const result = try self._search(filterOwnerId, filterOutValidation, overviewRulerOnly, versionId, onlyMarginDecorations);
        return try _ensureNodesHaveRanges(host, result);
    }

    fn _search(self: *DecorationsTrees, filterOwnerId: usize, filterOutValidation: bool, overviewRulerOnly: bool, cachedVersionId: u32, onlyMarginDecorations: bool) !ArrayList(*IntervalNode) {
        if (overviewRulerOnly) {
            return try self._decorationsTree1.search(filterOwnerId, filterOutValidation, cachedVersionId, onlyMarginDecorations);
        } else {
            const r0 = try self._decorationsTree0.search(filterOwnerId, filterOutValidation, cachedVersionId, onlyMarginDecorations);
            defer r0.deinit();
            const r1 = try self._decorationsTree1.search(filterOwnerId, filterOutValidation, cachedVersionId, onlyMarginDecorations);
            defer r1.deinit();
            const r2 = try self._injectedTextDecorationsTree.search(filterOwnerId, filterOutValidation, cachedVersionId, onlyMarginDecorations);
            defer r2.deinit();

            var result = ArrayList(*IntervalNode).init(self.allocator);
            defer result.deinit();
            try result.appendSlice(r0.items);
            try result.appendSlice(r1.items);
            try result.appendSlice(r2.items);
            return result;
        }
    }

    pub fn collectNodesFromOwner(self: *DecorationsTrees, ownerId: usize) !ArrayList(*IntervalNode) {
        const r0 = try self._decorationsTree0.collectNodesFromOwner(ownerId);
        defer r0.deinit();
        const r1 = try self._decorationsTree1.collectNodesFromOwner(ownerId);
        defer r1.deinit();
        const r2 = try self._injectedTextDecorationsTree.collectNodesFromOwner(ownerId);
        defer r2.deinit();

        var result = ArrayList(*IntervalNode).init(self.allocator);
        defer result.deinit();
        try result.appendSlice(r0.items);
        try result.appendSlice(r1.items);
        try result.appendSlice(r2.items);
        return result;
    }

    pub fn collectNodesPostOrder(self: *DecorationsTrees) !ArrayList(*IntervalNode) {
        const r0 = try self._decorationsTree0.collectNodesPostOrder();
        defer r0.deinit();
        const r1 = try self._decorationsTree1.collectNodesPostOrder();
        defer r1.deinit();
        const r2 = try self._injectedTextDecorationsTree.collectNodesPostOrder();
        defer r2.deinit();

        var result = ArrayList(*IntervalNode).init(self.allocator);
        defer result.deinit();
        try result.appendSlice(r0.items);
        try result.appendSlice(r1.items);
        try result.appendSlice(r2.items);
        return result;
    }

    pub fn insert(self: *DecorationsTrees, node: *IntervalNode) void {
        if (isNodeInjectedText(node)) {
            self._injectedTextDecorationsTree.insert(node);
        } else if (isNodeInOverviewRuler(node)) {
            self._decorationsTree1.insert(node);
        } else {
            self._decorationsTree0.insert(node);
        }
    }

    pub fn delete(self: *DecorationsTrees, node: *IntervalNode) void {
        if (isNodeInjectedText(node)) {
            self._injectedTextDecorationsTree.delete(node);
        } else if (isNodeInOverviewRuler(node)) {
            self._decorationsTree1.delete(node);
        } else {
            self._decorationsTree0.delete(node);
        }
    }

    pub fn getNodeRange(self: *DecorationsTrees, host: *TextModel, node: *IntervalNode) Range {
        const versionId = host.getVersionId();
        if (node.cachedVersionId != versionId) {
            self._resolveNode(node, versionId);
        }
        if (node.range == null) {
            node.range = host.getRangeAt(node.cachedAbsoluteStart, node.cachedAbsoluteEnd);
        }
        return node.range;
    }

    fn _resolveNode(self: *DecorationsTrees, node: *IntervalNode, cachedVersionId: usize) void {
        if (isNodeInjectedText(node)) {
            self._injectedTextDecorationsTree.resolveNode(node, cachedVersionId);
        } else if (isNodeInOverviewRuler(node)) {
            self._decorationsTree1.resolveNode(node, cachedVersionId);
        } else {
            self._decorationsTree0.resolveNode(node, cachedVersionId);
        }
    }

    pub fn acceptReplace(self: *DecorationsTrees, offset: usize, length: usize, textLength: usize, forceMoveMarkers: bool) !void {
        try self._decorationsTree0.acceptReplace(offset, length, textLength, forceMoveMarkers);
        try self._decorationsTree1.acceptReplace(offset, length, textLength, forceMoveMarkers);
        try self._injectedTextDecorationsTree.acceptReplace(offset, length, textLength, forceMoveMarkers);
    }
};
pub fn createTextBuffer(allocator: Allocator, source: io.AnyReader, defaultEOL: EOL) !PieceTreeTextBuffer {
    const factory = try createTextBufferFactory(allocator, source);
    defer factory.deinit();
    return try factory.create(defaultEOL);
}

var readerBuffer: [65535]u8 = undefined;
fn createTextBufferFactory(allocator: Allocator, reader: io.AnyReader) !PieceTreeTextBufferFactory {
    var builder = PieceTreeBufferBuilder.init(allocator);
    while (true) {
        const len = try reader.readAll(&readerBuffer);
        if (len == 0) {
            break;
        }
        try builder.acceptChunk(readerBuffer[0..len]);
    }
    return try builder.finish(false);
}

const LineHeightChangingDecoration = struct {
    ownerId: u64,
    decorationId: []const u8,
    lineNumber: usize,
    lineHeight: ?usize,

    pub fn toKey(allocator: Allocator, obj: LineHeightChangingDecoration) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "{};{};{}", .{ obj.ownerId, obj.decorationId, obj.lineNumber });
    }

    pub fn init(ownerId: u64, decorationId: []const u8, lineNumber: usize, lineHeight: ?usize) LineHeightChangingDecoration {
        return LineHeightChangingDecoration{
            .ownerId = ownerId,
            .decorationId = decorationId,
            .lineNumber = lineNumber,
            .lineHeight = lineHeight,
        };
    }
};

const DidChangeDecorationsEmitter = struct {
    _actual: Emitter(ModelDecorationsChangedEvent),
    allocator: Allocator,
    _deferredCnt: usize,
    _shouldFireDeferred: bool,
    _affectsMinimap: bool,
    _affectsOverviewRuler: bool,
    _affectedInjectedTextLines: ?Set(usize),
    _affectedLineHeights: ?SetWithKey(LineHeightChangingDecoration),
    _affectsGlyphMargin: bool,
    _affectsLineNumber: bool,

    _model: *anyopaque,
    handleBeforeFire: *const fn (m: *anyopaque, affectedInjectedTextLines: ?Set(usize), affectedLineHeights: ?SetWithKey(LineHeightChangingDecoration)) anyerror!void,

    pub fn init(allocator: Allocator, model: *anyopaque, handleBeforeFire: *const fn (m: *anyopaque, affectedInjectedTextLines: ?Set(usize), affectedLineHeights: ?SetWithKey(LineHeightChangingDecoration)) anyerror!void) DidChangeDecorationsEmitter {
        return DidChangeDecorationsEmitter{
            ._actual = Emitter(ModelDecorationsChangedEvent).init(allocator),
            .allocator = allocator,
            ._deferredCnt = 0,
            ._shouldFireDeferred = false,
            ._affectsMinimap = false,
            ._affectsOverviewRuler = false,
            ._affectsGlyphMargin = false,
            ._affectsLineNumber = false,
            ._model = model,
            .handleBeforeFire = handleBeforeFire,
            ._affectedInjectedTextLines = null,
            ._affectedLineHeights = null,
        };
    }

    pub fn deinit(self: *DidChangeDecorationsEmitter) void {
        self._actual.deinit();
    }

    fn event(self: *DidChangeDecorationsEmitter, callback: fn (ModelDecorationsChangedEvent) void) !void {
        try self._actual.event(callback);
    }

    pub fn hasListeners(self: *DidChangeDecorationsEmitter) bool {
        return self._actual.hasListeners();
    }

    pub fn beginDeferredEmit(self: *DidChangeDecorationsEmitter) void {
        self._deferredCnt += 1;
    }

    pub fn endDeferredEmit(self: *DidChangeDecorationsEmitter) void {
        self._deferredCnt -= 1;
        if (self._deferredCnt == 0) {
            if (self._shouldFireDeferred) {
                self.doFire();
            }

            if (self._affectedInjectedTextLines) |set| {
                set.deinit();
            }
            self._affectedInjectedTextLines = null;
            if (self._affectedLineHeights) |set| {
                var s = set;
                s.deinit();
            }
            self._affectedLineHeights = null;
        }
    }

    pub fn recordLineAffectedByInjectedText(self: *DidChangeDecorationsEmitter, lineNumber: usize) void {
        if (self._affectedInjectedTextLines == null) {
            self._affectedInjectedTextLines = Set(usize).init(self.allocator);
        }
        _ = self._affectedInjectedTextLines.?.add(lineNumber);
    }

    pub fn recordLineAffectedByLineHeightChange(self: *DidChangeDecorationsEmitter, ownerId: u64, decorationId: []const u8, lineNumber: usize, lineHeight: ?usize) void {
        if (self._affectedLineHeights == null) {
            self._affectedLineHeights = SetWithKey(LineHeightChangingDecoration).init(self.allocator, LineHeightChangingDecoration.toKey);
        }
        self._affectedLineHeights.?.add(LineHeightChangingDecoration.init(ownerId, decorationId, lineNumber, lineHeight));
    }

    pub fn checkAffectedAndFire(self: *DidChangeDecorationsEmitter, options: *ModelDecorationOptions) void {
        self._affectsMinimap = options.minimap != null;
        self._affectsOverviewRuler = options.overviewRuler != null;
        self._affectsGlyphMargin = options.glyphMarginClassName != null;
        self._affectsLineNumber = options.lineNumberClassName != null;
        self.tryFire();
    }

    pub fn fire(self: *DidChangeDecorationsEmitter) void {
        self._affectsMinimap = true;
        self._affectsOverviewRuler = true;
        self._affectsGlyphMargin = true;
        self.tryFire();
    }

    pub fn tryFire(self: *DidChangeDecorationsEmitter) void {
        if (self._deferredCnt == 0) {
            self.doFire();
        } else {
            self._shouldFireDeferred = true;
        }
    }

    pub fn doFire(self: *DidChangeDecorationsEmitter) void {
        self.handleBeforeFire(self._model, self._affectedInjectedTextLines, self._affectedLineHeights) catch unreachable;

        const evt: ModelDecorationsChangedEvent = ModelDecorationsChangedEvent{
            .affectsMinimap = self._affectsMinimap,
            .affectsOverviewRuler = self._affectsOverviewRuler,
            .affectsGlyphMargin = self._affectsGlyphMargin,
            .affectsLineNumber = self._affectsLineNumber,
        };
        self._shouldFireDeferred = false;
        self._affectsMinimap = false;
        self._affectsOverviewRuler = false;
        self._affectsGlyphMargin = false;
        self._actual.fire(evt);
    }
};

pub const DidChangeContentEmitter = struct {
    // Both `fastEvent` and `slowEvent` work the same way and contain the same events, but first we invoke `fastEvent` and then `slowEvent`.
    _fastEmitter: Emitter(InternalModelContentChangeEvent),
    _slowEmitter: Emitter(InternalModelContentChangeEvent),

    _deferredCnt: usize,
    _deferredEvent: ?InternalModelContentChangeEvent,

    pub fn init(allocator: Allocator) DidChangeContentEmitter {
        return DidChangeContentEmitter{
            ._fastEmitter = Emitter(InternalModelContentChangeEvent).init(allocator),
            ._slowEmitter = Emitter(InternalModelContentChangeEvent).init(allocator),
            ._deferredCnt = 0,
            ._deferredEvent = null,
        };
    }

    pub fn deinit(self: *DidChangeContentEmitter) void {
        self._fastEmitter.deinit();
        self._slowEmitter.deinit();
    }

    pub fn fastEvent(self: *DidChangeContentEmitter, context: anytype, callback: fn (InternalModelContentChangeEvent) void) !void {
        try self._fastEmitter.event(context, callback);
    }
    pub fn slowEvent(self: *DidChangeContentEmitter, context: anytype, callback: fn (InternalModelContentChangeEvent) void) !void {
        try self._slowEmitter.event(context, callback);
    }

    pub fn hasListeners(self: *DidChangeContentEmitter) bool {
        return self._fastEmitter.hasListeners() or self._slowEmitter.hasListeners();
    }

    pub fn beginDeferredEmit(self: *DidChangeContentEmitter) void {
        self._deferredCnt += 1;
    }

    pub fn endDeferredEmit(self: *DidChangeContentEmitter, resultingSelection: ?[]Selection) void {
        self._deferredCnt -= 1;
        if (self._deferredCnt == 0) {
            if (self._deferredEvent) |evt| {
                var e = evt;
                e.rawContentChangedEvent.resultingSelection = resultingSelection;
                self._deferredEvent = null;
                self._fastEmitter.fire(e);
                self._slowEmitter.fire(e);
            }
        }
    }

    pub fn fire(self: *DidChangeContentEmitter, e: InternalModelContentChangeEvent) void {
        if (self._deferredCnt > 0) {
            if (self._deferredEvent) |evt| {
                self._deferredEvent = evt.merge(e) catch unreachable;
            } else {
                self._deferredEvent = e;
            }
            return;
        }
        self._fastEmitter.fire(e);
        self._slowEmitter.fire(e);
    }
};

// An accessor that can add, change or remove model decorations.
// @internal
pub const ModelDecorationsChangeAccessor = struct {
    model: *TextModel,
    ownerId: u64,

    pub fn init(model: *TextModel, ownerId: u64) ModelDecorationsChangeAccessor {
        return ModelDecorationsChangeAccessor{
            .model = model,
            .ownerId = ownerId,
        };
    }
    // Add a new decoration.
    // @param range Range that this decoration covers.
    // @param options Options associated with this decoration.
    // @return An unique identifier associated with this decoration.
    fn addDecoration(self: *ModelDecorationsChangeAccessor, range: Range, options: ModelDecorationOptions) !u64 {
        return try self.model._deltaDecorationsImpl(self.ownerId, &[_]u64{}, &[_]ModelDeltaDecoration{.{ .range = range, .options = options }});
    }
    // Change the range that an existing decoration covers.
    // @param id The unique identifier associated with the decoration.
    // @param newRange The new range that this decoration covers.
    fn changeDecoration(self: *ModelDecorationsChangeAccessor, id: []const u8, newRange: Range) void {
        self.model._changeDecorationImpl(self.ownerId, id, newRange);
    }
    // Change the options associated with an existing decoration.
    // @param id The unique identifier associated with the decoration.
    // @param newOptions The new options associated with this decoration.
    fn changeDecorationOptions(self: *ModelDecorationsChangeAccessor, id: []const u8, newOptions: ModelDecorationOptions) void {
        self.model._changeDecorationOptionsImpl(self.ownerId, id, newOptions);
    }
    // Remove an existing decoration.
    // @param id The unique identifier associated with the decoration.
    fn removeDecoration(self: *ModelDecorationsChangeAccessor, id: []const u8) void {
        self.model._deltaDecorationsImpl(self.ownerId, &[_][]const u8{id}, &[_]ModelDeltaDecoration{}) catch unreachable;
    }
    // Perform a minimum amount of operations, in order to transform the decorations
    // identified by `oldDecorations` to the decorations described by `newDecorations`
    // and returns the new identifiers associated with the resulting decorations.
    //
    // @param oldDecorations Array containing previous decorations identifiers.
    // @param newDecorations Array describing what decorations should result after the call.
    // @return An array containing the new decorations identifiers.
    fn deltaDecorations(self: *ModelDecorationsChangeAccessor, oldDecorations: []const []const u8, newDecorations: []const ModelDeltaDecoration) ![]const []const u8 {
        if (oldDecorations.len == 0 and newDecorations.len == 0) {
            return &[_][]const u8{};
        }
        return try self.model._deltaDecorationsImpl(self.ownerId, oldDecorations, newDecorations);
    }
};
