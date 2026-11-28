// Port of the portable drop-target decisions in
// `src/vs/workbench/browser/parts/editor/editorDropTarget.ts` and the drop
// locations of `src/vs/base/browser/ui/grid/grid.ts`.
//
// The browser overlay is painted into the terminal cell grid. The group and
// editor targets share upstream's drop-area and split-direction decisions.

const std = @import("std");
const ui = @import("ui");
const grid = @import("../../../../base/browser/ui/grid/grid.zig");
const ThemeColors = @import("../../themeColors.zig").ThemeColors;

/// The upstream drop overlay respects the workbench reduced-motion setting.
pub fn animationsEnabled(configuration: ?@import("../../../../platform/configuration/common/configuration.zig").IConfigurationService) bool {
    const config = configuration orelse return true;
    const value = config.getString("workbench.reduceMotion") orelse return true;
    return !std.mem.eql(u8, value, "on");
}

pub const Zone = enum { center, left, right, top, bottom };

pub fn DropOverlay(comptime Pane: type) type {
    return struct {
        const Self = @This();
        const fade_duration = 150;
        const move_duration = 70;

        pane: Pane,
        zone: Zone,
        rect: ui.Rect,
        from: ui.Rect,
        fade_start: i64,
        move_start: i64,
        next_frame: i64,

        pub fn position(previous: ?Self, pane: Pane, zone: Zone, rect: ui.Rect, now: i64) Self {
            if (previous) |old| {
                if (old.pane == pane) {
                    if (old.zone == zone and std.meta.eql(old.rect, rect)) return old;
                    return .{
                        .pane = pane,
                        .zone = zone,
                        .rect = rect,
                        .from = old.rectangle(now),
                        .fade_start = old.fade_start,
                        .move_start = now,
                        .next_frame = now + 16,
                    };
                }
            }
            return .{
                .pane = pane,
                .zone = zone,
                .rect = rect,
                .from = rect,
                .fade_start = now,
                .move_start = now - move_duration,
                .next_frame = now + 16,
            };
        }

        fn animationEnd(self: Self) i64 {
            return @max(self.fade_start + fade_duration, self.move_start + move_duration);
        }

        pub fn frameDeadline(self: Self) ?i64 {
            const end = self.animationEnd();
            return if (self.next_frame <= end) self.next_frame else null;
        }

        pub fn advance(self: *Self, now: i64) bool {
            const deadline = self.frameDeadline() orelse return false;
            if (now < deadline) return false;
            const end = self.animationEnd();
            self.next_frame = if (now >= end) end + 1 else @min(end, now + 16);
            return true;
        }

        fn rectangle(self: Self, now: i64) ui.Rect {
            const fraction = easeOut(now, self.move_start, move_duration);
            return .{
                .x = self.from.x + (self.rect.x - self.from.x) * fraction,
                .y = self.from.y + (self.rect.y - self.from.y) * fraction,
                .w = self.from.w + (self.rect.w - self.from.w) * fraction,
                .h = self.from.h + (self.rect.h - self.from.h) * fraction,
            };
        }

        /// Port of updateStyles and the overlay's CSS fade and move. A text
        /// terminal implements the translucent background by blending colors.
        pub fn paint(self: Self, cells: *ui.CellGrid, theme: ?*const ThemeColors, borders: bool, animate: bool, now: i64) void {
            const rect = if (animate) self.rectangle(now) else self.rect;
            const progress: f32 = if (animate) @floatCast(easeOut(now, self.fade_start, fade_duration)) else 1;
            const scheme = if (theme) |colors| colors.theme.theme_type else .DARK;
            const raw = if (theme) |colors| colors.rawColor("editorGroup.dropBackground") else null;
            const color: ui.Color = if (raw) |custom| .{ .r = custom.r, .g = custom.g, .b = custom.b } else switch (scheme) {
                .LIGHT => .{ .r = 0x26, .g = 0x77, .b = 0xcb },
                .HIGH_CONTRAST_LIGHT => .{ .r = 0x0f, .g = 0x4a, .b = 0x85 },
                else => .{ .r = 0x53, .g = 0x59, .b = 0x5d },
            };
            const alpha: f32 = if (raw) |custom| custom.a else switch (scheme) {
                .LIGHT => 0.18,
                .HIGH_CONTRAST_DARK => 0,
                else => 0.5,
            };
            const defaults: ui.cell.PaintStyle = .{
                .fg = ui.cell.packColor(if (theme) |colors| colors.foreground else .{ .r = 204, .g = 204, .b = 204 }),
                .bg = ui.cell.packColor(if (theme) |colors| colors.background else .{ .r = 30, .g = 30, .b = 30 }),
            };
            cells.tintRect(rect, color, alpha * progress, defaults);
            if (scheme == .HIGH_CONTRAST_DARK or scheme == .HIGH_CONTRAST_LIGHT) {
                const fallback: [3]u8 = if (scheme == .HIGH_CONTRAST_LIGHT) .{ 0x0f, 0x4a, 0x85 } else .{ 0xf3, 0x85, 0x18 };
                const contrast = theme.?.color("contrastActiveBorder", fallback);
                if (borders) {
                    paintContrastOutline(cells, rect, contrast);
                } else if (alpha == 0) {
                    cells.tintRect(rect, contrast, 0.25 * progress, defaults);
                }
            }
        }
    };
}

fn easeOut(now: i64, start: i64, duration: i64) f64 {
    const elapsed: f64 = @floatFromInt(std.math.clamp(now - start, 0, duration));
    const length: f64 = @floatFromInt(duration);
    const remaining = 1 - elapsed / length;
    return 1 - remaining * remaining * remaining;
}

fn paintContrastOutline(cells: *ui.CellGrid, rect: ui.Rect, color: ui.Color) void {
    const stroke: ui.cell_border.Stroke = .{ .width = 48, .color = .{ .rgb = color }, .priority = 3, .style = .dashed };
    const edge = ui.cell_border.Segment;
    const left = ui.cell.snap(rect.x);
    const top = ui.cell.snap(rect.y);
    const right = ui.cell.snap(rect.right());
    const bottom = ui.cell.snap(rect.bottom());
    if (left >= right or top >= bottom) return;
    for (left..right) |col| {
        cells.addBorder(col, top, edge.top, stroke);
        cells.addBorder(col, bottom - 1, edge.bottom, stroke);
    }
    for (top..bottom) |row| {
        cells.addBorder(left, row, edge.left, stroke);
        cells.addBorder(right - 1, row, edge.right, stroke);
    }
}

pub fn dropArea(rect: ui.Rect, tab_offset: usize) ui.Rect {
    const offset = @min(rect.h, @as(f64, @floatFromInt(tab_offset)));
    return .{ .x = rect.x, .y = rect.y + offset, .w = rect.w, .h = rect.h - offset };
}

pub const Options = struct {
    is_dragging_group: bool = false,
    prefer_split_vertically: bool = true,
    enable_splitting: bool = true,
    splits_only: bool = false,
};

/// Upstream getSplitDirection, projected onto terminal-cell coordinates.
pub fn zoneAt(rect: ui.Rect, x: usize, y: usize, options: Options) ?Zone {
    const x0 = ui.cell.snap(rect.x);
    const y0 = ui.cell.snap(rect.y);
    const width = ui.cell.snap(rect.right()) -| x0;
    const height = ui.cell.snap(rect.bottom()) -| y0;
    if (width == 0 or height == 0) return null;
    if (x < x0 or x >= x0 + width or y < y0 or y >= y0 + height) return null;

    if (!options.enable_splitting) return .center;
    const w: f64 = @floatFromInt(width);
    const h: f64 = @floatFromInt(height);
    const px: f64 = @floatFromInt(x - x0);
    const py: f64 = @floatFromInt(y - y0);
    const edge_width = w * (if (options.is_dragging_group and options.prefer_split_vertically) @as(f64, 0.3) else 0.1);
    const edge_height = h * (if (options.is_dragging_group and !options.prefer_split_vertically) @as(f64, 0.3) else 0.1);
    if (px > edge_width and px < w - edge_width and py > edge_height and py < h - edge_height) {
        if (!options.splits_only) return .center;
        const sides = [_]Zone{ .left, .right, .top, .bottom };
        const distances = [_]f64{ px / w, (w - px) / w, py / h, (h - py) / h };
        var nearest: usize = 0;
        for (1..distances.len) |i| {
            if (distances[i] < distances[nearest]) nearest = i;
        }
        return sides[nearest];
    }
    if (options.prefer_split_vertically) {
        if (px < w / 3) return .left;
        if (px > w * 2 / 3) return .right;
        return if (py < h / 2) .top else .bottom;
    }
    if (py < h / 3) return .top;
    if (py > h * 2 / 3) return .bottom;
    return if (px < w / 2) .left else .right;
}

/// Upstream positionOverlay. Use the grid's split rounding and gutter, then
/// clip the incoming group's area to the current drop area below the title.
pub fn positionOverlay(rect: ui.Rect, area: ui.Rect, zone: Zone, gap: f64) ui.Rect {
    if (zone == .center) return area;
    const split = grid.splitRects(rect, orientation(zone), 0.5, gap);
    const destination = if (newFirst(zone)) split.first else split.second;
    const y = @max(destination.y, area.y);
    return .{ .x = destination.x, .y = y, .w = destination.w, .h = @max(destination.bottom() - y, 0) };
}

pub fn orientation(zone: Zone) grid.Orientation {
    return switch (zone) {
        .left, .right => .horizontal,
        .top, .bottom => .vertical,
        .center => .horizontal,
    };
}

pub fn newFirst(zone: Zone) bool {
    return zone == .left or zone == .top;
}

test "editorDropTarget: upstream edge and center zones" {
    const rect = ui.Rect{ .x = 0, .y = 0, .w = 100, .h = 40 };
    try std.testing.expectEqual(Zone.top, zoneAt(rect, 50, 1, .{}).?);
    try std.testing.expectEqual(Zone.bottom, zoneAt(rect, 50, 38, .{}).?);
    try std.testing.expectEqual(Zone.left, zoneAt(rect, 1, 20, .{}).?);
    try std.testing.expectEqual(Zone.right, zoneAt(rect, 98, 20, .{}).?);
    try std.testing.expectEqual(Zone.center, zoneAt(rect, 20, 20, .{}).?);
    try std.testing.expectEqual(Zone.left, zoneAt(rect, 20, 20, .{ .is_dragging_group = true }).?);
    try std.testing.expectEqual(Zone.top, zoneAt(rect, 1, 4, .{ .prefer_split_vertically = false }).?);
    try std.testing.expectEqual(Zone.center, zoneAt(rect, 1, 1, .{ .enable_splitting = false }).?);
    try std.testing.expect(zoneAt(rect, 101, 20, .{}) == null);
}

const Tab = @import("editorPane.zig").Tab;
const GroupPane = @import("editorGroupView.zig").EditorGroupView(*Tab);
const EditorPart = @import("editorPart.zig").EditorPart(GroupPane);
const editor_tabs_control = @import("editorTabsControl.zig");
const tab_bar = @import("multiEditorTabsControl.zig");
const group_mod = @import("../../../common/editor/editorGroupModel.zig");
const editor_mod = @import("../../../common/editor.zig");
const EditorInput = @import("../../../common/editor/editorInput.zig").EditorInput;
const editor_groups = @import("../../../services/editor/common/editorGroupsService.zig");
const ConfigurationService = @import("../../../services/configuration/browser/configurationService.zig").ConfigurationService;
const window = @import("../../../../base/common/windowDispatch.zig");
const time_compat = @import("../../../../base/common/timeCompat.zig");
const terminal_panel = @import("../../../contrib/terminal/browser/terminalTabbedView.zig");
const builtin = @import("builtin");

const DragSource = struct { pane: *GroupPane, tab: ?*Tab };
const DragTarget = union(enum) {
    pane: *GroupPane,
    tabs: struct { pane: *GroupPane, index: ?usize },
    terminal_panel,
};
const EditorDrag = ui.DragSession(DragSource, DragTarget, []*Tab);
const TabDrop = struct { pane: *GroupPane, index: usize };
const EditorOverlay = DropOverlay(*GroupPane);
const DragHover = struct { pane: *GroupPane, tab: *Tab, deadline: ?i64 };
const TabClick = struct {
    pane: *GroupPane,
    tab: *Tab,
    at_ms: i64,
    x: usize,
    y: usize,
    /// Geometry of the clicked tab in the frame the click was recorded in.
    /// The strip can scroll when the click activates a partially visible tab,
    /// so the second click is matched against the old rectangle instead of
    /// trusting the new frame's hit.
    start: usize,
    end: usize,
};

/// The drop target owns the drag, hover activation deadline and overlay. The
/// terminal uses DragSession instead of browser DragEvent/DataTransfer. It
/// supplies the current frame and pointer for drag-image projection, plus
/// narrow lifetime/focus adapters for groups and terminal input transfers.
pub const EditorDropTarget = struct {
    allocator: std.mem.Allocator,
    part: *EditorPart,
    configuration: *?*ConfigurationService,
    theme_palette: *?*ThemeColors,
    frame: *ui.Frame,
    pointer: *ui.Pointer,
    host: Host,
    editor_drag: EditorDrag = .{},
    drag_target: ?EditorOverlay = null,
    drag_tab_drop: ?TabDrop = null,
    drag_hover: ?DragHover = null,
    drag_task: window.Task,
    tab_selection_anchor: ?struct { pane: *GroupPane, tab: *Tab } = null,
    last_tab_click: ?TabClick = null,

    pub const Host = struct {
        context: *anyopaque,
        terminal_panel_rect: *const fn (*anyopaque) ?ui.Rect,
        clear_hover: *const fn (*anyopaque) void,
        activate_index: *const fn (*anyopaque, usize) anyerror!void,
        copy_editor: *const fn (*anyopaque, *GroupPane, *Tab, group_mod.EditorOpenOptions) anyerror!*Tab,
        move_editor: *const fn (*anyopaque, *GroupPane, *GroupPane, *Tab, group_mod.EditorOpenOptions) anyerror!*Tab,
        move_terminal_to_panel: *const fn (*anyopaque, *GroupPane, *Tab) anyerror!void,
        destroy_pane: *const fn (*anyopaque, *GroupPane) void,
        collapse_empty_pane: *const fn (*anyopaque, *GroupPane) void,
        focus_pane: *const fn (*anyopaque, *GroupPane) anyerror!void,
    };

    pub fn init(self: *EditorDropTarget, allocator: std.mem.Allocator, part: *EditorPart, queue: *window.Queue, configuration: *?*ConfigurationService, theme_palette: *?*ThemeColors, frame: *ui.Frame, pointer: *ui.Pointer, host: Host) void {
        self.* = .{ .allocator = allocator, .part = part, .configuration = configuration, .theme_palette = theme_palette, .frame = frame, .pointer = pointer, .host = host, .drag_task = .{ .queue = queue, .context = self, .run = onEditorDragDeadline } };
    }

    pub fn deinit(self: *EditorDropTarget) void {
        self.clearTabDrag();
        self.drag_task.schedule(null);
    }

    fn activeTab(self: *EditorDropTarget) ?*Tab {
        const pane = self.part.activeView() orelse return null;
        return pane.activeTab();
    }

    fn paneExists(self: *EditorDropTarget, pane: *GroupPane) bool {
        return std.mem.indexOfScalar(*GroupPane, self.part.group_views.items, pane) != null;
    }

    fn boolSetting(self: *EditorDropTarget, key: []const u8, default: bool) bool {
        const config = self.configuration.* orelse return default;
        return config.getBool(key, default);
    }

    fn preferredSideBySideDirection(self: *EditorDropTarget) editor_groups.GroupDirection {
        return editor_groups.preferredSideBySideGroupDirection(if (self.configuration.*) |config| config.interface() else null);
    }

    pub fn cancelEditorDrag(self: *EditorDropTarget) bool {
        if (self.editor_drag.source == null) return false;
        const was_active = self.editor_drag.active;
        self.clearTabDrag();
        return was_active;
    }

    pub fn clearTabDrag(self: *EditorDropTarget) void {
        self.editor_drag.cancel(self);
    }

    pub fn invalidateDragPane(self: *EditorDropTarget, pane: *GroupPane) void {
        if (self.editor_drag.source) |source| {
            if (source.pane == pane or
                (self.drag_target != null and self.drag_target.?.pane == pane) or
                (self.drag_tab_drop != null and self.drag_tab_drop.?.pane == pane)) self.clearTabDrag();
        }
        if (self.tab_selection_anchor) |anchor| {
            if (anchor.pane == pane) self.tab_selection_anchor = null;
        }
        if (self.last_tab_click) |click| {
            if (click.pane == pane) self.last_tab_click = null;
        }
    }

    pub fn invalidateDragTab(self: *EditorDropTarget, pane: *GroupPane, tab: *Tab) void {
        if (self.editor_drag.source) |source| {
            if (source.pane == pane or (self.drag_hover != null and self.drag_hover.?.tab == tab)) self.clearTabDrag();
        }
        if (self.tab_selection_anchor) |anchor| {
            if (anchor.tab == tab) self.tab_selection_anchor = null;
        }
        if (self.last_tab_click) |click| {
            if (click.tab == tab) self.last_tab_click = null;
        }
    }

    pub fn dragTarget(self: *EditorDropTarget, source: DragSource, mouse: ui.MouseEvent) ?DragTarget {
        if (source.tab) |tab| {
            if (tab.terminal_input != null and (if (self.host.terminal_panel_rect(self.host.context)) |rect| terminal_panel.contains(rect, mouse.x, mouse.y) else false))
                return .terminal_panel;
        }
        const pane = self.part.viewAt(mouse.x, mouse.y) orelse return null;
        if (!pane.isEmpty() and pane.tabs_visible and mouse.y == ui.cell.snap(pane.rect.y)) {
            if (pane.title_action_hit) |hit| {
                if (mouse.x >= hit.start and mouse.x < hit.end) return null;
            }
            return .{ .tabs = .{ .pane = pane, .index = tab_bar.hitAt(pane.hits.items, mouse.x) } };
        }
        return .{ .pane = pane };
    }

    pub fn dispatchDrag(self: *EditorDropTarget, event: *EditorDrag.Event) void {
        defer self.scheduleEditorDragDeadline();
        switch (event.kind) {
            .dragstart => self.onEditorDragStart(event) catch event.preventDefault(),
            .dragenter => {},
            .dragleave => {
                self.drag_hover = null;
                self.drag_target = null;
                self.drag_tab_drop = null;
            },
            .drag => self.pointer.* = .no_drop,
            .dragover => self.onEditorDragOver(event),
            .drop => self.onEditorDrop(event) catch |err| {
                if (self.activeTab()) |active| active.editor.setMessage("Drop failed: {s}", .{@errorName(err)});
            },
            .dragend => {
                if (event.data_transfer.payload) |tabs| self.allocator.free(tabs);
                self.drag_target = null;
                self.drag_tab_drop = null;
                self.drag_hover = null;
                self.pointer.* = .default;
            },
        }
    }

    fn onEditorDragStart(self: *EditorDropTarget, event: *EditorDrag.Event) !void {
        const source = event.source;
        self.host.clear_hover(self.host.context);
        var tabs = std.array_list.Managed(*Tab).init(self.allocator);
        defer tabs.deinit();
        try source.pane.orderedTabs(self.allocator, &tabs);
        if (source.tab != null) {
            var index = tabs.items.len;
            while (index > 0) {
                index -= 1;
                if (!source.pane.group.model.isSelected(.{ .editor = tabs.items[index].input })) {
                    _ = tabs.orderedRemove(index);
                }
            }
            if (tabs.items.len == 0) try tabs.append(source.tab.?);
        }
        if (tabs.items.len == 0) return error.EmptyDrag;
        event.data_transfer.payload = try tabs.toOwnedSlice();

        const frame = if (self.frame.have_prev) &self.frame.prev else &self.frame.next;
        if (source.tab != null and event.data_transfer.payload.?.len == 1 and
            tab_bar.tabSizing(self.configuration.*) != .shrink)
        {
            const row = ui.cell.snap(source.pane.rect.y);
            for (source.pane.hits.items) |hit| {
                if (source.pane.tabAtIndex(self.allocator, hit.index) != source.tab) continue;
                if (hit.end > hit.start and hit.end <= frame.cols and row < frame.rows) {
                    const image = try frame.captureRow(self.allocator, hit.start, row, hit.end - hit.start);
                    event.data_transfer.setDragImage(image, 0, 0);
                    return;
                }
            }
        }
        const count = event.data_transfer.payload.?.len;
        const tab = source.tab orelse source.pane.activeTab() orelse event.data_transfer.payload.?[0];
        const name = tab.input.getName();
        const label = if (count == 1) name else if (source.tab == null)
            try std.fmt.allocPrint(self.allocator, "{s} (+{d})", .{ name, count - 1 })
        else
            try std.fmt.allocPrint(self.allocator, "{s} + {d}", .{ name, count - 1 });
        defer if (count > 1) self.allocator.free(label);
        const image = try editor_tabs_control.applyDragImage(self.allocator, label, self.theme_palette.*, self.part.cell_borders);
        event.data_transfer.setDragImage(image, -1, -1);
    }

    fn onEditorDragOver(self: *EditorDropTarget, event: *EditorDrag.Event) void {
        const source = event.source;
        const target = event.target orelse return;
        const tabs = event.data_transfer.payload orelse return;
        const now = time_compat.milliTimestamp(self.drag_task.queue.?.io);
        const previous_overlay = self.drag_target;
        self.drag_target = null;
        self.drag_tab_drop = null;
        var copy = editor_tabs_control.isCopyIntoOtherGroup(event.mouse.mods, source.tab != null and
            tabs[0].input.hasCapability(editor_mod.EditorInputCapabilities.Singleton));
        const old_hover = self.drag_hover;
        self.drag_hover = null;
        switch (target) {
            .terminal_panel => {
                if (tabs.len != 1) return;
                copy = false;
            },
            .tabs => |strip| {
                if (strip.pane == source.pane) {
                    if (source.tab == null) return;
                    copy = false;
                }
                if (!canTransferTabs(source, tabs, strip.pane, copy)) return;
                self.drag_tab_drop = .{
                    .pane = strip.pane,
                    .index = tab_bar.dropIndexAt(strip.pane.hits.items, event.mouse.x, strip.pane.tabs.items.len),
                };
                if (strip.index) |index| {
                    if (strip.pane.tabAtIndex(self.allocator, index)) |tab| {
                        self.drag_hover = if (old_hover != null and old_hover.?.pane == strip.pane and old_hover.?.tab == tab)
                            old_hover
                        else
                            .{ .pane = strip.pane, .tab = tab, .deadline = now + 1500 };
                    }
                }
            },
            .pane => |pane| {
                const area = dropArea(pane.rect, if (pane.tabs.items.len == 0) 0 else pane.titleHeight());
                const zone = zoneAt(area, event.mouse.x, event.mouse.y, .{
                    .is_dragging_group = source.tab == null,
                    .prefer_split_vertically = self.preferredSideBySideDirection() == .RIGHT,
                    .enable_splitting = self.boolSetting("workbench.editor.splitOnDragAndDrop", true) !=
                        editor_tabs_control.isToggleSplitOperation(event.mouse.mods),
                }) orelse return;
                if (pane == source.pane and (zone == .center or (!copy and
                    (source.tab == null or pane.tabs.items.len < 2)))) return;
                if (!canTransferTabs(source, tabs, if (zone == .center) pane else null, copy)) return;
                const gap = self.part.gap(orientation(zone), pane.rect);
                const rect = positionOverlay(pane.rect, area, zone, gap);
                if (rect.w <= 0 or rect.h <= 0) return;
                self.drag_target = EditorOverlay.position(previous_overlay, pane, zone, rect, now);
            },
        }
        event.data_transfer.drop_effect = if (copy) .copy else .move;
        self.pointer.* = if (copy) .copy else .grabbing;
        event.preventDefault();
    }

    fn scheduleEditorDragDeadline(self: *EditorDropTarget) void {
        var deadline: ?i64 = null;
        if (self.drag_hover) |hover| deadline = hover.deadline;
        if (self.drag_target) |overlay| {
            if (animationsEnabled(if (self.configuration.*) |config| config.interface() else null)) {
                if (overlay.frameDeadline()) |frame| deadline = @min(deadline orelse frame, frame);
            }
        }
        self.drag_task.schedule(deadline);
    }

    fn onEditorDragDeadline(context: *anyopaque, now: i64, _: bool) bool {
        const self: *EditorDropTarget = @ptrCast(@alignCast(context));
        defer self.scheduleEditorDragDeadline();
        var redraw = false;
        const animate = animationsEnabled(if (self.configuration.*) |config| config.interface() else null);
        if (self.drag_target) |*overlay| {
            if (animate) redraw = overlay.advance(now);
        }
        if (self.drag_hover) |*hover| {
            if (hover.deadline) |deadline| {
                if (now >= deadline) {
                    hover.deadline = null;
                    if (self.paneExists(hover.pane) and hover.pane.indexOfTab(hover.tab) != null and
                        hover.pane.activeTab() != hover.tab)
                    {
                        hover.pane.activateTab(hover.tab) catch return redraw;
                        return true;
                    }
                }
            }
        }
        return redraw;
    }

    pub fn selectTabForDrag(self: *EditorDropTarget, pane: *GroupPane, tab: *Tab, index: usize, mods: ui.Modifiers) !void {
        const model = &pane.group.model;
        const selection = try model.selectedEditors(self.allocator);
        defer self.allocator.free(selection);
        var inactive: std.ArrayList(*EditorInput) = .empty;
        defer inactive.deinit(self.allocator);
        const clicked_selected = model.isSelected(.{ .editor = tab.input });
        const toggle = builtin.os.tag != .macos and mods.ctrl;
        const anchor = self.tab_selection_anchor;
        const anchor_tab = if (anchor != null and anchor.?.pane == pane and
            model.isSelected(.{ .editor = anchor.?.tab.input })) anchor.?.tab else pane.activeTab() orelse tab;
        if (mods.shift) {
            const start = model.indexOf(.{ .input = anchor_tab.input }) orelse index;
            try inactive.appendSlice(self.allocator, selection);
            var adjacent: isize = @intCast(start);
            const step: isize = if (start < index) -1 else 1;
            while (true) {
                adjacent += step;
                if (adjacent < 0) break;
                const candidate = model.getEditorByIndex(@intCast(adjacent)) orelse break;
                const found = std.mem.indexOfScalar(*EditorInput, inactive.items, candidate) orelse break;
                _ = inactive.orderedRemove(found);
            }
            for (@min(start, index)..@max(start, index) + 1) |i| {
                if (model.getEditorByIndex(i)) |candidate| try inactive.append(self.allocator, candidate);
            }
            self.tab_selection_anchor = .{ .pane = pane, .tab = anchor_tab };
        } else if (toggle and clicked_selected and selection.len > 1) {
            for (selection) |candidate| {
                if (candidate != tab.input) try inactive.append(self.allocator, candidate);
            }
            const active = model.activeEditor() orelse tab.input;
            try model.setSelection(if (active == tab.input) inactive.items[0] else active, inactive.items);
            pane.syncActivePane();
            return;
        } else {
            if (toggle or clicked_selected) try inactive.appendSlice(self.allocator, selection);
            self.tab_selection_anchor = .{ .pane = pane, .tab = tab };
        }
        try self.host.activate_index(self.host.context, index);
        try model.setSelection(tab.input, inactive.items);
    }

    /// Checks the editor operations before a drop can change the split tree.
    fn canTransferTabs(source: DragSource, tabs: []*Tab, target: ?*GroupPane, copy: bool) bool {
        for (tabs) |tab| {
            if (copy and (tab.input.hasCapability(editor_mod.EditorInputCapabilities.Singleton) or
                (tab.file_input == null and tab.image_input == null and tab.terminalInstance() == null))) return false;
            if (!copy) {
                const destination = target orelse continue;
                if (destination == source.pane) continue;
                const match = destination.group.model.findEditor(tab.input, .{}) orelse continue;
                const existing = destination.tabForInput(match.editor) orelse continue;
                if (existing.editor.model != tab.editor.model and tab.editor.isDirty()) return false;
            }
        }
        return true;
    }

    fn onEditorDrop(self: *EditorDropTarget, event: *EditorDrag.Event) !void {
        const tabs = event.data_transfer.payload orelse return;
        const copy = event.data_transfer.drop_effect == .copy;
        const source = event.source.pane;
        switch (event.target orelse return) {
            .terminal_panel => try self.host.move_terminal_to_panel(self.host.context, source, tabs[0]),
            .tabs => {
                const strip = self.drag_tab_drop orelse return;
                try self.dropEditors(source, tabs, strip.pane, strip.index, copy, event.source.tab == null);
            },
            .pane => {
                const overlay = self.drag_target orelse return;
                if (overlay.zone == .center) {
                    try self.dropEditors(source, tabs, overlay.pane, null, copy, event.source.tab == null);
                    return;
                }
                const split_orientation = orientation(overlay.zone);
                const first = newFirst(overlay.zone);
                const close_empty_groups = self.boolSetting("workbench.editor.closeEmptyGroups", true);
                self.part.setMaximizedGroup(null);
                if (!copy and (event.source.tab == null or
                    (tabs.len == 1 and source.tabs.items.len == 1 and close_empty_groups)))
                {
                    if (source == overlay.pane) return;
                    try self.part.moveGroupView(source, overlay.pane, split_orientation, first);
                    try self.host.focus_pane(self.host.context, source);
                    return;
                }

                const pane = try self.part.splitGroup(overlay.pane, split_orientation, first);
                errdefer if (copy or pane.tabs.items.len == 0) self.host.destroy_pane(self.host.context, pane);
                try self.dropEditors(source, tabs, pane, null, copy, event.source.tab == null);
            },
        }
    }

    /// Port of MultiEditorTabsControl.onDrop and the local editor/group
    /// branches of DropOverlay.onDrop. The existing group model owns order,
    /// sticky boundaries and matching inputs.
    fn dropEditors(
        self: *EditorDropTarget,
        source: *GroupPane,
        tabs: []*Tab,
        target: *GroupPane,
        insertion: ?usize,
        copy: bool,
        whole_group: bool,
    ) !void {
        const previous_active = source.activeTab();
        const target_active = target.activeTab();
        const group_active = if (whole_group and insertion == null) target_active else null;
        var preferred = group_active;
        var index = insertion;
        for (tabs) |tab| {
            const is_active = tab == previous_active;
            if (source == target) {
                const from = target.group.model.indexOf(.{ .input = tab.input }) orelse continue;
                const next = index orelse return;
                const to = if (from < next) next - 1 else next;
                if (from != to) _ = try target.group.model.moveEditor(tab.input, @intCast(to));
                index = to + 1;
                continue;
            }
            const options: group_mod.EditorOpenOptions = .{
                .pinned = true,
                .active = true,
                .sticky = source.group.model.isSticky(.{ .editor = tab.input }),
                .index = if (index) |i| @intCast(i) else null,
            };
            const result = if (copy)
                try self.host.copy_editor(self.host.context, target, tab, options)
            else
                try self.host.move_editor(self.host.context, source, target, tab, options);
            if (preferred == null or (is_active and group_active == null)) preferred = result;
            if (index != null) index = (target.group.model.indexOf(.{ .input = result.input }) orelse index.?) + 1;
        }
        if (preferred) |active| try target.activateTab(active);
        if (!copy and source != target and
            (whole_group or self.boolSetting("workbench.editor.closeEmptyGroups", true)))
            self.host.collapse_empty_pane(self.host.context, source);
        try self.host.focus_pane(self.host.context, target);
    }
};
