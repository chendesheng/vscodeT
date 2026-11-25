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
const config_keys = @import("../../platform/configuration/common/configuration.zig");
const zen = @import("workbench.zenMode.contribution.zig");
const layout_service = @import("../services/layout/browser/layoutService.zig");

const EditorInput = @import("../common/editor/editorInput.zig").EditorInput;
const SignalSubscription = @import("../../base/common/event.zig").SignalSubscription;
const Part = @import("part.zig").Part;
const IDisposable = @import("../../base/common/lifecycle.zig").IDisposable;
pub const Parts = layout_service.Parts;
pub const Position = layout_service.Position;

/// Port of the workbench grid's middle section for a left or right sidebar and a
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

    pub const Rects = struct {
        sidebar_position: Position = .left,
        activity_bar: ui.Rect,
        sidebar: ui.Rect,
        editor_column: ui.Rect,
        editor: ui.Rect,
        panel: ui.Rect,

        pub fn inColumn(rect: ui.Rect, x: usize) bool {
            return x >= ui.cell.snap(rect.x) and x < ui.cell.snap(rect.right());
        }

        pub fn sidebarSashCell(self: Rects) usize {
            const left = self.sidebar_position == .left;
            if (self.sidebar.w == 0) return if (left) ui.cell.snap(self.editor.x) else ui.cell.snap(self.editor.right()) -| 1;
            return if (left) ui.cell.snap(self.sidebar.right()) - 1 else ui.cell.snap(self.sidebar.x);
        }

        pub fn hitsSidebarSash(self: Rects, x: usize, include_editor_edge: bool) bool {
            const edge = self.sidebarSashCell();
            if (x == edge) return true;
            if (self.sidebar.w == 0 or !include_editor_edge) return false;
            return if (self.sidebar_position == .left) x == edge + 1 else edge != 0 and x == edge - 1;
        }
    };

    pub const Limits = struct { minimum: usize, maximum: usize };

    last_sidebar_click: ?struct { x: usize, y: usize, time: i64 } = null,
    drag: ?struct {
        sash: Sash,
        click_y: ?usize = null,
        current: usize,
        state: split_view.SashDragState,
        views: [2]split_view.ViewSize,
        fixed_index: usize,
    } = null,

    pub fn layout(rect: ui.Rect, activity_width: usize, sidebar_width: usize, panel_height: usize, position: Position) Rects {
        const activity = grid.splitRectsAt(rect, .horizontal, @floatFromInt(activity_width), 0);
        const middle = grid.splitRectsAt(activity.second, .horizontal, @floatFromInt(sidebar_width), 0);
        var rail_rect = activity.first;
        var sidebar_rect = middle.first;
        var column = middle.second;
        if (position == .right) {
            rail_rect.x = rect.right() - rail_rect.w;
            sidebar_rect.x = rail_rect.x - sidebar_rect.w;
            column.x = rect.x;
        }
        const editor = grid.splitRectsAt(column, .vertical, column.h - @as(f64, @floatFromInt(panel_height)), 0);
        return .{
            .sidebar_position = position,
            .activity_bar = rail_rect,
            .sidebar = sidebar_rect,
            .editor_column = column,
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
    pub fn onSashStart(self: *WorkbenchGrid, sash: Sash, start: usize, rects: Rects, limits: Limits, sibling_minimum: usize, alt: bool) void {
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
        const fixed_first = sash == .sidebar and rects.sidebar_position == .left;
        const views = if (fixed_first) [2]split_view.ViewSize{ fixed, flexible } else .{ flexible, fixed };
        self.drag = .{ .sash = sash, .current = start, .state = .onSashStart(start, views), .views = views, .fixed_index = @intFromBool(!fixed_first) };
        self.drag.?.state.alt = alt;
    }

    pub fn onSashChange(self: *WorkbenchGrid, current: usize) usize {
        const drag = &self.drag.?;
        if (current != drag.current) drag.click_y = null;
        drag.current = current;
        const sizes = drag.state.onSashChange(current, drag.views);
        return sizes[drag.fixed_index];
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

/// Port of `LayoutStateKeys.ZEN_MODE_EXIT_INFO`.
pub const ZenModeExitInfo = struct {
    transitionedToCenteredEditorLayout: bool = false,
    transitionedToFullScreen: bool = false,
    handleNotificationsDoNotDisturbMode: bool = false,
    wasVisible: struct {
        sideBar: bool = false,
        panel: bool = false,
        auxiliaryBar: bool = false,
    } = .{},
};

pub const Layout = struct {
    const Barrier = @import("../../base/common/async.zig").Barrier;

    const Binding = struct {
        owner: *Layout,
        part: *Part,
        listener: ?usize = null,

        fn changed(visible: bool, self: *@This()) !void {
            try self.owner.visibilityChanged(self.part.id, visible);
        }

        fn dispose(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.listener) |id| self.part.on_did_visibility_change.unlisten(id);
            self.part.registration = .none;
            self.owner.parts.set(self.part.id, null);
        }
    };

    const EditorListeners = struct {
        restored: *Barrier,
        active_editor_event: *Emitter(?*EditorInput),
        group_subscriptions: [4]?SignalSubscription = @splat(null),
        active_editor: ?SignalSubscription = null,

        fn dispose(self: EditorListeners, layout_model: *Layout) void {
            self.restored.cancelWait(.{ .context = layout_model, .run = afterEditorsRestored });
            if (self.active_editor) |subscription| subscription.dispose();
            for (self.group_subscriptions) |entry| if (entry) |subscription| subscription.dispose();
        }
    };

    editor_listeners: ?EditorListeners = null,
    when_ready: Barrier = .{},
    when_restored: Barrier = .{},
    parts: std.EnumArray(Parts, ?Binding) = .initFill(null),
    grid_ready: bool = false,
    reset_layout: bool = false,
    main_container: ?*ui.Node = null,
    on_did_change_part_visibility: Emitter(layout_service.IPartVisibilityChangeEvent),
    allocator: Allocator,
    states: [8]PartState = .{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} },
    sidebar_position: Position = .left,
    workbench_grid: WorkbenchGrid = .{},
    // Like the browser grid, Layout retains the last laid-out container and
    // its part geometry for subsequent resize commands.
    terminal_geometry: ?TerminalGeometry = null,
    /// Port of `LayoutStateKeys.ZEN_MODE_ACTIVE` / `ZEN_MODE_EXIT_INFO`.
    zen_host: ?ZenModeHost = null,
    notification_service: ?@import("../../platform/notification/common/notification.zig").INotificationService = null,
    configured_statusbar_visible: bool = true,
    zen_hide_line_numbers: bool = false,
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

    pub fn init(allocator: Allocator) Layout {
        return .{
            .allocator = allocator,
            .on_did_change_part_visibility = .init(allocator),
            .on_did_change = Emitter(void).init(allocator),
            .on_did_change_zen_mode = Emitter(bool).init(allocator),
            .on_did_change_main_editor_centered = Emitter(bool).init(allocator),
        };
    }

    /// Register group listeners before starting contributions. The active editor
    /// listener waits for restored groups, as in Layout.initLayout.
    pub fn initLayout(self: *Layout, part: anytype) !void {
        self.editor_listeners = .{ .restored = &part.when_restored, .active_editor_event = &part.service.on_did_active_editor_change };
        const listeners = &self.editor_listeners.?;
        errdefer {
            listeners.dispose(self);
            self.editor_listeners = null;
        }
        // The cell grid also revalidates when a group moves across a split.
        inline for (.{ &part.on_did_add_group, &part.on_did_remove_group, &part.on_did_change_group_maximized, &part.on_did_move_group }, 0..) |source, index| {
            listeners.group_subscriptions[index] = try source.listenSignal(self, revalidateCenteredLayout);
        }
        try part.when_restored.wait(self.allocator, .{ .context = self, .run = afterEditorsRestored });
    }

    fn afterEditorsRestored(context: *anyopaque) !void {
        const self: *Layout = @ptrCast(@alignCast(context));
        const listeners = &self.editor_listeners.?;
        listeners.active_editor = try listeners.active_editor_event.listenSignal(self, revalidateCenteredLayout);
        try self.revalidateCenteredLayout();
    }

    fn revalidateCenteredLayout(self: *Layout) anyerror!void {
        try self.centerMainEditorLayout(self.isMainEditorCentered(), false);
    }

    pub fn deinit(self: *Layout) void {
        if (self.editor_listeners) |listeners| listeners.dispose(self);
        self.when_ready.deinit(self.allocator);
        self.when_restored.deinit(self.allocator);
        for (&self.parts.values) |*entry| if (entry.*) |*binding| Binding.dispose(binding);
        self.on_did_change_part_visibility.deinit();
        self.on_did_change.deinit();
        self.on_did_change_zen_mode.deinit();
        self.on_did_change_main_editor_centered.deinit();
    }

    pub fn interface(self: *Layout) layout_service.IWorkbenchLayoutService {
        return .{ .context = self, .get_side_bar_position = getSideBarPositionContext, .get_container = getContainerContext, .get_size = getSizeContext, .set_size = setSizeContext, .resize_part = resizePartContext, .register_part = registerPartContext, .is_visible = isVisibleContext, .has_focus = hasFocusContext, .focus_part = focusPartContext, .set_part_hidden = setPartHiddenContext, .on_did_change_part_visibility = &self.on_did_change_part_visibility, .on_did_change_zen_mode = &self.on_did_change_zen_mode, .on_did_change_main_editor_centered = &self.on_did_change_main_editor_centered, .is_zen_mode_active = zenMode, .toggle_zen_mode = toggleZenModeContext, .is_main_editor_centered = mainEditorCentered, .center_main_editor_layout = centerMainEditorLayoutContext };
    }

    fn hasFocusContext(context: *anyopaque, part: Parts) bool {
        const self: *Layout = @ptrCast(@alignCast(context));
        const host = self.zen_host orelse return false;
        return host.get_focused_part(host.context) == part;
    }

    fn focusPartContext(context: *anyopaque, part: Parts) void {
        const self: *Layout = @ptrCast(@alignCast(context));
        if (!self.isVisible(part)) return;
        const host = self.zen_host orelse return;
        host.focus_part(host.context, part);
    }

    fn getContainerContext(context: *anyopaque, part: ?Parts) ?*ui.Node {
        const self: *Layout = @ptrCast(@alignCast(context));
        return self.getContainer(part);
    }

    fn getSizeContext(context: *anyopaque, part: Parts) layout_service.IViewSize {
        const self: *Layout = @ptrCast(@alignCast(context));
        return self.getSize(part);
    }

    fn setSizeContext(context: *anyopaque, part: Parts, size_value: layout_service.IViewSize) !void {
        const self: *Layout = @ptrCast(@alignCast(context));
        try self.setViewSize(part, size_value);
    }

    fn resizePartContext(context: *anyopaque, part: Parts, width_delta: isize, height_delta: isize) !void {
        const self: *Layout = @ptrCast(@alignCast(context));
        try self.resizePart(part, width_delta, height_delta);
    }

    fn getSideBarPositionContext(context: *anyopaque) Position {
        const self: *Layout = @ptrCast(@alignCast(context));
        return self.getSideBarPosition();
    }

    fn zenMode(context: *anyopaque) bool {
        const self: *Layout = @ptrCast(@alignCast(context));
        return self.isZenModeActive();
    }

    fn mainEditorCentered(context: *anyopaque) bool {
        const self: *Layout = @ptrCast(@alignCast(context));
        return self.isMainEditorCentered();
    }

    fn centerMainEditorLayoutContext(context: *anyopaque, centered: bool) !void {
        const self: *Layout = @ptrCast(@alignCast(context));
        try self.centerMainEditorLayout(centered, false);
    }

    fn registerPartContext(context: *anyopaque, part: *Part) !IDisposable {
        const self: *Layout = @ptrCast(@alignCast(context));
        return self.registerPart(part);
    }
    fn isVisibleContext(context: *anyopaque, part: Parts) bool {
        const self: *Layout = @ptrCast(@alignCast(context));
        return self.isVisible(part);
    }
    fn setPartHiddenContext(context: *anyopaque, hidden: bool, part: Parts) !void {
        const self: *Layout = @ptrCast(@alignCast(context));
        try self.setPartHidden(hidden, part);
    }

    pub fn registerPart(self: *Layout, part: *Part) !IDisposable {
        const slot = self.parts.getPtr(part.id);
        if (slot.* != null) return error.PartAlreadyRegistered;
        slot.* = .{ .owner = self, .part = part };
        errdefer slot.* = null;
        if (self.grid_ready) try self.listenToPart(&slot.*.?);
        return .{ .context = &slot.*.?, .disposeFn = Binding.dispose };
    }

    pub fn getPart(self: *Layout, id: Parts) !*Part {
        return if (self.parts.get(id)) |binding| binding.part else error.UnknownPart;
    }

    pub fn createWorkbenchLayout(self: *Layout) !void {
        for (&self.parts.values) |*entry| {
            if (entry.*) |*binding| try self.listenToPart(binding);
        }
        self.grid_ready = true;
    }

    fn listenToPart(self: *Layout, binding: *Binding) !void {
        if (binding.listener != null) return;
        binding.listener = try binding.part.on_did_visibility_change.listen(binding, Binding.changed);
        self.states[@backingInt(binding.part.id)].visible = binding.part.read_visible(binding.part);
    }

    pub fn statusBarVisible(self: *const Layout, rows: usize) bool {
        return self.isVisible(.statusbar) and rows >= 2;
    }

    /// The workbench status row in global cells. It spans the full window,
    /// including under the sidebar and activity bar.
    pub fn statusBarRect(self: *const Layout, cols: usize, rows: usize) ui.Rect {
        if (!self.statusBarVisible(rows)) return .{};
        return .{
            .x = 0,
            .y = @floatFromInt(rows - 1),
            .w = @floatFromInt(cols),
            .h = 1,
        };
    }

    pub fn workbenchRows(self: *const Layout, rows: usize) usize {
        return if (self.statusBarVisible(rows)) rows - 1 else rows;
    }

    pub fn layout(self: *Layout, cols: usize, rows: usize, rects: WorkbenchGrid.Rects, statusbar: ui.Rect) void {
        if (self.main_container) |container| {
            var style = container.asElement().style;
            style.width = .{ .cells = @floatFromInt(cols) };
            style.height = .{ .cells = @floatFromInt(rows) };
            if (!std.meta.eql(container.asElement().style, style)) container.setStyle(style);
        }
        self.layoutPart(.activitybar, rects.activity_bar);
        self.layoutPart(.sidebar, rects.sidebar);
        self.layoutPart(.editor, rects.editor);
        self.layoutPart(.panel, rects.panel);
        self.layoutPart(.statusbar, statusbar);
    }

    /// Terminal view of Layout.layout: apply the same grid rects to the
    /// registered parts and the editor group's centered/maximized layout.
    pub fn layoutTerminal(self: *Layout, geometry: TerminalGeometry) void {
        self.terminal_geometry = geometry;
        if (self.workbench_grid.activeSash()) |sash| {
            const visible = switch (sash) {
                .sidebar => geometry.sidebar_available, // snapped sash retains pointer capture
                .panel => geometry.panelShown(),
            };
            if (!visible) self.workbench_grid.onSashEnd();
        }
        const rects = geometry.workbenchGridLayout();
        self.layout(geometry.cols, geometry.rows, rects, geometry.statusBarRect());
        geometry.part.layout(self.centeredEditorRect(rects.editor));
    }

    fn layoutPart(self: *Layout, id: Parts, rect: ui.Rect) void {
        const binding = self.parts.get(id) orelse return;
        binding.part.layout(rect.w, rect.h, rect.y, rect.x);
    }

    pub fn setStatusBarConfiguration(self: *Layout, visible: bool) !void {
        self.configured_statusbar_visible = visible;
        if (!self.isZenModeActive()) try self.setPartHidden(!visible, .statusbar);
    }

    pub fn setPartHidden(self: *Layout, hidden: bool, part: Parts) !void {
        if (part == .statusbar and !self.isZenModeActive()) self.configured_statusbar_visible = !hidden;
        if (self.parts.get(part)) |binding| {
            try binding.part.apply_visible(binding.part, !hidden);
            return;
        }
        try self.visibilityChanged(part, !hidden);
    }

    fn visibilityChanged(self: *Layout, part: Parts, visible: bool) !void {
        const state = &self.states[@backingInt(part)];
        if (state.visible == visible) return;
        state.visible = visible;
        try self.on_did_change_part_visibility.fire(.{ .part_id = part, .visible = visible });
        try self.on_did_change.fire({});
    }

    pub fn isVisible(self: *const Layout, part: Parts) bool {
        if (self.parts.get(part)) |binding| return binding.part.read_visible(binding.part);
        return self.states[@backingInt(part)].visible;
    }

    pub fn getContainer(self: *const Layout, part: ?Parts) ?*ui.Node {
        const id = part orelse return self.main_container;
        const binding = self.parts.get(id) orelse return null;
        return binding.part.getContainer();
    }

    pub fn getSize(self: *const Layout, part: Parts) layout_service.IViewSize {
        const binding = self.parts.get(part) orelse return .{};
        const rect = binding.part.bounds orelse return .{};
        return .{ .width = ui.cell.snap(rect.w), .height = ui.cell.snap(rect.h) };
    }

    /// Upstream setSize resizes the corresponding registered grid view. This
    /// terminal subset has a vertical sidebar and horizontal bottom panel.
    pub fn setViewSize(self: *Layout, part: Parts, value: layout_service.IViewSize) !void {
        switch (part) {
            .sidebar => {
                const width = if (self.terminal_geometry) |geometry| geometry.clampSidebarWidth(value.width -| geometry.sidebarFrameInset()) else value.width;
                try self.setSize(.sidebar, width);
            },
            .panel => {
                const height = if (self.terminal_geometry) |geometry| geometry.clampPanelHeight(value.height) else value.height;
                try self.setSize(.panel, height);
            },
            .editor => {
                const before = self.getSize(.editor);
                try self.resizeEditorPart(@as(isize, @intCast(value.width)) - @as(isize, @intCast(before.width)), @as(isize, @intCast(value.height)) - @as(isize, @intCast(before.height)));
            },
            else => {}, // fixed-size or unsupported native part
        }
    }

    fn adjustSize(value: usize, delta: isize) usize {
        return @intCast(@max(@as(isize, @intCast(value)) +| delta, 0));
    }

    /// Upstream resizePart applies the requested change to the active editor
    /// group first. Only dimensions that could not change are then applied to
    /// the whole editor part. Deltas are already in terminal cells here.
    pub fn resizePart(self: *Layout, part: Parts, width_delta: isize, height_delta: isize) !void {
        const size_value = self.getSize(part);
        switch (part) {
            .sidebar => try self.setViewSize(.sidebar, .{ .width = adjustSize(size_value.width, width_delta), .height = size_value.height }),
            .panel => {
                if (self.terminal_geometry) |geometry| if (!geometry.panelShown()) return;
                try self.setViewSize(.panel, .{ .width = size_value.width, .height = adjustSize(size_value.height, height_delta) });
            },
            .editor => {
                var remaining_width = width_delta;
                var remaining_height = height_delta;
                if (self.terminal_geometry) |geometry| {
                    if (geometry.part.count() > 1) {
                        if (geometry.part.activeView()) |group| {
                            const before = geometry.part.getSize(group);
                            geometry.part.setSize(group, .{ .width = adjustSize(before.width, width_delta), .height = adjustSize(before.height, height_delta) });
                            const after = geometry.part.getSize(group);
                            if (before.width != after.width) remaining_width = 0;
                            if (before.height != after.height) remaining_height = 0;
                        }
                    }
                }
                try self.resizeEditorPart(remaining_width, remaining_height);
            },
            else => {},
        }
    }

    /// Resize the outer editor view in the workbench grid, used by setSize and
    /// by the resizePart fallback when there is no applicable group sash.
    pub fn resizeEditorPart(self: *Layout, width_delta: isize, height_delta: isize) !void {
        const geometry = self.terminal_geometry orelse return;
        if (width_delta != 0 and geometry.sidebarShown()) {
            const current: isize = @intCast(geometry.sidebarWidth());
            try self.setSize(.sidebar, geometry.clampSidebarWidth(@intCast(@max(current -| width_delta, 0))));
        }
        if (height_delta != 0 and geometry.panelShown()) {
            const current: isize = @intCast(geometry.panelHeight());
            try self.setSize(.panel, geometry.clampPanelHeight(@intCast(@max(current -| height_delta, 0))));
        }
        // Group resize also needs the normal layout event when no outer part
        // size changed (or a constrained value was already at its limit).
        try self.on_did_change.fire({});
    }

    pub fn setSize(self: *Layout, part: Parts, value: usize) !void {
        const index = @backingInt(part);
        const constrained = if (self.parts.get(part)) |binding| blk: {
            const resize = binding.part.resize_primary orelse break :blk value;
            break :blk try resize(binding.part, value);
        } else value;
        if (self.states[index].size == constrained) return;
        self.states[index].size = constrained;
        try self.on_did_change.fire({});
    }

    pub fn size(self: *const Layout, part: Parts) usize {
        return self.states[@backingInt(part)].size;
    }

    pub fn setSideBarPosition(self: *Layout, position: Position) !void {
        if (self.sidebar_position == position) return;
        const Class = @import("media/part_css.zig").Class;
        const side: Class = if (position == .left) .left else .right;
        const previous: Class = if (side == .left) .right else .left;
        for ([_]Parts{ .activitybar, .sidebar }) |id| {
            const part = self.parts.get(id) orelse continue;
            const container = part.part.getContainer() orelse continue;
            try container.addClass(side);
            container.removeClass(previous);
        }
        self.workbench_grid.onSashEnd();
        self.workbench_grid.last_sidebar_click = null;
        self.sidebar_position = position;
        try self.on_did_change.fire({});
    }

    pub fn getSideBarPosition(self: *const Layout) Position {
        return self.sidebar_position;
    }

    /// Workspace-scoped LayoutStateKeys. The terminal storage adapter owns
    /// the encoding and keeps these separate from profile part sizes.
    pub const WorkspaceState = struct {
        @"workbench.editor.centered": bool = false,
        @"workbench.zenMode.active": bool = false,
        @"workbench.zenMode.exitInfo": ZenModeExitInfo = .{},
        @"workbench.sideBar.hidden": ?bool = null,
        @"workbench.panel.hidden": ?bool = null,
        @"workbench.panelpart.activepanelid": ?[]const u8 = null,
    };

    pub const ProfileState = struct {
        @"workbench.sideBar.size": ?usize = null,
        @"workbench.panel.size": ?usize = null,
    };

    pub fn workspaceState(self: *const Layout, active_panel: ?[]const u8) WorkspaceState {
        return .{
            .@"workbench.editor.centered" = self.isMainEditorCentered(),
            .@"workbench.zenMode.active" = self.isZenModeActive(),
            .@"workbench.zenMode.exitInfo" = self.zen_mode_exit_info,
            .@"workbench.sideBar.hidden" = !self.isVisible(.sidebar),
            .@"workbench.panel.hidden" = !self.isVisible(.panel),
            .@"workbench.panelpart.activepanelid" = active_panel,
        };
    }

    /// Apply the stored visibility before zen mode so leaving a restored zen
    /// session can reopen the panes recorded in ZEN_MODE_EXIT_INFO.
    fn restorePartState(self: *Layout, state: WorkspaceState) !void {
        const host = self.zen_host orelse return error.LayoutNotInitialized;
        if (state.@"workbench.sideBar.hidden") |hidden| try self.setPartHidden(hidden, .sidebar);
        if (state.@"workbench.panel.hidden") |hidden| try self.setPartHidden(hidden, .panel);
        self.main_editor_centered = state.@"workbench.editor.centered";
        self.zen_mode_exit_info = state.@"workbench.zenMode.exitInfo";
        if (state.@"workbench.zenMode.active") {
            self.setZenModeActive(!host.get_configuration(host.context).restore);
            try self.toggleZenMode(false, true);
        }
        if (self.isMainEditorCentered()) try self.centerMainEditorLayout(true, true);
    }

    pub fn restoreParts(self: *Layout, saved: ?WorkspaceState, editors_restored: *Barrier) !void {
        const state_result = if (!self.reset_layout and saved != null) self.restorePartState(saved.?) else {};
        // The native layout builds group views and opens pane composites
        // synchronously. Editor resolution has its own completion boundary.
        const ready_result = self.when_ready.open(self.allocator);
        try editors_restored.wait(self.allocator, .{ .context = self, .run = onEditorsRestored });
        try ready_result;
        try state_result;
    }

    fn onEditorsRestored(context: *anyopaque) !void {
        const self: *Layout = @ptrCast(@alignCast(context));
        try self.when_restored.open(self.allocator);
    }

    pub fn isRestored(self: *const Layout) bool {
        return self.when_restored.is_open;
    }

    pub fn restorePartSizes(self: *Layout, state: ProfileState) !void {
        if (self.reset_layout) return;
        if (state.@"workbench.sideBar.size") |size_in_cells| try self.setSize(.sidebar, size_in_cells);
        if (state.@"workbench.panel.size") |size_in_cells| try self.setSize(.panel, size_in_cells);
    }

    /// Port of `isZenModeActive`.
    pub fn isZenModeActive(self: *const Layout) bool {
        return self.zen_mode_active;
    }

    /// Port of `setZenModeActive`. Upstream fires `onDidChangeZenMode` once at
    /// the end of `toggleZenMode`, after the layout and focus restoration.
    pub fn setZenModeActive(self: *Layout, active: bool) void {
        self.zen_mode_active = active;
    }

    /// The host supplies terminal focus, configured part visibility and the
    /// editor option overrides. Layout orders part and editor transitions.
    pub const ZenModeHost = struct {
        context: *anyopaque,
        get_configuration: *const fn (*anyopaque) zen.ZenModeConfiguration,
        get_centered_options: *const fn (*anyopaque) CenteredEditorOptions,
        configured_visible: *const fn (*anyopaque, Parts) bool,
        get_focused_part: *const fn (*anyopaque) Parts,
        focus_part: *const fn (*anyopaque, Parts) void,
        apply_line_numbers: *const fn (*anyopaque, bool) void,
    };

    fn toggleZenModeContext(context: *anyopaque) anyerror!void {
        const self: *Layout = @ptrCast(@alignCast(context));
        try self.toggleZenMode(false, false);
    }

    pub fn toggleZenMode(self: *Layout, skip_layout: bool, restoring: bool) !void {
        const host = self.zen_host orelse return error.LayoutNotInitialized;
        const focused = host.get_focused_part(host.context);
        self.setZenModeActive(!self.isZenModeActive());
        const config = host.get_configuration(host.context);
        if (self.isZenModeActive()) {
            if (!restoring) self.zen_mode_exit_info = .{
                .transitionedToCenteredEditorLayout = !self.isMainEditorCentered() and config.center_layout,
                .handleNotificationsDoNotDisturbMode = if (self.notification_service) |service| service.getFilter(null) == .OFF else false,
                .wasVisible = .{ .panel = self.isVisible(.panel), .sideBar = self.isVisible(.sidebar) },
            };
            try self.setPartHidden(true, .panel);
            try self.setPartHidden(true, .sidebar);
            if (config.hide_activity_bar) try self.setPartHidden(true, .activitybar);
            if (config.hide_status_bar) try self.setPartHidden(true, .statusbar);
            if (config.hide_line_numbers) self.setZenLineNumbers(host, true);
            if (config.silent_notifications and self.zen_mode_exit_info.handleNotificationsDoNotDisturbMode) {
                if (self.notification_service) |service| try service.setFilter(.{ .global = .ERROR });
            }
            if (config.center_layout) try self.centerMainEditorLayout(true, true);
        } else {
            const info = self.zen_mode_exit_info;
            if (info.wasVisible.panel) try self.setPartHidden(false, .panel);
            if (info.wasVisible.sideBar) try self.setPartHidden(false, .sidebar);
            try self.setPartHidden(!host.configured_visible(host.context, .activitybar), .activitybar);
            try self.setPartHidden(!self.configured_statusbar_visible, .statusbar);
            if (info.transitionedToCenteredEditorLayout) try self.centerMainEditorLayout(false, true);
            if (info.handleNotificationsDoNotDisturbMode) {
                if (self.notification_service) |service| try service.setFilter(.{ .global = .OFF });
            }
            self.setZenLineNumbers(host, false);
        }
        if (!skip_layout) try self.on_did_change.fire({});
        host.focus_part(host.context, if (self.isVisible(focused)) focused else .editor);
        try self.fireZenModeChanged();
    }

    fn setZenLineNumbers(self: *Layout, host: ZenModeHost, hidden: bool) void {
        self.zen_hide_line_numbers = hidden;
        host.apply_line_numbers(host.context, hidden);
    }

    /// A replacement configuration service applies every setting. Individual
    /// updates take the same affectsConfiguration branches as layout.ts.
    pub fn onZenModeConfigurationChange(self: *Layout, change: ?config_keys.Change) !void {
        if (!self.isZenModeActive()) return;
        const host = self.zen_host orelse return error.LayoutNotInitialized;
        const config = host.get_configuration(host.context);
        const settings = layout_service.ZenModeSettings;
        if (affects(change, settings.hide_activity_bar) or affects(change, layout_service.LayoutSettings.activity_bar_location))
            try self.setPartHidden(config.hide_activity_bar or !host.configured_visible(host.context, .activitybar), .activitybar);
        if (affects(change, settings.hide_status_bar)) try self.setPartHidden(config.hide_status_bar, .statusbar);
        if (affects(change, settings.silent_notifications) and self.zen_mode_exit_info.handleNotificationsDoNotDisturbMode) {
            if (self.notification_service) |service| try service.setFilter(.{ .global = if (config.silent_notifications) .ERROR else .OFF });
        }
        if (affects(change, settings.center_layout))
            try self.centerMainEditorLayout(config.center_layout, true);
        if (affects(change, settings.hide_line_numbers)) self.setZenLineNumbers(host, config.hide_line_numbers);
        // Tabs are enforced by the editor part when the grid lays out.
        try self.on_did_change.fire({});
    }

    fn affects(change: ?config_keys.Change, key: []const u8) bool {
        return if (change) |event| config_keys.affectsConfiguration(event, key) else true;
    }

    pub fn fireZenModeChanged(self: *Layout) !void {
        try self.on_did_change_zen_mode.fire(self.zen_mode_active);
    }

    /// Port of `isMainEditorLayoutCentered`.
    pub fn isMainEditorCentered(self: *const Layout) bool {
        return self.main_editor_centered;
    }

    pub const CenteredEditorOptions = struct {
        auto_resize: bool = true,
        multiple_columns: bool = false,
        maximized_group: bool = false,
        complex_editor: bool = false,

        pub fn fromEditorPart(part: anytype, configuration: ?*@import("../services/configuration/browser/configurationService.zig").ConfigurationService) CenteredEditorOptions {
            const side_by_side = if (configuration) |config| config.getBool("diffEditor.renderSideBySide", true) else true;
            const complex = for (part.group_views.items) |view| {
                const input = view.group.model.activeEditor() orelse continue;
                if (std.mem.eql(u8, input.type_id, @import("../common/editor/diffEditorInput.zig").ID)) {
                    if (side_by_side) break true;
                } else if (input.hasCapability(@import("../common/editor.zig").EditorInputCapabilities.MultipleEditors)) break true;
            } else false;
            return .{
                .auto_resize = if (configuration) |config| config.getBool(layout_service.LayoutSettings.editor_centered_layout_auto_resize, true) else true,
                .multiple_columns = part.hasMoreThanOneColumn(),
                .maximized_group = part.maximized_group != null,
                .complex_editor = complex,
            };
        }
    };

    pub fn centerMainEditorLayout(self: *Layout, active: bool, skip_layout: bool) !void {
        const options: CenteredEditorOptions = if (self.zen_host) |host| host.get_centered_options(host.context) else .{};
        self.main_editor_centered = active;
        const disable = options.auto_resize and ((options.multiple_columns and !options.maximized_group) or options.complex_editor);
        const effective = active and !disable;
        if (self.main_editor_centered_effective != effective) {
            self.main_editor_centered_effective = effective;
            if (!skip_layout) try self.on_did_change.fire({});
        }
        try self.on_did_change_main_editor_centered.fire(active);
    }

    pub fn isMainEditorCenteredEffective(self: *const Layout) bool {
        return self.main_editor_centered_effective;
    }

    /// Port of `CenteredViewLayout`'s proportional split view: the editor part
    /// occupies the centered width and the margins use the configured
    /// `editorPane.background`.
    const centered_layout_margin_ratio: f64 = 0.1909;
    const centered_layout_min_width: usize = 20;

    pub fn centeredEditorRect(self: *const Layout, base: ui.Rect) ui.Rect {
        if (!self.isMainEditorCenteredEffective()) return base;
        const width = ui.cell.snap(base.w);
        const margin = @as(usize, @intFromFloat(@floor(@as(f64, @floatFromInt(width)) * centered_layout_margin_ratio)));
        if (width <= margin * 2 + centered_layout_min_width) return base;
        return .{
            .x = base.x + @as(f64, @floatFromInt(margin)),
            .y = base.y,
            .w = base.w - @as(f64, @floatFromInt(margin * 2)),
            .h = base.h,
        };
    }
};

const Tab = @import("parts/editor/editorPane.zig").Tab;
const GroupView = @import("parts/editor/editorGroupView.zig").EditorGroupView(*Tab);
const editor_part_mod = @import("parts/editor/editorPart.zig");
const EditorPart = editor_part_mod.EditorPart(GroupView);
const SidebarPart = @import("parts/sidebar/sidebarPart.zig").SidebarPart;
const ActivityBarPart = @import("parts/activitybar/activitybarPart.zig").ActivityBarPart;
const panel_part_mod = @import("parts/panel/panelPart.zig");
const PanelPart = panel_part_mod.PanelPart;

/// Cell-grid adapter to the upstream workbench grid's layout and bounds.
/// The part instances own their size constraints; the terminal has only a
/// single main window and a bottom panel. Glyphs reserve a cell when native
/// cell borders are unavailable, rather than using browser pixel borders.
pub const TerminalGeometry = struct {
    layout: *const Layout,
    cols: usize,
    rows: usize,
    part: *EditorPart,
    sidebar_part: *const SidebarPart,
    activity_bar_part: *const ActivityBarPart,
    panel_part: *const PanelPart,
    sidebar_available: bool,

    pub fn statusBarVisible(self: *const TerminalGeometry) bool {
        return self.layout.statusBarVisible(self.rows);
    }

    pub fn statusBarRect(self: *const TerminalGeometry) ui.Rect {
        return self.layout.statusBarRect(self.cols, self.rows);
    }

    pub fn workbenchRows(self: *const TerminalGeometry) usize {
        return self.layout.workbenchRows(self.rows);
    }

    /// The bottom panel is visible with an active container. `hideIfEmpty`
    /// containers hide their title (not the panel) while they are empty; the
    /// panel itself stays open until the workbench closes it.
    pub fn panelShown(self: *const TerminalGeometry) bool {
        return self.panel_part.isVisible() and self.panel_part.pane.active_id != null;
    }

    pub fn activePanelId(self: *const TerminalGeometry) []const u8 {
        return self.panel_part.pane.active_id orelse "";
    }

    pub fn panelHeight(self: *const TerminalGeometry) usize {
        if (!self.panelShown()) return 0;
        const wanted = if (self.panel_part.getSize() == 0) 10 else self.panel_part.getSize();
        return self.clampPanelHeight(wanted);
    }

    pub fn panelHeightLimits(self: *const TerminalGeometry) WorkbenchGrid.Limits {
        const available = self.workbenchRows();
        const editor_minimum = @min(editor_part_mod.min_pane_height, @max(available -| self.panel_part.minimum_height, 1));
        const maximum = @min(self.panel_part.maximum_height, available -| editor_minimum);
        return .{ .minimum = @min(self.panel_part.minimum_height, maximum), .maximum = maximum };
    }

    pub fn clampPanelHeight(self: *const TerminalGeometry, wanted: usize) usize {
        const limits = self.panelHeightLimits();
        return std.math.clamp(wanted, limits.minimum, limits.maximum);
    }

    pub fn workbenchGridLayout(self: *const TerminalGeometry) WorkbenchGrid.Rects {
        return WorkbenchGrid.layout(.{
            .w = @floatFromInt(self.cols),
            .h = @floatFromInt(self.workbenchRows()),
        }, self.activityBarWidth(), if (self.sidebarShown()) self.sidebarWidth() + self.sidebarFrameInset() else 0, self.panelHeight(), self.layout.getSideBarPosition());
    }

    pub fn editorRows(self: *const TerminalGeometry) usize {
        return ui.cell.snap(self.workbenchGridLayout().editor.h);
    }

    pub fn panelFrameRect(self: *const TerminalGeometry) ui.Rect {
        return if (self.panelShown()) self.workbenchGridLayout().panel else .{};
    }

    /// The title bar and content share the same inset for painting and input.
    pub fn panelRect(self: *const TerminalGeometry) ui.Rect {
        const rect = self.panelFrameRect();
        if (!self.glyphPanelFrame(rect)) return rect;
        return .{ .x = rect.x + 1, .y = rect.y + 1, .w = rect.w - 2, .h = rect.h - 2 };
    }

    pub fn glyphPanelFrame(self: *const TerminalGeometry, rect: ui.Rect) bool {
        // Keep space for a title and a content row inside the border.
        return !self.part.cell_borders and rect.w >= 3 and rect.h >= panel_part_mod.title_height + 3;
    }

    /// Panel content below the one-row title (composite bar).
    pub fn panelContentRect(self: *const TerminalGeometry) ui.Rect {
        if (!self.panelShown()) return .{};
        return panel_part_mod.contentRect(self.panelRect());
    }

    pub fn sidebarWidth(self: *const TerminalGeometry) usize {
        return self.clampSidebarWidth(self.layout.size(.sidebar));
    }

    pub fn sidebarMinimum(self: *const TerminalGeometry) usize {
        return self.sidebar_part.minimum_width + self.sidebarFrameInset();
    }

    pub fn editorColumnMinimum(self: *const TerminalGeometry) usize {
        const available = self.cols -| self.activityBarWidth() -| self.sidebarMinimum();
        const editor = if (self.part.maximized_group != null) editor_part_mod.min_pane_width else self.part.minimumWidth(self.workbenchRows() -| self.panelHeight());
        const panel = if (self.panelShown()) self.panel_part.minimum_width else 0;
        return @min(available, @max(editor, panel));
    }

    pub fn clampSidebarWidth(self: *const TerminalGeometry, width: usize) usize {
        const maximum = self.cols -| self.activityBarWidth() -| self.editorColumnMinimum() -| self.sidebarFrameInset();
        return @min(maximum, std.math.clamp(width, self.sidebar_part.minimum_width, self.sidebar_part.maximum_width));
    }

    pub fn activityBarWidth(self: *const TerminalGeometry) usize {
        // The activity bar takes no cells when it is hidden or when it moved
        // into the side bar composite bar (top/bottom positions). Without a
        // side bar model there is no side bar area for the rail either; the
        // terminal app always initializes the side bar.
        if (!self.activity_bar_part.visible) return 0;
        if (!self.sidebar_available) return 0;
        return self.activity_bar_part.width();
    }

    pub fn sidebarShown(self: *const TerminalGeometry) bool {
        return self.layout.isVisible(.sidebar) and self.sidebar_available and
            self.cols > self.activityBarWidth() + self.sidebarMinimum();
    }

    pub fn activityRect(self: *const TerminalGeometry) ui.Rect {
        return self.workbenchGridLayout().activity_bar;
    }

    pub fn sidebarFrameInset(self: *const TerminalGeometry) usize {
        return @intFromBool(!self.part.cell_borders);
    }

    pub fn sidebarFrameRect(self: *const TerminalGeometry) ui.Rect {
        return self.workbenchGridLayout().sidebar;
    }

    pub fn sidebarRect(self: *const TerminalGeometry) ui.Rect {
        return SidebarPart.innerRect(self.sidebarFrameRect(), self.part.cell_borders, self.layout.getSideBarPosition());
    }

    pub fn glyphSidebarFrame(self: *const TerminalGeometry) bool {
        return !self.part.cell_borders and self.workbenchRows() >= 14;
    }
};
