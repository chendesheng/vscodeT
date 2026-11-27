// Port of `src/vs/workbench/contrib/multiDiffEditor/test/browser/actions.test.ts`.
const std = @import("std");
const action_registry = @import("../../../../../platform/actions/common/actions.zig");
const actions = @import("../../browser/actions.zig");
const Expr = @import("../../../../../platform/contextkey/common/contextkey.zig").Expr;
const common = @import("../../common/multiDiffEditor.zig");
const editor_service = @import("../../../../services/editor/common/editorService.zig");
const environment = @import("../../../../services/environment/common/environmentService.zig");
const editor_common = @import("../../../../common/editor.zig");
const EditorInput = @import("../../../../common/editor/editorInput.zig").EditorInput;
const TextResourceEditorInput = @import("../../../../common/editor/textResourceEditorInput.zig").TextResourceEditorInput;
const Accessor = @import("../../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const View = @import("../../../../../editor/browser/widget/codeEditor/terminalEditorView.zig").IEditorView;
const Widget = @import("../../../../../editor/browser/widget/multiDiffEditor/multiDiffEditorWidget.zig").MultiDiffEditorWidget(View);
const queue_mod = @import("../../../../../base/common/windowDispatch.zig");

fn findAction(id: []const u8) !action_registry.Action2 {
    for (actions.editor_actions) |action| if (std.mem.eql(u8, action.command.id, id)) return action;
    return error.ActionNotRegistered;
}
fn checkKeys(expr: *const Expr, expected: []const []const u8) !void {
    const a = std.testing.allocator;
    const keys = try expr.keys(a);
    defer a.free(keys);
    const sorted = try a.dupe([]const u8, keys);
    defer a.free(sorted);
    std.mem.sort([]const u8, sorted, {}, struct {
        fn less(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.less);
    try std.testing.expectEqual(expected.len, sorted.len);
    for (expected, sorted) |want, actual| try std.testing.expectEqualStrings(want, actual);
}

test "MultiDiffEditor Actions: groups the view modes and positions in the editor title overflow submenu" {
    const a = std.testing.allocator;
    var registry = action_registry.MenuRegistry.init(a);
    defer registry.deinit();
    try actions.registerMenus(&registry);
    const submenu = for (registry.getMenuItems(action_registry.menu_ids.EditorTitle)) |entry| {
        if (entry == .submenu and std.mem.eql(u8, entry.submenu.submenu.id, "MultiDiffEditorFilesViewAndPosition")) break entry.submenu;
    } else return error.FilesViewSubmenuMissing;
    try std.testing.expectEqualStrings("z_files", submenu.group);
    const expected = [_]struct { id: []const u8, group: []const u8, order: f64, toggled: []const u8 }{
        .{ .id = "multiDiffEditor.viewFileListAsList", .group = "1_view", .order = 1, .toggled = "multiDiffEditorFileListViewMode == 'list'" },
        .{ .id = "multiDiffEditor.viewFileListAsTree", .group = "1_view", .order = 2, .toggled = "multiDiffEditorFileListViewMode == 'tree'" },
        .{ .id = "multiDiffEditor.positionFileListLeft", .group = "2_position", .order = 1, .toggled = "multiDiffEditorFileListPosition == 'left'" },
        .{ .id = "multiDiffEditor.positionFileListRight", .group = "2_position", .order = 2, .toggled = "multiDiffEditorFileListPosition == 'right'" },
    };
    const shared_keys: []const []const u8 = &.{ "activeEditor", "config.multiDiffEditor.experimental.fileList", "multiDiffEditorFileListAvailable" };
    for (expected) |entry| {
        const action = try findAction(entry.id);
        try std.testing.expectEqual(@as(usize, 1), action.menus.len);
        const menu = action.menus[0];
        try std.testing.expectEqualStrings(submenu.submenu.id, menu.id.id);
        try std.testing.expectEqualStrings(entry.group, menu.group);
        try std.testing.expectEqual(entry.order, menu.order);
        const toggled = try action.command.toggled.?.serialize(a);
        defer a.free(toggled);
        try std.testing.expectEqualStrings(entry.toggled, toggled);
        try checkKeys(menu.when.?, shared_keys);
        try checkKeys(action.command.precondition.?, shared_keys);
    }
    const toggle = try findAction(common.TOGGLE_MULTI_DIFF_EDITOR_FILE_LIST_COMMAND_ID);
    try std.testing.expectEqualStrings("list-flat", toggle.command.icon.?);
    try std.testing.expectEqual(@as(usize, 1), toggle.menus.len);
    try std.testing.expectEqual(@as(f64, 100001), toggle.menus[0].order);
    try checkKeys(toggle.command.precondition.?, &.{ "activeEditor", "config.multiDiffEditor.experimental.fileList", "isSessionsWindow", "multiDiffEditorFileListAvailable" });
}

pub fn Tests(comptime NativeView: type) type {
    return struct {
        const Probe = struct {
            widget: *Widget,
            input: EditorInput,
            environment_api: environment.IWorkbenchEnvironmentService = .{},
            editor_api: editor_service.IEditorService = undefined,
            target: ?editor_service.EditorTarget = null,
            valid_log: bool = false,

            fn resolve(context: *anyopaque, _: usize, id: []const u8, _: []const u8) !*anyopaque {
                const self: *Probe = @ptrCast(@alignCast(context));
                if (std.mem.eql(u8, id, editor_service.editor_service_id.id)) return &self.editor_api;
                if (std.mem.eql(u8, id, environment.workbench_environment_service_id.id)) return &self.environment_api;
                return error.UnexpectedService;
            }
            fn activePane(context: *anyopaque) ?editor_common.IVisibleEditorPane {
                const self: *Probe = @ptrCast(@alignCast(context));
                return .{ .context = self, .input = &self.input, .id = common.MULTI_DIFF_EDITOR_ID, .get_control_fn = control };
            }
            fn control(context: *anyopaque) ?*anyopaque {
                const self: *Probe = @ptrCast(@alignCast(context));
                return self.widget;
            }
            fn open(context: *anyopaque, input: *TextResourceEditorInput, target: editor_service.EditorTarget) !void {
                const self: *Probe = @ptrCast(@alignCast(context));
                self.target = target;
                const model = input.document.model;
                var contents = try model.getValue(null, false);
                defer contents.deinit();
                self.valid_log = std.mem.eql(u8, model.uri().scheme, "inmemory") and std.mem.eql(u8, model.getLanguageId(), "jsonl") and std.mem.indexOf(u8, contents.items, "\"timestamp\"") != null;
            }
        };
        test "MultiDiffEditor Actions: opens layout debug in an auxiliary window from the Agents Window" {
            const a = std.testing.allocator;
            var queue: queue_mod.Queue = .{ .io = std.testing.io };
            const widget = try Widget.create(a, std.testing.io, &queue, .{ .context = @constCast(&{}), .view_factory = NativeView.createHandle }, .noCards);
            defer widget.destroy();
            try widget.layout(80, 12);
            var probe: Probe = .{ .widget = widget, .input = EditorInput.init(a, @import("../../browser/multiDiffEditorInput.zig").ID) };
            defer probe.input.deinit();
            // Only these two methods are called by the action, as in the
            // upstream mock editor service. Opening is captured at its real
            // service boundary, including the otherwise unsupported auxiliary
            // window target.
            probe.editor_api = .{
                .context = &probe,
                .active_editor_pane_fn = Probe.activePane,
                .active_editor_fn = undefined,
                .open_editor_fn = undefined,
                .open_text_resource_fn = Probe.open,
                .request_open_editor = undefined,
                .get_editors = undefined,
                .replace_editors = undefined,
                .on_did_active_editor_change = undefined,
                .on_did_visible_editors_change = undefined,
                .on_did_close_editor = undefined,
            };
            const action = try findAction("multiDiffEditor.openLayoutDebug");
            const accessor: Accessor = .{ .context = &probe, .scope = 0, .resolve = Probe.resolve };
            for ([_]bool{ false, true }) |is_sessions_window| {
                probe.environment_api.isSessionsWindow = is_sessions_window;
                probe.target = null;
                probe.valid_log = false;
                try action.run_fn(action.context, accessor);
                try std.testing.expectEqual(if (is_sessions_window) editor_service.EditorTarget.auxiliary_window else .side, probe.target.?);
                try std.testing.expect(probe.valid_log);
            }
        }
    };
}
