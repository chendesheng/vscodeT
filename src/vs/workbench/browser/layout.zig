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

const Part = @import("part.zig").Part;
const IDisposable = @import("../../base/common/lifecycle.zig").IDisposable;
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

    pub const Rects = struct {
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

    pub fn layout(rect: ui.Rect, activity_width: usize, sidebar_width: usize, panel_height: usize) Rects {
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

/// Port of `LayoutStateKeys.ZEN_MODE_EXIT_INFO`.
pub const ZenModeExitInfo = struct {
    transitioned_to_centered_editor_layout: bool = false,
    transitioned_to_full_screen: bool = false,
    handle_notifications_do_not_disturb_mode: bool = false,
    was_visible: struct {
        side_bar: bool = false,
        panel: bool = false,
        auxiliary_bar: bool = false,
    } = .{},
};

pub const Layout = struct {
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

    parts: std.EnumArray(Parts, ?Binding) = .initFill(null),
    grid_ready: bool = false,
    on_did_change_part_visibility: Emitter(layout_service.IPartVisibilityChangeEvent),
    allocator: Allocator,
    states: [8]PartState = .{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} },
    sidebar_position: Position = .left,
    workbench_grid: WorkbenchGrid = .{},
    /// Port of `LayoutStateKeys.ZEN_MODE_ACTIVE` / `ZEN_MODE_EXIT_INFO`.
    zen_host: ?ZenModeHost = null,
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

    pub fn deinit(self: *Layout) void {
        for (&self.parts.values) |*entry| if (entry.*) |*binding| Binding.dispose(binding);
        self.on_did_change_part_visibility.deinit();
        self.on_did_change.deinit();
        self.on_did_change_zen_mode.deinit();
        self.on_did_change_main_editor_centered.deinit();
    }

    pub fn interface(self: *Layout) layout_service.IWorkbenchLayoutService {
        return .{ .context = self, .register_part = registerPartContext, .is_visible = isVisibleContext, .set_part_hidden = setPartHiddenContext, .on_did_change_part_visibility = &self.on_did_change_part_visibility, .on_did_change_zen_mode = &self.on_did_change_zen_mode, .on_did_change_main_editor_centered = &self.on_did_change_main_editor_centered, .is_zen_mode_active = zenMode, .toggle_zen_mode = toggleZenModeContext, .is_main_editor_centered = mainEditorCentered };
    }

    fn zenMode(context: *anyopaque) bool {
        const self: *Layout = @ptrCast(@alignCast(context));
        return self.isZenModeActive();
    }

    fn mainEditorCentered(context: *anyopaque) bool {
        const self: *Layout = @ptrCast(@alignCast(context));
        return self.isMainEditorCentered();
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

    pub fn layout(self: *Layout, rects: WorkbenchGrid.Rects, statusbar: ui.Rect) void {
        self.layoutPart(.activitybar, rects.activity_bar);
        self.layoutPart(.sidebar, rects.sidebar);
        self.layoutPart(.editor, rects.editor);
        self.layoutPart(.panel, rects.panel);
        self.layoutPart(.statusbar, statusbar);
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

    pub fn setSidebarPosition(self: *Layout, position: Position) !void {
        if (self.sidebar_position == position) return;
        self.sidebar_position = position;
        try self.on_did_change.fire({});
    }

    pub fn sidebarPosition(self: *const Layout) Position {
        return self.sidebar_position;
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
                .transitioned_to_centered_editor_layout = !self.isMainEditorCentered() and config.center_layout,
                .was_visible = .{ .panel = self.isVisible(.panel), .side_bar = self.isVisible(.sidebar) },
            };
            try self.setPartHidden(true, .panel);
            try self.setPartHidden(true, .sidebar);
            if (config.hide_activity_bar) try self.setPartHidden(true, .activitybar);
            if (config.hide_status_bar) try self.setPartHidden(true, .statusbar);
            if (config.hide_line_numbers) self.setZenLineNumbers(host, true);
            if (config.center_layout) try self.centerMainEditorLayout(true, host.get_centered_options(host.context), true);
        } else {
            const info = self.zen_mode_exit_info;
            if (info.was_visible.panel) try self.setPartHidden(false, .panel);
            if (info.was_visible.side_bar) try self.setPartHidden(false, .sidebar);
            try self.setPartHidden(!host.configured_visible(host.context, .activitybar), .activitybar);
            try self.setPartHidden(!self.configured_statusbar_visible, .statusbar);
            if (info.transitioned_to_centered_editor_layout) try self.centerMainEditorLayout(false, host.get_centered_options(host.context), true);
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
        if (affects(change, settings.center_layout))
            try self.centerMainEditorLayout(config.center_layout, host.get_centered_options(host.context), true);
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

    pub fn centerMainEditorLayout(self: *Layout, active: bool, options: CenteredEditorOptions, skip_layout: bool) !void {
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
