// Port of the terminal subset of
// `src/vs/workbench/browser/parts/views/viewPane.ts`.
//
// The header is a 1-row `ui` DOM surface: a chevron, the view title, an
// optional "Outdated" badge and the title actions. The body belongs to the
// view pane itself (see `viewPaneContainer.zig`). Browser focus rings, the
// merged-header animation, the context menu and title tooltips are not ported.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const views = @import("../../../common/views.zig");
const theme_colors_mod = @import("../../themeColors.zig");

pub const Hit = union(enum) {
    toggle,
    action: []const u8,
};

pub const Header = struct {
    allocator: Allocator,
    title: []const u8,
    actions: []const views.TitleAction = &.{},
    collapsed: bool = false,
    outdated: bool = false,
    hovered_action: ?[]const u8 = null,
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
        hashText(&hasher, self.hovered_action orelse "");
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
            }
        }
        const surface = &self.surface.?;

        if (self.signature != signature) {
            const doc = surface.document();
            doc.clear();
            self.nodes.clearRetainingCapacity();

            const root = try doc.createElement(.div);
            root.setStyle(.{
                .display = .flex,
                .flex_direction = .row,
                .align_items = .center,
                .width = .{ .percent = 100 },
                .height = .{ .cells = 1 },
                .overflow = .hidden,
                .background = colors.background,
                .color = colors.foreground,
            });

            const twistie = try doc.createElement(.span);
            twistie.setStyle(.{
                .padding = .{ .left = 1 },
                .flex_shrink = 0,
                .color = if (self.collapsed) colors.dim else colors.foreground,
            });
            _ = try twistie.appendText(if (self.collapsed) "\u{25B8}" else "\u{25BE}");
            _ = try root.appendChild(twistie);
            try self.nodes.append(.{ .id = "", .node = twistie, .toggle = true });

            const label = try doc.createElement(.span);
            label.setStyle(.{
                .padding = .{ .left = 1, .right = 1 },
                .flex_shrink = 0,
                .color = if (focused) colors.foreground else colors.foreground,
            });
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

            for (self.actions) |action| {
                const hovered = self.hovered_action != null and std.mem.eql(u8, self.hovered_action.?, action.id);
                const button = try doc.createElement(.div);
                button.setStyle(.{
                    .display = .flex,
                    .align_items = .center,
                    .height = .{ .percent = 100 },
                    .flex_shrink = 0,
                    .padding = .{ .left = 1, .right = 1 },
                    .background = if (hovered) colors.hover_background else null,
                    .color = if (action.enabled) colors.foreground else null,
                    .dim = !action.enabled,
                });
                var glyph_buf: [4]u8 = undefined;
                const glyph_len = std.unicode.utf8Encode(action.glyph, &glyph_buf) catch 0;
                _ = try button.appendText(glyph_buf[0..glyph_len]);
                if (action.show_label and action.label.len > 0 and width > 16) {
                    _ = try button.appendText(" ");
                    _ = try button.appendText(action.label);
                }
                _ = try root.appendChild(button);
                try self.nodes.append(.{ .id = action.id, .node = button });
            }

            doc.setRoot(root);
            try surface.paintFrame();
            self.signature = signature;
        }

        try grid.blit(surface.grid(), x, y, width, 1);
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
    dim: ui.Color,
    hover_background: ui.Color,
    badge_background: ui.Color,
    badge_foreground: ui.Color,
};

fn colorsFor(palette: ?*const theme_colors_mod.ThemeColors) Colors {
    if (palette) |colors| {
        const background = colors.color("sideBarSectionHeader.background", .{ 38, 38, 42 });
        const foreground = colors.color("sideBarSectionHeader.foreground", .{ 204, 204, 204 });
        return .{
            .background = background,
            .foreground = foreground,
            .dim = colors.color("descriptionForeground", .{ 150, 150, 150 }),
            .hover_background = colors.color("toolbar.hoverBackground", .{ 90, 93, 94 }),
            .badge_background = colors.color("badge.background", .{ 97, 97, 97 }),
            .badge_foreground = colors.color("badge.foreground", .{ 255, 255, 255 }),
        };
    }
    return .{
        .background = .{ .r = 38, .g = 38, .b = 42 },
        .foreground = .{ .r = 204, .g = 204, .b = 204 },
        .dim = .{ .r = 150, .g = 150, .b = 150 },
        .hover_background = .{ .r = 90, .g = 93, .b = 94 },
        .badge_background = .{ .r = 97, .g = 97, .b = 97 },
        .badge_foreground = .{ .r = 255, .g = 255, .b = 255 },
    };
}

fn hashText(hasher: *std.hash.Wyhash, text: []const u8) void {
    hasher.update(text);
    hasher.update(&[_]u8{0});
}
