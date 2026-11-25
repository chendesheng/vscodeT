// Port of `src/vs/editor/contrib/lineSelection/browser/lineSelection.ts`.
const std = @import("std");
const Allocator = std.mem.Allocator;

const cursor_common = @import("../../../common/cursorCommon.zig");
const CursorState = cursor_common.CursorState;
const ICursorSimpleModel = cursor_common.ICursorSimpleModel;
const PartialCursorState = cursor_common.PartialCursorState;
const CursorMoveCommands = @import("../../../common/cursor/cursorMoveCommands.zig").CursorMoveCommands;
const editor_extensions = @import("../../../browser/editorExtensions.zig");
const EditorAction = editor_extensions.EditorAction;

pub fn expandLineSelection(
    allocator: Allocator,
    model: ICursorSimpleModel,
    cursors: []const CursorState,
) ![]PartialCursorState {
    return CursorMoveCommands.expandLineSelection(allocator, model, cursors);
}

/// Upstream's `ExpandLineSelectionAction`. The action metadata mirrors the
/// command registration; `run` delegates to the supplied editor callback.
pub const ExpandLineSelectionAction = struct {
    pub const id = "expandLineSelection";
    pub const label = "Expand Line Selection";
    pub const description = "Expand Line Selection";
    pub const keybinding = editor_extensions.Keybinding{
        .key = "l",
        .ctrl = true,
        .weight = .editor_core,
    };

    context: *anyopaque,
    run_editor: *const fn (context: *anyopaque) anyerror!void,

    pub fn init(context: *anyopaque, run_editor: *const fn (context: *anyopaque) anyerror!void) ExpandLineSelectionAction {
        return .{ .context = context, .run_editor = run_editor };
    }

    pub fn run(self: *ExpandLineSelectionAction) !void {
        return self.run_editor(self.context);
    }

    pub fn editorAction(self: *ExpandLineSelectionAction) EditorAction {
        return EditorAction.init(.{
            .id = id,
            .label = label,
            .description = description,
            .keybinding = keybinding,
            .context = self,
            .run = runEditorAction,
        });
    }

    fn runEditorAction(context: *anyopaque) anyerror!void {
        const self: *ExpandLineSelectionAction = @ptrCast(@alignCast(context));
        return self.run();
    }
};

test "lineSelection: action metadata and run" {
    const State = struct {
        ran: bool = false,
        fn run(context: *anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.ran = true;
        }
    };

    var state = State{};
    var action = ExpandLineSelectionAction.init(&state, State.run);
    try std.testing.expectEqualStrings("expandLineSelection", action.editorAction().id);
    try std.testing.expectEqualStrings("Expand Line Selection", action.editorAction().description);
    try action.run();
    try std.testing.expect(state.ran);
}

const ActionEditor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const ActionCommand = @import("../../../browser/editorExtensions.zig").EditorCommand;
const action_registry = @import("../../../../platform/actions/common/actions.zig");

pub const editor_actions = [_]action_registry.Action2{
    ActionCommand.action(.{ .id = "expandLineSelection", .title = "Expand Line Selection", .category = "Editor" }, false, ActionEditor.expandLineSelection),
};
