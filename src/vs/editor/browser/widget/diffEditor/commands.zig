// Port of the diff editor actions in
// src/vs/editor/browser/widget/diffEditor/commands.ts.
const actions = @import("../../../../platform/actions/common/actions.zig");
const bindings = @import("../../../../platform/keybinding/common/keybindingsRegistry.zig");
const key_codes = @import("../../../../base/common/keyCodes.zig");
const ServicesAccessor = @import("../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const configuration = @import("../../../../platform/configuration/common/configuration.zig");
const contextkey = @import("../../../../platform/contextkey/common/contextkey.zig");
const code_editors = @import("../../services/codeEditorService.zig");
const IDiffEditor = @import("../../editorBrowser.zig").IDiffEditor;

const in_diff = contextkey.Expr{ .Defined = "isInDiffEditor" };
const collapse_config = contextkey.Expr{ .Defined = "config.diffEditor.hideUnchangedRegions.enabled" };

pub const diff_actions = [_]actions.Action2{
    .{
        .command = .{
            .id = "diffEditor.toggleCollapseUnchangedRegions",
            .title = "Toggle Collapse Unchanged Regions",
            .icon = "map",
            .precondition = &in_diff,
            .toggled = &collapse_config,
        },
        .menus = &.{.{ .id = actions.menu_ids.EditorTitle, .group = "navigation", .order = 22, .when = &in_diff }},
        .context = @constCast(&{}),
        .run_fn = toggleSetting("diffEditor.hideUnchangedRegions.enabled", false),
    },
    .{
        .command = .{ .id = "diffEditor.toggleShowMovedCodeBlocks", .title = "Toggle Show Moved Code Blocks", .precondition = &in_diff },
        .context = @constCast(&{}),
        .run_fn = toggleSetting("diffEditor.experimental.showMoves", false),
    },
    .{
        .command = .{ .id = "diffEditor.toggleUseInlineViewWhenSpaceIsLimited", .title = "Toggle Use Inline View When Space Is Limited", .precondition = &in_diff },
        .context = @constCast(&{}),
        .run_fn = toggleSetting("diffEditor.useInlineViewWhenSpaceIsLimited", true),
    },
    editorAction("diffEditor.switchSide", "Switch Side", "Diff Editor", "arrow-swap", null, IDiffEditor.switchSide),
    editorAction("diffEditor.collapseAllUnchangedRegions", "Collapse All Unchanged Regions", "Diff Editor", "fold", null, IDiffEditor.collapseAllUnchangedRegions),
    editorAction("diffEditor.showAllUnchangedRegions", "Show All Unchanged Regions", "Diff Editor", "unfold", null, IDiffEditor.showAllUnchangedRegions),
    editorAction("editor.action.accessibleDiffViewer.next", "Go to Next Difference", "Accessible Diff Viewer", null, @backingInt(key_codes.KeyCode.F7), IDiffEditor.accessibleDiffViewerNext),
    editorAction("editor.action.accessibleDiffViewer.prev", "Go to Previous Difference", "Accessible Diff Viewer", null, key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.F7), IDiffEditor.accessibleDiffViewerPrev),
};

fn toggleSetting(comptime setting: []const u8, comptime default: bool) actions.ActionRun {
    return struct {
        fn run(_: *anyopaque, accessor: ServicesAccessor) !void {
            const config = (try accessor.get(configuration.configuration_service_id)).*;
            try config.updateValue(setting, .{ .bool = !config.getBool(setting, default) }, .USER);
        }
    }.run;
}

fn editorAction(comptime id: []const u8, title: []const u8, category: []const u8, icon: ?[]const u8, comptime key: ?u32, comptime operation: fn (IDiffEditor) anyerror!void) actions.Action2 {
    return .{
        .command = .{ .id = id, .title = title, .category = category, .icon = icon, .precondition = &in_diff },
        .f1 = true,
        .keybindings = if (key) |primary| &.{.{ .id = id, .weight = @backingInt(bindings.KeybindingWeight.EditorContrib), .bindings = .{ .primary = primary } }} else &.{},
        .context = @constCast(&{}),
        .run_fn = struct {
            fn run(_: *anyopaque, accessor: ServicesAccessor) !void {
                const service = try accessor.get(code_editors.code_editor_service_id);
                const editor = service.getFocusedDiffEditor() orelse return;
                try operation(editor);
            }
        }.run,
    };
}
