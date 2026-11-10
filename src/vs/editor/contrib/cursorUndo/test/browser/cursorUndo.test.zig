// Port of the cursor undo/redo stack behavior from
// `src/vs/editor/contrib/cursorUndo/test/browser/cursorUndo.test.ts`.
const std = @import("std");
const Selection = @import("../../../../common/core/selection.zig").Selection;
const CursorUndoRedoController = @import("../../browser/cursorUndo.zig").CursorUndoRedoController;

test "cursorUndo: restores previous selections" {
    const allocator = std.testing.allocator;
    var controller = CursorUndoRedoController.init(allocator);
    defer controller.deinit();

    const old = [_]Selection{Selection.init(1, 1, 1, 1)};
    const current = [_]Selection{Selection.init(1, 2, 1, 2)};
    try controller.recordSelectionChange(&old, 0, 0);

    const restored = controller.cursorUndo(&current);
    defer allocator.free(@constCast(restored));
    try std.testing.expectEqual(@as(usize, 1), restored.len);
    try std.testing.expectEqual(@as(usize, 1), restored[0].startColumn);

    const redone = controller.cursorRedo(&old);
    defer allocator.free(@constCast(redone));
    try std.testing.expectEqual(@as(usize, 2), redone[0].startColumn);
}

test "cursorUndo: ignores selection changes across model versions" {
    const allocator = std.testing.allocator;
    var controller = CursorUndoRedoController.init(allocator);
    defer controller.deinit();

    const old = [_]Selection{Selection.init(1, 1, 1, 1)};
    try controller.recordSelectionChange(&old, 1, 2);
    try std.testing.expectEqual(@as(usize, 0), controller.undo_stack.items.len);
}
