const std = @import("std");
const Allocator = std.mem.Allocator;
const Position = @import("./core/position.zig").Position;
const Range = @import("./core/range.zig").Range;
const selection_mod = @import("./core/selection.zig");
const Selection = selection_mod.Selection;
const PositionAffinity = @import("./model.zig").PositionAffinity;
const CursorColumns = @import("./core/cursorColumns.zig").CursorColumns;
const editor_options = @import("./config/editorOptions.zig");
const EditorAutoClosingStrategy = editor_options.EditorAutoClosingStrategy;
const EditorAutoClosingEditStrategy = editor_options.EditorAutoClosingEditStrategy;
const EditorAutoIndentStrategy = editor_options.EditorAutoIndentStrategy;
const ILanguageConfigurationService = @import("./languages/languageConfigurationRegistry.zig").ILanguageConfigurationService;
const normalizeIndentationFn = @import("./core/misc/indentation.zig").normalizeIndentation;
const StandardAutoClosingPairConditional = @import("./languages/languageConfiguration.zig").StandardAutoClosingPairConditional;
const DefaultWordSeparators = @import("./core/wordCharacterClassifier.zig").DefaultWordSeparators;

const DEFAULT_AUTOCLOSE_BEFORE_LANGUAGE_DEFINED_QUOTES: []const u8 = ";:.,=}])> \n\t";
const DEFAULT_AUTOCLOSE_BEFORE_LANGUAGE_DEFINED_BRACKETS: []const u8 = "'\"`:.,=}])> \n\t";

pub const IColumnSelectData = struct {
    isReal: bool,
    fromViewLineNumber: usize,
    fromViewVisualColumn: usize,
    toViewLineNumber: usize,
    toViewVisualColumn: usize,
};

/// Represents an operation type recorded for undo/redo purposes.
pub const EditOperationType = enum(u3) {
    Other = 0,
    DeletingLeft = 2,
    DeletingRight = 3,
    TypingOther = 4,
    TypingFirstSpace = 5,
    TypingConsecutiveSpace = 6,
};

/// A replace edit command. This is the subset of upstream `ICommand` used by
/// the delete and type operations.
///
/// `cursor_line_offset`/`cursor_column_offset` mirror upstream
/// `ReplaceCommandWithOffsetCursorState`; they are applied to the end of the
/// replaced range after the edit. `text_owned` lets commands such as
/// `EnterOperation` return freshly allocated text that `deinit` can release.
pub const ReplaceCommand = struct {
    range: Range,
    text: []const u8,
    insertsAutoWhitespace: bool = false,
    cursor_line_offset: isize = 0,
    cursor_column_offset: isize = 0,
    text_owned: bool = false,

    pub fn init(range: Range, text: []const u8) ReplaceCommand {
        return .{ .range = range, .text = text };
    }

    pub fn initOwned(range: Range, text: []u8) ReplaceCommand {
        return .{ .range = range, .text = text, .text_owned = true };
    }

    pub fn deinit(self: *const ReplaceCommand, allocator: Allocator) void {
        if (self.text_owned) {
            allocator.free(@constCast(self.text));
        }
    }
};

pub const EditOperationResult = struct {
    type: EditOperationType,
    commands: []const ?ReplaceCommand,
    shouldPushStackElementBefore: bool,
    shouldPushStackElementAfter: bool,

    pub fn deinit(self: *EditOperationResult, allocator: Allocator) void {
        for (self.commands) |*command| {
            if (command.*) |*value| value.deinit(allocator);
        }
        allocator.free(self.commands);
    }
};

pub const SelectionStartKind = enum {
    Simple,
    Word,
    Line,
};

/// A simple model interface implemented by either the model or the view model.
pub const ICursorSimpleModel = struct {
    context: *anyopaque,
    getLineCount: *const fn (context: *anyopaque) usize,
    getLineContent: *const fn (context: *anyopaque, lineNumber: usize) []const u8,
    getLineMinColumn: *const fn (context: *anyopaque, lineNumber: usize) usize,
    getLineMaxColumn: *const fn (context: *anyopaque, lineNumber: usize) usize,
    getLineFirstNonWhitespaceColumn: *const fn (context: *anyopaque, lineNumber: usize) usize,
    getLineLastNonWhitespaceColumn: *const fn (context: *anyopaque, lineNumber: usize) usize,
    normalizePosition: *const fn (context: *anyopaque, position: Position, affinity: PositionAffinity) Position,
    getLineIndentColumn: *const fn (context: *anyopaque, lineNumber: usize) usize,
};

/// The subset of upstream `CursorConfiguration` that is independent of the
/// editor-options service. It can grow as more cursor modules are ported.
pub const CursorConfiguration = struct {
    tabSize: usize,
    indentSize: usize,
    insertSpaces: bool,
    pageSize: usize,
    stickyTabStops: bool = false,
    multiCursorMergeOverlapping: bool = true,
    trimWhitespaceOnDelete: bool = false,
    useTabStops: bool = false,
    autoSurround: @import("./config/editorOptions.zig").EditorAutoSurroundStrategy = .never,
    overtype: bool = false,
    autoIndent: EditorAutoIndentStrategy = .Full,
    languageConfigurationService: ?ILanguageConfigurationService = null,

    autoClosingBrackets: EditorAutoClosingStrategy = .languageDefined,
    autoClosingQuotes: EditorAutoClosingStrategy = .languageDefined,
    autoClosingDelete: EditorAutoClosingEditStrategy = .auto,
    autoClosingOvertype: EditorAutoClosingEditStrategy = .auto,
    auto_closing_pairs: []const StandardAutoClosingPairConditional = &.{},
    auto_close_before_quotes: []const u8 = DEFAULT_AUTOCLOSE_BEFORE_LANGUAGE_DEFINED_QUOTES,
    auto_close_before_brackets: []const u8 = DEFAULT_AUTOCLOSE_BEFORE_LANGUAGE_DEFINED_BRACKETS,
    wordSeparators: []const u8 = DefaultWordSeparators,

    pub fn visibleColumnFromColumn(self: *const CursorConfiguration, model: ICursorSimpleModel, position: Position) usize {
        return CursorColumns.visibleColumnFromColumn(
            model.getLineContent(model.context, position.lineNumber),
            position.column,
            self.tabSize,
        );
    }

    pub fn columnFromVisibleColumn(self: *const CursorConfiguration, model: ICursorSimpleModel, lineNumber: usize, visibleColumn: usize) usize {
        const result = CursorColumns.columnFromVisibleColumn(
            model.getLineContent(model.context, lineNumber),
            visibleColumn,
            self.tabSize,
        );
        const minColumn = model.getLineMinColumn(model.context, lineNumber);
        if (result < minColumn) return minColumn;
        const maxColumn = model.getLineMaxColumn(model.context, lineNumber);
        if (result > maxColumn) return maxColumn;
        return result;
    }

    /// Upstream `CursorConfiguration.normalizeIndentation`.
    pub fn normalizeIndentation(self: *const CursorConfiguration, allocator: Allocator, text: []const u8) ![]const u8 {
        return normalizeIndentationFn(allocator, text, self.indentSize, self.insertSpaces);
    }
};

/// Represents the cursor state on either the model or the view model.
pub const SingleCursorState = struct {
    selectionStart: Range,
    selectionStartKind: SelectionStartKind,
    selectionStartLeftoverVisibleColumns: isize,
    position: Position,
    leftoverVisibleColumns: isize,
    selection: Selection,

    pub fn init(
        selectionStart: Range,
        selectionStartKind: SelectionStartKind,
        selectionStartLeftoverVisibleColumns: isize,
        position: Position,
        leftoverVisibleColumns: isize,
    ) SingleCursorState {
        return .{
            .selectionStart = selectionStart,
            .selectionStartKind = selectionStartKind,
            .selectionStartLeftoverVisibleColumns = selectionStartLeftoverVisibleColumns,
            .position = position,
            .leftoverVisibleColumns = leftoverVisibleColumns,
            .selection = computeSelection(selectionStart, position),
        };
    }

    pub fn equals(self: *const SingleCursorState, other: *const SingleCursorState) bool {
        return self.selectionStartLeftoverVisibleColumns == other.selectionStartLeftoverVisibleColumns and
            self.leftoverVisibleColumns == other.leftoverVisibleColumns and
            self.selectionStartKind == other.selectionStartKind and
            self.position.lineNumber == other.position.lineNumber and
            self.position.column == other.position.column and
            self.selectionStart.startLineNumber == other.selectionStart.startLineNumber and
            self.selectionStart.startColumn == other.selectionStart.startColumn and
            self.selectionStart.endLineNumber == other.selectionStart.endLineNumber and
            self.selectionStart.endColumn == other.selectionStart.endColumn;
    }

    pub fn hasSelection(self: *const SingleCursorState) bool {
        return !selectionIsEmpty(self.selection) or !self.selectionStart.isEmpty();
    }

    pub fn move(self: *const SingleCursorState, inSelectionMode: bool, lineNumber: usize, column: usize, leftoverVisibleColumns: isize) SingleCursorState {
        if (inSelectionMode) {
            return SingleCursorState.init(
                self.selectionStart,
                self.selectionStartKind,
                self.selectionStartLeftoverVisibleColumns,
                Position.init(lineNumber, column),
                leftoverVisibleColumns,
            );
        }
        return SingleCursorState.init(
            Range.init(lineNumber, column, lineNumber, column),
            .Simple,
            leftoverVisibleColumns,
            Position.init(lineNumber, column),
            leftoverVisibleColumns,
        );
    }

    fn computeSelection(selectionStart: Range, position: Position) Selection {
        if (selectionStart.isEmpty() or !position.isBeforeOrEqual(selectionStart.getStartPosition())) {
            return selection_mod.fromPositions(selectionStart.getStartPosition(), position);
        }
        return selection_mod.fromPositions(selectionStart.getEndPosition(), position);
    }
};

fn selectionIsEmpty(selection: Selection) bool {
    return selection.startLineNumber == selection.endLineNumber and selection.startColumn == selection.endColumn;
}

pub const CursorState = struct {
    modelState: SingleCursorState,
    viewState: SingleCursorState,

    pub fn equals(self: *const CursorState, other: *const CursorState) bool {
        return self.viewState.equals(&other.viewState) and self.modelState.equals(&other.modelState);
    }

    pub fn fromModelState(modelState: SingleCursorState) PartialCursorState {
        return .{ .modelState = modelState };
    }

    pub fn fromViewState(viewState: SingleCursorState) PartialCursorState {
        return .{ .viewState = viewState };
    }

    pub fn fromModelSelection(modelSelection: Selection) PartialCursorState {
        const selectionStart = modelSelection.getSelectionStart();
        const modelState = SingleCursorState.init(
            Range.init(selectionStart.lineNumber, selectionStart.column, selectionStart.lineNumber, selectionStart.column),
            .Simple,
            0,
            modelSelection.getPosition(),
            0,
        );
        return fromModelState(modelState);
    }

    pub fn fromModelSelections(allocator: Allocator, modelSelections: []const Selection) ![]PartialCursorState {
        const states = try allocator.alloc(PartialCursorState, modelSelections.len);
        for (modelSelections, 0..) |selection, i| {
            states[i] = fromModelSelection(selection);
        }
        return states;
    }
};

pub const PartialCursorState = struct {
    modelState: ?SingleCursorState = null,
    viewState: ?SingleCursorState = null,
};

pub fn isQuote(ch: u8) bool {
    return ch == '\'' or ch == '"' or ch == '`';
}

fn expectSelection(selection: Selection, startLine: usize, startColumn: usize, endLine: usize, endColumn: usize) !void {
    try std.testing.expectEqual(startLine, selection.startLineNumber);
    try std.testing.expectEqual(startColumn, selection.startColumn);
    try std.testing.expectEqual(endLine, selection.endLineNumber);
    try std.testing.expectEqual(endColumn, selection.endColumn);
}

test "cursorCommon: SingleCursorState computes selections" {
    var state = SingleCursorState.init(Range.init(1, 1, 1, 1), .Simple, 0, Position.init(1, 5), 0);
    try expectSelection(state.selection, 1, 1, 1, 5);
    try std.testing.expect(state.hasSelection());

    state = SingleCursorState.init(Range.init(1, 5, 1, 5), .Simple, 0, Position.init(1, 1), 0);
    try expectSelection(state.selection, 1, 1, 1, 5);

    state = SingleCursorState.init(Range.init(1, 2, 1, 4), .Word, 0, Position.init(1, 3), 0);
    try expectSelection(state.selection, 1, 2, 1, 3);
}

test "cursorCommon: SingleCursorState move preserves or resets selection start" {
    const state = SingleCursorState.init(Range.init(1, 2, 1, 2), .Simple, 0, Position.init(1, 4), 0);

    const selected = state.move(true, 2, 3, 1);
    try std.testing.expectEqual(@as(usize, 1), selected.selectionStart.startLineNumber);
    try std.testing.expectEqual(@as(usize, 2), selected.selectionStart.startColumn);
    try std.testing.expectEqual(@as(isize, 1), selected.leftoverVisibleColumns);

    const unselected = state.move(false, 2, 3, 1);
    try std.testing.expectEqual(@as(usize, 2), unselected.selectionStart.startLineNumber);
    try std.testing.expectEqual(@as(usize, 3), unselected.selectionStart.startColumn);
    try std.testing.expect(!unselected.hasSelection());
}

test "cursorCommon: quote detection" {
    try std.testing.expect(isQuote('\''));
    try std.testing.expect(isQuote('"'));
    try std.testing.expect(isQuote('`'));
    try std.testing.expect(!isQuote('a'));
}
