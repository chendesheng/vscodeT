// Portable part of `src/vs/workbench/browser/layout.ts`.
//
// The browser `Layout` owns the workbench grid, DOM sashes, part instances and
// the full layout engine. The terminal model keeps the state the editor shell
// needs: which parts are visible, their cell size, the side-bar position, the
// zen-mode runtime state and the centered-editor-layout state. The terminal
// workbench still owns the grid composition and cell painting.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../base/common/event.zig").Emitter;
const layout_service = @import("../services/layout/browser/layoutService.zig");

pub const Parts = layout_service.Parts;
pub const Position = layout_service.Position;

pub const PartState = struct {
    visible: bool = true,
    /// Terminal cells. Vertical parts use height, horizontal parts width.
    size: usize = 0,
};

/// Port of `LayoutStateKeys.ZEN_MODE_EXIT_INFO`. The browser state model only
/// tracks the side bar, panel and auxiliary bar; the terminal also records the
/// status bar because the terminal workbench has no separate hidden-state key
/// to fall back to when leaving zen mode.
pub const ZenModeExitInfo = struct {
    transitioned_to_centered_editor_layout: bool = false,
    transitioned_to_full_screen: bool = false,
    handle_notifications_do_not_disturb_mode: bool = false,
    was_visible: struct {
        side_bar: bool = false,
        panel: bool = false,
        auxiliary_bar: bool = false,
        status_bar: bool = false,
    } = .{},
};

pub const LayoutModel = struct {
    allocator: Allocator,
    states: [8]PartState = .{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} },
    sidebar_position: Position = .left,
    /// Port of `LayoutStateKeys.ZEN_MODE_ACTIVE` / `ZEN_MODE_EXIT_INFO`.
    zen_mode_active: bool = false,
    zen_mode_exit_info: ZenModeExitInfo = .{},
    /// Port of `LayoutStateKeys.MAIN_EDITOR_CENTERED`. The requested state is
    /// kept separately from the effective state, like upstream
    /// `centerMainEditorLayout` keeping the runtime value while disabling the
    /// centered split view for multiple groups or complex editors.
    main_editor_centered: bool = false,
    main_editor_centered_effective: bool = false,
    on_did_change: Emitter(void),
    on_did_change_zen_mode: Emitter(bool),
    on_did_change_main_editor_centered: Emitter(bool),

    pub fn init(allocator: Allocator) LayoutModel {
        return .{
            .allocator = allocator,
            .on_did_change = Emitter(void).init(allocator),
            .on_did_change_zen_mode = Emitter(bool).init(allocator),
            .on_did_change_main_editor_centered = Emitter(bool).init(allocator),
        };
    }

    pub fn deinit(self: *LayoutModel) void {
        self.on_did_change.deinit();
        self.on_did_change_zen_mode.deinit();
        self.on_did_change_main_editor_centered.deinit();
    }

    pub fn setVisible(self: *LayoutModel, part: Parts, visible: bool) !void {
        const index = @backingInt(part);
        if (self.states[index].visible == visible) return;
        self.states[index].visible = visible;
        try self.on_did_change.fire({});
    }

    pub fn isVisible(self: *const LayoutModel, part: Parts) bool {
        return self.states[@backingInt(part)].visible;
    }

    pub fn setSize(self: *LayoutModel, part: Parts, value: usize) !void {
        const index = @backingInt(part);
        if (self.states[index].size == value) return;
        self.states[index].size = value;
        try self.on_did_change.fire({});
    }

    pub fn size(self: *const LayoutModel, part: Parts) usize {
        return self.states[@backingInt(part)].size;
    }

    pub fn setSidebarPosition(self: *LayoutModel, position: Position) !void {
        if (self.sidebar_position == position) return;
        self.sidebar_position = position;
        try self.on_did_change.fire({});
    }

    pub fn sidebarPosition(self: *const LayoutModel) Position {
        return self.sidebar_position;
    }

    /// Port of `isZenModeActive`.
    pub fn isZenModeActive(self: *const LayoutModel) bool {
        return self.zen_mode_active;
    }

    /// Port of `setZenModeActive`. Upstream fires `onDidChangeZenMode` once at
    /// the end of `toggleZenMode`, after the layout and focus restoration.
    pub fn setZenModeActive(self: *LayoutModel, active: bool) void {
        self.zen_mode_active = active;
    }

    pub fn zenModeExitInfo(self: *const LayoutModel) ZenModeExitInfo {
        return self.zen_mode_exit_info;
    }

    pub fn setZenModeExitInfo(self: *LayoutModel, info: ZenModeExitInfo) void {
        self.zen_mode_exit_info = info;
    }

    pub fn fireZenModeChanged(self: *LayoutModel) !void {
        try self.on_did_change_zen_mode.fire(self.zen_mode_active);
    }

    /// Port of `isMainEditorLayoutCentered`.
    pub fn isMainEditorCentered(self: *const LayoutModel) bool {
        return self.main_editor_centered;
    }

    pub fn setMainEditorCentered(self: *LayoutModel, active: bool) void {
        self.main_editor_centered = active;
    }

    pub fn isMainEditorCenteredEffective(self: *const LayoutModel) bool {
        return self.main_editor_centered_effective;
    }

    pub fn setMainEditorCenteredEffective(self: *LayoutModel, active: bool) void {
        self.main_editor_centered_effective = active;
    }

    pub fn fireMainEditorCenteredChanged(self: *LayoutModel) !void {
        try self.on_did_change_main_editor_centered.fire(self.main_editor_centered);
    }
};
