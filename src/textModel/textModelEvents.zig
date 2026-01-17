const std = @import("std");
const ArrayList = std.array_list.Managed;
const Allocator = std.mem.Allocator;
const Range = @import("../basics/range.zig").Range;
const Selection = @import("../basics/selection.zig").Selection;
const InjectedTextOptions = @import("model.zig").InjectedTextOptions;
const ModelDecoration = @import("model.zig").ModelDecoration;
const EOL = @import("../basics/eolCounter.zig").EOL;
const String = @import("../basics/strings.zig").String;

pub const ModelContentChange = struct {
    range: Range,
    rangeOffset: usize,
    rangeLength: usize,
    text: String,

    pub fn deinit(self: *ModelContentChange) void {
        self.text.deinit();
    }
};

// An event describing a change in the text of a model.
pub const ModelContentChangedEvent = struct {
    // The changes are ordered from the end of the document to the beginning, so they should be safe to apply in sequence.
    changes: ArrayList(ModelContentChange),
    // The (new) end-of-line character.
    eol: EOL,
    // The new version id the model has transitioned to.
    versionId: i32,
    // Flag that indicates that this event was generated while undoing.
    isUndoing: bool,
    // Flag that indicates that this event was generated while redoing.
    isRedoing: bool,
    // Flag that indicates that all decorations were lost with this edit.
    // The model has been reset to a new value.
    isFlush: bool,
    // Flag that indicates that this event describes an eol change.
    isEolChange: bool,

    pub fn deinit(self: ModelContentChangedEvent) void {
        for (self.changes.items) |*change| {
            change.deinit();
        }
        self.changes.deinit();
    }

    pub fn merge(self: *ModelContentChangedEvent, other: *const ModelContentChangedEvent) !void {
        try self.changes.appendSlice(other.changes.items);
        self.eol = other.eol;
        self.versionId = other.versionId;
        self.isUndoing = (self.isUndoing or other.isUndoing);
        self.isRedoing = (self.isRedoing or other.isRedoing);
        self.isFlush = (self.isFlush or other.isFlush);
        self.isEolChange = self.isEolChange and other.isEolChange; // both must be true to not confuse listeners who skip such edits
    }
};

// An event describing that model decorations have changed.
pub const ModelDecorationsChangedEvent = struct {
    affectsMinimap: bool,
    affectsOverviewRuler: bool,
    affectsGlyphMargin: bool,
    affectsLineNumber: bool,
};

// An event describing that some ranges of lines have been tokenized (their tokens have changed).
// @internal
pub const ModelTokensChangedEvent = struct {
    semanticTokensApplied: bool,
    ranges: []const ModelTokensChangedRange,
};

pub const ModelOptionsChangedEvent = struct {
    tabSize: bool,
    indentSize: bool,
    insertSpaces: bool,
    trimAutoWhitespace: bool,
};

pub const RawContentChangedType = enum(u8) {
    flush = 1,
    lineChanged = 2,
    linesDeleted = 3,
    linesInserted = 4,
    eolChanged = 5,
};

// An event describing that a model has been reset to a new value.
pub const ModelRawFlush = struct {
    pub fn init() ModelRawFlush {
        return ModelRawFlush{};
    }
};

// Represents text injected on a line
pub const LineInjectedText = struct {
    ownerId: usize,
    lineNumber: usize,
    column: usize,
    options: InjectedTextOptions,
    order: usize,

    pub fn applyInjectedText(allocator: Allocator, lineText: String, injectedTexts: ?[]const LineInjectedText) !String {
        if (injectedTexts == null or injectedTexts.?.len == 0) {
            return .initOwned(try lineText.toSlice(allocator));
        }
        var result = ArrayList(u8).init(allocator);
        var lastOriginalOffset: usize = 0;
        for (injectedTexts.?) |injectedText| {
            try (try lineText.substring(lastOriginalOffset, injectedText.column - 1)).fillItems(&result);
            lastOriginalOffset = injectedText.column - 1;
            try result.appendSlice(injectedText.options.content);
        }
        try (try lineText.substring(lastOriginalOffset, lineText.len())).fillItems(&result);
        return .initOwned(result);
    }

    pub fn fromDecorations(allocator: Allocator, decorations: []const ModelDecoration) !ArrayList(LineInjectedText) {
        var result = ArrayList(LineInjectedText).init(allocator);
        for (decorations) |decoration| {
            if (decoration.options.before) |before| {
                if (before.content.len > 0) {
                    try result.append(LineInjectedText{
                        .ownerId = decoration.ownerId,
                        .lineNumber = decoration.range.startLineNumber,
                        .column = decoration.range.startColumn,
                        .options = before,
                        .order = 0,
                    });
                }
            }
            if (decoration.options.after) |after| {
                if (after.content.len > 0) {
                    try result.append(LineInjectedText{
                        .ownerId = decoration.ownerId,
                        .lineNumber = decoration.range.endLineNumber,
                        .column = decoration.range.endColumn,
                        .options = after,
                        .order = 1,
                    });
                }
            }
        }
        std.sort.heap(LineInjectedText, result.items, {}, struct {
            fn lessThan(context: void, a: LineInjectedText, b: LineInjectedText) bool {
                _ = context;
                if (a.lineNumber == b.lineNumber) {
                    if (a.column == b.column) {
                        return a.order < b.order;
                    }
                    return a.column < b.column;
                }
                return a.lineNumber < b.lineNumber;
            }
        }.lessThan);
        return result;
    }

    pub fn init(
        ownerId: usize,
        lineNumber: usize,
        column: usize,
        options: InjectedTextOptions,
        order: usize,
    ) LineInjectedText {
        return LineInjectedText{
            .ownerId = ownerId,
            .lineNumber = lineNumber,
            .column = column,
            .options = options,
            .order = order,
        };
    }

    pub fn withText(self: LineInjectedText, text: []const u8) LineInjectedText {
        var options = self.options;
        options.content = text;
        return LineInjectedText.init(self.ownerId, self.lineNumber, self.column, options, self.order);
    }
};

// An event describing that a line has changed in a model.
pub const ModelRawLineChanged = struct {
    // The line that has changed.
    lineNumber: usize,
    // The new value of the line.
    detail: String,
    // The injected text on the line.
    injectedText: ?[]const LineInjectedText,

    allocator: ?Allocator = null,

    pub fn init(lineNumber: usize, detail: String, injectedText: ?[]const LineInjectedText, allocator: ?Allocator) ModelRawLineChanged {
        return ModelRawLineChanged{
            .lineNumber = lineNumber,
            .detail = detail,
            .injectedText = injectedText,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ModelRawLineChanged) void {
        self.detail.deinit();
        if (self.allocator) |allocator| {
            if (self.injectedText) |injectedText| {
                allocator.free(injectedText);
            }
        }
    }
};

// An event describing that line(s) have been deleted in a model.
// @internal
pub const ModelRawLinesDeleted = struct {
    // At what line the deletion began (inclusive).
    fromLineNumber: usize,
    // At what line the deletion stopped (inclusive).
    toLineNumber: usize,

    pub fn init(fromLineNumber: usize, toLineNumber: usize) ModelRawLinesDeleted {
        return ModelRawLinesDeleted{
            .fromLineNumber = fromLineNumber,
            .toLineNumber = toLineNumber,
        };
    }
};

// An event describing that line(s) have been inserted in a model.
// @internal
pub const ModelRawLinesInserted = struct {
    // Before what line did the insertion begin
    fromLineNumber: usize,
    // `toLineNumber` - `fromLineNumber` + 1 denotes the number of lines that were inserted
    toLineNumber: usize,
    // The text that was inserted
    detail: ArrayList(String),
    // The injected texts for every inserted line.
    injectedTexts: ArrayList(?[]const LineInjectedText),

    pub fn init(fromLineNumber: usize, toLineNumber: usize, detail: ArrayList(String), injectedTexts: ArrayList(?[]const LineInjectedText)) ModelRawLinesInserted {
        return ModelRawLinesInserted{
            .fromLineNumber = fromLineNumber,
            .toLineNumber = toLineNumber,
            .detail = detail,
            .injectedTexts = injectedTexts,
        };
    }

    pub fn deinit(self: ModelRawLinesInserted) void {
        for (self.detail.items) |*line| {
            line.deinit();
        }
        self.detail.deinit();

        for (self.injectedTexts.items) |item| {
            if (item) |injectedText| {
                self.injectedTexts.allocator.free(injectedText);
            }
        }
        self.injectedTexts.deinit();
    }
};

// An event describing that a model has had its EOL changed.
// @internal
pub const ModelRawEOLChanged = struct {
    pub fn init() ModelRawEOLChanged {
        return ModelRawEOLChanged{};
    }
};

pub const ModelRawChange = union(RawContentChangedType) {
    flush: ModelRawFlush,
    lineChanged: ModelRawLineChanged,
    linesDeleted: ModelRawLinesDeleted,
    linesInserted: ModelRawLinesInserted,
    eolChanged: ModelRawEOLChanged,

    pub fn changeType(self: ModelRawChange) RawContentChangedType {
        return switch (self) {
            .flush => RawContentChangedType.flush,
            .lineChanged => RawContentChangedType.lineChanged,
            .linesDeleted => RawContentChangedType.linesDeleted,
            .linesInserted => RawContentChangedType.linesInserted,
            .eolChanged => RawContentChangedType.eolChanged,
        };
    }

    pub fn deinit(self: *ModelRawChange) void {
        switch (self.*) {
            .lineChanged => self.lineChanged.deinit(),
            .linesInserted => self.linesInserted.deinit(),
            else => {},
        }
    }
};

// An event describing a change in the text of a model.
pub const ModelRawContentChangedEvent = struct {
    changes: ArrayList(ModelRawChange),
    // The new version id the model has transitioned to.
    versionId: i32,
    // Flag that indicates that this event was generated while undoing.
    isUndoing: bool,
    // Flag that indicates that this event was generated while redoing.
    isRedoing: bool,

    resultingSelection: ?[]Selection,

    pub fn init(changes: ArrayList(ModelRawChange), versionId: i32, isUndoing: bool, isRedoing: bool) ModelRawContentChangedEvent {
        return ModelRawContentChangedEvent{
            .changes = changes,
            .versionId = versionId,
            .isUndoing = isUndoing,
            .isRedoing = isRedoing,
            .resultingSelection = null,
        };
    }

    pub fn deinit(self: ModelRawContentChangedEvent) void {
        for (self.changes.items) |*change| {
            change.deinit();
        }
        self.changes.deinit();
    }

    pub fn containsEvent(self: *const ModelRawContentChangedEvent, changedType: RawContentChangedType) bool {
        for (self.changes.items) |change| {
            if (change.changeType() == changedType) {
                return true;
            }
        }
        return false;
    }

    pub fn merge(self: *ModelRawContentChangedEvent, other: *const ModelRawContentChangedEvent) !void {
        try self.changes.appendSlice(other.changes.items);

        self.versionId = other.versionId;
        self.isUndoing = (self.isUndoing or other.isUndoing);
        self.isRedoing = (self.isRedoing or other.isRedoing);
    }
};

// An event describing a change in injected text.
// @internal
pub const ModelInjectedTextChangedEvent = struct {
    changes: []ModelRawLineChanged,

    pub fn init(changes: []ModelRawLineChanged) ModelInjectedTextChangedEvent {
        return ModelInjectedTextChangedEvent{
            .changes = changes,
        };
    }
};

// An event describing that a line height has changed in the model.
// @internal
pub const ModelLineHeightChanged = struct {
    // Editor owner ID
    ownerId: usize,
    // The decoration ID that has changed.
    decorationId: u64,
    // The line that has changed.
    lineNumber: usize,
    // The line height on the line.
    lineHeight: ?usize,

    pub fn init(ownerId: usize, decorationId: u64, lineNumber: usize, lineHeight: ?usize) ModelLineHeightChanged {
        return ModelLineHeightChanged{
            .ownerId = ownerId,
            .decorationId = decorationId,
            .lineNumber = lineNumber,
            .lineHeight = lineHeight,
        };
    }
};

// An event describing a change of a line height.
// @internal
pub const ModelLineHeightChangedEvent = struct {
    changes: []ModelLineHeightChanged,

    pub fn init(changes: []ModelLineHeightChanged) ModelLineHeightChangedEvent {
        return ModelLineHeightChangedEvent{
            .changes = changes,
        };
    }

    pub fn affects(self: *const ModelLineHeightChangedEvent, rangeOrPosition: Range) bool {
        if (Range.isIRange(rangeOrPosition)) {
            for (self.changes) |change| {
                if (change.lineNumber >= rangeOrPosition.startLineNumber and change.lineNumber <= rangeOrPosition.endLineNumber) {
                    return true;
                }
            }
            return false;
        } else {
            for (self.changes) |change| {
                if (change.lineNumber == rangeOrPosition.lineNumber) {
                    return true;
                }
            }
            return false;
        }
    }
};

pub const InternalModelContentChangeOrModelInjectedTextChangedEvent = union(enum) {
    internalModelContentChangeEvent: InternalModelContentChangeEvent,
    injectedTextChangedEvent: ModelInjectedTextChangedEvent,
};

pub const InternalModelContentChangeEvent = struct {
    rawContentChangedEvent: ModelRawContentChangedEvent,
    contentChangedEvent: ModelContentChangedEvent,

    pub fn init(rawContentChangedEvent: ModelRawContentChangedEvent, contentChangedEvent: ModelContentChangedEvent) InternalModelContentChangeEvent {
        return InternalModelContentChangeEvent{
            .rawContentChangedEvent = rawContentChangedEvent,
            .contentChangedEvent = contentChangedEvent,
        };
    }

    pub fn deinit(self: InternalModelContentChangeEvent) void {
        self.rawContentChangedEvent.deinit();
        self.contentChangedEvent.deinit();
    }

    pub fn merge(self: *InternalModelContentChangeEvent, other: *const InternalModelContentChangeEvent) !void {
        try self.rawContentChangedEvent.merge(&other.rawContentChangedEvent);
        try self.contentChangedEvent.merge(&other.contentChangedEvent);
    }
};

pub const ModelTokensChangedRange = struct {
    fromLineNumber: usize,
    toLineNumber: usize,
};

// An event describing that the current language associated with a model has changed.
pub const ModelLanguageChangedEvent = struct {
    // Previous language
    oldLanguage: []const u8,
    // New language
    newLanguage: []const u8,
    // Source of the call that caused the event.
    source: []const u8,
};

// An event describing that the language configuration associated with a model has changed.
pub const ModelLanguageConfigurationChangedEvent = struct {};
