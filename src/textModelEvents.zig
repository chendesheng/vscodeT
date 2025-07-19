const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Range = @import("range.zig").Range;
const Selection = @import("selection.zig").Selection;
const InjectedTextOptions = @import("model.zig").InjectedTextOptions;
const ModelDecoration = @import("model.zig").ModelDecoration;

pub const ModelContentChange = struct {
    range: Range,
    rangeOffset: usize,
    rangeLength: usize,
    text: []const u8,
};

// An event describing a change in the text of a model.
pub const ModelContentChangedEvent = struct {
    // The changes are ordered from the end of the document to the beginning, so they should be safe to apply in sequence.
    changes: []ModelContentChange,
    // The (new) end-of-line character.
    eol: []const u8,
    // The new version id the model has transitioned to.
    versionId: i64,
    // Flag that indicates that this event was generated while undoing.
    isUndoing: bool,
    // Flag that indicates that this event was generated while redoing.
    isRedoing: bool,
    // Flag that indicates that all decorations were lost with this edit.
    // The model has been reset to a new value.
    isFlush: bool,
    // Flag that indicates that this event describes an eol change.
    isEolChange: bool,
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
    ranges: []struct {
        // The start of the range (inclusive)
        fromLineNumber: usize,
        // The end of the range (inclusive)
        toLineNumber: usize,
    },
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

    pub fn applyInjectedText(lineText: []const u8, injectedTexts: ?[]LineInjectedText) []const u8 {
        if (injectedTexts == null or injectedTexts.len == 0) {
            return lineText;
        }
        var result: []const u8 = "";
        var lastOriginalOffset: usize = 0;
        for (injectedTexts.?) |injectedText| {
            result = result ++ lineText[lastOriginalOffset .. injectedText.column - 1];
            lastOriginalOffset = injectedText.column - 1;
            result += injectedText.options.content;
        }
        result = result ++ lineText[lastOriginalOffset..];
        return result;
    }

    pub fn fromDecorations(allocator: Allocator, decorations: []ModelDecoration) !ArrayList(LineInjectedText) {
        var result = ArrayList(LineInjectedText).init(allocator);
        for (decorations) |decoration| {
            if (decoration.options.before and decoration.options.before.content.length > 0) {
                try result.append(LineInjectedText{
                    .ownerId = decoration.ownerId,
                    .lineNumber = decoration.range.startLineNumber,
                    .column = decoration.range.startColumn,
                    .options = decoration.options.before,
                    .order = 0,
                });
            }
            if (decoration.options.after and decoration.options.after.content.length > 0) {
                try result.append(LineInjectedText{
                    .ownerId = decoration.ownerId,
                    .lineNumber = decoration.range.endLineNumber,
                    .column = decoration.range.endColumn,
                    .options = decoration.options.after,
                    .order = 1,
                });
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
    detail: []const u8,
    // The injected text on the line.
    injectedText: ?[]LineInjectedText,

    pub fn init(lineNumber: usize, detail: []const u8, injectedText: ?[]LineInjectedText) ModelRawLineChanged {
        return ModelRawLineChanged{
            .lineNumber = lineNumber,
            .detail = detail,
            .injectedText = injectedText,
        };
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
    detail: []const []const u8,
    // The injected texts for every inserted line.
    injectedTexts: [](?[]LineInjectedText),

    pub fn init(fromLineNumber: usize, toLineNumber: usize, detail: []const []const u8, injectedTexts: [](?[]LineInjectedText)) ModelRawLinesInserted {
        return ModelRawLinesInserted{
            .fromLineNumber = fromLineNumber,
            .toLineNumber = toLineNumber,
            .detail = detail,
            .injectedTexts = injectedTexts,
        };
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
};

// An event describing a change in the text of a model.
pub const ModelRawContentChangedEvent = struct {
    changes: []ModelRawChange,
    // The new version id the model has transitioned to.
    versionId: i64,
    // Flag that indicates that this event was generated while undoing.
    isUndoing: bool,
    // Flag that indicates that this event was generated while redoing.
    isRedoing: bool,

    resultingSelection: ?[]Selection,

    pub fn init(changes: []const ModelRawChange, versionId: u32, isUndoing: bool, isRedoing: bool) ModelRawContentChangedEvent {
        return ModelRawContentChangedEvent{
            .changes = changes,
            .versionId = versionId,
            .isUndoing = isUndoing,
            .isRedoing = isRedoing,
            .resultingSelection = null,
        };
    }

    pub fn containsEvent(self: *const ModelRawContentChangedEvent, changedType: RawContentChangedType) bool {
        for (self.changes) |change| {
            if (change.changeType() == changedType) {
                return true;
            }
        }
        return false;
    }

    pub fn merge(a: ModelRawContentChangedEvent, b: ModelRawContentChangedEvent) ModelRawContentChangedEvent {
        const changes = ArrayList(ModelRawChange).init(a.changes.allocator);
        changes.appendSlice(a.changes);
        changes.appendSlice(b.changes);

        const versionId = b.versionId;
        const isUndoing = (a.isUndoing or b.isUndoing);
        const isRedoing = (a.isRedoing or b.isRedoing);
        return ModelRawContentChangedEvent.init(changes.toOwnedSlice(), versionId, isUndoing, isRedoing);
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
    decorationId: []const u8,
    // The line that has changed.
    lineNumber: usize,
    // The line height on the line.
    lineHeight: ?usize,

    pub fn init(ownerId: usize, decorationId: []const u8, lineNumber: usize, lineHeight: ?usize) ModelLineHeightChanged {
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

pub const InternalModelContentChangeEvent = struct {
    rawContentChangedEvent: ModelRawContentChangedEvent,
    contentChangedEvent: ModelContentChangedEvent,

    pub fn merge(self: InternalModelContentChangeEvent, other: InternalModelContentChangeEvent) InternalModelContentChangeEvent {
        const rawContentChangedEvent = ModelRawContentChangedEvent.merge(self.rawContentChangedEvent, other.rawContentChangedEvent);
        const contentChangedEvent = InternalModelContentChangeEvent._mergeChangeEvents(self.contentChangedEvent, other.contentChangedEvent);
        return InternalModelContentChangeEvent{
            .rawContentChangedEvent = rawContentChangedEvent,
            .contentChangedEvent = contentChangedEvent,
        };
    }

    fn _mergeChangeEvents(a: ModelContentChangedEvent, b: ModelContentChangedEvent) ModelContentChangedEvent {
        const changes = a.changes ++ b.changes;
        const eol = b.eol;
        const versionId = b.versionId;
        const isUndoing = (a.isUndoing or b.isUndoing);
        const isRedoing = (a.isRedoing or b.isRedoing);
        const isFlush = (a.isFlush or b.isFlush);
        const isEolChange = a.isEolChange and b.isEolChange; // both must be true to not confuse listeners who skip such edits
        return ModelContentChangedEvent{
            .changes = changes,
            .eol = eol,
            .isEolChange = isEolChange,
            .versionId = versionId,
            .isUndoing = isUndoing,
            .isRedoing = isRedoing,
            .isFlush = isFlush,
        };
    }
};
