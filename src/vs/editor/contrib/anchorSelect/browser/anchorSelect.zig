const std = @import("std");
// Port of the portable selection-anchor state from
// `src/vs/editor/contrib/anchorSelect/browser/anchorSelect.ts`.
const Position = @import("../../../common/core/position.zig").Position;
const Selection = @import("../../../common/core/selection.zig").Selection;
const editor_extensions = @import("../../../browser/editorExtensions.zig");
const EditorAction = editor_extensions.EditorAction;

pub const SelectionAnchorSet = "selectionAnchorSet";

pub const SelectionAnchorController = struct {
    anchor: ?Position = null,

    pub fn setSelectionAnchor(self: *SelectionAnchorController, position: Position) void {
        self.anchor = position;
    }

    pub fn goToSelectionAnchor(self: *const SelectionAnchorController) ?Position {
        return self.anchor;
    }

    pub fn selectFromAnchorToCursor(self: *SelectionAnchorController, cursor: Position) ?Selection {
        const anchor = self.anchor orelse return null;
        self.cancelSelectionAnchor();
        return Selection.init(anchor.lineNumber, anchor.column, cursor.lineNumber, cursor.column);
    }

    pub fn cancelSelectionAnchor(self: *SelectionAnchorController) void {
        self.anchor = null;
    }
};

pub const SetSelectionAnchorAction = struct {
    pub const id = "editor.action.setSelectionAnchor";
    pub const label = "Set Selection Anchor";
    pub const description = "Set Selection Anchor";
};

pub const GoToSelectionAnchorAction = struct {
    pub const id = "editor.action.goToSelectionAnchor";
    pub const label = "Go to Selection Anchor";
    pub const description = "Go to Selection Anchor";
    pub const precondition = SelectionAnchorSet;
};

pub const SelectFromAnchorToCursorAction = struct {
    pub const id = "editor.action.selectFromAnchorToCursor";
    pub const label = "Select from Anchor to Cursor";
    pub const description = "Select from Anchor to Cursor";
    pub const precondition = SelectionAnchorSet;
};

pub const CancelSelectionAnchorAction = struct {
    pub const id = "editor.action.cancelSelectionAnchor";
    pub const label = "Cancel Selection Anchor";
    pub const description = "Cancel Selection Anchor";
    pub const precondition = SelectionAnchorSet;
};

test "anchorSelect: set, go, select, cancel" {
    var controller = SelectionAnchorController{};
    try std.testing.expect(controller.goToSelectionAnchor() == null);

    controller.setSelectionAnchor(Position.init(1, 3));
    try std.testing.expectEqual(@as(usize, 3), controller.goToSelectionAnchor().?.column);

    const selection = controller.selectFromAnchorToCursor(Position.init(2, 2)).?;
    try std.testing.expectEqual(@as(usize, 1), selection.startLineNumber);
    try std.testing.expectEqual(@as(usize, 2), selection.endLineNumber);
    try std.testing.expect(controller.goToSelectionAnchor() == null);
}
