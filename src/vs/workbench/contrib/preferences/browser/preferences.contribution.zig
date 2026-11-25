// Port of the JSON preferences actions from
// src/vs/workbench/contrib/preferences/browser/preferences.contribution.ts.
const actions = @import("../../../../platform/actions/common/actions.zig");
const ServicesAccessor = @import("../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const preferences = @import("../../../services/preferences/common/preferences.zig");

pub const preferences_actions = [_]actions.Action2{
    .{ .command = .{ .id = "workbench.action.openSettingsJson", .title = "Open User Settings (JSON)", .category = "Preferences" }, .f1 = true, .context = @constCast(&{}), .run_fn = openSettingsJson },
    .{ .command = .{ .id = "workbench.action.openGlobalKeybindingsFile", .title = "Open Keyboard Shortcuts (JSON)", .category = "Preferences" }, .f1 = true, .context = @constCast(&{}), .run_fn = openGlobalKeybindingsFile },
};

fn openSettingsJson(_: *anyopaque, accessor: ServicesAccessor) !void {
    const service = try accessor.get(preferences.preferences_service_id);
    try service.openUserSettings();
}

fn openGlobalKeybindingsFile(_: *anyopaque, accessor: ServicesAccessor) !void {
    const service = try accessor.get(preferences.preferences_service_id);
    try service.openGlobalKeybindingSettings(true);
}
