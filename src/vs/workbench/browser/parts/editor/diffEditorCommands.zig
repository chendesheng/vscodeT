// Port of the current Diff Editor command registrations from
// src/vs/workbench/browser/parts/editor/diffEditorCommands.ts.
// Keep the existing terminal palette metadata, including the native
// snapshot-provider refresh command.
const actions = @import("../../../../platform/actions/common/actions.zig");
const ServicesAccessor = @import("../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const service = @import("diffEditorCommandsService.zig");

pub const diff_actions = [_]actions.Action2{
    .{ .command = .{ .id = "workbench.action.compareEditor.nextChange", .title = "Go to Next Change", .category = "Diff" }, .f1 = true, .context = @constCast(&{}), .run_fn = next },
    .{ .command = .{ .id = "workbench.action.compareEditor.previousChange", .title = "Go to Previous Change", .category = "Diff" }, .f1 = true, .context = @constCast(&{}), .run_fn = previous },
    .{ .command = .{ .id = "workbench.action.compareEditor.swapSides", .title = "Swap Sides", .category = "Diff" }, .f1 = true, .context = @constCast(&{}), .run_fn = swap },
    .{ .command = .{ .id = "workbench.action.compareEditor.refreshDiff", .title = "Refresh Diff", .category = "Diff" }, .f1 = true, .context = @constCast(&{}), .run_fn = refresh },
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
