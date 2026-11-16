// Port of the portable state in
// `src/vs/workbench/browser/parts/activitybar/activitybarPart.ts`.
//
// The browser part is a DOM view with menu/action/composite-bar services. The
// terminal port keeps the activity entries, their order and visibility, the
// active container, compact sizing and the change event. Rendering, hit
// testing and the terminal glyph/color mapping stay in `src/tui/`.
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
