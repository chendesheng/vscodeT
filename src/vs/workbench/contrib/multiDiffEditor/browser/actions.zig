// Port of the multi-diff navigation and collapse actions in
// `src/vs/workbench/contrib/multiDiffEditor/browser/actions.ts`.
const std = @import("std");
const actions = @import("../../../../platform/actions/common/actions.zig");
const ServicesAccessor = @import("../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const editor_service = @import("../../../services/editor/common/editorService.zig");
const Expr = @import("../../../../platform/contextkey/common/contextkey.zig").Expr;
const keys = @import("../../../../base/common/keyCodes.zig");
const bindings = @import("../../../../platform/keybinding/common/keybindingsRegistry.zig");
const argument_mod = @import("../../../../platform/commands/common/commands.zig");
const View = @import("../../../../editor/browser/widget/codeEditor/terminalEditorView.zig").IEditorView;
const MultiDiffWidget = @import("../../../../editor/browser/widget/multiDiffEditor/multiDiffEditorWidget.zig").MultiDiffEditorWidget(View);

const active: Expr = .{ .Equals = .{ .key = "activeEditor", .value = .{ .string = "workbench.editor.multiDiffEditor" } } };
const collapsed: Expr = .{ .Defined = "multiDiffEditorAllCollapsed" };
const not_collapsed: Expr = .{ .Not = "multiDiffEditorAllCollapsed" };
const can_collapse: Expr = .{ .And = @constCast(&[_]*const Expr{ &active, &not_collapsed }) };
const can_expand: Expr = .{ .And = @constCast(&[_]*const Expr{ &active, &collapsed }) };
const weight = @backingInt(bindings.KeybindingWeight.EditorContrib);

fn activeWidget(accessor: ServicesAccessor) !?*MultiDiffWidget {
    const service = try accessor.get(editor_service.editor_service_id);
    const pane = service.activeEditorPane() orelse return null;
    if (!std.mem.eql(u8, pane.input.type_id, @import("multiDiffEditorInput.zig").ID)) return null;
    return @ptrCast(@alignCast(pane.getControl() orelse return null));
}

fn next(_: *anyopaque, accessor: ServicesAccessor) !void {
    if (try activeWidget(accessor)) |widget| try widget.goToNextChange();
}
fn previous(_: *anyopaque, accessor: ServicesAccessor) !void {
    if (try activeWidget(accessor)) |widget| try widget.goToPreviousChange();
}
fn collapseAll(_: *anyopaque, accessor: ServicesAccessor) !void {
    if (try activeWidget(accessor)) |widget| try widget.collapseAll();
}
fn expandAll(_: *anyopaque, accessor: ServicesAccessor) !void {
    if (try activeWidget(accessor)) |widget| try widget.expandAll();
}
fn goToFile(_: *anyopaque, accessor: ServicesAccessor) !void {
    if (try activeWidget(accessor)) |widget| try widget.impl.openFile(null);
}
fn goToFileWithArgument(_: *anyopaque, accessor: ServicesAccessor, argument: argument_mod.CommandArgument) !void {
    if (try activeWidget(accessor)) |widget| {
        const resource = argument.as(std.Uri) orelse return error.InvalidArgument;
        try widget.impl.openFile(resource.*);
    }
}

pub const editor_actions = [_]actions.Action2{
    .{
        .command = .{ .id = "multiDiffEditor.goToFile", .title = "Open File", .icon = "go-to-file", .precondition = &active },
        .menus = &.{.{ .id = actions.menu_ids.MultiDiffEditorFileToolbar, .group = "navigation", .order = 22, .when = &active }},
        .context = @constCast(&{}),
        .run_fn = goToFile,
        .run_with_argument_fn = goToFileWithArgument,
    },
    .{
        .command = .{ .id = "multiDiffEditor.goToNextChange", .title = "Go to Next Change", .icon = "arrow-down", .precondition = &active },
        .f1 = true,
        .menus = &.{
            .{ .id = actions.menu_ids.EditorTitle, .group = "navigation", .order = 2, .when = &active },
            .{ .id = actions.menu_ids.CompactWindowEditorTitle, .group = "navigation", .order = 2, .when = &active },
        },
        .keybindings = &.{.{ .id = "multiDiffEditor.goToNextChange", .weight = weight, .when = &active, .bindings = .{ .primary = keys.KeyMod.Alt | @backingInt(keys.KeyCode.F5) } }},
        .context = @constCast(&{}),
        .run_fn = next,
    },
    .{
        .command = .{ .id = "multiDiffEditor.goToPreviousChange", .title = "Go to Previous Change", .icon = "arrow-up", .precondition = &active },
        .f1 = true,
        .menus = &.{
            .{ .id = actions.menu_ids.EditorTitle, .group = "navigation", .order = 1, .when = &active },
            .{ .id = actions.menu_ids.CompactWindowEditorTitle, .group = "navigation", .order = 1, .when = &active },
        },
        .keybindings = &.{.{ .id = "multiDiffEditor.goToPreviousChange", .weight = weight, .when = &active, .bindings = .{ .primary = keys.KeyMod.Alt | keys.KeyMod.Shift | @backingInt(keys.KeyCode.F5) } }},
        .context = @constCast(&{}),
        .run_fn = previous,
    },
    .{
        .command = .{ .id = "multiDiffEditor.collapseAll", .title = "Collapse All Diffs", .icon = "collapse-all", .precondition = &can_collapse },
        .f1 = true,
        .menus = &.{
            .{ .id = actions.menu_ids.EditorTitle, .group = "navigation", .order = 100, .when = &can_collapse },
            .{ .id = actions.menu_ids.CompactWindowEditorTitle, .group = "navigation", .order = 100, .when = &can_collapse },
        },
        .context = @constCast(&{}),
        .run_fn = collapseAll,
    },
    .{
        .command = .{ .id = "multiDiffEditor.expandAll", .title = "Expand All Diffs", .icon = "expand-all", .precondition = &can_expand },
        .f1 = true,
        .menus = &.{
            .{ .id = actions.menu_ids.EditorTitle, .group = "navigation", .order = 100, .when = &can_expand },
            .{ .id = actions.menu_ids.CompactWindowEditorTitle, .group = "navigation", .order = 100, .when = &can_expand },
        },
        .context = @constCast(&{}),
        .run_fn = expandAll,
    },
};
