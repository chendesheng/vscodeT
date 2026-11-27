// Port of `src/vs/editor/browser/widget/diffEditor/diffEditor.contribution.ts`.
// Static factories replace the module-load registrations; composition calls
// this once with the workbench's command and menu registries.
const actions = @import("../../../../platform/actions/common/actions.zig");
const commands = @import("../../../../platform/commands/common/commands.zig");
const Expr = @import("../../../../platform/contextkey/common/contextkey.zig").Expr;

const in_diff = Expr{ .Defined = "isInDiffEditor" };
const moves = Expr{ .Equals = .{ .key = "config.diffEditor.experimental.showMoves", .value = .{ .boolean = true } } };
const writable = Expr{ .Defined = "diffEditorModifiedWritable" };
const inline_mode = Expr{ .Defined = "diffEditorInlineMode" };
const side_by_side = Expr{ .Not = "diffEditorInlineMode" };
const writable_inline = Expr{ .And = @constCast(&[_]*const Expr{ &writable, &inline_mode }) };
const writable_side_by_side = Expr{ .And = @constCast(&[_]*const Expr{ &writable, &side_by_side }) };
const accessible_hidden = Expr{ .Not = "accessibleDiffViewerVisible" };
const accessible_available = Expr{ .And = @constCast(&[_]*const Expr{ &in_diff, &accessible_hidden }) };

pub const editor_actions = @import("commands.zig").diff_actions;

pub fn registerMenus(registry: *actions.MenuRegistry) !void {
    try registry.appendMenuItem(actions.menu_ids.EditorTitle, .{
        .command = .{ .id = "diffEditor.toggleShowMovedCodeBlocks", .title = "Show Moved Code Blocks", .icon = "move", .precondition = &in_diff, .toggled = &moves },
        .order = 10,
        .group = "1_diff",
        .when = &in_diff,
    });
    for ([_]struct { icon: []const u8, when: *const Expr }{
        .{ .icon = "arrow-right", .when = &writable_side_by_side },
        .{ .icon = "discard", .when = &writable_inline },
    }) |variant| {
        try registry.appendMenuItem(actions.menu_ids.DiffEditorHunkToolbar, .{
            .command = .{ .id = "diffEditor.revert", .title = "Revert Block", .icon = variant.icon },
            .when = variant.when,
            .group = "primary",
            .order = 5,
        });
        try registry.appendMenuItem(actions.menu_ids.DiffEditorSelectionToolbar, .{
            .command = .{ .id = "diffEditor.revert", .title = "Revert Selection", .icon = variant.icon },
            .when = variant.when,
            .group = "primary",
            .order = 5,
        });
    }
    try registry.appendMenuItem(actions.menu_ids.EditorTitle, .{
        .command = .{ .id = "editor.action.accessibleDiffViewer.next", .title = "Open Accessible Diff Viewer", .precondition = &in_diff },
        .order = 10,
        .group = "2_diff",
        .when = &accessible_available,
    });
}

pub fn registerAliases(registry: *commands.CommandRegistry) !void {
    try registry.registerCommandAlias("editor.action.diffReview.next", "editor.action.accessibleDiffViewer.next");
    try registry.registerCommandAlias("editor.action.diffReview.prev", "editor.action.accessibleDiffViewer.prev");
}
