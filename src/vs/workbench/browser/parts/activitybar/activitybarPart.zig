// Port of the portable state in
// `src/vs/workbench/browser/parts/activitybar/activitybarPart.ts`.
//
// The browser part is a DOM view with menu/action/composite-bar services. The
// terminal port keeps the activity entries, their order and visibility, the
// active container, compact sizing and the change event. Rendering, hit
// testing and the terminal glyph/color mapping live in this file.
//
// Terminal adaptation: dimensions are whole cells instead of CSS pixels. The
// compact mode narrows the rail by one cell; the floating-panel pixel margins
// have no terminal equivalent and are not ported.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../../../base/common/event.zig").Emitter;

/// Upstream activity entries are view containers with an icon and an action.
/// The terminal model keeps the icon as a single-cell glyph for the view.
pub const Activity = struct {
    id: []const u8,
    name: []const u8,
    glyph: u21 = '?',
    order: usize = 0,
    visible: bool = true,
};

pub const ActivityBarPart = struct {
    allocator: Allocator,
    activities: std.array_list.Managed(Activity),
    active_id: ?[]const u8 = null,
    visible: bool = false,
    compact: bool = false,
    on_did_change: Emitter(void),

    /// Upstream `ACTIVITYBAR_WIDTH` is 48 px; the terminal rail is 3 cells.
    pub const default_width: usize = 3;
    /// Upstream compact width is 36 px; the terminal compact rail is 2 cells.
    pub const compact_width: usize = 2;

    pub fn init(allocator: Allocator) ActivityBarPart {
        return .{
            .allocator = allocator,
            .activities = std.array_list.Managed(Activity).init(allocator),
            .on_did_change = Emitter(void).init(allocator),
        };
    }

    pub fn deinit(self: *ActivityBarPart) void {
        self.on_did_change.deinit();
        self.activities.deinit();
    }

    pub fn width(self: *const ActivityBarPart) usize {
        return if (self.compact) compact_width else default_width;
    }

    pub fn minimumWidth(self: *const ActivityBarPart) usize {
        return self.width();
    }

    pub fn maximumWidth(self: *const ActivityBarPart) usize {
        return self.width();
    }

    pub fn minimumHeight(_: *const ActivityBarPart) usize {
        return 0;
    }

    pub fn maximumHeight(_: *const ActivityBarPart) usize {
        return std.math.maxInt(usize);
    }

    pub fn setVisible(self: *ActivityBarPart, visible: bool) !void {
        if (self.visible == visible) return;
        self.visible = visible;
        try self.on_did_change.fire({});
    }

    pub fn setCompact(self: *ActivityBarPart, compact: bool) !void {
        if (self.compact == compact) return;
        self.compact = compact;
        try self.on_did_change.fire({});
    }

    pub fn addActivity(self: *ActivityBarPart, activity: Activity) !void {
        for (self.activities.items, 0..) |*existing, index| {
            if (std.mem.eql(u8, existing.id, activity.id)) {
                existing.* = activity;
                if (self.active_id == null and activity.visible) self.active_id = activity.id;
                try self.on_did_change.fire({});
                _ = index;
                return;
            }
        }
        var insert_at: usize = 0;
        while (insert_at < self.activities.items.len and self.activities.items[insert_at].order <= activity.order) {
            insert_at += 1;
        }
        try self.activities.insert(insert_at, activity);
        if (self.active_id == null and activity.visible) self.active_id = activity.id;
        try self.on_did_change.fire({});
    }

    pub fn removeActivity(self: *ActivityBarPart, id: []const u8) !void {
        for (self.activities.items, 0..) |activity, index| {
            if (!std.mem.eql(u8, activity.id, id)) continue;
            _ = self.activities.orderedRemove(index);
            if (self.active_id != null and std.mem.eql(u8, self.active_id.?, id)) {
                self.active_id = self.firstVisibleId();
            }
            try self.on_did_change.fire({});
            return;
        }
    }

    pub fn count(self: *const ActivityBarPart) usize {
        return self.activities.items.len;
    }

    /// Visible activities in declaration/order order.
    pub fn visibleActivities(self: *const ActivityBarPart, allocator: Allocator) ![]Activity {
        var result = std.array_list.Managed(Activity).init(allocator);
        errdefer result.deinit();
        for (self.activities.items) |activity| {
            if (activity.visible) try result.append(activity);
        }
        return result.toOwnedSlice();
    }

    pub fn setActive(self: *ActivityBarPart, id: []const u8) !bool {
        for (self.activities.items) |activity| {
            if (!std.mem.eql(u8, activity.id, id) or !activity.visible) continue;
            self.active_id = activity.id;
            try self.on_did_change.fire({});
            return true;
        }
        return false;
    }

    pub fn activeIndex(self: *const ActivityBarPart) ?usize {
        const active = self.active_id orelse return null;
        var visible_index: usize = 0;
        for (self.activities.items) |activity| {
            if (!activity.visible) continue;
            if (std.mem.eql(u8, activity.id, active)) return visible_index;
            visible_index += 1;
        }
        return null;
    }

    pub fn next(self: *const ActivityBarPart, current: usize, delta: isize) usize {
        const total: isize = @intCast(self.visibleCount());
        if (total == 0) return 0;
        return @intCast(@mod(@as(isize, @intCast(current)) + delta, total));
    }

    pub fn activityAtVisibleIndex(self: *const ActivityBarPart, index: usize) ?Activity {
        var visible_index: usize = 0;
        for (self.activities.items) |activity| {
            if (!activity.visible) continue;
            if (visible_index == index) return activity;
            visible_index += 1;
        }
        return null;
    }

    fn visibleCount(self: *const ActivityBarPart) usize {
        var total: usize = 0;
        for (self.activities.items) |activity| {
            if (activity.visible) total += 1;
        }
        return total;
    }

    fn firstVisibleId(self: *const ActivityBarPart) ?[]const u8 {
        for (self.activities.items) |activity| {
            if (activity.visible) return activity.id;
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Terminal activity-bar view
//
// Upstream `ActivitybarPart` owns both the part container and the DOM view;
// this port keeps the model above and maps it to terminal cells here. Badges
// are terminal-adapted: a single-character badge is painted as-is in the
// rightmost rail cell; a multi-character numeric badge becomes a dot because a
// single digit next to the sidebar reads like adjacent panel text.
// ---------------------------------------------------------------------------

const ui = @import("ui");
const ActivityService = @import("../../../services/activity/browser/activityService.zig").ActivityService;
const CellGrid = ui.CellGrid;
const PaintStyle = ui.cell.PaintStyle;

pub const default_activities = [_]Activity{
    .{ .id = "explorer", .name = "Explorer", .glyph = 'E', .order = 1 },
    .{ .id = "search", .name = "Search", .glyph = 'F', .order = 2 },
    .{ .id = "scm", .name = "Source Control", .glyph = 'G', .order = 3 },
    .{ .id = "problems", .name = "Problems", .glyph = '!', .order = 4 },
    .{ .id = "settings", .name = "Settings", .glyph = 'S', .order = 5 },
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
    service: ?*const ActivityService,
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
    const badge_foreground = ui.cell.packColor(.{ .r = 250, .g = 200, .b = 80 });
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
        if (service) |activity_service| {
            if (activity_service.getContainerBadgeDescription(activity.id)) |description| {
                if (description.len > 0 and width > 0) {
                    const badge_col = x + width - 1;
                    grid.putCodepoint(badge_col, row, badgeGlyph(description), 1, .{
                        .fg = badge_foreground,
                        .bg = paint.bg,
                        .attrs = ui.cell.Attr.bold,
                    });
                }
            }
        }
        visible_index += 1;
    }

    if (focused and visible_index > 0 and active < visible_index) {
        grid.putCodepoint(x, y + 1 + active, '▎', 1, active_style);
    }
}

fn badgeGlyph(description: []const u8) u21 {
    if (description.len <= 1) return description[0];
    for (description) |character| {
        if (!std.ascii.isDigit(character)) return description[0];
    }
    return '•';
}

test "activityBar: hit testing and cycling use the ported model" {
    var part = ActivityBarPart.init(std.testing.allocator);
    defer part.deinit();
    for (default_activities) |activity| try part.addActivity(activity);
    try part.setVisible(true);

    const rect = ui.Rect{ .x = 0, .y = 0, .w = 3, .h = 10 };
    try std.testing.expectEqual(@as(?usize, 0), hitAt(&part, 1, 1, rect));
    try std.testing.expectEqual(@as(?usize, 2), hitAt(&part, 1, 3, rect));
    try std.testing.expectEqual(@as(?usize, 3), hitAt(&part, 1, 4, rect));
    try std.testing.expectEqual(@as(?usize, null), hitAt(&part, 1, 6, rect));
    try std.testing.expectEqual(@as(usize, 3), part.next(2, 1));
    try std.testing.expectEqual(@as(usize, 4), part.next(0, -1));
}

test "activityBar: draws the active entry from the model" {
    const allocator = std.testing.allocator;
    var grid = try CellGrid.init(allocator, 3, 4);
    defer grid.deinit();

    var part = ActivityBarPart.init(allocator);
    defer part.deinit();
    for (default_activities) |activity| try part.addActivity(activity);
    try part.setVisible(true);

    render(&part, null, &grid, .{ .x = 0, .y = 0, .w = 3, .h = 4 }, 1, true);
    const row = try grid.rowText(allocator, 2);
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "F") != null);

    var service = ActivityService.init(allocator);
    defer service.deinit();
    try service.showViewContainerActivity("search", .{
        .id = "search.results",
        .badge = .{ .description = "572" },
    });
    render(&part, &service, &grid, .{ .x = 0, .y = 0, .w = 3, .h = 4 }, 1, true);
    const badge_row = try grid.rowText(allocator, 2);
    defer allocator.free(badge_row);
    try std.testing.expect(std.mem.indexOf(u8, badge_row, "•") != null);
}
