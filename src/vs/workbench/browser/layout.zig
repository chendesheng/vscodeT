// Portable part of `src/vs/workbench/browser/layout.ts`.
//
// The workbench grid lays out the parts and delegates sash resizing to
// SplitView. The terminal shell supplies cell sizes and paints the parts.

const std = @import("std");
const ui = @import("ui");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../base/common/event.zig").Emitter;
const grid = @import("../../base/browser/ui/grid/grid.zig");
const split_view = @import("../../base/browser/ui/splitview/splitview.zig");
const layout_service = @import("../services/layout/browser/layoutService.zig");

pub const Parts = layout_service.Parts;
pub const Position = layout_service.Position;

/// Port of the workbench grid's middle section for a left sidebar and a
/// bottom, center-aligned panel. As in createGridDescriptor, the editor and
/// panel share a vertical branch inside the horizontal middle section.
pub const WorkbenchGrid = struct {
    pub const Sash = enum {
        sidebar,
        panel,

        pub fn coordinate(self: Sash, x: usize, y: usize) usize {
            return if (self == .sidebar) x else y;
        }
    };

    pub const Layout = struct {
        activity_bar: ui.Rect,
        sidebar: ui.Rect,
        editor_column: ui.Rect,
        editor: ui.Rect,
        panel: ui.Rect,
    };

    pub const Limits = struct { minimum: usize, maximum: usize };

    last_sidebar_click: ?struct { x: usize, y: usize, time: i64 } = null,
    drag: ?struct {
        sash: Sash,
        click_y: ?usize = null,
        current: usize,
        state: split_view.SashDragState,
        views: [2]split_view.ViewSize,
    } = null,

    pub fn layout(rect: ui.Rect, activity_width: usize, sidebar_width: usize, panel_height: usize) Layout {
        const activity = grid.splitRectsAt(rect, .horizontal, @floatFromInt(activity_width), 0);
        const middle = grid.splitRectsAt(activity.second, .horizontal, @floatFromInt(sidebar_width), 0);
        const editor = grid.splitRectsAt(middle.second, .vertical, middle.second.h - @as(f64, @floatFromInt(panel_height)), 0);
        return .{
            .activity_bar = activity.first,
            .sidebar = middle.first,
            .editor_column = middle.second,
            .editor = editor.first,
            .panel = editor.second,
        };
    }

    pub fn activeSash(self: *const WorkbenchGrid) ?Sash {
        const drag = self.drag orelse return null;
        return drag.sash;
    }

    /// The fixed-size part in each branch contributes its size constraints.
    /// Its sibling takes the rest of the available space.
    pub fn onSashStart(self: *WorkbenchGrid, sash: Sash, start: usize, rects: Layout, limits: Limits, sibling_minimum: usize, alt: bool) void {
        const side = switch (sash) {
            .sidebar => ui.cell.snap(rects.sidebar.w),
            .panel => ui.cell.snap(rects.panel.h),
        };
        const remaining = switch (sash) {
            .sidebar => ui.cell.snap(rects.editor_column.w),
            .panel => ui.cell.snap(rects.editor.h),
        };
        const fixed: split_view.ViewSize = .{ .size = side, .minimum = limits.minimum, .maximum = limits.maximum, .snap = sash == .sidebar };
        const flexible: split_view.ViewSize = .{ .size = remaining, .minimum = sibling_minimum, .maximum = std.math.maxInt(usize) };
        const views = if (sash == .sidebar) [2]split_view.ViewSize{ fixed, flexible } else .{ flexible, fixed };
        self.drag = .{ .sash = sash, .current = start, .state = .onSashStart(start, views), .views = views };
        self.drag.?.state.alt = alt;
    }

    pub fn onSashChange(self: *WorkbenchGrid, current: usize) usize {
        const drag = &self.drag.?;
        if (current != drag.current) drag.click_y = null;
        drag.current = current;
        const sizes = drag.state.onSashChange(current, drag.views);
        return sizes[if (drag.sash == .sidebar) 0 else 1];
    }

    pub fn onSashEnd(self: *WorkbenchGrid) void {
        self.drag = null;
    }
};

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
    workbench_grid: WorkbenchGrid = .{},
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
