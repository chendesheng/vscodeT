// Port of the terminal subset of
// `src/vs/workbench/browser/parts/views/viewPane.ts`.
//
// Pane headers share the twisty, title, and toolbar layout. The container
// supplies expansion, focus and hover state as in Pane and PaneView.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const views = @import("../../../common/views.zig");
const theme_colors_mod = @import("../../themeColors.zig");

const css = @import("./media/paneviewlet_css.zig");

pub const ShowActions = enum {
    default,
    always,
    when_expanded,

    pub fn visible(self: ShowActions, expanded: bool, hovered: bool, focused: bool, always_show: bool) bool {
        return self == .always or (expanded and (self == .when_expanded or hovered or focused or always_show));
    }
};

pub const Hit = union(enum) {
    toggle,
    action: []const u8,
};

pub const Header = struct {
    allocator: Allocator,
    title: []const u8,
    actions: []const views.TitleAction = &.{},
    collapsed: bool = false,
    focused_action: ?usize = null,
    native_outline: bool = false,
    outdated: bool = false,
    surface: ?ui.Surface = null,
    nodes: std.array_list.Managed(NodeRef),
    signature: u64 = 0,

    pub const NodeRef = struct { id: []const u8, node: *ui.Node, toggle: bool = false };

    pub fn init(allocator: Allocator, title: []const u8) Header {
        return .{
            .allocator = allocator,
            .title = title,
            .nodes = std.array_list.Managed(NodeRef).init(allocator),
        };
    }

    pub fn deinit(self: *Header) void {
        if (self.surface) |*surface| surface.deinit();
        self.nodes.deinit();
        self.* = undefined;
    }

    pub fn setActions(self: *Header, actions: []const views.TitleAction) void {
        self.actions = actions;
    }

    /// Moves the pointer over the header surface. The library resolves the
    /// element under the cell, keeps the hover chain and repaints the hover
    /// style on the next `paintFrame`; layout errors only lose the highlight.
    pub fn setHoveredAt(self: *Header, local_x: usize, local_y: usize) void {
        if (self.surface) |*surface| {
            _ = surface.updateHoverAt(local_x, local_y) catch {};
        }
    }

    /// Clears the header's pointer/hover state when the pointer moves away.
    pub fn clearHover(self: *Header) void {
        if (self.surface) |*surface| _ = surface.clearHover();
    }

    pub fn render(
        self: *Header,
        grid: *ui.CellGrid,
        rect: ui.Rect,
        palette: ?*const theme_colors_mod.ThemeColors,
        focused: bool,
    ) !void {
        const x = ui.cell.snap(rect.x);
        const y = ui.cell.snap(rect.y);
        const width = ui.cell.snap(rect.w);
        const height = ui.cell.snap(rect.h);
        if (width == 0 or height == 0) return;

        const colors = colorsFor(palette);
        var hasher = std.hash.Wyhash.init(0);
        hashText(&hasher, self.title);
        hasher.update(std.mem.asBytes(&x));
        hasher.update(std.mem.asBytes(&y));
        hasher.update(std.mem.asBytes(&width));
        hasher.update(&[_]u8{
            @intFromBool(self.collapsed),
            @intFromBool(self.outdated),
            @intFromBool(focused),
        });
        const focused_action = self.focused_action orelse std.math.maxInt(usize);
        hasher.update(std.mem.asBytes(&focused_action));
        hasher.update(&.{@intFromBool(self.native_outline)});
        const palette_ptr: usize = if (palette) |value| @intFromPtr(value) else 0;
        hasher.update(std.mem.asBytes(&palette_ptr));
        for (self.actions) |action| {
            hashText(&hasher, action.id);
            hashText(&hasher, action.label);
            hasher.update(std.mem.asBytes(&action.glyph));
            hasher.update(&[_]u8{ @intFromBool(action.enabled), @intFromBool(action.show_label) });
        }
        const signature = hasher.final();

        if (self.surface == null or self.surface.?.doc.cols != width) {
            if (self.surface) |*surface| {
                try surface.resize(width, 1);
            } else {
                self.surface = try ui.Surface.init(self.allocator, .{ .cols = width, .rows = 1 });
                _ = try self.surface.?.document().registerSheet(css.sheet);
            }
        }
        const surface = &self.surface.?;

        if (self.signature != signature) {
            const doc = surface.document();
            doc.clear();
            self.nodes.clearRetainingCapacity();

            const root = try doc.createElement(.div);
            try root.addClass(css.Class.pane_header);
            root.setStyle(.{
                .background = if (focused and !self.native_outline) colors.focus_background else colors.background,
                .color = colors.foreground,
            });

            const twistie = try doc.createElement(.span);
            try twistie.addClass(css.Class.twisty);
            _ = try twistie.appendText(if (self.collapsed) "›" else "⌄");
            _ = try root.appendChild(twistie);
            try self.nodes.append(.{ .id = "", .node = twistie, .toggle = true });

            const label = try doc.createElement(.span);
            try label.addClass(css.Class.title);
            _ = try label.appendText(self.title);
            _ = try root.appendChild(label);
            try self.nodes.append(.{ .id = "", .node = label, .toggle = true });

            const spacer = try doc.createElement(.span);
            spacer.setStyle(.{ .flex_grow = 1 });
            _ = try root.appendChild(spacer);

            if (self.outdated) {
                const badge = try doc.createElement(.span);
                badge.setStyle(.{
                    .padding = .{ .left = 1, .right = 1 },
                    .flex_shrink = 0,
                    .background = colors.badge_background,
                    .color = colors.badge_foreground,
                });
                _ = try badge.appendText("Outdated");
                _ = try root.appendChild(badge);
            }

            var required = self.actions.len + doc.measureText(self.title) + 5;
            for (self.actions) |action| {
                if (action.show_label) required += 1 + doc.measureText(action.label);
            }
            const show_labels = required <= width;
            const action_padding: f64 = if (required + self.actions.len * 2 <= width) 1 else 0;
            const toolbar = try doc.createElement(.div);
            try toolbar.addClass(css.Class.actions);
            _ = try root.appendChild(toolbar);
            for (self.actions, 0..) |action, action_index| {
                const action_focused = self.focused_action == action_index;
                const button = try doc.createElement(.div);
                try button.addClass(css.Class.action_item);
                button.setStyle(.{
                    .padding = .{ .left = action_padding, .right = action_padding },
                    .background = if (action_focused and !self.native_outline) colors.focus_background else null,
                    .dim = !action.enabled,
                });
                // The browser gets this from `:hover` on the toolbar action;
                // the ui surface tracks the pointer and paints the declaration.
                button.setHoverStyle(.{ .background = colors.hover_background });
                var glyph_buf: [4]u8 = undefined;
                const glyph_len = std.unicode.utf8Encode(action.glyph, &glyph_buf) catch 0;
                const text = if (show_labels and action.show_label and action.label.len > 0)
                    try std.fmt.allocPrint(doc.arena.allocator(), "{s} {s}", .{ glyph_buf[0..glyph_len], action.label })
                else
                    glyph_buf[0..glyph_len];
                _ = try button.appendText(text);
                _ = try toolbar.appendChild(button);
                try self.nodes.append(.{ .id = action.id, .node = button });
            }
            doc.setRoot(root);
            self.signature = signature;
        }

        // Hover is live paint state, not part of the signature: repaint the
        // one-row surface so a pointer move over a title action is reflected.
        // The library also re-resolves the stored pointer cell after a rebuild.
        try surface.paintFrame();
        try grid.blit(surface.grid(), x, y, width, 1);
        if (!self.native_outline) return;
        if (focused) {
            paintFocusOutline(grid, x, y, width, colors.focus_border);
        } else if (self.focused_action) |index| {
            const action = if (index < self.actions.len) self.actions[index] else return;
            for (self.nodes.items) |entry| {
                if (!std.mem.eql(u8, entry.id, action.id)) continue;
                const box = surface.box_tree.find(entry.node) orelse break;
                const left = @min(ui.cell.snap(box.rect.x), width);
                const right = @min(ui.cell.snap(box.rect.right()), width);
                paintFocusOutline(grid, x + left, y, right -| left, colors.focus_border);
                break;
            }
        }
    }

    fn paintFocusOutline(grid: *ui.CellGrid, x: usize, y: usize, width: usize, color: ui.Color) void {
        const edges = ui.cell_border.Segment;
        for (0..width) |col| {
            var mask = edges.top | edges.bottom;
            if (col == 0) mask |= edges.left;
            if (col + 1 == width) mask |= edges.right;
            grid.addBorder(x + col, y, mask, .{ .width = 16, .color = .{ .rgb = color } });
        }
    }

    pub fn hitTest(self: *const Header, rect: ui.Rect, x: usize, y: usize) ?Hit {
        const rect_x = ui.cell.snap(rect.x);
        const rect_y = ui.cell.snap(rect.y);
        const width = ui.cell.snap(rect.w);
        if (width == 0 or y != rect_y or x < rect_x or x >= rect_x + width) return null;
        const surface = self.surface orelse return null;
        const local_x = @as(f64, @floatFromInt(x - rect_x)) + 0.5;
        for (self.nodes.items) |entry| {
            const box = surface.box_tree.find(entry.node) orelse continue;
            if (local_x < box.rect.x or local_x >= box.rect.x + box.rect.w) continue;
            if (entry.toggle) return .toggle;
            return .{ .action = entry.id };
        }
        return .toggle;
    }
};

const Colors = struct {
    background: ui.Color,
    foreground: ui.Color,
    hover_background: ui.Color,
    focus_border: ui.Color,
    focus_background: ui.Color,
    badge_background: ui.Color,
    badge_foreground: ui.Color,
};

fn colorsFor(palette: ?*const theme_colors_mod.ThemeColors) Colors {
    if (palette) |colors| {
        const background = colors.color("sideBarSectionHeader.background", .{ 38, 38, 42 });
        const foreground = colors.colorOr("sideBarSectionHeader.foreground", colors.colorOr("sideBar.foreground", colors.text()));
        return .{
            .background = background,
            .foreground = foreground,
            .hover_background = colors.color("toolbar.hoverBackground", .{ 90, 93, 94 }),
            .focus_border = colors.color("focusBorder", .{ 0, 122, 204 }),
            .focus_background = colors.color("toolbar.hoverBackground", .{ 58, 61, 65 }),
            .badge_background = colors.color("badge.background", .{ 97, 97, 97 }),
            .badge_foreground = colors.color("badge.foreground", .{ 255, 255, 255 }),
        };
    }
    return .{
        .background = .{ .r = 38, .g = 38, .b = 42 },
        .foreground = .{ .r = 204, .g = 204, .b = 204 },
        .hover_background = .{ .r = 90, .g = 93, .b = 94 },
        .focus_border = .{ .r = 0, .g = 122, .b = 204 },
        .focus_background = .{ .r = 58, .g = 61, .b = 65 },
        .badge_background = .{ .r = 97, .g = 97, .b = 97 },
        .badge_foreground = .{ .r = 255, .g = 255, .b = 255 },
    };
}

fn hashText(hasher: *std.hash.Wyhash, text: []const u8) void {
    hasher.update(text);
    hasher.update(&[_]u8{0});
}

test "view pane header paints title/actions and hit-tests them" {
    const allocator = std.testing.allocator;
    var grid = try ui.CellGrid.init(allocator, 40, 1);
    defer grid.deinit();

    var header = Header.init(allocator, "Explorer");
    defer header.deinit();
    const actions = [_]views.TitleAction{
        .{ .id = "settings", .label = "Settings", .glyph = 0x2699, .enabled = true, .show_label = true },
    };
    header.setActions(&actions);
    header.outdated = true;
    const rect = ui.Rect{ .x = 0, .y = 0, .w = 40, .h = 1 };
    try header.render(&grid, rect, null, false);

    const text = try grid.rowText(allocator, 0);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Explorer") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Outdated") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\u{2699} Settings") != null);
    try std.testing.expect(header.hitTest(rect, 1, 0) != null);
    try std.testing.expect(header.hitTest(rect, 39, 0) != null);
    try std.testing.expect(header.hitTest(rect, 1, 1) == null);

    const title_col = std.mem.indexOfScalar(u32, grid.cluster, 'E').?;
    const title_fg = grid.fg[title_col];
    const title_bg = grid.bg[title_col];
    try header.render(&grid, rect, null, true);
    try std.testing.expectEqual(title_fg, grid.fg[title_col]);
    try std.testing.expect(title_bg != grid.bg[title_col]);
    try std.testing.expectEqual(@as(u16, 0), grid.attrs[title_col] & ui.cell.Attr.underline);

    header.native_outline = true;
    try header.render(&grid, rect, null, true);
    try std.testing.expectEqual(title_fg, grid.fg[title_col]);
    try std.testing.expectEqual(title_bg, grid.bg[title_col]);
    try std.testing.expect(grid.border[title_col] != 0);
}
