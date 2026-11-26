// Port of the current Diff Editor command registrations from
// src/vs/workbench/browser/parts/editor/diffEditorCommands.ts.
// Keep the existing terminal palette metadata, including the native
// snapshot-provider refresh command.
const actions = @import("../../../../platform/actions/common/actions.zig");
const ServicesAccessor = @import("../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const service = @import("diffEditorCommandsService.zig");
const configuration = @import("../../../../platform/configuration/common/configuration.zig");
const Expr = @import("../../../../platform/contextkey/common/contextkey.zig").Expr;
const compare_active = Expr{ .Defined = "textCompareEditorActive" };

pub const diff_actions = [_]actions.Action2{
    .{ .command = .{ .id = "workbench.action.compareEditor.nextChange", .title = "Go to Next Change", .category = "Diff" }, .f1 = true, .context = @constCast(&{}), .run_fn = next },
    .{ .command = .{ .id = "workbench.action.compareEditor.previousChange", .title = "Go to Previous Change", .category = "Diff" }, .f1 = true, .context = @constCast(&{}), .run_fn = previous },
    .{ .command = .{ .id = "workbench.action.compareEditor.swapSides", .title = "Swap Sides", .category = "Diff" }, .f1 = true, .context = @constCast(&{}), .run_fn = swap },
    .{ .command = .{ .id = "workbench.action.compareEditor.refreshDiff", .title = "Refresh Diff", .category = "Diff" }, .f1 = true, .context = @constCast(&{}), .run_fn = refresh },
    viewModeAction("toggle.diff.renderSideBySide", "Toggle Inline View", .toggle, true),
    viewModeAction("diffEditor.setViewMode.inline", "Inline View", .inline_view, false),
    viewModeAction("diffEditor.setViewMode.sideBySide", "Side by Side View", .side_by_side, false),
    viewModeAction("diffEditor.setViewMode.automatic", "Automatic View", .automatic, false),
    focusAction("workbench.action.compareEditor.focusPrimarySide", "Focus Modified Side", .modified),
    focusAction("workbench.action.compareEditor.focusSecondarySide", "Focus Original Side", .original),
    focusAction("workbench.action.compareEditor.focusOtherSide", "Focus Other Side", .toggle),
    .{ .command = .{ .id = "toggle.diff.ignoreTrimWhitespace", .title = "Toggle Ignore Trim Whitespace" }, .context = @constCast(&{}), .run_fn = toggleWhitespace },
};

fn next(_: *anyopaque, accessor: ServicesAccessor) !void {
    (try accessor.get(service.diff_editor_commands_service_id)).navigateInDiffEditor(true);
}

fn previous(_: *anyopaque, accessor: ServicesAccessor) !void {
    (try accessor.get(service.diff_editor_commands_service_id)).navigateInDiffEditor(false);
}

fn swap(_: *anyopaque, accessor: ServicesAccessor) !void {
    (try accessor.get(service.diff_editor_commands_service_id)).swapDiffSides();
}

fn refresh(_: *anyopaque, accessor: ServicesAccessor) !void {
    try (try accessor.get(service.diff_editor_commands_service_id)).refreshDiff();
}

fn viewModeAction(comptime id: []const u8, title: []const u8, comptime mode: service.ViewMode, palette: bool) actions.Action2 {
    return .{
        .command = .{ .id = id, .title = title, .category = "Compare", .precondition = if (palette) &compare_active else null },
        .f1 = palette,
        .context = @constCast(&{}),
        .run_fn = struct {
            fn run(_: *anyopaque, accessor: ServicesAccessor) !void {
                try (try accessor.get(service.diff_editor_commands_service_id)).setViewMode((try accessor.get(configuration.configuration_service_id)).*, mode);
            }
        }.run,
    };
}

fn focusAction(comptime id: []const u8, title: []const u8, comptime side: service.FocusSide) actions.Action2 {
    return .{
        .command = .{ .id = id, .title = title },
        .context = @constCast(&{}),
        .run_fn = struct {
            fn run(_: *anyopaque, accessor: ServicesAccessor) !void {
                (try accessor.get(service.diff_editor_commands_service_id)).focusInDiffEditor(side);
            }
        }.run,
    };
}

fn toggleWhitespace(_: *anyopaque, accessor: ServicesAccessor) !void {
    try (try accessor.get(service.diff_editor_commands_service_id)).toggleIgnoreTrimWhitespace((try accessor.get(configuration.configuration_service_id)).*);
}
