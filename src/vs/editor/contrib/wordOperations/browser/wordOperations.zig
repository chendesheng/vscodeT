// Port of the portable command logic from
// `src/vs/editor/contrib/wordOperations/browser/wordOperations.ts`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const Position = @import("../../../common/core/position.zig").Position;
const Range = @import("../../../common/core/range.zig").Range;
const Selection = @import("../../../common/core/selection.zig").Selection;
const WordCharacterClassifier = @import("../../../common/core/wordCharacterClassifier.zig").WordCharacterClassifier;
const cursor_common = @import("../../../common/cursorCommon.zig");
const ICursorSimpleModel = cursor_common.ICursorSimpleModel;
const word_operations = @import("../../../common/cursor/cursorWordOperations.zig");
const WordOperations = word_operations.WordOperations;
const WordNavigationType = word_operations.WordNavigationType;
const DeleteWordContext = word_operations.DeleteWordContext;
const StandardAutoClosingPairConditional = @import("../../../common/languages/languageConfiguration.zig").StandardAutoClosingPairConditional;
const EditorAutoClosingEditStrategy = @import("../../../common/config/editorOptions.zig").EditorAutoClosingEditStrategy;

pub const WordDirection = enum { left, right };

pub const WordMoveCommand = struct {
    id: []const u8,
    label: []const u8,
    direction: WordDirection,
    navigation_type: WordNavigationType,
    in_selection_mode: bool,

    pub fn move(self: WordMoveCommand, word_separators: *const WordCharacterClassifier, model: ICursorSimpleModel, selection: Selection, has_multicursor: bool) Position {
        const position = Position.init(selection.positionLineNumber, selection.positionColumn);
        return switch (self.direction) {
            .left => WordOperations.moveWordLeft(word_separators, model, position, self.navigation_type, has_multicursor),
            .right => WordOperations.moveWordRight(word_separators, model, position, self.navigation_type),
        };
    }

    pub fn apply(self: WordMoveCommand, word_separators: *const WordCharacterClassifier, model: ICursorSimpleModel, selection: Selection, has_multicursor: bool) Selection {
        const to = self.move(word_separators, model, selection, has_multicursor);
        if (self.in_selection_mode) {
            return Selection.init(selection.selectionStartLineNumber, selection.selectionStartColumn, to.lineNumber, to.column);
        }
        return Selection.init(to.lineNumber, to.column, to.lineNumber, to.column);
    }

    pub fn applyAll(self: WordMoveCommand, allocator: Allocator, word_separators: *const WordCharacterClassifier, model: ICursorSimpleModel, selections: []const Selection) ![]Selection {
        const result = try allocator.alloc(Selection, selections.len);
        errdefer allocator.free(result);
        for (selections, 0..) |selection, i| {
            result[i] = self.apply(word_separators, model, selection, selections.len > 1);
        }
        return result;
    }
};

pub const cursor_word_start_left = WordMoveCommand{ .id = "cursorWordStartLeft", .label = "Move Word Start Left", .direction = .left, .navigation_type = .WordStart, .in_selection_mode = false };
pub const cursor_word_end_left = WordMoveCommand{ .id = "cursorWordEndLeft", .label = "Move Word End Left", .direction = .left, .navigation_type = .WordEnd, .in_selection_mode = false };
pub const cursor_word_left = WordMoveCommand{ .id = "cursorWordLeft", .label = "Move Word Left", .direction = .left, .navigation_type = .WordStartFast, .in_selection_mode = false };
pub const cursor_word_start_left_select = WordMoveCommand{ .id = "cursorWordStartLeftSelect", .label = "Move Word Start Left Select", .direction = .left, .navigation_type = .WordStart, .in_selection_mode = true };
pub const cursor_word_end_left_select = WordMoveCommand{ .id = "cursorWordEndLeftSelect", .label = "Move Word End Left Select", .direction = .left, .navigation_type = .WordEnd, .in_selection_mode = true };
pub const cursor_word_left_select = WordMoveCommand{ .id = "cursorWordLeftSelect", .label = "Move Word Left Select", .direction = .left, .navigation_type = .WordStartFast, .in_selection_mode = true };
pub const cursor_word_start_right = WordMoveCommand{ .id = "cursorWordStartRight", .label = "Move Word Start Right", .direction = .right, .navigation_type = .WordStart, .in_selection_mode = false };
pub const cursor_word_end_right = WordMoveCommand{ .id = "cursorWordEndRight", .label = "Move Word End Right", .direction = .right, .navigation_type = .WordEnd, .in_selection_mode = false };
pub const cursor_word_right = WordMoveCommand{ .id = "cursorWordRight", .label = "Move Word Right", .direction = .right, .navigation_type = .WordEnd, .in_selection_mode = false };
pub const cursor_word_start_right_select = WordMoveCommand{ .id = "cursorWordStartRightSelect", .label = "Move Word Start Right Select", .direction = .right, .navigation_type = .WordStart, .in_selection_mode = true };
pub const cursor_word_end_right_select = WordMoveCommand{ .id = "cursorWordEndRightSelect", .label = "Move Word End Right Select", .direction = .right, .navigation_type = .WordEnd, .in_selection_mode = true };
pub const cursor_word_right_select = WordMoveCommand{ .id = "cursorWordRightSelect", .label = "Move Word Right Select", .direction = .right, .navigation_type = .WordEnd, .in_selection_mode = true };

pub const DeleteWordCommand = struct {
    id: []const u8,
    label: []const u8,
    direction: WordDirection,
    navigation_type: WordNavigationType,
    whitespace_heuristics: bool,

    pub fn range(self: DeleteWordCommand, ctx: DeleteWordContext) ?Range {
        return switch (self.direction) {
            .left => WordOperations.deleteWordLeft(ctx, self.navigation_type),
            .right => WordOperations.deleteWordRight(ctx, self.navigation_type),
        };
    }

    pub fn apply(self: DeleteWordCommand, ctx: DeleteWordContext) ?Range {
        if (self.direction == .left) {
            if (self.range(ctx)) |delete_range| return delete_range;
            return Range.init(1, 1, 1, 1);
        }
        if (self.range(ctx)) |delete_range| return delete_range;
        const line_count = ctx.model.getLineCount(ctx.model.context);
        const max_column = ctx.model.getLineMaxColumn(ctx.model.context, line_count);
        return Range.init(line_count, max_column, line_count, max_column);
    }

    pub fn makeContext(self: DeleteWordCommand, word_separators: *const WordCharacterClassifier, model: ICursorSimpleModel, selection: Selection, auto_closing_delete: EditorAutoClosingEditStrategy, auto_closing_pairs: []const StandardAutoClosingPairConditional) DeleteWordContext {
        return .{
            .wordSeparators = word_separators,
            .model = model,
            .selection = selection,
            .whitespaceHeuristics = self.whitespace_heuristics,
            .autoClosingDelete = auto_closing_delete,
            .autoClosingPairs = auto_closing_pairs,
        };
    }
};

pub const delete_word_start_left = DeleteWordCommand{ .id = "deleteWordStartLeft", .label = "Delete Word Start Left", .direction = .left, .navigation_type = .WordStart, .whitespace_heuristics = false };
pub const delete_word_end_left = DeleteWordCommand{ .id = "deleteWordEndLeft", .label = "Delete Word End Left", .direction = .left, .navigation_type = .WordEnd, .whitespace_heuristics = false };
pub const delete_word_left = DeleteWordCommand{ .id = "deleteWordLeft", .label = "Delete Word Left", .direction = .left, .navigation_type = .WordStart, .whitespace_heuristics = true };
pub const delete_word_start_right = DeleteWordCommand{ .id = "deleteWordStartRight", .label = "Delete Word Start Right", .direction = .right, .navigation_type = .WordStart, .whitespace_heuristics = false };
pub const delete_word_end_right = DeleteWordCommand{ .id = "deleteWordEndRight", .label = "Delete Word End Right", .direction = .right, .navigation_type = .WordEnd, .whitespace_heuristics = false };
pub const delete_word_right = DeleteWordCommand{ .id = "deleteWordRight", .label = "Delete Word Right", .direction = .right, .navigation_type = .WordEnd, .whitespace_heuristics = true };

pub fn deleteInsideWord(word_separators: *const WordCharacterClassifier, model: ICursorSimpleModel, selection: Selection, only_word: bool) Range {
    return WordOperations.deleteInsideWord(word_separators, model, selection, only_word);
}

test "wordOperations: word move metadata" {
    try std.testing.expectEqualStrings("cursorWordLeft", cursor_word_left.id);
    try std.testing.expect(cursor_word_left_select.in_selection_mode);
}
