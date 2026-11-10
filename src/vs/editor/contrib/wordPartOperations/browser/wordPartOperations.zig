// Port of the portable command logic from
// `src/vs/editor/contrib/wordPartOperations/browser/wordPartOperations.ts`.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Position = @import("../../../common/core/position.zig").Position;
const Range = @import("../../../common/core/range.zig").Range;
const Selection = @import("../../../common/core/selection.zig").Selection;
const WordCharacterClassifier = @import("../../../common/core/wordCharacterClassifier.zig").WordCharacterClassifier;
const cursor_common = @import("../../../common/cursorCommon.zig");
const ICursorSimpleModel = cursor_common.ICursorSimpleModel;
const word_operations = @import("../../../common/cursor/cursorWordOperations.zig");
const WordPartOperations = word_operations.WordPartOperations;
const DeleteWordContext = word_operations.DeleteWordContext;
const word_operations_contrib = @import("../../wordOperations/browser/wordOperations.zig");
const WordMoveCommand = word_operations_contrib.WordMoveCommand;
const WordDirection = word_operations_contrib.WordDirection;
const WordNavigationType = word_operations.WordNavigationType;
const DeleteWordCommand = word_operations_contrib.DeleteWordCommand;

pub const WordPartLeftCommand = struct {
    in_selection_mode: bool,

    pub fn apply(self: WordPartLeftCommand, word_separators: *const WordCharacterClassifier, model: ICursorSimpleModel, selection: Selection, has_multicursor: bool) Selection {
        const from = Position.init(selection.positionLineNumber, selection.positionColumn);
        const to = WordPartOperations.moveWordPartLeft(word_separators, model, from, has_multicursor);
        if (self.in_selection_mode) {
            return Selection.init(selection.selectionStartLineNumber, selection.selectionStartColumn, to.lineNumber, to.column);
        }
        return Selection.init(to.lineNumber, to.column, to.lineNumber, to.column);
    }
};

pub const WordPartRightCommand = struct {
    in_selection_mode: bool,

    pub fn apply(self: WordPartRightCommand, word_separators: *const WordCharacterClassifier, model: ICursorSimpleModel, selection: Selection) Selection {
        const from = Position.init(selection.positionLineNumber, selection.positionColumn);
        const to = WordPartOperations.moveWordPartRight(word_separators, model, from);
        if (self.in_selection_mode) {
            return Selection.init(selection.selectionStartLineNumber, selection.selectionStartColumn, to.lineNumber, to.column);
        }
        return Selection.init(to.lineNumber, to.column, to.lineNumber, to.column);
    }
};

pub const cursor_word_part_left = WordPartLeftCommand{ .in_selection_mode = false };
pub const cursor_word_part_left_select = WordPartLeftCommand{ .in_selection_mode = true };
pub const cursor_word_part_right = WordPartRightCommand{ .in_selection_mode = false };
pub const cursor_word_part_right_select = WordPartRightCommand{ .in_selection_mode = true };

pub const DeleteWordPartLeft = struct {
    pub fn range(ctx: DeleteWordContext) Range {
        return WordPartOperations.deleteWordPartLeft(ctx);
    }
};

pub const DeleteWordPartRight = struct {
    pub fn range(ctx: DeleteWordContext) Range {
        return WordPartOperations.deleteWordPartRight(ctx);
    }
};
