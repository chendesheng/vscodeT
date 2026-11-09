// Port of `src/vs/editor/contrib/lineSelection/browser/lineSelection.ts`.
//
// Upstream only contributes an editor action. The portable work is done by
// `CursorMoveCommands.expandLineSelection`, so this module re-exports that
// operation with the action's name.
const Allocator = @import("std").mem.Allocator;

const cursor_common = @import("../../../common/cursorCommon.zig");
const CursorState = cursor_common.CursorState;
const ICursorSimpleModel = cursor_common.ICursorSimpleModel;
const PartialCursorState = cursor_common.PartialCursorState;
const CursorMoveCommands = @import("../../../common/cursor/cursorMoveCommands.zig").CursorMoveCommands;

pub fn expandLineSelection(
    allocator: Allocator,
    model: ICursorSimpleModel,
    cursors: []const CursorState,
) ![]PartialCursorState {
    return CursorMoveCommands.expandLineSelection(allocator, model, cursors);
}
