// Port of the portable state in
// `src/vs/workbench/browser/parts/panel/panelPart.ts`, plus the terminal
// panel title view.
//
// The browser part inherits `AbstractPaneCompositePart`, hosts the panel title
// composite bar (Terminal, Problems, Output, Debug Console, Ports) and moves
// the panel between `Position.BOTTOM/TOP/LEFT/RIGHT`. The terminal model keeps
// the pane composites, the visible/size/position state and the active
// container; the same file paints the composite bar and routes its hit
// testing, matching `activitybarPart.zig`.
//
// Terminal adaptation: the panel uses the same four positions in the cell
// grid; the title is one cell row. The title
// is still built the upstream way: `renderTitle` creates a `ui.Document`
// element tree (flex row, one element per composite) and paints it through a
// `ui.Surface`, so tabs keep DOM-shaped node state instead of ad-hoc spans.
// Single-cell glyphs replace theme icons. PanelTitle menu actions are resolved
// through MenuService and reserve the trailing title cells. Floating panels, the
// overflow switcher and drag-and-drop move actions are not ported.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const pane = @import("../paneCompositePart.zig");
const layout_mod = @import("../../layout.zig");
const theme_colors_mod = @import("../../themeColors.zig");
const ui = @import("ui");
const menus = @import("../../../../platform/actions/common/menuService.zig");
const IAction = @import("../../../../base/common/actions.zig").IAction;

pub const Position = layout_mod.Position;

/// A composite-bar badge. Upstream badges come from the activity service; the
/// workbench passes the Problems error/warning counts here.
pub const Badge = pane.Badge;

const Part = @import("../../part.zig").Part;

pub const PanelPart = struct {
    base: Part,
    allocator: Allocator,
    pane: pane.PaneCompositePart,
    visible: bool = false,
    /// Terminal cells. Upstream stores pixels in the layout service.
    size: usize = 10,
    position: Position = .bottom,
    minimum_width: usize = @import("../../../services/layout/browser/layoutService.zig").widthInCells(300),
    /// Upstream `minimumHeight` is 77 px; the terminal title plus one content
    /// row is the smallest useful panel.
    minimum_height: usize = 2,
    maximum_height: usize = std.math.maxInt(usize),
    /// Composite-bar hover, driven by the workbench mouse routing.
    hovered_id: ?[]const u8 = null,
    /// One-row title surface; created on the first render.
    title_surface: ?ui.Surface = null,
    /// Element nodes per visible composite, used for hit testing. The nodes
    /// live in the surface document arena and are rebuilt every render.
    title_nodes: std.array_list.Managed(TitleNode),
    title_action_nodes: std.array_list.Managed(TitleNode),
    title_menu: ?*menus.Menu = null,
    on_did_change: Emitter(void),
    /// Last painted title grid; unchanged chrome is blitted instead of being
    /// cleared and laid out again on every editor frame.
    title_signature: ?u64 = null,

    pub const TitleNode = struct {
        id: []const u8,
        node: *ui.Node,
    };

    pub fn init(allocator: Allocator) PanelPart {
        var part = PanelPart{
            .base = Part.init(allocator, .panel, PanelPart),
            .allocator = allocator,
            .pane = pane.PaneCompositePart.init(
                allocator,
                "workbench.contributions.panels",
                "workbench.parts.panel",
                .panel,
            ),
            .title_nodes = std.array_list.Managed(TitleNode).init(allocator),
            .title_action_nodes = std.array_list.Managed(TitleNode).init(allocator),
            .on_did_change = Emitter(void).init(allocator),
        };
        // PanelPart always shows its composite bar in the title.
        part.pane.composite_bar_position = .title;
        part.base.resize_primary = resizePrimary;
        part.base.apply_position = applyPosition;
        return part;
    }

    pub fn deinit(self: *PanelPart) void {
        self.base.deinit();
        if (self.title_surface) |*surface| surface.deinit();
        self.title_surface = null;
        self.title_nodes.deinit();
        self.title_action_nodes.deinit();
        if (self.title_menu) |menu| {
            menu.deinit();
            self.allocator.destroy(menu);
        }
        self.on_did_change.deinit();
        self.pane.deinit();
    }

    /// AbstractPaneCompositePart's title toolbar resolves its menu through
    /// MenuService and refreshes on the menu/context-key event.
    pub fn attachTitleMenu(self: *PanelPart, service: *menus.MenuService, context: @import("../../../../platform/contextkey/common/contextkey.zig").IContext) !void {
        if (self.title_menu != null) return;
        const menu = try service.createMenu(self.allocator, @import("../../../../platform/actions/common/actions.zig").menu_ids.PanelTitle, context);
        errdefer {
            menu.deinit();
            self.allocator.destroy(menu);
        }
        _ = try menu.onDidChange.listenSignal(self, onTitleMenuChanged);
        self.title_menu = menu;
        errdefer self.title_menu = null;
        try self.onTitleMenuChanged();
    }

    fn onTitleMenuChanged(self: *PanelPart) !void {
        self.title_signature = null;
        self.title_action_nodes.clearRetainingCapacity();
        try self.on_did_change.fire({});
    }

    fn titleActions(self: *const PanelPart) []const IAction {
        const menu = self.title_menu orelse return &.{};
        for (menu.getActions()) |group| {
            if (std.mem.eql(u8, group.id, "navigation")) return group.actions;
        }
        return &.{};
    }

    pub fn titleActionTooltip(self: *const PanelPart, id: []const u8) ?[]const u8 {
        for (self.titleActions()) |action| {
            if (std.mem.eql(u8, action.id(), id)) return if (action.tooltip().len != 0) action.tooltip() else action.label();
        }
        return null;
    }

    pub fn runTitleAction(self: *PanelPart, id: []const u8) !void {
        for (self.titleActions()) |action| {
            if (!std.mem.eql(u8, action.id(), id)) continue;
            if (action.enabled()) try action.execute(null);
            return;
        }
    }

    pub fn setVisible(self: *PanelPart, visible: bool) !void {
        if (self.visible == visible) return;
        self.visible = visible;
        try self.base.setVisible(visible);
        try self.on_did_change.fire({});
    }

    pub fn isVisible(self: *const PanelPart) bool {
        return self.visible;
    }

    pub fn resizePrimary(base: *Part, size: usize) !usize {
        const self: *PanelPart = @fieldParentPtr("base", base);
        try self.setSize(size);
        return self.size;
    }

    pub fn setSize(self: *PanelPart, size: usize) !void {
        const horizontal = @import("../../../services/layout/browser/layoutService.zig").isHorizontal(self.position);
        const clamped = if (horizontal) @max(self.minimum_height, @min(size, self.maximum_height)) else @max(self.minimum_width, size);
        if (self.size == clamped) return;
        self.size = clamped;
        try self.on_did_change.fire({});
    }

    pub fn getSize(self: *const PanelPart) usize {
        return self.size;
    }

    fn applyPosition(base: *Part, position: Position) !void {
        const self: *PanelPart = @fieldParentPtr("base", base);
        try self.setPosition(position);
    }

    pub fn setPosition(self: *PanelPart, position: Position) !void {
        if (self.position == position) return;
        self.position = position;
        try self.on_did_change.fire({});
    }

    pub fn getPosition(self: *const PanelPart) Position {
        return self.position;
    }

    pub fn setHovered(self: *PanelPart, id: ?[]const u8) void {
        if (self.hovered_id) |current| {
            if (id) |wanted| {
                if (std.mem.eql(u8, current, wanted)) return;
            }
        } else if (id == null) {
            return;
        }
        self.hovered_id = id;
    }

    /// Opens a panel container and reveals the panel. Upstream reveals the
    /// part through `layoutService.setPartHidden` in `doOpenPaneComposite`.
    pub fn openPaneComposite(self: *PanelPart, id: []const u8) !bool {
        return self.openPaneCompositeWithFocus(id, true);
    }

    pub fn openPaneCompositeWithFocus(self: *PanelPart, id: []const u8, focus: bool) !bool {
        const opened = try self.pane.openPaneComposite(id, focus);
        if (opened == null) return false;
        if (!self.visible) {
            self.visible = true;
            try self.base.setVisible(true);
        }
        try self.on_did_change.fire({});
        return true;
    }

    pub fn activePaneComposite(self: *const PanelPart) ?pane.PaneCompositeDescriptor {
        return self.pane.getActivePaneComposite();
    }

    pub fn hideActivePaneComposite(self: *PanelPart) !void {
        try self.pane.hideActivePaneComposite();
        if (self.visible) {
            self.visible = false;
            try self.base.setVisible(false);
        }
        self.hovered_id = null;
        try self.on_did_change.fire({});
    }

    pub fn getPinnedPaneCompositeIds(self: *const PanelPart, allocator: Allocator) ![][]const u8 {
        return self.pane.getPinnedPaneCompositeIds(allocator);
    }

    pub fn visibleComposites(self: *const PanelPart, allocator: Allocator) ![]pane.PaneCompositeDescriptor {
        return self.pane.visibleComposites(allocator);
    }
};

// ---------------------------------------------------------------------------
// Terminal panel title view
// ---------------------------------------------------------------------------

pub const title_height: usize = 1;

/// Content area below the panel title row.
pub fn contentRect(rect: ui.Rect) ui.Rect {
    const y = ui.cell.snap(rect.y);
    const height = ui.cell.snap(rect.h);
    return .{
        .x = rect.x,
        .y = @floatFromInt(y + title_height),
        .w = rect.w,
        .h = @floatFromInt(height -| title_height),
    };
}

fn upperAscii(buf: []u8, text: []const u8) []const u8 {
    const len = @min(buf.len, text.len);
    for (text[0..len], 0..) |ch, index| buf[index] = std.ascii.toUpper(ch);
    return buf[0..len];
}

fn badgeFor(badges: []const Badge, id: []const u8) []const u8 {
    for (badges) |badge| {
        if (std.mem.eql(u8, badge.id, id)) return badge.text;
    }
    return "";
}

/// Paints the panel title: one DOM row of container tabs in pane-composite
/// order. The title is rebuilt from the model on every render, like the
/// status-bar part, so the surface keeps its frame diff for the blitted row.
pub fn renderTitle(
    part: *PanelPart,
    grid: *ui.CellGrid,
    rect: ui.Rect,
    focused: bool,
    palette: ?*const theme_colors_mod.ThemeColors,
    badges: []const Badge,
) !void {
    const x = ui.cell.snap(rect.x);
    const y = ui.cell.snap(rect.y);
    const width = ui.cell.snap(rect.w);
    if (!part.visible or width == 0 or ui.cell.snap(rect.h) == 0) return;

    if (part.title_surface) |*surface| {
        if (surface.doc.cols != width or surface.doc.rows != 1) try surface.resize(width, 1);
    } else {
        part.title_surface = try ui.Surface.init(part.allocator, .{ .cols = width, .rows = 1 });
    }
    const surface = &part.title_surface.?;

    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&x));
    hasher.update(std.mem.asBytes(&y));
    hasher.update(std.mem.asBytes(&width));
    const height = ui.cell.snap(rect.h);
    hasher.update(std.mem.asBytes(&height));
    const palette_ptr: usize = if (palette) |p| @intFromPtr(p) else 0;
    hasher.update(std.mem.asBytes(&palette_ptr));
    hasher.update(&[_]u8{@intFromBool(focused)});
    hasher.update(part.pane.active_id orelse "");
    hasher.update(&[_]u8{0});
    hasher.update(part.hovered_id orelse "");
    hasher.update(&[_]u8{0});
    for (part.pane.bar.items.items) |item| {
        hasher.update(item.id);
        hasher.update(&[_]u8{0});
        hasher.update(&[_]u8{@intFromBool(item.visible)});
        if (part.pane.getPaneComposite(item.id)) |descriptor| {
            hasher.update(std.mem.asBytes(&descriptor.glyph));
            hasher.update(descriptor.name);
            hasher.update(&[_]u8{0});
        }
    }
    for (badges) |badge| {
        hasher.update(badge.id);
        hasher.update(&[_]u8{0});
        hasher.update(badge.text);
        hasher.update(&[_]u8{0});
    }
    const signature = hasher.final();
    if (part.title_signature == signature) {
        try grid.blit(surface.grid(), x, y, width, 1);
        return;
    }

    const doc = surface.document();
    doc.clear();
    part.title_nodes.clearRetainingCapacity();
    part.title_action_nodes.clearRetainingCapacity();

    const background = if (palette) |colors|
        colors.color("panel.background", .{ 30, 30, 33 })
    else
        ui.Color{ .r = 30, .g = 30, .b = 33 };
    const active_foreground = if (palette) |colors|
        colors.color("panelTitle.activeForeground", .{ 255, 255, 255 })
    else
        ui.Color{ .r = 255, .g = 255, .b = 255 };
    const inactive_foreground = if (palette) |colors|
        colors.color("panelTitle.inactiveForeground", .{ 150, 150, 150 })
    else
        ui.Color{ .r = 150, .g = 150, .b = 150 };
    const description_foreground = if (palette) |colors|
        colors.color("descriptionForeground", .{ 165, 165, 165 })
    else
        ui.Color{ .r = 165, .g = 165, .b = 165 };
    const active_background = if (palette) |colors|
        colors.color("panelTitle.activeBackground", .{ 45, 45, 48 })
    else
        ui.Color{ .r = 45, .g = 45, .b = 48 };
    const hover_background = if (palette) |colors|
        colors.color("toolbar.hoverBackground", .{ 48, 48, 52 })
    else
        ui.Color{ .r = 48, .g = 48, .b = 52 };

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .display = .flex,
        .flex_direction = .row,
        .width = .{ .percent = 100 },
        .height = .{ .cells = 1 },
        .overflow = .hidden,
        .background = background,
        .color = inactive_foreground,
    });

    const composite_row = try doc.createElement(.div);
    const composites_width = titleActionsStart(part, rect) -| x;
    composite_row.setStyle(.{ .display = .flex, .flex_direction = .row, .width = .{ .cells = @floatFromInt(composites_width) }, .height = .{ .cells = 1 }, .flex_shrink = 0, .overflow = .hidden });
    _ = try root.appendChild(composite_row);

    for (part.pane.bar.items.items) |item| {
        if (!item.visible) continue;
        const descriptor = part.pane.getPaneComposite(item.id) orelse continue;
        const badge = badgeFor(badges, item.id);
        const active = part.pane.active_id != null and std.mem.eql(u8, part.pane.active_id.?, item.id);
        const hovered = part.hovered_id != null and std.mem.eql(u8, part.hovered_id.?, item.id);

        const tab = try doc.createElement(.div);
        tab.setStyle(.{
            .display = .flex,
            .flex_direction = .row,
            .align_items = .center,
            .height = .{ .percent = 100 },
            .flex_shrink = 0,
            .overflow = .hidden,
            .padding = .{ .left = 1, .right = 1 },
            .background = if (active)
                active_background
            else if (hovered)
                hover_background
            else
                null,
            .color = if (active) active_foreground else inactive_foreground,
            .bold = active,
            .underline = active and focused,
        });

        var name_buf: [96]u8 = undefined;
        var label_buf: [160]u8 = undefined;
        const label = std.fmt.bufPrint(
            &label_buf,
            "{u} {s}",
            .{ descriptor.glyph, upperAscii(&name_buf, descriptor.name) },
        ) catch descriptor.name;
        _ = try tab.appendText(label);

        if (badge.len > 0) {
            const badge_node = try doc.createElement(.span);
            badge_node.setStyle(.{
                .padding = .{ .left = 1 },
                .color = description_foreground,
            });
            _ = try badge_node.appendText(badge);
            _ = try tab.appendChild(badge_node);
        }

        _ = try composite_row.appendChild(tab);
        try part.title_nodes.append(.{ .id = item.id, .node = tab });
    }

    for (part.titleActions()) |action| {
        const button = try doc.createElement(.div);
        const hovered = part.hovered_id != null and std.mem.eql(u8, part.hovered_id.?, action.id());
        button.setStyle(.{
            .display = .flex,
            .align_items = .center,
            .justify_content = .center,
            .width = .{ .cells = 2 },
            .height = .{ .cells = 1 },
            .flex_shrink = 0,
            .overflow = .hidden,
            .background = if (hovered) hover_background else null,
            .color = if (action.enabled()) active_foreground else inactive_foreground,
            .pointer = if (action.enabled()) .pointer else .default,
        });
        const icon = if (menus.MenuItemAction.from(action)) |item| item.item.icon orelse "" else "";
        const label = if (std.mem.eql(u8, icon, "panel-maximize"))
            if (action.checked() == true) "⊟" else "⊞"
        else if (std.mem.eql(u8, icon, "panel-close"))
            "×"
        else
            action.label();
        _ = try button.appendText(label);
        _ = try root.appendChild(button);
        try part.title_action_nodes.append(.{ .id = action.id(), .node = button });
    }

    doc.setRoot(root);
    try surface.paintFrame();
    part.title_signature = signature;
    try grid.blit(surface.grid(), x, y, width, 1);
}

/// First column after the composite titles and their badges.
pub fn titleContentEnd(part: *const PanelPart, rect: ui.Rect) usize {
    const x = ui.cell.snap(rect.x);
    const surface = &(part.title_surface orelse return x);
    const last = part.title_nodes.getLastOrNull() orelse return x;
    const box = surface.box_tree.find(last.node) orelse return x;
    return @min(titleActionsStart(part, rect), x + ui.cell.snap(box.rect.right()));
}

/// Panel navigation actions occupy the right-hand end of the one-cell title.
/// The active composite toolbar uses the remaining cells before this boundary.
pub fn titleActionsStart(part: *const PanelPart, rect: ui.Rect) usize {
    const count = part.titleActions().len;
    const reserve = if (count == 0) 0 else count * 2 + 1;
    return ui.cell.snap(rect.x) + (ui.cell.snap(rect.w) -| reserve);
}

pub fn hitTitleAction(part: *const PanelPart, rect: ui.Rect, x: usize, y: usize) ?[]const u8 {
    if (!part.visible or y != ui.cell.snap(rect.y) or x < titleActionsStart(part, rect) or x >= ui.cell.snap(rect.right())) return null;
    const surface = &(part.title_surface orelse return null);
    const local_x = @as(f64, @floatFromInt(x - ui.cell.snap(rect.x))) + 0.5;
    for (part.title_action_nodes.items) |button| {
        const box = surface.box_tree.find(button.node) orelse continue;
        if (local_x >= box.rect.x and local_x < box.rect.right()) return button.id;
    }
    return null;
}

/// Returns the composite id under the mouse position. The boxes come from the
/// DOM layout pass that produced the currently painted title.
pub fn hitTest(part: *const PanelPart, rect: ui.Rect, x: usize, y: usize) ?[]const u8 {
    if (!part.visible) return null;
    const surface = &(part.title_surface orelse return null);
    const rect_x = ui.cell.snap(rect.x);
    const rect_y = ui.cell.snap(rect.y);
    const width = ui.cell.snap(rect.w);
    if (width == 0 or y != rect_y or x < rect_x or x >= titleActionsStart(part, rect)) return null;

    const local_x = @as(f64, @floatFromInt(x - rect_x)) + 0.5;
    for (part.title_nodes.items) |tab| {
        const box = surface.box_tree.find(tab.node) orelse continue;
        if (local_x >= box.rect.x and local_x < box.rect.x + box.rect.w) return tab.id;
    }
    return null;
}

test "panelPart: opening a composite reveals the panel" {
    const allocator = std.testing.allocator;
    var part = PanelPart.init(allocator);
    defer part.deinit();

    try part.pane.addPaneComposite(.{ .id = "workbench.panel.markers", .name = "Problems", .order = 0, .glyph = '!' });
    try part.pane.addPaneComposite(.{ .id = "terminal", .name = "Terminal", .order = 3, .glyph = '>' });

    try std.testing.expect(!part.isVisible());
    try std.testing.expect(try part.openPaneComposite("terminal"));
    try std.testing.expect(part.isVisible());
    try std.testing.expectEqualStrings("terminal", part.activePaneComposite().?.id);

    try part.hideActivePaneComposite();
    try std.testing.expect(!part.isVisible());
    try std.testing.expectEqualStrings("terminal", part.pane.getLastActivePaneCompositeId());

    try part.setSize(1);
    try std.testing.expectEqual(@as(usize, 2), part.getSize());
    try part.setPosition(.bottom);
    try std.testing.expectEqual(Position.bottom, part.getPosition());
}

test "panelPart: title order, badges and hit testing" {
    const allocator = std.testing.allocator;
    var grid = try ui.CellGrid.init(allocator, 40, 2);
    defer grid.deinit();

    var part = PanelPart.init(allocator);
    defer part.deinit();
    try part.pane.addPaneComposite(.{ .id = "terminal", .name = "Terminal", .order = 3, .glyph = '>' });
    try part.pane.addPaneComposite(.{ .id = "workbench.panel.markers", .name = "Problems", .order = 0, .glyph = '!' });
    part.visible = true;
    _ = try part.pane.openPaneComposite("workbench.panel.markers", true);

    const rect = ui.Rect{ .x = 0, .y = 0, .w = 40, .h = 2 };
    try renderTitle(&part, &grid, rect, true, null, &.{
        .{ .id = "workbench.panel.markers", .text = "\u{2716} 8 \u{26A0} 0" },
    });

    const row = try grid.rowText(allocator, 0);
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "PROBLEMS") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "TERMINAL") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "\u{2716}") != null);
    const problems_index = std.mem.indexOf(u8, row, "PROBLEMS") orelse return error.TestUnexpectedResult;
    const terminal_index = std.mem.indexOf(u8, row, "TERMINAL") orelse return error.TestUnexpectedResult;
    try std.testing.expect(problems_index < terminal_index);

    try std.testing.expectEqualStrings("workbench.panel.markers", hitTest(&part, rect, 3, 0).?);
    try std.testing.expectEqualStrings("terminal", hitTest(&part, rect, 30, 0).?);
    try std.testing.expect(hitTest(&part, rect, 3, 1) == null);
}
