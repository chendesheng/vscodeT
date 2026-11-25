// Port of `src/vs/workbench/browser/workbench.zenMode.contribution.ts`.
//
// The toggle action, Appearance menu item and Escape Escape keybinding use
// IWorkbenchLayoutService. Layout owns the transition and emits the event
// after restoring focus.
//
// Terminal adaptations:
// - `workbench.zenMode.contribution.ts` has no tests; the portable values and
//   the command metadata are tested here and through the workbench shell tests.
// - `zenMode.fullScreen` has no terminal equivalent: the TUI cannot full-screen
//   its host terminal window. `zenMode.centerLayout` is implemented as a
//   centered cell layout in `Layout` (upstream's `CenteredViewLayout` ratio
//   adapted to whole cells). `zenMode.silentNotifications` has no effect because
//   the terminal workbench has no notification service.
// - `zenMode.restore` is read but has no effect: the terminal has no
//   saved zen-mode state in the workspace session.

const std = @import("std");
const configuration = @import("../../platform/configuration/common/configuration.zig");
const configuration_registry = @import("../../platform/configuration/common/configurationRegistry.zig");
const layout_service = @import("../services/layout/browser/layoutService.zig");
const ConfigurationService = @import("../services/configuration/browser/configurationService.zig").ConfigurationService;

pub const EditorTabsMode = layout_service.EditorTabsMode;
pub const ZenModeSettings = layout_service.ZenModeSettings;

const actions = @import("../../platform/actions/common/actions.zig");
const key_codes = @import("../../base/common/keyCodes.zig");
const bindings = @import("../../platform/keybinding/common/keybindingsRegistry.zig");
const Expr = @import("../../platform/contextkey/common/contextkey.zig").Expr;
const ServicesAccessor = @import("../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const in_zen_mode = Expr{ .Defined = "inZenMode" };

pub const toggle_action = actions.Action2{
    .command = .{ .id = toggle_zen_mode_id, .title = toggle_zen_mode_label, .category = category, .toggled = &in_zen_mode, .precondition = &.{ .Not = "isAuxiliaryWindowFocusedContext" } },
    .f1 = true,
    .menus = &.{.{ .id = actions.menu_ids.MenubarAppearanceMenu, .group = "1_toggle_view", .order = 2, .when = &.{ .Not = "isSessionsWindow" } }},
    .keybindings = &.{.{ .id = toggle_zen_mode_id, .weight = @backingInt(bindings.KeybindingWeight.WorkbenchContrib), .bindings = .{ .primary = key_codes.KeyChord(key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyK), @backingInt(key_codes.KeyCode.KeyZ)) } }},
    .context = @constCast(&{}),
    .run_fn = toggle,
};

pub const exit_action = actions.Action2{
    .command = .{ .id = exit_zen_mode_id, .title = exit_zen_mode_label, .category = category },
    .keybindings = &.{.{ .id = exit_zen_mode_id, .weight = @backingInt(bindings.KeybindingWeight.EditorContrib) - 1000, .when = &in_zen_mode, .bindings = .{ .primary = key_codes.KeyChord(@backingInt(key_codes.KeyCode.Escape), @backingInt(key_codes.KeyCode.Escape)) } }},
    .context = @constCast(&{}),
    .run_fn = exit,
};

fn toggle(_: *anyopaque, accessor: ServicesAccessor) anyerror!void {
    const layout = try accessor.get(layout_service.layout_service_id);
    try layout.toggleZenMode();
}

fn exit(_: *anyopaque, accessor: ServicesAccessor) anyerror!void {
    const layout = try accessor.get(layout_service.layout_service_id);
    if (layout.is_zen_mode_active(layout.context)) try layout.toggleZenMode();
}

/// Port of the configuration registered by
/// `registerZenModeConfiguration` in `workbench.zenMode.contribution.ts`.
pub const defaults_json =
    \\{
    \\  "zenMode": {
    \\    "fullScreen": true,
    \\    "centerLayout": true,
    \\    "showTabs": "multiple",
    \\    "hideStatusBar": true,
    \\    "hideActivityBar": true,
    \\    "hideLineNumbers": true,
    \\    "restore": true,
    \\    "silentNotifications": true
    \\  }
    \\}
;

/// Port of the toggle action's id/label/category
/// (`workbench.action.toggleZenMode`).
pub const toggle_zen_mode_id = "workbench.action.toggleZenMode";
pub const toggle_zen_mode_label = "Toggle Zen Mode";
pub const category = "View";

/// Port of the exit command registered with
/// `KeybindingsRegistry.registerCommandAndKeybindingRule`.
pub const exit_zen_mode_id = "workbench.action.exitZenMode";
pub const exit_zen_mode_label = "Exit Zen Mode";

/// Port of the zen-mode editor-tabs `AbstractSetShowTabsAction` classes in
/// `actions/layoutActions.ts` and their use in
/// `workbench.zenMode.contribution.ts`.
pub const zen_hide_editor_tabs_id = "workbench.action.zenHideEditorTabs";
pub const zen_hide_editor_tabs_label = "Hide Editor Tabs in Zen Mode";
pub const zen_hide_editor_tabs_description = "Hide Tab Bar in Zen Mode";

pub const zen_show_multiple_editor_tabs_id = "workbench.action.zenShowMultipleEditorTabs";
pub const zen_show_multiple_editor_tabs_label = "Show Multiple Editor Tabs in Zen Mode";
pub const zen_show_multiple_editor_tabs_description = "Show Tab Bar in Zen Mode";

pub const zen_show_single_editor_tab_id = "workbench.action.zenShowEditorTab";
pub const zen_show_single_editor_tab_label = "Show Single Editor Tab in Zen Mode";
pub const zen_show_single_editor_tab_description = "Show Tab Bar in Zen Mode with one Tab";

/// Port of `getZenModeConfiguration` (`type ZenModeConfiguration` in
/// `layout.ts`). Values are read from the effective configuration; a folder
/// resource selects that folder's `.vscode/settings.json` layer.
pub const ZenModeConfiguration = struct {
    center_layout: bool = true,
    full_screen: bool = true,
    hide_activity_bar: bool = true,
    hide_line_numbers: bool = true,
    hide_status_bar: bool = true,
    show_tabs: EditorTabsMode = .multiple,
    restore: bool = true,
    silent_notifications: bool = true,
};

pub fn load(configuration_service: ?*ConfigurationService, resource: ?[]const u8) ZenModeConfiguration {
    var values = ZenModeConfiguration{};
    const config = configuration_service orelse return values;
    const overrides: configuration.Overrides = if (resource) |path| .{ .resource = path } else .{};
    if (readValue(config, ZenModeSettings.center_layout, overrides)) |value| {
        if (value.* == .bool) values.center_layout = value.bool;
    }
    if (readValue(config, ZenModeSettings.full_screen, overrides)) |value| {
        if (value.* == .bool) values.full_screen = value.bool;
    }
    if (readValue(config, ZenModeSettings.hide_activity_bar, overrides)) |value| {
        if (value.* == .bool) values.hide_activity_bar = value.bool;
    }
    if (readValue(config, ZenModeSettings.hide_line_numbers, overrides)) |value| {
        if (value.* == .bool) values.hide_line_numbers = value.bool;
    }
    if (readValue(config, ZenModeSettings.hide_status_bar, overrides)) |value| {
        if (value.* == .bool) values.hide_status_bar = value.bool;
    }
    if (readValue(config, ZenModeSettings.restore, overrides)) |value| {
        if (value.* == .bool) values.restore = value.bool;
    }
    if (readValue(config, ZenModeSettings.silent_notifications, overrides)) |value| {
        if (value.* == .bool) values.silent_notifications = value.bool;
    }
    if (readValue(config, ZenModeSettings.show_tabs, overrides)) |value| {
        values.show_tabs = layout_service.editorTabsMode(value.*, .multiple);
    }
    return values;
}

fn readValue(
    config: *ConfigurationService,
    key: []const u8,
    overrides: configuration.Overrides,
) ?*const configuration.Value {
    return config.getValue(key, overrides);
}

/// Upstream `EditorTabsMode` string values, used when a zen-tabs action writes
/// `zenMode.showTabs`.
pub fn showTabsValue(mode: EditorTabsMode) []const u8 {
    return switch (mode) {
        .multiple => "multiple",
        .single => "single",
        .none => "none",
    };
}

test "zen mode contribution: defaults match the upstream configuration" {
    const allocator = std.testing.allocator;
    const registry = try configuration_registry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerDefaultsJson(defaults_json);

    var model = try registry.buildDefaultModel(allocator);
    defer model.deinit();

    try std.testing.expect(model.getValue("zenMode.fullScreen").?.bool);
    try std.testing.expect(model.getValue("zenMode.centerLayout").?.bool);
    try std.testing.expectEqualStrings("multiple", model.getValue("zenMode.showTabs").?.string);
    try std.testing.expect(model.getValue("zenMode.hideStatusBar").?.bool);
    try std.testing.expect(model.getValue("zenMode.hideActivityBar").?.bool);
    try std.testing.expect(model.getValue("zenMode.hideLineNumbers").?.bool);
    try std.testing.expect(model.getValue("zenMode.restore").?.bool);
    try std.testing.expect(model.getValue("zenMode.silentNotifications").?.bool);

    const defaults = load(null, null);
    try std.testing.expectEqual(EditorTabsMode.multiple, defaults.show_tabs);
    try std.testing.expect(defaults.center_layout);
    try std.testing.expectEqualStrings("single", showTabsValue(.single));
}
