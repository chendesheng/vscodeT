// Port of the textual preferences subset of
// src/vs/workbench/services/preferences/common/preferences.ts.
// The settings GUI and default-settings split editor are not yet ported.
const instantiation = @import("../../../../platform/instantiation/common/instantiation.zig");

pub const preferences_service_id = instantiation.ServiceIdentifier(IPreferencesService, "preferencesService");

pub const IPreferencesService = struct {
    context: *anyopaque,
    open_user_settings_fn: *const fn (*anyopaque) anyerror!void,
    open_global_keybinding_settings_fn: *const fn (*anyopaque, bool) anyerror!void,

    pub fn openUserSettings(self: IPreferencesService) !void {
        try self.open_user_settings_fn(self.context);
    }

    pub fn openGlobalKeybindingSettings(self: IPreferencesService, textual: bool) !void {
        try self.open_global_keybinding_settings_fn(self.context, textual);
    }
};
