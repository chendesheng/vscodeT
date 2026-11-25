// Port of the single-window part registration, visibility and settings contracts
// from `src/vs/workbench/services/layout/browser/layoutService.ts`.
// A terminal uses cell geometry and one main window for every part.
const std = @import("std");
const configuration = @import("../../../../platform/configuration/common/configuration.zig");
const ConfigurationService = @import("../../configuration/browser/configurationService.zig").ConfigurationService;

const Part = @import("../../../browser/part.zig").Part;
const IDisposable = @import("../../../../base/common/lifecycle.zig").IDisposable;
const Emitter = @import("../../../../base/common/event.zig").Emitter;

pub const IPartVisibilityChangeEvent = struct { part_id: Parts, visible: bool };

pub const layout_service_id = @import("../../../../platform/instantiation/common/instantiation.zig").ServiceIdentifier(IWorkbenchLayoutService, "layoutService");

pub const IWorkbenchLayoutService = struct {
    context: *anyopaque,
    register_part: *const fn (*anyopaque, *Part) anyerror!IDisposable,
    set_part_hidden: *const fn (*anyopaque, bool, Parts) anyerror!void,
    is_visible: *const fn (*anyopaque, Parts) bool,
    on_did_change_part_visibility: *Emitter(IPartVisibilityChangeEvent),
    on_did_change_zen_mode: *Emitter(bool),
    on_did_change_main_editor_centered: *Emitter(bool),
    toggle_zen_mode: *const fn (*anyopaque) anyerror!void,
    is_zen_mode_active: *const fn (*anyopaque) bool,
    is_main_editor_centered: *const fn (*anyopaque) bool,

    pub fn toggleZenMode(self: @This()) !void {
        try self.toggle_zen_mode(self.context);
    }

    pub fn registerPart(self: @This(), part: *Part) !IDisposable {
        return self.register_part(self.context, part);
    }
    pub fn setPartHidden(self: @This(), hidden: bool, part: Parts) !void {
        try self.set_part_hidden(self.context, hidden, part);
    }
    pub fn isVisible(self: @This(), part: Parts) bool {
        return self.is_visible(self.context, part);
    }
};

/// Horizontal workbench constraints use the sidebar's 170 px / 10 columns
/// scale. Round minimums up so a fractional column still reserves space.
pub fn widthInCells(pixels: usize) usize {
    return std.math.divCeil(usize, pixels, 17) catch unreachable;
}

/// Upstream `Parts`. The terminal paints the same single-window parts.
pub const Parts = enum {
    titlebar,
    banner,
    activitybar,
    sidebar,
    editor,
    panel,
    auxiliarybar,
    statusbar,
};

/// Upstream `Position`: the side bar position and the panel position.
pub const Position = enum { left, right, top, bottom };

/// Upstream `ActivityBarPosition`. The terminal shell supports every value:
/// `default` is the vertical rail left of the side bar, `top`/`bottom` move the
/// activity bar into the side bar title area as a composite bar, `hidden` keeps
/// the side bar title label but removes the activity entries.
pub const ActivityBarPosition = enum {
    default,
    top,
    bottom,
    hidden,
};

/// Upstream `LayoutSettings` ids read by the terminal shell.
pub const LayoutSettings = struct {
    pub const status_bar_visible = "workbench.statusBar.visible";
    pub const activity_bar_location = "workbench.activityBar.location";
    pub const activity_bar_auto_hide = "workbench.activityBar.autoHide";
    pub const activity_bar_compact = "workbench.activityBar.compact";
    pub const editor_tabs_mode = "workbench.editor.showTabs";
    pub const editor_centered_layout_auto_resize = "workbench.editor.centeredLayoutAutoResize";
};

/// Upstream `EditorTabsMode` (`workbench.editor.showTabs` and
/// `zenMode.showTabs`).
pub const EditorTabsMode = enum { multiple, single, none };

/// Upstream `ZenModeSettings` ids.
pub const ZenModeSettings = struct {
    pub const show_tabs = "zenMode.showTabs";
    pub const hide_line_numbers = "zenMode.hideLineNumbers";
    pub const hide_status_bar = "zenMode.hideStatusBar";
    pub const hide_activity_bar = "zenMode.hideActivityBar";
    pub const center_layout = "zenMode.centerLayout";
    pub const full_screen = "zenMode.fullScreen";
    pub const restore = "zenMode.restore";
    pub const silent_notifications = "zenMode.silentNotifications";
};

/// The layout settings the terminal shell reads, with upstream defaults.
pub const LayoutSettingsValues = struct {
    status_bar_visible: bool = true,
    activity_bar_location: ActivityBarPosition = .default,
    activity_bar_auto_hide: bool = false,
    activity_bar_compact: bool = false,

    /// Reads the layout settings for `resource` (the workspace folder).
    ///
    /// Terminal adaptation: the port's configuration service only resolves the
    /// folder-level `.vscode/settings.json` layer for a resource inside the
    /// folder, so the workbench passes its workspace root; upstream
    /// `getValue(key)` resolves the window-level setting without a resource.
    pub fn load(configuration_service: ?*ConfigurationService, resource: ?[]const u8) LayoutSettingsValues {
        var values = LayoutSettingsValues{};
        const config = configuration_service orelse return values;
        const overrides: configuration.Overrides = if (resource) |path| .{ .resource = path } else .{};
        if (config.getValue(LayoutSettings.status_bar_visible, overrides)) |value| {
            if (value.* == .bool) values.status_bar_visible = value.bool;
        }
        if (config.getValue(LayoutSettings.activity_bar_location, overrides)) |value| {
            values.activity_bar_location = activityBarPosition(value.*, .default);
        }
        if (config.getValue(LayoutSettings.activity_bar_auto_hide, overrides)) |value| {
            if (value.* == .bool) values.activity_bar_auto_hide = value.bool;
        }
        if (config.getValue(LayoutSettings.activity_bar_compact, overrides)) |value| {
            if (value.* == .bool) values.activity_bar_compact = value.bool;
        }
        return values;
    }
};

pub fn activityBarPosition(value: std.json.Value, fallback: ActivityBarPosition) ActivityBarPosition {
    if (value != .string) return fallback;
    if (std.mem.eql(u8, value.string, "default")) return .default;
    if (std.mem.eql(u8, value.string, "top")) return .top;
    if (std.mem.eql(u8, value.string, "bottom")) return .bottom;
    if (std.mem.eql(u8, value.string, "hidden")) return .hidden;
    return fallback;
}

pub fn editorTabsMode(value: std.json.Value, fallback: EditorTabsMode) EditorTabsMode {
    if (value != .string) return fallback;
    if (std.mem.eql(u8, value.string, "multiple")) return .multiple;
    if (std.mem.eql(u8, value.string, "single")) return .single;
    if (std.mem.eql(u8, value.string, "none")) return .none;
    return fallback;
}

test "layoutService: activity bar position values and defaults" {
    var values = LayoutSettingsValues{};
    try std.testing.expectEqual(ActivityBarPosition.default, values.activity_bar_location);
    try std.testing.expect(!values.activity_bar_auto_hide);
    try std.testing.expect(!values.activity_bar_compact);

    values = LayoutSettingsValues.load(null, null);
    try std.testing.expectEqual(ActivityBarPosition.default, values.activity_bar_location);

    try std.testing.expectEqual(ActivityBarPosition.top, activityBarPosition(.{ .string = "top" }, .default));
    try std.testing.expectEqual(ActivityBarPosition.bottom, activityBarPosition(.{ .string = "bottom" }, .default));
    try std.testing.expectEqual(ActivityBarPosition.hidden, activityBarPosition(.{ .string = "hidden" }, .default));
    try std.testing.expectEqual(ActivityBarPosition.default, activityBarPosition(.{ .string = "sideways" }, .default));
    try std.testing.expectEqual(ActivityBarPosition.top, activityBarPosition(.{ .integer = 1 }, .top));
}

test "layoutService: editor tabs mode values and defaults" {
    try std.testing.expectEqual(EditorTabsMode.multiple, editorTabsMode(.{ .string = "multiple" }, .none));
    try std.testing.expectEqual(EditorTabsMode.single, editorTabsMode(.{ .string = "single" }, .multiple));
    try std.testing.expectEqual(EditorTabsMode.none, editorTabsMode(.{ .string = "none" }, .multiple));
    try std.testing.expectEqual(EditorTabsMode.multiple, editorTabsMode(.{ .string = "bogus" }, .multiple));
    try std.testing.expectEqual(EditorTabsMode.none, editorTabsMode(.{ .bool = true }, .none));
}
