// Port of the portable state in
// `src/vs/workbench/browser/parts/sidebar/sidebarPart.ts`, plus the terminal
// side bar title view.
//
// Upstream `SidebarPart` extends `AbstractPaneCompositePart`: it clamps its
// width, reports a preferred width from the active viewlet, keeps the activity
// bar position (`workbench.activityBar.location`), moves the activity bar into
// the side bar for the top/bottom positions, delegates the pinned/visible view
// container ids to the activity bar when the side bar does not host the
// composite bar, and renders a title area with the active viewlet's title label
// and actions. The browser class also owns DOM sashes, menus, storage and
// drag-and-drop; the terminal part keeps the state, the title chrome and the
// hit testing.
//
// Terminal adaptation: the title area is one cell row built with the `ui` DOM
// (a `Document` painted through a `Surface`), like the panel title. The title
// label is uppercased (`text-transform: uppercase` upstream). The activity bar
// at the top/bottom becomes a one-row icon composite bar in the side bar
// header/footer; there is no horizontal activity bar widget because a cell row
// already is one. The 1px theme borders around the title/header/footer have no
// cell equivalent and are not painted; the terminal draws part borders as
// single-cell dividers in the workbench layout. The active viewlet settings key
// (`workbench.sidebar.activeviewletid`, WORKSPACE scope) is not persisted: the
// terminal has no session-surviving workspace storage. `focusActivityBar`,
// browser boundary sash classes and the activity bar visibility action need a
// focus model, browser classes and configuration writes. The workbench grid
// owns the draggable terminal sash.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const pane = @import("../paneCompositePart.zig");
const activity_bar_mod = @import("../activitybar/activitybarPart.zig");
const layout_service = @import("../../../services/layout/browser/layoutService.zig");
const theme_colors_mod = @import("../../themeColors.zig");
const views = @import("../../../common/views.zig");
const ui = @import("ui");

pub const Position = layout_service.Position;
pub const ActivityBarPosition = layout_service.ActivityBarPosition;
pub const CompositeBarPosition = pane.CompositeBarPosition;

const ViewPaneContainer = @import("../views/viewPaneContainer.zig").ViewPaneContainer;
const DropDestination = @import("../views/viewPaneContainer.zig").DropDestination;

const Part = @import("../../part.zig").Part;

pub const SidebarPart = struct {
    base: Part,
    allocator: Allocator,
    view_pane_containers: std.StringHashMapUnmanaged(*ViewPaneContainer) = .empty,
    pane: pane.PaneCompositePart,
    /// Layout visibility, like `layoutService.isVisible(Parts.SIDEBAR_PART)`.
    visible: bool = false,
    /// Terminal cells. The layout model keeps the same value.
    width: usize = 28,
    position: Position = .left,
    /// Upstream `minimumWidth` is 170 px; the terminal minimum is 10 cells.
    minimum_width: usize = layout_service.widthInCells(170),
    maximum_width: usize = std.math.maxInt(usize),
    /// Port of `SidebarPart.activeViewletSettingsKey`.
    active_viewlet_settings_key: []const u8 = "workbench.sidebar.activeviewletid",
    /// `workbench.activityBar.location` / `workbench.activityBar.autoHide`.
    activity_bar_position: ActivityBarPosition = .default,
    activity_bar_auto_hide: bool = false,
    /// The workbench's activity bar (upstream the side bar creates it). Used for
    /// the pinned/visible id fallbacks when the side bar does not host the
    /// composite bar.
    activity_bar: ?*const activity_bar_mod.ActivityBarPart = null,
    /// One-row title chrome. `title` holds the title label and the actions,
    /// `bar` holds the top/bottom activity bar composite bar.
    title_surface: ?ui.Surface = null,
    title_nodes: std.array_list.Managed(TitleNode),
    bar_surface: ?ui.Surface = null,
    bar_nodes: std.array_list.Managed(TitleNode),
    hovered_action_id: ?[]const u8 = null,
    hovered_composite_id: ?[]const u8 = null,
    on_did_change: Emitter(void),
    /// Last painted title/composite-bar grids. The terminal equivalent of
    /// upstream's retained DOM: unchanged chrome is blitted instead of being
    /// cleared and flex-laid-out again on every editor frame.
    title_signature: ?u64 = null,
    bar_signature: ?u64 = null,

    /// A painted title element: a title action or a composite-bar item.
    pub const TitleNode = struct {
        id: []const u8,
        node: *ui.Node,
    };

    pub const Hit = union(enum) {
        action: []const u8,
        composite: []const u8,
    };

    /// One-row title (the upstream 35 px title area).
    pub const title_height: usize = 1;
    /// One-row activity bar composite bar in the header/footer.
    pub const bar_height: usize = 1;

    pub fn init(allocator: Allocator) SidebarPart {
        return .{
            .base = Part.init(allocator, .sidebar, SidebarPart),
            .allocator = allocator,
            .pane = pane.PaneCompositePart.init(
                allocator,
                "workbench.contributions.viewlets",
                "workbench.parts.sidebar",
                .sidebar,
            ),
            .title_nodes = std.array_list.Managed(TitleNode).init(allocator),
            .bar_nodes = std.array_list.Managed(TitleNode).init(allocator),
            .on_did_change = Emitter(void).init(allocator),
        };
    }

    pub fn registerViewPaneContainer(self: *SidebarPart, container: *ViewPaneContainer) !void {
        try self.view_pane_containers.putNoClobber(self.allocator, container.model.container.id, container);
    }

    pub fn unregisterViewPaneContainer(self: *SidebarPart, container: *ViewPaneContainer) void {
        _ = self.view_pane_containers.remove(container.model.container.id);
    }

    pub fn getViewPaneContainer(self: *const SidebarPart, id: []const u8) ?*ViewPaneContainer {
        return self.view_pane_containers.get(id);
    }

    pub fn dropDestination(self: *const SidebarPart, sidebar_rect: ui.Rect, activity_rect: ui.Rect, x: usize, y: usize) ?DropDestination {
        if (x >= ui.cell.snap(activity_rect.x) and x < ui.cell.snap(activity_rect.right())) if (self.activity_bar) |bar| {
            if (activity_bar_mod.hitAt(bar, x, y, activity_rect)) |index| {
                const activity = bar.activityAtVisibleIndex(index) orelse return null;
                return .{
                    .container = self.getViewPaneContainer(activity.id) orelse return null,
                    .rect = .{ .x = activity_rect.x, .y = @floatFromInt(y), .w = activity_rect.w, .h = 1 },
                };
            }
        };
        const hit = hitTest(self, sidebar_rect, x, y) orelse return null;
        if (hit != .composite) return null;
        return .{
            .container = self.getViewPaneContainer(hit.composite) orelse return null,
            .rect = compositeItemRect(self, sidebar_rect, hit.composite) orelse return null,
        };
    }

    pub fn deinit(self: *SidebarPart) void {
        self.base.deinit();
        self.view_pane_containers.deinit(self.allocator);
        if (self.title_surface) |*surface| surface.deinit();
        self.title_surface = null;
        self.title_nodes.deinit();
        if (self.bar_surface) |*surface| surface.deinit();
        self.bar_surface = null;
        self.bar_nodes.deinit();
        self.on_did_change.deinit();
        self.pane.deinit();
    }

    /// Upstream the side bar owns its activity bar instance; the terminal
    /// workbench owns the rail and hands it over for the id fallbacks.
    pub fn attachActivityBar(self: *SidebarPart, bar: *const activity_bar_mod.ActivityBarPart) void {
        self.activity_bar = bar;
    }

    pub fn setVisible(self: *SidebarPart, visible: bool) !void {
        if (self.visible == visible) return;
        self.visible = visible;
        try self.pane.setVisible(visible);
        try self.base.setVisible(visible);
        try self.on_did_change.fire({});
    }

    pub fn isVisible(self: *const SidebarPart) bool {
        return self.visible;
    }

    pub fn resizeWidth(base: *Part, width: usize) !usize {
        const self: *SidebarPart = @fieldParentPtr("base", base);
        try self.setWidth(width);
        return self.width;
    }

    /// The terminal border is painted on the cell edge when supported.
    /// Glyph borders reserve space inside the sidebar's grid rectangle.
    pub fn innerRect(frame: ui.Rect, cell_borders: bool) ui.Rect {
        if (cell_borders) return frame;
        if (frame.h >= 14) return .{ .x = frame.x + 1, .y = frame.y + 1, .w = frame.w - 2, .h = frame.h - 2 };
        return .{ .x = frame.x, .y = frame.y, .w = frame.w - 1, .h = frame.h };
    }

    pub fn setWidth(self: *SidebarPart, width: usize) !void {
        const clamped = @max(self.minimum_width, @min(width, self.maximum_width));
        if (self.width == clamped) return;
        self.width = clamped;
        try self.on_did_change.fire({});
    }

    pub fn setPosition(self: *SidebarPart, position: Position) !void {
        if (self.position == position) return;
        self.position = position;
        try self.on_did_change.fire({});
    }

    /// Port of `SidebarPart.get preferredWidth`: the active viewlet's optimal
    /// width with a 300 px floor. Both dimensions are terminal columns here.
    pub fn preferredWidth(self: *const SidebarPart, optimal_width: usize) ?usize {
        if (self.pane.active_id == null) return null;
        return @max(layout_service.widthInCells(300), optimal_width);
    }

    /// Applies `workbench.activityBar.location` and
    /// `workbench.activityBar.autoHide`; `SidebarPart.onDidChangeActivityBarLocation`
    /// updates the composite bar and shows/hides the activity bar.
    pub fn setLayoutSettings(self: *SidebarPart, values: layout_service.LayoutSettingsValues) !void {
        if (self.activity_bar_position == values.activity_bar_location and
            self.activity_bar_auto_hide == values.activity_bar_auto_hide) return;
        self.activity_bar_position = values.activity_bar_location;
        self.activity_bar_auto_hide = values.activity_bar_auto_hide;
        try self.updateCompositeBar();
    }

    /// Port of `SidebarPart.updateCompositeBar` (also called after the view
    /// containers register, like the upstream extension-registration listener).
    pub fn updateCompositeBar(self: *SidebarPart) !void {
        _ = try self.pane.setCompositeBar(self.shouldShowCompositeBar(), self.getCompositeBarPosition());
    }

    /// Port of `SidebarPart.shouldShowCompositeBar`.
    pub fn shouldShowCompositeBar(self: *const SidebarPart) bool {
        const position = self.activity_bar_position;
        if (position != .top and position != .bottom) return false;

        // Auto-hide keeps the composite bar hidden while there is at most one
        // visible view container.
        if (self.activity_bar_auto_hide) {
            return self.visibleViewContainerCount() > 1;
        }
        return true;
    }

    /// Port of `SidebarPart.getCompositeBarPosition`.
    pub fn getCompositeBarPosition(self: *const SidebarPart) CompositeBarPosition {
        return switch (self.activity_bar_position) {
            .top => .top,
            .bottom => .bottom,
            .default, .hidden => .title,
        };
    }

    /// Port of `SidebarPart.shouldShowActivityBar`: the activity bar lives in
    /// the side bar (top/bottom) only while the composite bar is hidden.
    pub fn shouldShowActivityBar(self: *const SidebarPart) bool {
        if (self.shouldShowCompositeBar()) return false;
        return self.activity_bar_position != .hidden;
    }

    fn visibleViewContainerCount(self: *const SidebarPart) usize {
        var count: usize = 0;
        for (self.pane.bar.items.items) |item| {
            if (item.visible) count += 1;
        }
        return count;
    }

    pub fn openPaneComposite(self: *SidebarPart, id: []const u8) !bool {
        const opened = try self.pane.openPaneComposite(id, true);
        if (opened == null) return false;
        if (!self.visible) {
            self.visible = true;
            try self.base.setVisible(true);
            try self.on_did_change.fire({});
        }
        return true;
    }

    pub fn activePaneComposite(self: *const SidebarPart) ?pane.PaneCompositeDescriptor {
        return self.pane.getActivePaneComposite();
    }

    pub fn hideActivePaneComposite(self: *SidebarPart) !void {
        if (self.visible) {
            self.visible = false;
            try self.base.setVisible(false);
            try self.on_did_change.fire({});
        }
        try self.pane.hideActivePaneComposite();
    }

    pub fn getPinnedPaneCompositeIds(self: *const SidebarPart, allocator: Allocator) ![][]const u8 {
        if (self.shouldShowCompositeBar()) return self.pane.getPinnedPaneCompositeIds(allocator);
        const bar = self.activity_bar orelse return allocator.alloc([]const u8, 0);
        return bar.getPinnedPaneCompositeIds(allocator);
    }

    pub fn getVisiblePaneCompositeIds(self: *const SidebarPart, allocator: Allocator) ![][]const u8 {
        if (self.shouldShowCompositeBar()) return self.pane.getVisiblePaneCompositeIds(allocator);
        const bar = self.activity_bar orelse return allocator.alloc([]const u8, 0);
        return bar.getVisiblePaneCompositeIds(allocator);
    }

    pub fn getPaneCompositeIds(self: *const SidebarPart, allocator: Allocator) ![][]const u8 {
        if (self.shouldShowCompositeBar()) return self.pane.getPaneCompositeIds(allocator);
        const bar = self.activity_bar orelse return allocator.alloc([]const u8, 0);
        return bar.getPaneCompositeIds(allocator);
    }

    /// Port of `SwitchCompositeViewAction`: the next visible composite relative
    /// to the active one, in bar order.
    pub fn switchViewTarget(self: *const SidebarPart, offset: isize, allocator: Allocator) !?[]const u8 {
        const ids = try self.getVisiblePaneCompositeIds(allocator);
        defer allocator.free(ids);
        if (ids.len == 0) return null;
        const active = self.pane.active_id orelse return ids[0];
        for (ids, 0..) |id, index| {
            if (!std.mem.eql(u8, id, active)) continue;
            const len: isize = @intCast(ids.len);
            const next: usize = @intCast(@mod(@as(isize, @intCast(index)) + offset + len, len));
            return ids[next];
        }
        return null;
    }

    /// Registered side-bar containers in pane-composite order.
    pub fn visibleComposites(self: *const SidebarPart, allocator: Allocator) ![]pane.PaneCompositeDescriptor {
        return self.pane.visibleComposites(allocator);
    }

    /// The location this part hosts, for the view-descriptor service.
    pub fn location(_: *const SidebarPart) views.ViewContainerLocation {
        return .sidebar;
    }

    /// Number of chrome rows above/below the content.
    pub fn chromeRows(self: *const SidebarPart) usize {
        const position = self.pane.getCompositeBarPosition();
        var rows: usize = if (self.pane.has_title) SidebarPart.title_height else 0;
        if (position == .top) rows += SidebarPart.bar_height;
        if (position == .bottom) rows += SidebarPart.bar_height;
        return rows;
    }
};

/// The side bar title/header/footer/content rectangles for a part rectangle.
pub const Layout = struct {
    header: ?ui.Rect = null,
    title: ui.Rect,
    content: ui.Rect,
    footer: ?ui.Rect = null,
};

pub fn layout(part: *const SidebarPart, rect: ui.Rect) Layout {
    const x = ui.cell.snap(rect.x);
    const y = ui.cell.snap(rect.y);
    const width = ui.cell.snap(rect.w);
    const height = ui.cell.snap(rect.h);
    const position = part.pane.getCompositeBarPosition();

    var top = y;
    var header: ?ui.Rect = null;
    if (position == .top and height > 0) {
        header = .{ .x = @floatFromInt(x), .y = @floatFromInt(top), .w = @floatFromInt(width), .h = @floatFromInt(SidebarPart.bar_height) };
        top += SidebarPart.bar_height;
    }

    var title = ui.Rect{ .x = @floatFromInt(x), .y = @floatFromInt(top), .w = @floatFromInt(width), .h = 0 };
    if (part.pane.has_title and top < y + height) {
        title.h = @floatFromInt(SidebarPart.title_height);
        top += SidebarPart.title_height;
    }

    var bottom = y + height;
    var footer: ?ui.Rect = null;
    if (position == .bottom and bottom > top) {
        bottom -= SidebarPart.bar_height;
        footer = .{ .x = @floatFromInt(x), .y = @floatFromInt(bottom), .w = @floatFromInt(width), .h = @floatFromInt(SidebarPart.bar_height) };
    }

    return .{
        .header = header,
        .title = title,
        .content = .{
            .x = @floatFromInt(x),
            .y = @floatFromInt(top),
            .w = @floatFromInt(width),
            .h = @floatFromInt(bottom -| top),
        },
        .footer = footer,
    };
}

/// The content area below the title (and above the footer).
pub fn contentRect(part: *const SidebarPart, rect: ui.Rect) ui.Rect {
    return layout(part, rect).content;
}

// ---------------------------------------------------------------------------
// Terminal side bar title view
// ---------------------------------------------------------------------------

fn upperAscii(buf: []u8, text: []const u8) []const u8 {
    const len = @min(buf.len, text.len);
    for (text[0..len], 0..) |ch, index| buf[index] = std.ascii.toUpper(ch);
    return buf[0..len];
}

fn hashText(hasher: *std.hash.Wyhash, text: []const u8) void {
    hasher.update(text);
    hasher.update(&[_]u8{0});
}

fn hashRect(hasher: *std.hash.Wyhash, x: usize, y: usize, w: usize, h: usize) void {
    hasher.update(std.mem.asBytes(&x));
    hasher.update(std.mem.asBytes(&y));
    hasher.update(std.mem.asBytes(&w));
    hasher.update(std.mem.asBytes(&h));
}

fn hashPalette(hasher: *std.hash.Wyhash, palette: ?*const theme_colors_mod.ThemeColors) void {
    const value: usize = if (palette) |p| @intFromPtr(p) else 0;
    hasher.update(std.mem.asBytes(&value));
}

fn prepareSurface(part: *SidebarPart, slot: *?ui.Surface, width: usize) !*ui.Surface {
    if (slot.*) |*surface| {
        if (surface.doc.cols != width or surface.doc.rows != 1) try surface.resize(width, 1);
    } else {
        slot.* = try ui.Surface.init(part.allocator, .{ .cols = width, .rows = 1 });
    }
    return &slot.*.?;
}

fn sidebarColors(palette: ?*const theme_colors_mod.ThemeColors) struct {
    background: ui.Color,
    title_background: ui.Color,
    title_foreground: ui.Color,
    hover_background: ui.Color,
    bar_background: ui.Color,
    bar_foreground: ui.Color,
    bar_inactive_foreground: ui.Color,
    bar_active_background: ui.Color,
    badge_foreground: ui.Color,
} {
    const side_bar_background = ui.Color{ .r = 30, .g = 30, .b = 33 };
    const side_bar_foreground = ui.Color{ .r = 204, .g = 204, .b = 204 };
    if (palette) |colors| {
        const background = colors.colorOr("sideBar.background", side_bar_background);
        const foreground = colors.colorOr("sideBar.foreground", side_bar_foreground);
        return .{
            .background = background,
            .title_background = colors.colorOr("sideBarTitle.background", background),
            .title_foreground = colors.colorOr("sideBarTitle.foreground", foreground),
            .hover_background = colors.color("toolbar.hoverBackground", .{ 48, 48, 52 }),
            .bar_background = colors.colorOr("activityBarTop.background", background),
            .bar_foreground = colors.color("activityBarTop.foreground", .{ 231, 231, 231 }),
            .bar_inactive_foreground = colors.color("activityBarTop.inactiveForeground", .{ 150, 150, 150 }),
            .bar_active_background = colors.colorOr("activityBarTop.activeBackground", colors.color("activityBar.activeBackground", .{ 45, 45, 50 })),
            .badge_foreground = colors.color("activityBarBadge.foreground", .{ 250, 200, 80 }),
        };
    }
    return .{
        .background = side_bar_background,
        .title_background = side_bar_background,
        .title_foreground = side_bar_foreground,
        .hover_background = .{ .r = 48, .g = 48, .b = 52 },
        .bar_background = side_bar_background,
        .bar_foreground = .{ .r = 231, .g = 231, .b = 231 },
        .bar_inactive_foreground = .{ .r = 150, .g = 150, .b = 150 },
        .bar_active_background = .{ .r = 45, .g = 45, .b = 50 },
        .badge_foreground = .{ .r = 250, .g = 200, .b = 80 },
    };
}

/// Paints the side bar title: the active viewlet's title label on the left and
/// its actions on the right. The DOM row is rebuilt from the model on every
/// render, like the panel title, so the surface keeps its frame diff.
pub fn renderTitle(
    part: *SidebarPart,
    grid: *ui.CellGrid,
    rect: ui.Rect,
    palette: ?*const theme_colors_mod.ThemeColors,
) !void {
    const x = ui.cell.snap(rect.x);
    const y = ui.cell.snap(rect.y);
    const width = ui.cell.snap(rect.w);
    const height = ui.cell.snap(rect.h);
    if (!part.visible or width == 0 or height == 0 or !part.pane.has_title) return;

    const surface = try prepareSurface(part, &part.title_surface, width);

    var hasher = std.hash.Wyhash.init(0);
    hashRect(&hasher, x, y, width, height);
    hashPalette(&hasher, palette);
    hashText(&hasher, part.pane.title_label.title);
    hashText(&hasher, part.hovered_action_id orelse "");
    for ([_][]const pane.TitleAction{ part.pane.primary_actions.items, part.pane.secondary_actions.items }) |actions| {
        for (actions) |action| {
            hashText(&hasher, action.id);
            hasher.update(std.mem.asBytes(&action.glyph));
            hasher.update(&[_]u8{@intFromBool(action.enabled)});
        }
    }
    const signature = hasher.final();
    if (part.title_signature == signature) {
        try grid.blit(surface.grid(), x, y, width, 1);
        return;
    }

    const doc = surface.document();
    doc.clear();
    part.title_nodes.clearRetainingCapacity();

    const colors = sidebarColors(palette);
    const root = try doc.createElement(.div);
    root.setStyle(.{
        .display = .flex,
        .flex_direction = .row,
        .align_items = .center,
        .width = .{ .percent = 100 },
        .height = .{ .cells = 1 },
        .overflow = .hidden,
        .background = colors.title_background,
        .color = colors.title_foreground,
    });

    const label = try doc.createElement(.span);
    const source_control = std.mem.eql(u8, part.pane.active_id orelse "", "scm");
    label.setStyle(.{
        .padding = .{ .left = 1 },
        .min_width = .{ .cells = 0 },
        .overflow = .hidden,
        .bold = source_control,
    });
    var title_buf: [96]u8 = undefined;
    _ = try label.appendText(if (source_control) part.pane.title_label.title else upperAscii(&title_buf, part.pane.title_label.title));
    _ = try root.appendChild(label);

    const spacer = try doc.createElement(.span);
    spacer.setStyle(.{ .flex_grow = 1 });
    _ = try root.appendChild(spacer);

    // Leave the last cell as title background so a hovered action cannot
    // paint into the inside stroke of the sidebar frame or the sash.
    const action_count = part.pane.primary_actions.items.len + part.pane.secondary_actions.items.len;
    const action_padding: f64 = if (action_count * 3 + 8 <= width) 1 else 0;
    var remaining = width -| 1;
    for ([_][]const pane.TitleAction{ part.pane.primary_actions.items, part.pane.secondary_actions.items }) |actions| {
        for (actions) |action| {
            if (remaining == 0) break;
            remaining -= 1;
            const hovered = part.hovered_action_id != null and
                std.mem.eql(u8, part.hovered_action_id.?, action.id);
            const button = try doc.createElement(.div);
            button.setStyle(.{
                .display = .flex,
                .align_items = .center,
                .height = .{ .percent = 100 },
                .flex_shrink = 0,
                .padding = .{ .left = action_padding, .right = action_padding },
                .background = if (hovered) colors.hover_background else null,
                .color = if (action.enabled) colors.title_foreground else null,
                .dim = !action.enabled,
            });
            var glyph_buf: [4]u8 = undefined;
            const glyph_len = std.unicode.utf8Encode(action.glyph, &glyph_buf) catch 0;
            _ = try button.appendText(glyph_buf[0..glyph_len]);
            _ = try root.appendChild(button);
            try part.title_nodes.append(.{ .id = action.id, .node = button });
        }
    }

    const inset = try doc.createElement(.span);
    inset.setStyle(.{ .width = .{ .cells = 1 }, .flex_shrink = 0 });
    _ = try root.appendChild(inset);

    doc.setRoot(root);
    try surface.paintFrame();
    part.title_signature = signature;
    try grid.blit(surface.grid(), x, y, width, 1);
}

/// Paints the activity bar when it lives in the side bar: a one-row composite
/// bar of the visible view containers in the header (top) or footer (bottom).
pub fn renderCompositeBar(
    part: *SidebarPart,
    grid: *ui.CellGrid,
    rect: ui.Rect,
    palette: ?*const theme_colors_mod.ThemeColors,
    badges: []const pane.Badge,
) !void {
    const x = ui.cell.snap(rect.x);
    const y = ui.cell.snap(rect.y);
    const width = ui.cell.snap(rect.w);
    const height = ui.cell.snap(rect.h);
    if (!part.visible or width == 0 or height == 0 or !part.pane.shouldShowCompositeBar()) return;

    const surface = try prepareSurface(part, &part.bar_surface, width);

    var hasher = std.hash.Wyhash.init(0);
    hashRect(&hasher, x, y, width, height);
    hashPalette(&hasher, palette);
    hashText(&hasher, part.pane.active_id orelse "");
    hashText(&hasher, part.hovered_composite_id orelse "");
    for (part.pane.bar.items.items) |item| {
        hashText(&hasher, item.id);
        hasher.update(&[_]u8{@intFromBool(item.visible)});
        if (part.pane.getPaneComposite(item.id)) |descriptor| {
            hasher.update(std.mem.asBytes(&descriptor.glyph));
        }
    }
    for (badges) |badge| {
        hashText(&hasher, badge.id);
        hashText(&hasher, badge.text);
    }
    const signature = hasher.final();
    if (part.bar_signature == signature) {
        try grid.blit(surface.grid(), x, y, width, 1);
        return;
    }

    const doc = surface.document();
    doc.clear();
    part.bar_nodes.clearRetainingCapacity();

    const colors = sidebarColors(palette);
    const root = try doc.createElement(.div);
    root.setStyle(.{
        .display = .flex,
        .flex_direction = .row,
        .align_items = .center,
        .justify_content = .flex_start,
        .width = .{ .percent = 100 },
        .height = .{ .cells = 1 },
        .overflow = .hidden,
        .background = colors.bar_background,
        .color = colors.bar_inactive_foreground,
    });

    for (part.pane.bar.items.items) |item| {
        if (!item.visible) continue;
        const descriptor = part.pane.getPaneComposite(item.id) orelse continue;
        const active = part.pane.active_id != null and std.mem.eql(u8, part.pane.active_id.?, item.id);
        const hovered = part.hovered_composite_id != null and std.mem.eql(u8, part.hovered_composite_id.?, item.id);
        const button = try doc.createElement(.div);
        button.setStyle(.{
            .display = .flex,
            .align_items = .center,
            .justify_content = .center,
            .height = .{ .percent = 100 },
            .width = .{ .cells = 3 },
            .flex_shrink = 0,
            .background = if (active)
                colors.bar_active_background
            else if (hovered)
                colors.hover_background
            else
                null,
            .color = if (active) colors.bar_foreground else colors.bar_inactive_foreground,
            .bold = active,
            .underline = active,
        });
        var glyph_buf: [4]u8 = undefined;
        const glyph_len = std.unicode.utf8Encode(descriptor.glyph, &glyph_buf) catch 0;
        _ = try button.appendText(glyph_buf[0..glyph_len]);
        if (badgeText(badges, item.id)) |text| {
            const badge_node = try doc.createElement(.span);
            badge_node.setStyle(.{ .color = colors.badge_foreground });
            var badge_buf: [4]u8 = undefined;
            const badge_len = std.unicode.utf8Encode(activity_bar_mod.badgeGlyph(text), &badge_buf) catch 0;
            _ = try badge_node.appendText(badge_buf[0..badge_len]);
            _ = try button.appendChild(badge_node);
        }
        _ = try root.appendChild(button);
        try part.bar_nodes.append(.{ .id = item.id, .node = button });
    }

    doc.setRoot(root);
    try surface.paintFrame();
    part.bar_signature = signature;
    try grid.blit(surface.grid(), x, y, width, 1);
}

/// Paints the side bar background and its title chrome (header composite bar,
/// title, footer composite bar). The active view renders into `contentRect`.
pub fn render(
    part: *SidebarPart,
    grid: *ui.CellGrid,
    rect: ui.Rect,
    palette: ?*const theme_colors_mod.ThemeColors,
    badges: []const pane.Badge,
) !void {
    if (!part.visible) return;
    const x = ui.cell.snap(rect.x);
    const y = ui.cell.snap(rect.y);
    const width = ui.cell.snap(rect.w);
    const height = ui.cell.snap(rect.h);
    if (width == 0 or height == 0) return;

    const colors = sidebarColors(palette);
    grid.fillRect(
        @floatFromInt(x),
        @floatFromInt(y),
        @floatFromInt(width),
        @floatFromInt(height),
        .{ .bg = ui.cell.packColor(colors.background) },
    );

    const chrome = layout(part, rect);
    if (chrome.header) |header| try renderCompositeBar(part, grid, header, palette, badges);
    if (part.pane.has_title) try renderTitle(part, grid, chrome.title, palette);
    if (chrome.footer) |footer| try renderCompositeBar(part, grid, footer, palette, badges);
}

fn badgeText(badges: []const pane.Badge, id: []const u8) ?[]const u8 {
    for (badges) |badge| {
        if (!std.mem.eql(u8, badge.id, id)) continue;
        if (badge.text.len > 0) return badge.text;
    }
    return null;
}

fn hitSurface(surface: *const ui.Surface, nodes: []const SidebarPart.TitleNode, rect: ui.Rect, x: usize, y: usize) ?[]const u8 {
    const rect_x = ui.cell.snap(rect.x);
    const rect_y = ui.cell.snap(rect.y);
    const width = ui.cell.snap(rect.w);
    if (width == 0 or y != rect_y or x < rect_x or x >= rect_x + width) return null;
    const local_x = @as(f64, @floatFromInt(x - rect_x)) + 0.5;
    for (nodes) |node| {
        const box = surface.box_tree.find(node.node) orelse continue;
        if (local_x >= box.rect.x and local_x < box.rect.x + box.rect.w) return node.id;
    }
    return null;
}

/// Returns the title action or the composite-bar item under the mouse.
pub fn hitTest(part: *const SidebarPart, rect: ui.Rect, x: usize, y: usize) ?SidebarPart.Hit {
    if (!part.visible) return null;
    const chrome = layout(part, rect);
    if (chrome.header) |header| {
        if (part.bar_surface) |*surface| {
            if (hitSurface(surface, part.bar_nodes.items, header, x, y)) |id| return .{ .composite = id };
        }
    }
    if (chrome.footer) |footer| {
        if (part.bar_surface) |*surface| {
            if (hitSurface(surface, part.bar_nodes.items, footer, x, y)) |id| return .{ .composite = id };
        }
    }
    if (part.title_surface) |*surface| {
        if (hitSurface(surface, part.title_nodes.items, chrome.title, x, y)) |id| return .{ .action = id };
    }
    return null;
}

pub fn compositeItemRect(part: *const SidebarPart, rect: ui.Rect, id: []const u8) ?ui.Rect {
    const chrome = layout(part, rect);
    const bar = chrome.header orelse chrome.footer orelse return null;
    const surface = if (part.bar_surface) |*value| value else return null;
    for (part.bar_nodes.items) |entry| {
        if (!std.mem.eql(u8, entry.id, id)) continue;
        const box = surface.box_tree.find(entry.node) orelse continue;
        const width = @min(box.rect.w, bar.w - box.rect.x);
        return .{ .x = bar.x + box.rect.x, .y = bar.y, .w = width, .h = 1 };
    }
    return null;
}

pub fn setHovered(part: *SidebarPart, hit: ?SidebarPart.Hit) void {
    part.hovered_action_id = null;
    part.hovered_composite_id = null;
    if (hit) |value| switch (value) {
        .action => |id| part.hovered_action_id = id,
        .composite => |id| part.hovered_composite_id = id,
    };
}

test "sidebarPart: width clamps to the terminal minimum" {
    var part = SidebarPart.init(std.testing.allocator);
    defer part.deinit();

    try part.setWidth(4);
    try std.testing.expectEqual(@as(usize, 10), part.width);
    try part.setWidth(28);
    try std.testing.expectEqual(@as(usize, 28), part.width);
    try std.testing.expect(part.preferredWidth(0) == null);
}

test "sidebarPart: visibility, position and active pane composite" {
    var part = SidebarPart.init(std.testing.allocator);
    defer part.deinit();

    try part.pane.addPaneComposite(.{ .id = "explorer", .name = "Explorer", .order = 1 });
    try part.pane.addPaneComposite(.{ .id = "search", .name = "Search", .order = 2 });

    try std.testing.expect(!part.visible);
    try std.testing.expect(try part.openPaneComposite("search"));
    try std.testing.expect(part.visible);
    try std.testing.expectEqualStrings("search", part.activePaneComposite().?.id);
    try std.testing.expectEqualStrings("Search", part.pane.title_label.title);

    try part.setPosition(.right);
    try std.testing.expectEqual(Position.right, part.position);
    try std.testing.expect(!try part.openPaneComposite("missing"));

    try part.hideActivePaneComposite();
    try std.testing.expect(!part.visible);
    try std.testing.expect(part.activePaneComposite() == null);
    try std.testing.expectEqualStrings("search", part.pane.last_active_id.?);
}

test "sidebarPart: activity bar position drives the composite bar" {
    var part = SidebarPart.init(std.testing.allocator);
    defer part.deinit();
    try part.pane.addPaneComposite(.{ .id = "explorer", .name = "Explorer", .order = 0 });
    try part.pane.addPaneComposite(.{ .id = "search", .name = "Search", .order = 1 });

    // Default: separate activity bar, no composite bar.
    try part.setLayoutSettings(.{ .activity_bar_location = .default });
    try std.testing.expect(!part.shouldShowCompositeBar());
    try std.testing.expect(part.shouldShowActivityBar());
    try std.testing.expectEqual(CompositeBarPosition.title, part.getCompositeBarPosition());
    try std.testing.expectEqual(@as(?CompositeBarPosition, null), part.pane.getCompositeBarPosition());

    // Top/bottom: the activity bar moves into the side bar composite bar.
    try part.setLayoutSettings(.{ .activity_bar_location = .top });
    try std.testing.expect(part.shouldShowCompositeBar());
    try std.testing.expect(!part.shouldShowActivityBar());
    try std.testing.expectEqual(CompositeBarPosition.top, part.getCompositeBarPosition());
    try std.testing.expectEqual(CompositeBarPosition.top, part.pane.getCompositeBarPosition().?);

    try part.setLayoutSettings(.{ .activity_bar_location = .bottom });
    try std.testing.expectEqual(CompositeBarPosition.bottom, part.pane.getCompositeBarPosition().?);

    // Hidden: no activity bar and no composite bar.
    try part.setLayoutSettings(.{ .activity_bar_location = .hidden });
    try std.testing.expect(!part.shouldShowCompositeBar());
    try std.testing.expect(!part.shouldShowActivityBar());
    try std.testing.expectEqual(@as(?CompositeBarPosition, null), part.pane.getCompositeBarPosition());

    // Auto-hide keeps the composite bar only while more than one container is
    // visible.
    try part.setLayoutSettings(.{ .activity_bar_location = .top, .activity_bar_auto_hide = true });
    try std.testing.expect(part.shouldShowCompositeBar());
    _ = try part.pane.setPaneCompositeVisible("search", false);
    try part.updateCompositeBar();
    try std.testing.expect(!part.shouldShowCompositeBar());
    try std.testing.expectEqual(@as(?CompositeBarPosition, null), part.pane.getCompositeBarPosition());
}

test "sidebarPart: title label, actions and hit testing" {
    const allocator = std.testing.allocator;
    var grid = try ui.CellGrid.init(allocator, 30, 3);
    defer grid.deinit();

    var part = SidebarPart.init(allocator);
    defer part.deinit();
    try part.pane.addPaneComposite(.{ .id = "explorer", .name = "Explorer", .order = 0 });
    try part.pane.addPaneComposite(.{ .id = "search", .name = "Search", .order = 1 });
    part.visible = true;
    _ = try part.pane.openPaneComposite("search", true);
    try part.pane.setTitleActions(&.{
        .{ .id = "search.action.clearSearchResults", .label = "Clear Search Results", .glyph = 'x' },
    }, &.{
        .{ .id = "workbench.action.search.toggleQueryDetails", .label = "Toggle Search Details", .glyph = 0x2026 },
    });

    const rect = ui.Rect{ .x = 0, .y = 0, .w = 30, .h = 3 };
    try renderTitle(&part, &grid, layout(&part, rect).title, null);

    const row = try grid.rowText(allocator, 0);
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "SEARCH") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "x") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "\u{2026}") != null);

    const title = layout(&part, rect).title;
    // The actions are right-aligned with an inset at the frame edge.
    try std.testing.expectEqualStrings("search.action.clearSearchResults", hitTest(&part, rect, 25, 0).?.action);
    try std.testing.expectEqualStrings("workbench.action.search.toggleQueryDetails", hitTest(&part, rect, 28, 0).?.action);
    const edge = grid.index(29, 0);
    const background = grid.bg[edge];
    setHovered(&part, hitTest(&part, rect, 28, 0));
    try renderTitle(&part, &grid, title, null);
    try std.testing.expect(hitTest(&part, rect, 29, 0) == null);
    try std.testing.expectEqual(background, grid.bg[edge]);
    try std.testing.expect(grid.bg[grid.index(28, 0)] != background);
    try std.testing.expect(hitTest(&part, rect, 2, 0) == null);
    try std.testing.expect(hitTest(&part, rect, 2, 1) == null);
    try std.testing.expectEqual(@as(usize, 1), title.h);
}

test "sidebarPart: composite bar header and footer layout" {
    const allocator = std.testing.allocator;
    var grid = try ui.CellGrid.init(allocator, 30, 3);
    defer grid.deinit();

    var part = SidebarPart.init(allocator);
    defer part.deinit();
    try part.pane.addPaneComposite(.{ .id = "explorer", .name = "Explorer", .order = 0, .glyph = 'E' });
    try part.pane.addPaneComposite(.{ .id = "search", .name = "Search", .order = 1, .glyph = 'F' });
    part.visible = true;
    _ = try part.pane.openPaneComposite("search", true);
    try part.setLayoutSettings(.{ .activity_bar_location = .top });

    const rect = ui.Rect{ .x = 0, .y = 0, .w = 30, .h = 3 };
    const chrome = layout(&part, rect);
    try std.testing.expectEqual(@as(usize, 0), ui.cell.snap(chrome.header.?.y));
    try std.testing.expectEqual(@as(usize, 1), ui.cell.snap(chrome.title.y));
    try std.testing.expectEqual(@as(usize, 2), ui.cell.snap(chrome.content.y));
    try std.testing.expect(chrome.footer == null);

    try renderCompositeBar(&part, &grid, chrome.header.?, null, &.{});
    try renderTitle(&part, &grid, chrome.title, null);
    const bar_row = try grid.rowText(allocator, 0);
    defer allocator.free(bar_row);
    try std.testing.expectEqual(@as(u8, 'E'), bar_row[1]);
    try std.testing.expectEqual(@as(u8, 'F'), bar_row[4]);
    try std.testing.expectEqualStrings("explorer", hitTest(&part, rect, 1, 0).?.composite);
    try std.testing.expectEqualStrings("search", hitTest(&part, rect, 4, 0).?.composite);
    try std.testing.expect(hitTest(&part, rect, 1, 1) == null);

    // A container badge takes a cell inside the item, like the activity rail.
    try renderCompositeBar(&part, &grid, chrome.header.?, null, &.{.{ .id = "search", .text = "3" }});
    const badge_row = try grid.rowText(allocator, 0);
    defer allocator.free(badge_row);
    try std.testing.expect(std.mem.indexOf(u8, badge_row, "3") != null);

    // The bottom position moves the bar into the footer and keeps the title on
    // top.
    try part.setLayoutSettings(.{ .activity_bar_location = .bottom });
    const bottom = layout(&part, rect);
    try std.testing.expect(bottom.header == null);
    try std.testing.expectEqual(@as(usize, 0), ui.cell.snap(bottom.title.y));
    try std.testing.expectEqual(@as(usize, 1), ui.cell.snap(bottom.content.y));
    try std.testing.expectEqual(@as(usize, 2), ui.cell.snap(bottom.footer.?.y));
    try std.testing.expectEqual(@as(usize, 1), ui.cell.snap(bottom.content.h));
}

test "sidebarPart: switching views follows the visible bar order" {
    const allocator = std.testing.allocator;
    var part = SidebarPart.init(allocator);
    defer part.deinit();
    try part.pane.addPaneComposite(.{ .id = "explorer", .name = "Explorer", .order = 0 });
    try part.pane.addPaneComposite(.{ .id = "search", .name = "Search", .order = 1 });
    try part.pane.addPaneComposite(.{ .id = "scm", .name = "Source Control", .order = 2 });
    _ = try part.pane.openPaneComposite("search", true);
    try part.setLayoutSettings(.{ .activity_bar_location = .top });

    try std.testing.expectEqualStrings("scm", (try part.switchViewTarget(1, allocator)).?);
    try std.testing.expectEqualStrings("explorer", (try part.switchViewTarget(-1, allocator)).?);

    // With the separate activity bar the ids come from the rail.
    try part.setLayoutSettings(.{ .activity_bar_location = .default });
    var bar = activity_bar_mod.ActivityBarPart.init(allocator);
    defer bar.deinit();
    try bar.addActivity(.{ .id = "explorer", .name = "Explorer", .order = 0 });
    try bar.addActivity(.{ .id = "search", .name = "Search", .order = 1 });
    part.attachActivityBar(&bar);
    try std.testing.expectEqualStrings("explorer", (try part.switchViewTarget(1, allocator)).?);
}
