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
