// Port of the portable service in
// `src/vs/workbench/services/activity/browser/activityService.ts` and
// `src/vs/workbench/services/activity/common/activity.ts`.
//
// Browser activities are badges attached to DOM actions. The terminal model
// stores a description per id; the view paints it as text. Activity objects are
// borrowed for the lifetime of the registration, matching the upstream
// disposable contract without adding a storage/context-key service.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../../../base/common/event.zig").Emitter;

pub const Badge = struct {
    description: []const u8,
};

pub const Activity = struct {
    id: []const u8,
    badge: Badge,
};

pub const Change = union(enum) {
    container: []const u8,
    global,
};

pub const ActivityService = struct {
    allocator: Allocator,
    by_id: std.StringHashMap(std.array_list.Managed(Activity)),
    global: std.array_list.Managed(Activity),
    on_did_change_activity: Emitter(Change),

    pub fn init(allocator: Allocator) ActivityService {
        return .{
            .allocator = allocator,
            .by_id = std.StringHashMap(std.array_list.Managed(Activity)).init(allocator),
            .global = std.array_list.Managed(Activity).init(allocator),
            .on_did_change_activity = Emitter(Change).init(allocator),
        };
    }

    pub fn deinit(self: *ActivityService) void {
        var iterator = self.by_id.valueIterator();
        while (iterator.next()) |list| list.deinit();
        self.by_id.deinit();
        self.global.deinit();
        self.on_did_change_activity.deinit();
    }

    pub fn showViewContainerActivity(self: *ActivityService, view_container_id: []const u8, activity: Activity) !void {
        const result = try self.by_id.getOrPut(view_container_id);
        if (!result.found_existing) result.value_ptr.* = std.array_list.Managed(Activity).init(self.allocator);
        try result.value_ptr.append(activity);
        try self.on_did_change_activity.fire(.{ .container = view_container_id });
    }

    pub fn getViewContainerActivities(self: *const ActivityService, allocator: Allocator, view_container_id: []const u8) ![]Activity {
        const list = self.by_id.get(view_container_id) orelse return allocator.alloc(Activity, 0);
        return allocator.dupe(Activity, list.items);
    }

    pub fn showViewActivity(self: *ActivityService, view_id: []const u8, activity: Activity) !void {
        return self.showViewContainerActivity(view_id, activity);
    }

    pub fn showAccountsActivity(self: *ActivityService, activity: Activity) !void {
        return self.showViewContainerActivity("accounts", activity);
    }

    pub fn showGlobalActivity(self: *ActivityService, activity: Activity) !void {
        try self.global.append(activity);
        try self.on_did_change_activity.fire(.global);
    }

    pub fn getActivity(self: *const ActivityService, allocator: Allocator, id: []const u8) ![]Activity {
        if (std.mem.eql(u8, id, "global")) return allocator.dupe(Activity, self.global.items);
        return self.getViewContainerActivities(allocator, id);
    }

    /// Removes every activity with the id from a container (or global).
    pub fn removeActivity(self: *ActivityService, view_container_id: ?[]const u8, id: []const u8) void {
        if (view_container_id) |container_id| {
            if (self.by_id.getPtr(container_id)) |list| {
                removeById(list, id);
            }
        } else {
            removeById(&self.global, id);
        }
        self.on_did_change_activity.fire(if (view_container_id) |container_id|
            .{ .container = container_id }
        else
            .global) catch {};
    }
};

fn removeById(list: *std.array_list.Managed(Activity), id: []const u8) void {
    var index: usize = 0;
    while (index < list.items.len) {
        if (std.mem.eql(u8, list.items[index].id, id)) {
            _ = list.orderedRemove(index);
        } else {
            index += 1;
        }
    }
}
