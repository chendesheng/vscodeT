// Port of the diff editor actions in
// src/vs/editor/browser/widget/diffEditor/commands.ts.
const std = @import("std");
const actions = @import("../../../../platform/actions/common/actions.zig");
const bindings = @import("../../../../platform/keybinding/common/keybindingsRegistry.zig");
const key_codes = @import("../../../../base/common/keyCodes.zig");
const ServicesAccessor = @import("../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const configuration = @import("../../../../platform/configuration/common/configuration.zig");
const contextkey = @import("../../../../platform/contextkey/common/contextkey.zig");
const code_editors = @import("../../services/codeEditorService.zig");
const IDiffEditor = @import("../../editorBrowser.zig").IDiffEditor;
const CommandArgument = @import("../../../../platform/commands/common/commands.zig").CommandArgument;
const Range = @import("../../../common/core/range.zig").Range;

/// The command registry carries borrowed typed arguments. For the upstream
/// dry-run command result, the caller provides a nullable result slot.
pub const SwitchSideArguments = struct {
    dry_run: bool,
    destination_selection: ?*?Range = null,
};

const in_diff = contextkey.Expr{ .Defined = "isInDiffEditor" };
const comparing_move = contextkey.Expr{ .Defined = "comparingMovedCode" };
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
    blk: {
        var action = editorAction("diffEditor.revert", "Revert", "Diff Editor", null, null, IDiffEditor.revertFocusedRangeMappings);
        action.run_with_argument_fn = revertToolbarContext;
        break :blk action;
    },
    blk: {
        var action = editorAction("diffEditor.switchSide", "Switch Side", "Diff Editor", "arrow-swap", null, IDiffEditor.switchSide);
        action.run_with_argument_fn = switchSideWithArgument;
        break :blk action;
    },
    .{
        .command = .{ .id = "diffEditor.exitCompareMove", .title = "Exit Compare Move", .category = "Diff Editor", .icon = "close", .precondition = &comparing_move },
        .keybindings = &.{.{ .id = "diffEditor.exitCompareMove", .weight = 10000, .bindings = .{ .primary = @backingInt(key_codes.KeyCode.Escape) } }},
        .context = @constCast(&{}),
        .run_fn = struct {
            fn run(_: *anyopaque, accessor: ServicesAccessor) !void {
                const service = try accessor.get(code_editors.code_editor_service_id);
                const editor = service.getFocusedDiffEditor() orelse return;
                try editor.exitCompareMove();
            }
        }.run,
    },
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

fn findDiffEditor(service: code_editors.ICodeEditorService, original_uri: std.Uri, modified_uri: std.Uri) !?IDiffEditor {
    const allocator = std.heap.page_allocator;
    const uri = @import("../../../../base/common/stdUri.zig");
    const original_key = try uri.resourceKey(allocator, original_uri);
    defer allocator.free(original_key);
    const modified_key = try uri.resourceKey(allocator, modified_uri);
    defer allocator.free(modified_key);
    for (service.listDiffEditors()) |diff| {
        const original = (diff.getOriginalEditor() orelse continue).getModel() orelse continue;
        const modified = (diff.getModifiedEditor() orelse continue).getModel() orelse continue;
        const left = try uri.resourceKey(allocator, original.uri());
        defer allocator.free(left);
        const right = try uri.resourceKey(allocator, modified.uri());
        defer allocator.free(right);
        if (std.mem.eql(u8, left, original_key) and std.mem.eql(u8, right, modified_key)) return diff;
    }
    return null;
}

fn revertToolbarContext(_: *anyopaque, accessor: ServicesAccessor, argument: CommandArgument) !void {
    const service = (try accessor.get(code_editors.code_editor_service_id)).*;
    const context = argument.as(@import("features/gutterFeature.zig").DiffEditorSelectionHunkToolbarContext) orelse return;
    if (try findDiffEditor(service, context.originalUri, context.modifiedUri)) |diff| {
        try diff.revertRangeMappings(context.mapping.inner_changes orelse &.{});
    }
}

fn switchSideWithArgument(_: *anyopaque, accessor: ServicesAccessor, argument: CommandArgument) !void {
    const service = (try accessor.get(code_editors.code_editor_service_id)).*;
    const editor = service.getFocusedDiffEditor() orelse return;
    if (argument.as(SwitchSideArguments)) |args| {
        if (args.dry_run) {
            if (args.destination_selection) |result| result.* = editor.mapToOtherSide();
            return;
        }
    }
    try editor.switchSide();
}
