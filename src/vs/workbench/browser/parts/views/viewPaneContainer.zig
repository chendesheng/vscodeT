// Port of the terminal subset of
// `src/vs/workbench/browser/parts/views/viewPaneContainer.ts`.
//
// The container supplies the terminal PaneView layout and header interactions.
// Pane bodies and their title actions are supplied by the individual views.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const views = @import("../../../common/views.zig");
const model_mod = @import("../../../services/views/common/viewContainerModel.zig");
const view_pane = @import("./viewPane.zig");
const split_view = @import("../../../../base/browser/ui/splitview/splitview.zig");
const time_compat = @import("../../../../base/common/timeCompat.zig");
const theme_colors_mod = @import("../../themeColors.zig");

pub const Pane = struct {
    id: []const u8,
    title: []const u8,
    context: *anyopaque,
    render_body: *const fn (context: *anyopaque, grid: *ui.CellGrid, rect: ui.Rect, focused: bool) anyerror!void,
    handle_key: *const fn (context: *anyopaque, event: *ui.KeyEvent) anyerror!bool,
    handle_mouse: *const fn (context: *anyopaque, event: *const ui.MouseEvent, rect: ui.Rect) anyerror!bool,
    title_actions: *const fn (context: *anyopaque) []const views.TitleAction,
    show_actions: view_pane.ShowActions = .default,
    run_title_action: ?*const fn (context: *anyopaque, id: []const u8) void = null,
};

pub const Section = struct {
    id: []const u8,
    header_rect: ui.Rect,
    body_rect: ui.Rect,
    collapsed: bool,
    merged: bool,
};

pub const Hit = union(enum) {
    toggle: []const u8,
    action: struct { id: []const u8, action: []const u8 },
    body: []const u8,
};

pub const HeaderEvent = union(enum) {
    handled,
    action: []const u8,
    context_menu: []const u8,
};

const HeaderPress = struct {
    id: []const u8,
    x: usize,
    y: usize,
};

const DropTarget = struct {
    id: []const u8,
    position: model_mod.ViewContainerModel.DropPosition,

    fn previewRect(self: DropTarget, section: Section) ui.Rect {
        const top = if (section.merged) section.body_rect.y else section.header_rect.y;
        const height = section.header_rect.h + section.body_rect.h;
        const first_half = @ceil(height / 2);
        return .{
            .x = section.header_rect.x,
            .y = if (self.position == .before or height == 1) top else top + first_half,
            .w = section.header_rect.w,
            .h = if (self.position == .before or height == 1) first_half else height - first_half,
        };
    }
};

const Sash = struct {
    rect: ui.Rect,
    first: usize,
    second: usize,
};

const SashDrag = struct {
    index: usize,
    state: split_view.SashDragState,
    views: [2]split_view.ViewSize,
};

pub const ViewPaneContainer = struct {
    allocator: Allocator,
    model: *model_mod.ViewContainerModel,
    panes: []const Pane,
    headers: std.array_list.Managed(view_pane.Header),
    sections: std.array_list.Managed(Section),
    active_id: ?[]const u8 = null,
    merge_view_with_container_when_single_view: bool = true,
    always_show_header_actions: bool = false,
    focused_header: ?[]const u8 = null,
    focused_action: ?usize = null,
    hovered_pane: ?[]const u8 = null,
    header_press: ?HeaderPress = null,
    dragging_header: bool = false,
    drop_target: ?DropTarget = null,
    drop_activity: ?ui.Rect = null,
    native_outline: bool = false,
    sashes: std.ArrayList(Sash) = .empty,
    sash_hovered: ?usize = null,
    sash_dragging: ?SashDrag = null,
    last_sash_click: ?struct { index: usize, time: i64 } = null,
    body_rows: std.ArrayList(usize) = .empty,

    pub fn init(
        allocator: Allocator,
        model: *model_mod.ViewContainerModel,
        panes: []const Pane,
    ) !*ViewPaneContainer {
        const self = try allocator.create(ViewPaneContainer);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .model = model,
            .panes = panes,
            .headers = std.array_list.Managed(view_pane.Header).init(allocator),
            .sections = std.array_list.Managed(Section).init(allocator),
        };
        errdefer {
            for (self.headers.items) |*header| header.deinit();
            self.headers.deinit();
            self.sections.deinit();
        }
        for (panes) |pane| {
            try self.headers.append(view_pane.Header.init(allocator, pane.title));
        }
        self.active_id = model.activeView();
        return self;
    }

    /// Releases the header surfaces and lists. The owner destroys the struct,
    /// matching the other terminal view objects.
    pub fn deinit(self: *ViewPaneContainer) void {
        for (self.headers.items) |*header| header.deinit();
        self.headers.deinit();
        self.sections.deinit();
        self.sashes.deinit(self.allocator);
        self.body_rows.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn activeView(self: *const ViewPaneContainer) ?[]const u8 {
        return self.active_id;
    }

    pub fn setActive(self: *ViewPaneContainer, id: []const u8) void {
        if (!self.model.isVisible(id)) return;
        self.active_id = id;
        self.focused_header = null;
        self.focused_action = null;
        self.model.setActiveView(id);
    }

    /// Recomputes section rectangles for the container content area.
    pub fn layout(self: *ViewPaneContainer, content: ui.Rect) !void {
        self.sections.clearRetainingCapacity();
        self.sashes.clearRetainingCapacity();
        const visible = try self.model.visibleViews(self.allocator);
        defer self.allocator.free(visible);
        if (visible.len == 0) return;

        const height = ui.cell.snap(content.h);
        if (ui.cell.snap(content.w) == 0 or height == 0) return;
        if (visible.len == 1 and self.merge_view_with_container_when_single_view) {
            try self.sections.append(.{
                .id = visible[0].id,
                .header_rect = .{ .x = content.x, .y = content.y, .w = content.w, .h = 0 },
                .body_rect = content,
                .collapsed = false,
                .merged = true,
            });
            self.setActive(visible[0].id);
            return;
        }

        var first_expanded: ?usize = null;
        var last_expanded: ?usize = null;
        var expanded_count: usize = 0;
        var total_weight: f64 = 0;
        for (visible, 0..) |descriptor, index| {
            if (descriptor.collapsed and visible.len > 1) continue;
            if (first_expanded == null) first_expanded = index;
            last_expanded = index;
            expanded_count += 1;
            total_weight += paneWeight(descriptor);
        }
        const max_sashes = (last_expanded orelse 0) - (first_expanded orelse 0);
        const sash_rows = @min(max_sashes, height -| (visible.len + expanded_count));
        const available = height -| (visible.len + sash_rows);
        try self.body_rows.resize(self.allocator, visible.len);
        @memset(self.body_rows.items, 0);
        var remaining = available;
        var remaining_panes = expanded_count;
        var distributed: f64 = 0;
        for (visible, 0..) |descriptor, index| {
            if (descriptor.collapsed and visible.len > 1) continue;
            remaining_panes -= 1;
            if (remaining == 0) break;
            distributed += @as(f64, @floatFromInt(available)) * paneWeight(descriptor) / total_weight;
            const target = ui.cell.snap(distributed) -| (available - remaining);
            const maximum = remaining - @min(remaining - 1, remaining_panes);
            const size = if (remaining_panes == 0) remaining else std.math.clamp(target, 1, maximum);
            self.body_rows.items[index] = size;
            remaining -= size;
        }

        var cursor = ui.cell.snap(content.y);
        var headers_left = @min(visible.len, height);
        var preceding_body: ?usize = null;
        for (visible, 0..) |descriptor, index| {
            if (preceding_body != null and index <= (last_expanded orelse 0) and self.sashes.items.len < sash_rows) {
                var following_body = index;
                while (self.body_rows.items[following_body] == 0) : (following_body += 1) {}
                try self.sashes.append(self.allocator, .{
                    .rect = .{ .x = content.x, .y = @floatFromInt(cursor), .w = content.w, .h = 1 },
                    .first = preceding_body.?,
                    .second = following_body,
                });
                cursor += 1;
            }
            const header_h: usize = if (headers_left > 0) 1 else 0;
            headers_left -|= header_h;
            const header_rect: ui.Rect = .{ .x = content.x, .y = @floatFromInt(cursor), .w = content.w, .h = @floatFromInt(header_h) };
            cursor += header_h;
            const body_h = self.body_rows.items[index];
            const body_rect: ui.Rect = .{ .x = content.x, .y = @floatFromInt(cursor), .w = content.w, .h = @floatFromInt(body_h) };
            cursor += body_h;
            if (body_h > 0) preceding_body = index;
            try self.sections.append(.{
                .id = descriptor.id,
                .header_rect = header_rect,
                .body_rect = body_rect,
                .collapsed = descriptor.collapsed and visible.len > 1,
                .merged = false,
            });
        }
        if (self.active_id == null or !self.model.isVisible(self.active_id.?)) self.setActive(visible[0].id);
    }

    fn paneWeight(descriptor: model_mod.ViewDescriptor) f64 {
        return descriptor.size orelse @floatFromInt(@max(descriptor.weight, 1));
    }

    fn sashAt(self: *const ViewPaneContainer, x: usize, y: usize) ?usize {
        for (self.sashes.items, 0..) |sash, index| {
            if (y == ui.cell.snap(sash.rect.y) and x >= ui.cell.snap(sash.rect.x) and x < ui.cell.snap(sash.rect.right())) return index;
        }
        return null;
    }

    pub fn handleSashMouse(self: *ViewPaneContainer, event: *const ui.MouseEvent) bool {
        if (event.kind == .wheel) return false;
        self.sash_hovered = self.sashAt(event.x, event.y);
        if (self.sash_dragging) |drag| {
            if (drag.index >= self.sashes.items.len) {
                self.sash_dragging = null;
                return false;
            }
            if (event.kind == .move or event.kind == .up or event.kind == .click) {
                const sash = self.sashes.items[drag.index];
                const sizes = drag.state.onSashChange(event.y, drag.views);
                if (event.y != drag.state.start or self.body_rows.items[sash.first] != sizes[0]) {
                    self.storeSizes(sash, sizes);
                    self.last_sash_click = null;
                }
                if (event.kind != .move) self.sash_dragging = null;
            }
            return true;
        }
        const index = self.sash_hovered orelse return false;
        if (event.kind != .down or event.button != .left) return true;
        const sash = self.sashes.items[index];
        const first = self.body_rows.items[sash.first];
        const second = self.body_rows.items[sash.second];
        const total = first + second;
        const now = time_compat.milliTimestamp();
        if (self.last_sash_click) |last| {
            if (last.index == index and now - last.time < 300) {
                self.storeSizes(sash, .{ (total + 1) / 2, total / 2 });
                self.last_sash_click = null;
                return true;
            }
        }
        self.last_sash_click = .{ .index = index, .time = now };
        const sizes: [2]split_view.ViewSize = .{
            .{ .size = first, .minimum = 1, .maximum = total - 1 },
            .{ .size = second, .minimum = 1, .maximum = total - 1 },
        };
        self.sash_dragging = .{ .index = index, .state = split_view.SashDragState.onSashStart(event.y, sizes), .views = sizes };
        return true;
    }

    fn storeSizes(self: *ViewPaneContainer, sash: Sash, sizes: [2]usize) void {
        var total_rows: usize = 0;
        var total_weight: f64 = 0;
        for (self.sections.items, self.body_rows.items) |section, body_h| {
            if (body_h == 0) continue;
            total_rows += body_h;
            for (self.model.views.items) |descriptor| {
                if (std.mem.eql(u8, descriptor.id, section.id)) {
                    total_weight += paneWeight(descriptor);
                    break;
                }
            }
        }
        self.body_rows.items[sash.first] = sizes[0];
        self.body_rows.items[sash.second] = sizes[1];
        for (self.sections.items, self.body_rows.items) |section, body_h| {
            if (body_h > 0) self.model.setSize(section.id, total_weight * @as(f64, @floatFromInt(body_h)) / @as(f64, @floatFromInt(total_rows)));
        }
    }

    pub fn render(
        self: *ViewPaneContainer,
        grid: *ui.CellGrid,
        content: ui.Rect,
        focused: bool,
        palette: ?*const theme_colors_mod.ThemeColors,
    ) !void {
        try self.layout(content);
        var background = ui.Color{ .r = 30, .g = 30, .b = 33 };
        if (palette) |colors| background = colors.color("sideBar.background", .{ 30, 30, 33 });
        grid.fillRect(content.x, content.y, content.w, content.h, .{
            .bg = ui.cell.packColor(background),
        });
        for (self.sections.items) |section| {
            const index = self.paneIndex(section.id) orelse continue;
            const pane = self.panes[index];
            const pane_focused = focused and idEquals(self.active_id, section.id);
            const header_focused = focused and idEquals(self.focused_header, section.id);
            if (section.header_rect.h > 0) {
                const header = &self.headers.items[index];
                header.collapsed = section.collapsed;
                const show = pane.show_actions.visible(!section.collapsed, idEquals(self.hovered_pane, section.id), pane_focused, self.always_show_header_actions);
                header.setActions(if (show) pane.title_actions(pane.context) else &.{});
                header.focused_action = if (header_focused) self.focused_action else null;
                header.native_outline = self.native_outline;
                try header.render(grid, section.header_rect, palette, header_focused and self.focused_action == null);
            }
            if (section.body_rect.h > 0) {
                try pane.render_body(pane.context, grid, section.body_rect, pane_focused and !header_focused);
            }
        }
        for (self.sashes.items, 0..) |divider, index| {
            const sash = divider.rect;
            const active = self.sash_hovered == index or if (self.sash_dragging) |drag| drag.index == index else false;
            const fallback = if (active) ui.Color{ .r = 0, .g = 127, .b = 212 } else ui.Color{ .r = 62, .g = 62, .b = 66 };
            const color = if (palette) |colors| colors.colorOr(if (active) "sash.hoverBorder" else "sideBarSectionHeader.border", fallback) else fallback;
            const left = ui.cell.snap(sash.x) + 1;
            const right = ui.cell.snap(sash.right()) -| 1;
            for (left..@max(left, right)) |column| {
                grid.putCodepoint(column, ui.cell.snap(sash.y), '─', 1, .{
                    .fg = ui.cell.packColor(color),
                    .bg = ui.cell.packColor(background),
                });
            }
        }
        if (self.drop_target) |target| {
            for (self.sections.items) |section| {
                if (!std.mem.eql(u8, section.id, target.id)) continue;
                paintDropOverlay(grid, target.previewRect(section), palette);
                break;
            }
        }
    }

    pub fn paintDropOverlay(grid: *ui.CellGrid, rect: ui.Rect, palette: ?*const theme_colors_mod.ThemeColors) void {
        const theme = if (palette) |colors| colors.theme.theme_type else .DARK;
        const raw = if (palette) |colors| colors.rawColor("sideBar.dropBackground") orelse colors.rawColor("editorGroup.dropBackground") else null;
        const color: ui.Color = if (raw) |custom| .{ .r = custom.r, .g = custom.g, .b = custom.b } else switch (theme) {
            .LIGHT => .{ .r = 0x26, .g = 0x77, .b = 0xcb },
            .HIGH_CONTRAST_LIGHT => .{ .r = 0x0f, .g = 0x4a, .b = 0x85 },
            .HIGH_CONTRAST_DARK => .{ .r = 0xf3, .g = 0x85, .b = 0x18 },
            .DARK => .{ .r = 0x53, .g = 0x59, .b = 0x5d },
        };
        const alpha: f32 = if (raw) |custom| custom.a else switch (theme) {
            .LIGHT => 0.18,
            .HIGH_CONTRAST_DARK => 0.32,
            else => 0.5,
        };
        grid.tintRect(rect, color, alpha, .{
            .bg = ui.cell.packColor(if (palette) |colors| colors.background else .{ .r = 30, .g = 30, .b = 33 }),
            .fg = ui.cell.packColor(if (palette) |colors| colors.foreground else .{ .r = 204, .g = 204, .b = 204 }),
        });
    }

    fn paneIndex(self: *const ViewPaneContainer, id: []const u8) ?usize {
        for (self.panes, 0..) |pane, index| {
            if (std.mem.eql(u8, pane.id, id)) return index;
        }
        return null;
    }

    pub fn hitTest(self: *ViewPaneContainer, content: ui.Rect, x: usize, y: usize) ?Hit {
        _ = content;
        for (self.sections.items) |section| {
            const index = self.paneIndex(section.id) orelse continue;
            if (section.header_rect.h > 0 and
                x >= ui.cell.snap(section.header_rect.x) and
                x < ui.cell.snap(section.header_rect.x) + ui.cell.snap(section.header_rect.w) and
                y == ui.cell.snap(section.header_rect.y))
            {
                if (self.headers.items[index].hitTest(section.header_rect, x, y)) |hit| {
                    return switch (hit) {
                        .toggle => .{ .toggle = section.id },
                        .action => |action| .{ .action = .{ .id = section.id, .action = action } },
                    };
                }
                return .{ .toggle = section.id };
            }
            if (section.body_rect.h > 0 and
                x >= ui.cell.snap(section.body_rect.x) and
                x < ui.cell.snap(section.body_rect.x) + ui.cell.snap(section.body_rect.w) and
                y >= ui.cell.snap(section.body_rect.y) and
                y < ui.cell.snap(section.body_rect.y) + ui.cell.snap(section.body_rect.h))
            {
                return .{ .body = section.id };
            }
        }
        return null;
    }

    pub fn bodyRect(self: *const ViewPaneContainer, id: []const u8) ?ui.Rect {
        for (self.sections.items) |section| {
            if (std.mem.eql(u8, section.id, id)) return section.body_rect;
        }
        return null;
    }

    fn viewAtHit(hit: ?Hit) ?[]const u8 {
        return if (hit) |value| switch (value) {
            .toggle, .body => |id| id,
            .action => |action| action.id,
        } else null;
    }

    fn idEquals(id: ?[]const u8, other: []const u8) bool {
        return if (id) |value| std.mem.eql(u8, value, other) else false;
    }

    fn focusHeader(self: *ViewPaneContainer, id: []const u8) void {
        self.setActive(id);
        self.focused_header = id;
    }

    pub fn handleKey(self: *ViewPaneContainer, event: *ui.KeyEvent) !bool {
        const id = self.active_id orelse return false;
        const index = self.paneIndex(id) orelse return false;
        const pane = self.panes[index];
        for (self.sections.items, 0..) |section, section_index| {
            if (!std.mem.eql(u8, section.id, id) or section.header_rect.h == 0) continue;
            if (!event.mods.alt and !event.mods.ctrl) {
                if (idEquals(self.focused_header, id)) {
                    const reverse_tab = event.key == .backtab or (event.key == .tab and event.mods.shift);
                    if (self.focused_action != null) {
                        self.handleToolbarKey(pane, section, section_index, event, reverse_tab);
                        return true;
                    }
                    if (event.key == .up or reverse_tab) {
                        self.focusHeader(self.sections.items[section_index -| 1].id);
                    } else if (event.key == .down) {
                        self.focusNextHeader(section_index);
                    } else if (event.key == .tab) {
                        const show = pane.show_actions.visible(!section.collapsed, false, true, self.always_show_header_actions);
                        if (show) self.focused_action = nextAction(pane.title_actions(pane.context), null, 1);
                        if (self.focused_action == null) self.focusAfterHeader(section, section_index);
                    } else if (self.sections.items.len > 1) {
                        switch (event.key) {
                            .left => self.model.setCollapsed(id, true),
                            .right => self.model.setCollapsed(id, false),
                            .enter => self.model.setCollapsed(id, !self.model.isCollapsed(id)),
                            .char => |ch| if (ch == ' ') self.model.setCollapsed(id, !self.model.isCollapsed(id)),
                            else => {},
                        }
                    }
                    return true;
                }
                if (event.key == .backtab or (event.key == .tab and event.mods.shift)) {
                    self.focusHeader(id);
                    return true;
                }
            }
            break;
        }
        return pane.handle_key(pane.context, event);
    }

    fn handleToolbarKey(self: *ViewPaneContainer, pane: Pane, section: Section, section_index: usize, event: *ui.KeyEvent, reverse_tab: bool) void {
        const current = self.focused_action.?;
        const actions = pane.title_actions(pane.context);
        if (reverse_tab) {
            self.focused_action = null;
            return;
        }
        switch (event.key) {
            .left => self.focused_action = nextAction(actions, current, -1) orelse current,
            .right => self.focused_action = nextAction(actions, current, 1) orelse current,
            .home => self.focused_action = nextAction(actions, null, 1),
            .end => self.focused_action = nextAction(actions, null, -1),
            .tab => self.focusAfterHeader(section, section_index),
            else => {
                const activate = event.key == .enter or (event.key == .char and event.key.char == ' ');
                if (activate and current < actions.len and actions[current].enabled) {
                    if (pane.run_title_action) |run| run(pane.context, actions[current].id);
                }
            },
        }
    }

    fn nextAction(actions: []const views.TitleAction, current: ?usize, direction: isize) ?usize {
        const end: isize = @intCast(actions.len);
        const initial: isize = if (current) |value| @intCast(value) else if (direction == 1) -1 else end;
        var index = initial + direction;
        while (index >= 0 and index < end) : (index += direction) {
            if (actions[@intCast(index)].enabled) return @intCast(index);
        }
        return null;
    }

    fn focusNextHeader(self: *ViewPaneContainer, section_index: usize) void {
        const next = self.sections.items[@min(section_index + 1, self.sections.items.len - 1)];
        if (next.header_rect.h > 0) self.focusHeader(next.id);
    }

    fn focusAfterHeader(self: *ViewPaneContainer, section: Section, section_index: usize) void {
        self.focused_action = null;
        if (section.collapsed) {
            self.focusNextHeader(section_index);
        } else {
            self.focused_header = null;
        }
    }

    pub fn cancelHeaderDrag(self: *ViewPaneContainer) void {
        self.header_press = null;
        self.dragging_header = false;
        self.drop_target = null;
        self.drop_activity = null;
    }

    fn dropTargetAt(self: *const ViewPaneContainer, source: HeaderPress, hit: ?Hit, row: usize) ?DropTarget {
        const id = viewAtHit(hit) orelse return null;
        if (std.mem.eql(u8, id, source.id) or !self.model.canMoveView(source.id)) return null;
        for (self.sections.items) |section| {
            if (!std.mem.eql(u8, section.id, id)) continue;
            const top = ui.cell.snap(section.header_rect.y);
            const height = ui.cell.snap(section.header_rect.h + section.body_rect.h);
            // A collapsed header has a single terminal row. Allow inserting
            // across it from either direction.
            const before = if (height == 1) source.y > top else row -| top < (height + 1) / 2;
            return .{ .id = id, .position = if (before) .before else .after };
        }
        return null;
    }

    pub fn handleHeaderMouse(self: *ViewPaneContainer, event: *const ui.MouseEvent, content: ui.Rect) ?HeaderEvent {
        const hit = self.hitTest(content, event.x, event.y);
        const header_id: ?[]const u8 = if (hit) |value| switch (value) {
            .toggle => |id| id,
            .action => |action| action.id,
            .body => null,
        } else null;
        if (event.kind == .move) {
            const press = self.header_press orelse return null;
            if (event.y != press.y or event.x +| 1 < press.x or event.x > press.x +| 1) self.dragging_header = true;
            if (self.dragging_header) self.drop_target = self.dropTargetAt(press, hit, event.y);
            return .handled;
        }
        if (event.kind == .up) {
            const press = self.header_press orelse return null;
            defer self.cancelHeaderDrag();
            if (self.dragging_header) {
                if (self.dropTargetAt(press, hit, event.y)) |target| self.model.move(press.id, target.id, target.position);
            } else if (idEquals(header_id, press.id) and self.sections.items.len > 1) {
                self.model.setCollapsed(press.id, !self.model.isCollapsed(press.id));
            }
            return .handled;
        }
        if (event.kind != .down and event.kind != .click) return null;
        self.cancelHeaderDrag();
        const id = header_id orelse return null;
        if (event.button == .right) return .{ .context_menu = id };
        if (event.button != .left) return null;
        self.focusHeader(id);
        if (hit.? == .action) {
            const index = self.paneIndex(id) orelse return .handled;
            const action_id = hit.?.action.action;
            for (self.headers.items[index].actions, 0..) |action, action_index| {
                if (!action.enabled or !std.mem.eql(u8, action.id, action_id)) continue;
                self.focused_action = action_index;
                return .{ .action = action_id };
            }
            return .handled;
        }
        if (event.kind == .down) {
            self.header_press = .{ .id = id, .x = event.x, .y = event.y };
        } else if (self.sections.items.len > 1) {
            self.model.setCollapsed(id, !self.model.isCollapsed(id));
        }
        return .handled;
    }

    pub fn handleMouse(self: *ViewPaneContainer, event: *const ui.MouseEvent, content: ui.Rect) !bool {
        if (self.handleHeaderMouse(event, content) != null) return true;
        const hit = self.hitTest(content, event.x, event.y) orelse return false;
        if (hit != .body) return true;
        const id = hit.body;
        const index = self.paneIndex(id) orelse return false;
        if ((event.kind == .down or event.kind == .click) and event.button == .left) self.setActive(id);
        const pane = self.panes[index];
        const rect = self.bodyRect(id) orelse return false;
        return pane.handle_mouse(pane.context, event, rect);
    }

    /// Moves the pointer into the container: only the header that contains the
    /// cell receives it, every other header is cleared. The surface resolves
    /// the hovered element and paints its `HoverStyle`.
    pub fn setHoveredAt(self: *ViewPaneContainer, x: usize, y: usize) void {
        self.hovered_pane = viewAtHit(self.hitTest(.{}, x, y));
        for (self.sections.items) |section| {
            const index = self.paneIndex(section.id) orelse continue;
            const header = &self.headers.items[index];
            if (section.header_rect.h == 0) {
                header.clearHover();
                continue;
            }
            const header_x = ui.cell.snap(section.header_rect.x);
            const header_y = ui.cell.snap(section.header_rect.y);
            const header_w = ui.cell.snap(section.header_rect.w);
            if (x >= header_x and x < header_x + header_w and y == header_y) {
                header.setHoveredAt(x - header_x, y - header_y);
            } else {
                header.clearHover();
            }
        }
    }

    pub fn clearHover(self: *ViewPaneContainer) void {
        self.hovered_pane = null;
        for (self.headers.items) |*header| header.clearHover();
    }

    /// Title actions for the side-bar title toolbar when a single view is
    /// merged with the container.
    pub fn mergedTitleActions(self: *const ViewPaneContainer, allocator: Allocator) !?[]const views.TitleAction {
        _ = allocator;
        const visible = try self.model.visibleViews(self.allocator);
        defer self.allocator.free(visible);
        if (visible.len != 1 or !self.merge_view_with_container_when_single_view) return null;
        const index = self.paneIndex(visible[0].id) orelse return null;
        const pane = self.panes[index];
        return pane.title_actions(pane.context);
    }
};
