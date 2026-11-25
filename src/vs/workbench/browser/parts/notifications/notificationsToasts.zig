// Port of `src/vs/workbench/browser/parts/notifications/notificationsToasts.ts`.
// Terminal adaptation: the window queue schedules pending rows and purge
// timers, while the host lays out the visible notification rows in cells.
const std = @import("std");
const Allocator = std.mem.Allocator;
const model_mod = @import("../../../common/notifications.zig");
const Item = model_mod.NotificationViewItem;
const Queue = @import("../../../../base/common/windowDispatch.zig").Queue;
const Task = @import("../../../../base/common/windowDispatch.zig").Task;
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const time = @import("../../../../base/common/timeCompat.zig");
const Pending = @import("./pendingNotificationToasts.zig").PendingNotificationToasts;

pub const NotificationsToasts = struct {
    pub const MAX_NOTIFICATIONS = 3;
    const interval = 800;
    allocator: Allocator,
    model: *model_mod.NotificationsModel,
    queue: *Queue,
    pending: Pending,
    toasts: std.ArrayList(*Toast) = .empty,
    notification_listener: ?usize = null,
    filter_listener: usize,
    on_did_change_visibility: Emitter(void),
    on_did_change: Emitter(void),
    is_visible: bool = false,
    center_visible: bool = false,
    window_focused: bool = true,
    focus_index: ?usize = null,
    hovered: ?*Item = null,
    added_since: i64 = 0,
    added_count: usize = 0,
    max_height: usize = std.math.maxInt(usize),
    max_width: usize = 56,
    row_height: usize = 2,

    pub const Toast = struct {
        owner: *NotificationsToasts,
        item: *Item,
        timer: Task,
        waiting_for_focus: bool = false,
        visible: bool = false,
    };

    pub fn create(allocator: Allocator, model: *model_mod.NotificationsModel, queue: *Queue) !*NotificationsToasts {
        const self = try allocator.create(NotificationsToasts);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .model = model, .queue = queue, .pending = undefined, .filter_listener = undefined, .on_did_change_visibility = .init(allocator), .on_did_change = .init(allocator) };
        self.pending.init(allocator, model, queue, self, renderPending);
        errdefer self.pending.deinit();
        self.filter_listener = try model.on_did_change_filter.listen(self, onFilter);
        return self;
    }
    pub fn deinit(self: *NotificationsToasts) void {
        if (self.notification_listener) |id| self.model.on_did_change_notification.unlisten(id);
        self.model.on_did_change_filter.unlisten(self.filter_listener);
        self.hide();
        self.pending.deinit();
        self.toasts.deinit(self.allocator);
        self.on_did_change_visibility.deinit();
        self.on_did_change.deinit();
        self.allocator.destroy(self);
    }
    // Mirrors the upstream Restored lifecycle barrier.
    pub fn start(self: *NotificationsToasts) !void {
        if (self.notification_listener != null) return;
        self.notification_listener = try self.model.on_did_change_notification.listen(self, onNotification);
        for (self.model.notifications.items) |item| try self.addToast(item);
    }
    fn onNotification(event: model_mod.INotificationChangeEvent, self: *NotificationsToasts) !void {
        switch (event.kind) {
            .ADD => try self.addToast(event.item),
            .REMOVE => self.removeToast(event.item),
            .CHANGE, .EXPAND_COLLAPSE => {
                if (self.findToast(event.item) != null) {
                    self.layoutContainer();
                    try self.on_did_change.fire({});
                }
            },
        }
    }
    fn onFilter(event: model_mod.FilterChange, self: *NotificationsToasts) !void {
        if (event.global == .ERROR) self.hide();
        if (event.sources) {
            var i: usize = self.toasts.items.len;
            while (i != 0) {
                i -= 1;
                const item = self.toasts.items[i].item;
                if (item.severity != .Error and item.priority != .URGENT and item.source_id != null and self.model.filter.sources.get(item.source_id.?) == .ERROR) self.removeToast(item);
            }
        }
    }
    fn addToast(self: *NotificationsToasts, item: *Item) !void {
        if (self.center_visible or item.priority == .SILENT) return;
        if (self.pending.tryReplace(item)) return;
        const now = time.milliTimestamp();
        if (now - self.added_since >= interval) {
            self.added_since = now;
            self.added_count = 0;
        }
        self.added_count += 1;
        if (self.added_count > MAX_NOTIFICATIONS) return;
        try self.pending.add(item);
    }
    fn renderPending(ctx: *anyopaque, item: *Item, now: i64) void {
        const self: *NotificationsToasts = @ptrCast(@alignCast(ctx));
        if (self.center_visible or item.closed) return;
        const toast = self.allocator.create(Toast) catch return;
        toast.* = .{ .owner = self, .item = item, .timer = .{ .queue = self.queue, .context = toast, .run = purge } };
        self.toasts.insert(self.allocator, 0, toast) catch {
            self.allocator.destroy(toast);
            return;
        };
        if (self.focus_index) |index| self.focus_index = index + 1;
        item.retainView();
        toast.timer.schedule(now + timeout(item));
        self.layoutContainer();
        self.on_did_change.fire({}) catch {};
    }
    fn timeout(item: *Item) i64 {
        return switch (item.severity) {
            .Error => 15000,
            .Warning => 12000,
            else => 10000,
        };
    }
    fn purge(ctx: *anyopaque, now: i64, _: bool) bool {
        const toast: *Toast = @ptrCast(@alignCast(ctx));
        const self = toast.owner;
        if (!self.window_focused) {
            toast.waiting_for_focus = true;
            return false;
        }
        if (toast.item.sticky() or self.hovered == toast.item or (self.focus_index != null and self.toasts.items[self.focus_index.?] == toast)) {
            toast.timer.schedule(now + timeout(toast.item));
            return false;
        }
        self.removeToast(toast.item);
        return true;
    }
    pub fn onWindowFocus(self: *NotificationsToasts, focused: bool) void {
        self.window_focused = focused;
        if (!focused) return;
        const now = time.milliTimestamp();
        for (self.toasts.items) |toast| if (toast.waiting_for_focus) {
            toast.waiting_for_focus = false;
            toast.timer.schedule(now + timeout(toast.item));
        };
    }
    fn findToast(self: *NotificationsToasts, item: *Item) ?usize {
        for (self.toasts.items, 0..) |toast, index| if (toast.item == item) return index;
        return null;
    }
    fn removeToast(self: *NotificationsToasts, item: *Item) void {
        self.pending.remove(item);
        const index = self.findToast(item) orelse return;
        self.removeAt(index);
        self.layoutContainer();
        self.on_did_change.fire({}) catch {};
    }
    fn removeAt(self: *NotificationsToasts, index: usize) void {
        const toast = self.toasts.orderedRemove(index);
        toast.timer.schedule(null);
        if (self.hovered == toast.item) self.hovered = null;
        if (self.focus_index) |focused| {
            if (self.toasts.items.len == 0) self.focus_index = null else if (focused >= index) self.focus_index = @min(focused -| @intFromBool(focused > index), self.toasts.items.len - 1);
        }
        if (toast.visible and !self.center_visible) toast.item.updateVisibility(false);
        toast.item.releaseView();
        self.allocator.destroy(toast);
    }
    pub fn hide(self: *NotificationsToasts) void {
        self.pending.clear();
        while (self.toasts.items.len != 0) self.removeAt(self.toasts.items.len - 1);
        self.focus_index = null;
        self.layoutContainer();
        self.on_did_change.fire({}) catch {};
    }
    pub fn update(self: *NotificationsToasts, center_visible: bool) void {
        if (self.center_visible == center_visible) return;
        self.center_visible = center_visible;
        if (center_visible) self.hide();
    }
    pub fn layout(self: *NotificationsToasts, width: usize, height: usize) void {
        self.max_width = width;
        self.max_height = height;
        self.layoutContainer();
    }
    pub fn setRowHeight(self: *NotificationsToasts, height: usize) void {
        self.row_height = height;
        self.layoutContainer();
    }
    pub fn heightFor(self: *const NotificationsToasts, item: *Item) usize {
        const text_height = if (item.expanded) (item.message.raw.len +| @max(self.max_width -| 6, 1) - 1) / @max(self.max_width -| 6, 1) else 1;
        return self.row_height +| text_height -| 1 +| @intFromBool(item.actions.primary.len != 0 or item.actions.secondary.len != 0);
    }
    fn layoutContainer(self: *NotificationsToasts) void {
        var single = self.max_height;
        // Golden ratio, as upstream's multi-toast height limit.
        var multiple = self.max_height / 1000 * 618 + ((self.max_height % 1000) * 618 + 500) / 1000;
        var visible: usize = 0;
        for (self.toasts.items) |toast| {
            const height = self.heightFor(toast.item);
            const show = visible < MAX_NOTIFICATIONS and (if (visible == 0) single >= height else multiple >= height);
            single -|= height;
            multiple -|= height;
            if (show != toast.visible) {
                toast.visible = show;
                toast.item.updateVisibility(show);
            }
            if (show) visible += 1;
        }
        const visible_now = visible != 0;
        if (self.is_visible != visible_now) {
            self.is_visible = visible_now;
            self.on_did_change_visibility.fire({}) catch {};
        }
    }
    pub fn visibleCount(self: *const NotificationsToasts) usize {
        var count: usize = 0;
        for (self.toasts.items) |toast| if (toast.visible) {
            count += 1;
        };
        return count;
    }
    pub fn focusFirst(self: *NotificationsToasts) bool {
        for (self.toasts.items, 0..) |toast, index| if (toast.visible) {
            self.focus_index = index;
            return true;
        };
        return false;
    }
    pub fn focusLast(self: *NotificationsToasts) bool {
        var index = self.toasts.items.len;
        while (index > 0) {
            index -= 1;
            if (self.toasts.items[index].visible) {
                self.focus_index = index;
                return true;
            }
        }
        return false;
    }
    pub fn focusNext(self: *NotificationsToasts) bool {
        const focused = self.focus_index orelse return self.focusFirst();
        for (self.toasts.items[focused + 1 ..], focused + 1..) |toast, index| if (toast.visible) {
            self.focus_index = index;
            return true;
        };
        return false;
    }
    pub fn focusPrevious(self: *NotificationsToasts) bool {
        var index = self.focus_index orelse return false;
        while (index > 0) {
            index -= 1;
            if (self.toasts.items[index].visible) {
                self.focus_index = index;
                return true;
            }
        }
        return false;
    }
    pub fn focusedItem(self: *const NotificationsToasts) ?*Item {
        if (self.focus_index) |index| if (index < self.toasts.items.len) return self.toasts.items[index].item;
        return null;
    }
};
