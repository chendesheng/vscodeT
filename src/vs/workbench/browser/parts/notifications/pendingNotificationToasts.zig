// Port of `src/vs/workbench/browser/parts/notifications/pendingNotificationToasts.ts`.
// The window dispatch queue replaces requestAnimationFrame. A pending item is
// retained until the next turn so a synchronous duplicate ADD can retarget it.
const std = @import("std");
const model = @import("../../../common/notifications.zig");
const Item = model.NotificationViewItem;
const Queue = @import("../../../../base/common/windowDispatch.zig").Queue;
const Task = @import("../../../../base/common/windowDispatch.zig").Task;

pub const PendingNotificationToasts = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(*Item) = .empty,
    model: *model.NotificationsModel,
    task: Task,
    context: *anyopaque,
    render: *const fn (*anyopaque, *Item, i64) void,

    pub fn init(self: *PendingNotificationToasts, allocator: std.mem.Allocator, notifications: *model.NotificationsModel, queue: *Queue, context: *anyopaque, render: *const fn (*anyopaque, *Item, i64) void) void {
        self.* = .{ .allocator = allocator, .model = notifications, .task = .{ .queue = queue, .context = self, .run = flush, .progress = true }, .context = context, .render = render };
    }
    pub fn deinit(self: *PendingNotificationToasts) void {
        self.clear();
        self.items.deinit(self.allocator);
    }
    pub fn tryReplace(self: *PendingNotificationToasts, item: *Item) bool {
        for (self.items.items) |*pending| {
            if (pending.*.equals(item)) {
                item.retainView();
                pending.*.releaseView();
                pending.* = item;
                return true;
            }
        }
        return false;
    }
    pub fn add(self: *PendingNotificationToasts, item: *Item) !void {
        try self.items.append(self.allocator, item);
        item.retainView();
        self.task.post();
    }
    // Removal is intentionally deferred through this render turn: the model
    // can synchronously add an equal notification just after removing one.
    pub fn remove(_: *PendingNotificationToasts, _: *Item) void {}
    pub fn clear(self: *PendingNotificationToasts) void {
        self.task.schedule(null);
        for (self.items.items) |item| item.releaseView();
        self.items.clearRetainingCapacity();
    }
    fn flush(context: *anyopaque, now: i64, _: bool) bool {
        const self: *PendingNotificationToasts = @ptrCast(@alignCast(context));
        var pending: std.ArrayList(*Item) = .empty;
        std.mem.swap(@TypeOf(pending), &pending, &self.items);
        defer pending.deinit(self.allocator);
        for (pending.items) |item| {
            if (std.mem.indexOfScalar(*Item, self.model.notifications.items, item) != null) self.render(self.context, item, now);
            item.releaseView();
        }
        return true;
    }
};
