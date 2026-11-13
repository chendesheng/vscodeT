//! Minimal terminal activity bar: the vertical container switcher next to the
//! side panel. Upstream this is the workbench activity bar contribution area;
//! the TUI keeps a fixed set of containers until the registered view-container
//! and activity-bar services are ported.

const std = @import("std");
const ui = @import("ui");
const CellGrid = ui.CellGrid;
const PaintStyle = ui.cell.PaintStyle;

pub const Activity = struct {
    id: []const u8,
    label: []const u8,
    glyph: u21,
};

pub const default_activities = [_]Activity{
    .{ .id = "explorer", .label = "Explorer", .glyph = 'E' },
    .{ .id = "search", .label = "Search", .glyph = 'F' },
    .{ .id = "settings", .label = "Settings", .glyph = 'S' },
};

pub const ActivityBar = struct {
    activities: []const Activity = &default_activities,

    pub fn count(self: *const ActivityBar) usize {
        return self.activities.len;
    }

    pub fn hitAt(self: *const ActivityBar, x: usize, y: usize, rect: ui.Rect) ?usize {
        _ = x;
        if (y <= ui.cell.snap(rect.y)) return null;
        const index = y - ui.cell.snap(rect.y) - 1;
        if (index >= self.activities.len) return null;
        return index;
    }

    pub fn next(self: *const ActivityBar, current: usize, delta: isize) usize {
        if (self.activities.len == 0) return 0;
        const total: isize = @intCast(self.activities.len);
        return @intCast(@mod(@as(isize, @intCast(current)) + delta, total));
    }

    pub fn render(self: *const ActivityBar, grid: *CellGrid, rect: ui.Rect, active: usize, focused: bool) void {
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

        var index: usize = 0;
        while (index < self.activities.len and index + 1 < height) : (index += 1) {
            const row = y + 1 + index;
            const paint = if (index == active) active_style else base;
            if (index == active) {
                grid.fillRect(@floatFromInt(x), @floatFromInt(row), @floatFromInt(width), 1, paint);
            }
            const glyph = self.activities[index].glyph;
            const glyph_width = ui.dom.defaultMeasureWidth(glyph);
            const col = x + (width -| glyph_width) / 2;
            grid.putCodepoint(col, row, glyph, glyph_width, paint);
        }

        if (focused) {
            grid.putCodepoint(x, y + 1 + active, '▎', 1, active_style);
        }
    }
};

test "activityBar: hit testing and cycling" {
    const activities = ActivityBar{};
    const rect = ui.Rect{ .x = 0, .y = 0, .w = 3, .h = 10 };
    try std.testing.expectEqual(@as(?usize, 0), activities.hitAt(1, 1, rect));
    try std.testing.expectEqual(@as(?usize, 2), activities.hitAt(1, 3, rect));
    try std.testing.expectEqual(@as(?usize, null), activities.hitAt(1, 4, rect));
    try std.testing.expectEqual(@as(usize, 0), activities.next(2, 1));
    try std.testing.expectEqual(@as(usize, 2), activities.next(0, -1));
}

test "activityBar: draws the active entry" {
    const allocator = std.testing.allocator;
    var grid = try CellGrid.init(allocator, 3, 4);
    defer grid.deinit();

    const activities = ActivityBar{};
    activities.render(&grid, .{ .x = 0, .y = 0, .w = 3, .h = 4 }, 1, true);
    const row = try grid.rowText(allocator, 2);
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "F") != null);
}
