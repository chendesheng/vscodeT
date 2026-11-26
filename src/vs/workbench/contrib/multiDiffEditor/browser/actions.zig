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
const multi_common = @import("../common/multiDiffEditor.zig");
const storage = @import("../../../../platform/storage/common/storage.zig");
const MultiDiffWidget = @import("../../../../editor/browser/widget/multiDiffEditor/multiDiffEditorWidget.zig").MultiDiffEditorWidget(View);

const active: Expr = .{ .Equals = .{ .key = "activeEditor", .value = .{ .string = multi_common.MULTI_DIFF_EDITOR_ID } } };
const collapsed: Expr = .{ .Defined = "multiDiffEditorAllCollapsed" };
const not_collapsed: Expr = .{ .Not = "multiDiffEditorAllCollapsed" };
const can_collapse: Expr = .{ .And = @constCast(&[_]*const Expr{ &active, &not_collapsed }) };
const can_expand: Expr = .{ .And = @constCast(&[_]*const Expr{ &active, &collapsed }) };
const weight = @backingInt(bindings.KeybindingWeight.EditorContrib);

const file_list_available: Expr = .{ .Defined = "multiDiffEditorFileListAvailable" };
const file_list_enabled: Expr = .{ .Defined = "multiDiffEditorFileListEnabled" };
const file_list_setting: Expr = .{ .Defined = "config.multiDiffEditor.experimental.fileList" };
const not_sessions_window: Expr = .{ .Not = "isSessionsWindow" };
const active_file_list: Expr = .{ .And = @constCast(&[_]*const Expr{ &active, &file_list_available, &file_list_setting }) };
const files_view_when: Expr = .{ .And = @constCast(&[_]*const Expr{ &active_file_list, &not_sessions_window }) };
const file_list_tree: Expr = .{ .Equals = .{ .key = "multiDiffEditorFileListViewMode", .value = .{ .string = "tree" } } };
const file_list_list: Expr = .{ .Equals = .{ .key = "multiDiffEditorFileListViewMode", .value = .{ .string = "list" } } };
const file_list_left: Expr = .{ .Equals = .{ .key = "multiDiffEditorFileListPosition", .value = .{ .string = "left" } } };
const file_list_right: Expr = .{ .Equals = .{ .key = "multiDiffEditorFileListPosition", .value = .{ .string = "right" } } };
pub const files_view_menu = actions.MenuId{ .id = "MultiDiffEditorFilesViewAndPosition" };

pub fn registerMenus(registry: *actions.MenuRegistry) !void {
    try registry.appendSubmenuItem(actions.menu_ids.EditorTitle, .{
        .title = "Files View & Position",
        .submenu = files_view_menu,
        .when = &files_view_when,
        .group = "z_files",
    });
}

fn focusFileList(_: *anyopaque, accessor: ServicesAccessor) !void {
    const service = try accessor.get(editor_service.editor_service_id);
    const pane = service.activeEditorPane() orelse return;
    if (pane.multi_diff_file_list_host) |host| try host.focusFileList();
}
fn toggleFileList(_: *anyopaque, accessor: ServicesAccessor) !void {
    try multi_common.toggleMultiDiffEditorFileList((try accessor.get(storage.storage_service_id)).*);
}
fn viewMode(comptime mode: multi_common.MultiDiffEditorFileListViewMode) *const fn (*anyopaque, ServicesAccessor) anyerror!void {
    return struct {
        fn run(_: *anyopaque, accessor: ServicesAccessor) !void {
            try multi_common.setMultiDiffEditorFileListViewMode((try accessor.get(storage.storage_service_id)).*, mode);
        }
    }.run;
}
fn position(comptime side: multi_common.MultiDiffEditorFileListPosition) *const fn (*anyopaque, ServicesAccessor) anyerror!void {
    return struct {
        fn run(_: *anyopaque, accessor: ServicesAccessor) !void {
            try multi_common.setMultiDiffEditorFileListPosition((try accessor.get(storage.storage_service_id)).*, side);
        }
    }.run;
}

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
        .command = .{ .id = "multiDiffEditor.focusFileList", .title = "Focus File List", .precondition = &file_list_available },
        .f1 = true,
        .context = @constCast(&{}),
        .run_fn = focusFileList,
    },
    .{
        .command = .{ .id = multi_common.TOGGLE_MULTI_DIFF_EDITOR_FILE_LIST_COMMAND_ID, .title = "Toggle Files", .icon = "list-flat", .precondition = &files_view_when, .toggled = &file_list_enabled },
        .f1 = true,
        .menus = &.{.{ .id = actions.menu_ids.EditorTitle, .group = "navigation", .order = 100001, .when = &files_view_when }},
        .context = @constCast(&{}),
        .run_fn = toggleFileList,
    },
    .{
        .command = .{ .id = "multiDiffEditor.viewFileListAsTree", .title = "View as Tree", .precondition = &active_file_list, .toggled = &file_list_tree },
        .menus = &.{.{ .id = files_view_menu, .group = "1_view", .order = 2, .when = &active_file_list }},
        .context = @constCast(&{}),
        .run_fn = viewMode(.tree),
    },
    .{
        .command = .{ .id = "multiDiffEditor.viewFileListAsList", .title = "View as List", .precondition = &active_file_list, .toggled = &file_list_list },
        .menus = &.{.{ .id = files_view_menu, .group = "1_view", .order = 1, .when = &active_file_list }},
        .context = @constCast(&{}),
        .run_fn = viewMode(.list),
    },
    .{
        .command = .{ .id = "multiDiffEditor.positionFileListLeft", .title = "On the Left", .precondition = &active_file_list, .toggled = &file_list_left },
        .menus = &.{.{ .id = files_view_menu, .group = "2_position", .order = 1, .when = &active_file_list }},
        .context = @constCast(&{}),
        .run_fn = position(.left),
    },
    .{
        .command = .{ .id = "multiDiffEditor.positionFileListRight", .title = "On the Right", .precondition = &active_file_list, .toggled = &file_list_right },
        .menus = &.{.{ .id = files_view_menu, .group = "2_position", .order = 2, .when = &active_file_list }},
        .context = @constCast(&{}),
        .run_fn = position(.right),
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
