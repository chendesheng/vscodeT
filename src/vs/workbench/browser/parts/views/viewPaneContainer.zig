// Port of the terminal subset of
// `src/vs/workbench/browser/parts/views/viewPaneContainer.ts`.
//
// The container stacks visible views with 1-row headers and splits the
// remaining body rows by `ViewDescriptor.weight` (upstream uses pixel sizes and
// draggable sashes; the terminal allocates whole rows). With a single visible
// view the header is merged into the container title and the body takes the
// whole area, matching upstream `mergeViewWithContainerWhenSingleView`.
// View moving, hiding, drag/drop, context menus and resize sashes are not
// ported.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const views = @import("../../../common/views.zig");
const model_mod = @import("../../../services/views/common/viewContainerModel.zig");
const view_pane = @import("./viewPane.zig");
const theme_colors_mod = @import("../../themeColors.zig");

pub const Pane = struct {
    id: []const u8,
    title: []const u8,
    context: *anyopaque,
    render_body: *const fn (context: *anyopaque, grid: *ui.CellGrid, rect: ui.Rect, focused: bool) anyerror!void,
    handle_key: *const fn (context: *anyopaque, event: *ui.KeyEvent) anyerror!bool,
    handle_mouse: *const fn (context: *anyopaque, event: *const ui.MouseEvent, rect: ui.Rect) anyerror!bool,
    title_actions: *const fn (context: *anyopaque) []const views.TitleAction,
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

pub const ViewPaneContainer = struct {
    allocator: Allocator,
    model: *model_mod.ViewContainerModel,
    panes: []const Pane,
    headers: std.array_list.Managed(view_pane.Header),
    sections: std.array_list.Managed(Section),
    active_id: ?[]const u8 = null,

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
        self.* = undefined;
    }

    pub fn activeView(self: *const ViewPaneContainer) ?[]const u8 {
        return self.active_id;
    }

    pub fn setActive(self: *ViewPaneContainer, id: []const u8) void {
        if (!self.model.isVisible(id)) return;
        self.active_id = id;
        self.model.setActiveView(id);
    }

    /// Recomputes section rectangles for the container content area.
    pub fn layout(self: *ViewPaneContainer, content: ui.Rect) !void {
        self.sections.clearRetainingCapacity();
        const visible = try self.model.visibleViews(self.allocator);
        defer self.allocator.free(visible);
        if (visible.len == 0) return;

        const content_x = ui.cell.snap(content.x);
        const content_y = ui.cell.snap(content.y);
        const content_w = ui.cell.snap(content.w);
        const content_h = ui.cell.snap(content.h);
        if (content_w == 0 or content_h == 0) return;

        if (visible.len == 1) {
            const descriptor = visible[0];
            try self.sections.append(.{
                .id = descriptor.id,
                .header_rect = .{ .x = @floatFromInt(content_x), .y = @floatFromInt(content_y), .w = @floatFromInt(content_w), .h = 0 },
                .body_rect = .{
                    .x = @floatFromInt(content_x),
                    .y = @floatFromInt(content_y),
                    .w = @floatFromInt(content_w),
                    .h = @floatFromInt(content_h),
                },
                .collapsed = false,
                .merged = true,
            });
            if (self.active_id == null) self.active_id = descriptor.id;
            return;
        }

        const header_rows = @min(visible.len, content_h);
        const available = content_h -| visible.len;

        // Rows for each expanded body, split by weight with a minimum of one.
        var body_rows: [16]usize = undefined;
        @memset(&body_rows, 0);
        var expanded_count: usize = 0;
        var total_weight: usize = 0;
        for (visible, 0..) |descriptor, index| {
            if (descriptor.collapsed) continue;
            expanded_count += 1;
            total_weight += @max(descriptor.weight, 1);
            if (index >= body_rows.len) continue;
        }
        if (expanded_count > 0 and available >= expanded_count) {
            var allocated: usize = 0;
            var last_expanded: ?usize = null;
            for (visible, 0..) |descriptor, index| {
                if (descriptor.collapsed or index >= body_rows.len) continue;
                const rows = @max(available * @max(descriptor.weight, 1) / total_weight, 1);
                body_rows[index] = rows;
                allocated += rows;
                last_expanded = index;
            }
            if (allocated > available) {
                var excess = allocated - available;
                var index = body_rows.len;
                while (index > 0 and excess > 0) {
                    index -= 1;
                    if (visible[index].collapsed or body_rows[index] <= 1) continue;
                    const take = @min(excess, body_rows[index] - 1);
                    body_rows[index] -= take;
                    excess -= take;
                }
            } else if (allocated < available) {
                if (last_expanded) |index| body_rows[index] += available - allocated;
            }
        } else if (expanded_count > 0) {
            var row: usize = 0;
            for (visible, 0..) |descriptor, index| {
                if (descriptor.collapsed or index >= body_rows.len) continue;
                if (row >= available) break;
                body_rows[index] = 1;
                row += 1;
            }
        }

        var cursor = content_y;
        const bottom = content_y + content_h;
        for (visible, 0..) |descriptor, index| {
            const header_h: usize = if (cursor < bottom and index < header_rows) 1 else 0;
            const header_rect = ui.Rect{
                .x = @floatFromInt(content_x),
                .y = @floatFromInt(cursor),
                .w = @floatFromInt(content_w),
                .h = @floatFromInt(header_h),
            };
            cursor += header_h;

            const rows = if (descriptor.collapsed) 0 else if (index < body_rows.len) body_rows[index] else 0;
            const body_h = @min(rows, bottom -| cursor);
            const body_rect = ui.Rect{
                .x = @floatFromInt(content_x),
                .y = @floatFromInt(cursor),
                .w = @floatFromInt(content_w),
                .h = @floatFromInt(body_h),
            };
            cursor += body_h;

            try self.sections.append(.{
                .id = descriptor.id,
                .header_rect = header_rect,
                .body_rect = body_rect,
                .collapsed = descriptor.collapsed,
                .merged = false,
            });
            if (self.active_id == null) self.active_id = descriptor.id;
        }
        if (self.active_id) |active| {
            if (!self.model.isVisible(active)) {
                self.active_id = visible[0].id;
                self.model.setActiveView(visible[0].id);
            }
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
            const pane_focused = focused and self.active_id != null and std.mem.eql(u8, self.active_id.?, section.id);
            if (section.header_rect.h > 0) {
                const header = &self.headers.items[index];
                header.collapsed = section.collapsed;
                header.setActions(pane.title_actions(pane.context));
                try header.render(grid, section.header_rect, palette, pane_focused);
            }
            if (section.body_rect.h > 0) {
                try pane.render_body(pane.context, grid, section.body_rect, pane_focused);
            }
        }
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

    pub fn handleKey(self: *ViewPaneContainer, event: *ui.KeyEvent) !bool {
        const id = self.active_id orelse return false;
        const index = self.paneIndex(id) orelse return false;
        const pane = self.panes[index];
        return pane.handle_key(pane.context, event);
    }

    pub fn handleMouse(self: *ViewPaneContainer, event: *const ui.MouseEvent, content: ui.Rect) !bool {
        const hit = self.hitTest(content, event.x, event.y) orelse return false;
        switch (hit) {
            .toggle => |id| {
                self.model.setCollapsed(id, !self.model.isCollapsed(id));
                self.setActive(id);
                return true;
            },
            .action => |action| {
                self.setActive(action.id);
                return true;
            },
            .body => |id| {
                const index = self.paneIndex(id) orelse return false;
                self.setActive(id);
                const pane = self.panes[index];
                const rect = self.bodyRect(id) orelse return false;
                return pane.handle_mouse(pane.context, event, rect);
            },
        }
    }

    /// Title actions for the side-bar title toolbar when a single view is
    /// merged with the container.
    pub fn mergedTitleActions(self: *const ViewPaneContainer, allocator: Allocator) !?[]const views.TitleAction {
        _ = allocator;
        const visible = try self.model.visibleViews(self.allocator);
        defer self.allocator.free(visible);
        if (visible.len != 1) return null;
        const index = self.paneIndex(visible[0].id) orelse return null;
        const pane = self.panes[index];
        return pane.title_actions(pane.context);
    }
};
