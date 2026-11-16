// Terminal activity-bar view over the ported
// `src/vs/workbench/browser/parts/activitybar/activitybarPart.zig` model.
//
// The model owns the activity entries, order, visibility, active container and
// compact width. This file only maps the model's activities to terminal cells
// and performs row hit testing; that is the same split as upstream's
// `ActivitybarPart` view versus the view-container/activity services.

const std = @import("std");
const ui = @import("ui");
const activitybar = @import("../vs/workbench/browser/parts/activitybar/activitybarPart.zig");
const ActivityBarPart = activitybar.ActivityBarPart;
const Activity = activitybar.Activity;

const CellGrid = ui.CellGrid;
const PaintStyle = ui.cell.PaintStyle;

pub const default_activities = [_]Activity{
    .{ .id = "explorer", .name = "Explorer", .glyph = 'E', .order = 1 },
    .{ .id = "search", .name = "Search", .glyph = 'F', .order = 2 },
    .{ .id = "settings", .name = "Settings", .glyph = 'S', .order = 3 },
};

/// The visible activity at a terminal row. Rows start under the top padding
/// row, matching the painted layout.
pub fn hitAt(part: *const ActivityBarPart, x: usize, y: usize, rect: ui.Rect) ?usize {
    _ = x;
    if (y <= ui.cell.snap(rect.y)) return null;
    const index = y - ui.cell.snap(rect.y) - 1;
    if (index >= part.count()) return null;
    _ = part.activityAtVisibleIndex(index) orelse return null;
    return index;
}

pub fn render(
    part: *const ActivityBarPart,
    grid: *CellGrid,
    rect: ui.Rect,
    active: usize,
    focused: bool,
) void {
    if (!part.visible) return;
    const x = ui.cell.snap(rect.x);
    const y = ui.cell.snap(rect.y);
    const width = ui.cell.snap(rect.w);
    const height = ui.cell.snap(rect.h);
    if (width == 0 or height == 0) return;

    const base = PaintStyle{
        .fg = ui.cell.packColor(.{ .r = 130, .g = 130, .b = 135 }),
        .bg = ui.cell.packColor(.{ .r = 30, .g = 30, .b = 33 }),
    };
    const active_style = PaintStyle{
        .fg = ui.cell.packColor(.{ .r = 245, .g = 245, .b = 245 }),
        .bg = ui.cell.packColor(.{ .r = 45, .g = 45, .b = 50 }),
    };
    grid.fillRect(@floatFromInt(x), @floatFromInt(y), @floatFromInt(width), @floatFromInt(height), base);

    var visible_index: usize = 0;
    for (part.activities.items) |activity| {
        if (!activity.visible) continue;
        if (visible_index + 1 >= height) break;
        const row = y + 1 + visible_index;
        const paint = if (visible_index == active) active_style else base;
        if (visible_index == active) {
            grid.fillRect(@floatFromInt(x), @floatFromInt(row), @floatFromInt(width), 1, paint);
        }
        const glyph_width = ui.dom.defaultMeasureWidth(activity.glyph);
        const col = x + (width -| glyph_width) / 2;
        grid.putCodepoint(col, row, activity.glyph, glyph_width, paint);
        visible_index += 1;
    }

    if (focused and visible_index > 0 and active < visible_index) {
        grid.putCodepoint(x, y + 1 + active, '▎', 1, active_style);
    }
}

test "activityBar: hit testing and cycling use the ported model" {
    var part = ActivityBarPart.init(std.testing.allocator);
    defer part.deinit();
    for (default_activities) |activity| try part.addActivity(activity);
    try part.setVisible(true);

    const rect = ui.Rect{ .x = 0, .y = 0, .w = 3, .h = 10 };
    try std.testing.expectEqual(@as(?usize, 0), hitAt(&part, 1, 1, rect));
    try std.testing.expectEqual(@as(?usize, 2), hitAt(&part, 1, 3, rect));
    try std.testing.expectEqual(@as(?usize, null), hitAt(&part, 1, 4, rect));
    try std.testing.expectEqual(@as(usize, 0), part.next(2, 1));
    try std.testing.expectEqual(@as(usize, 2), part.next(0, -1));
}

test "activityBar: draws the active entry from the model" {
    const allocator = std.testing.allocator;
    var grid = try CellGrid.init(allocator, 3, 4);
    defer grid.deinit();

    var part = ActivityBarPart.init(allocator);
    defer part.deinit();
    for (default_activities) |activity| try part.addActivity(activity);
    try part.setVisible(true);

    render(&part, &grid, .{ .x = 0, .y = 0, .w = 3, .h = 4 }, 1, true);
    const row = try grid.rowText(allocator, 2);
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "F") != null);
}
