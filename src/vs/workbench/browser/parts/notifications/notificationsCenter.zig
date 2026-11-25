// Port of `src/vs/workbench/browser/parts/notifications/notificationsCenter.ts`.
// The notification list retains keyboard selection and scroll in terminal rows.
// Browser DOM classes, title-bar offset and accessibility signal plumbing are
// replaced by the terminal overlay and terminal input boundary.
const std = @import("std");
const model_mod = @import("../../../common/notifications.zig");
const Item = model_mod.NotificationViewItem;
const Emitter = @import("../../../../base/common/event.zig").Emitter;

pub const NotificationsCenter = struct {
    allocator: std.mem.Allocator,
    model: *model_mod.NotificationsModel,
    notification_listener: usize,
    filter_listener: usize,
    is_visible: bool = false,
    focus_index: usize = 0,
    scroll_index: usize = 0,
    on_did_change_visibility: Emitter(void),
    on_did_change: Emitter(void),

    pub fn create(allocator: std.mem.Allocator, model: *model_mod.NotificationsModel) !*NotificationsCenter {
        const self = try allocator.create(NotificationsCenter);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .model = model, .notification_listener = undefined, .filter_listener = undefined, .on_did_change_visibility = .init(allocator), .on_did_change = .init(allocator) };
        self.notification_listener = try model.on_did_change_notification.listen(self, notificationChanged);
        errdefer model.on_did_change_notification.unlisten(self.notification_listener);
        self.filter_listener = try model.on_did_change_filter.listen(self, filterChanged);
        return self;
    }
    pub fn deinit(self: *NotificationsCenter) void {
        self.model.on_did_change_notification.unlisten(self.notification_listener);
        self.model.on_did_change_filter.unlisten(self.filter_listener);
        self.hide();
        self.on_did_change_visibility.deinit();
        self.on_did_change.deinit();
        self.allocator.destroy(self);
    }
    pub fn show(self: *NotificationsCenter) void {
        self.focus_index = 0;
        self.scroll_index = 0;
        if (self.is_visible) {
            self.on_did_change.fire({}) catch {};
            return;
        }
        self.is_visible = true;
        for (self.model.notifications.items) |item| item.updateVisibility(true);
        self.on_did_change_visibility.fire({}) catch {};
        self.on_did_change.fire({}) catch {};
    }
    pub fn hide(self: *NotificationsCenter) void {
        if (!self.is_visible) return;
        self.is_visible = false;
        for (self.model.notifications.items) |item| item.updateVisibility(false);
        self.on_did_change_visibility.fire({}) catch {};
        self.on_did_change.fire({}) catch {};
    }
    fn notificationChanged(event: model_mod.INotificationChangeEvent, self: *NotificationsCenter) !void {
        if (!self.is_visible) return;
        switch (event.kind) {
            .ADD => {
                event.item.updateVisibility(true);
                if (self.model.notifications.items.len > 1 and event.index <= self.focus_index) self.focus_index += 1;
                if (self.scroll_index != 0 and event.index <= self.scroll_index) self.scroll_index += 1;
            },
            .REMOVE => {
                event.item.updateVisibility(false);
                if (event.index < self.focus_index) self.focus_index -= 1;
                if (event.index < self.scroll_index) self.scroll_index -= 1;
                self.focus_index = @min(self.focus_index, self.model.notifications.items.len -| 1);
                self.scroll_index = @min(self.scroll_index, self.model.notifications.items.len -| 1);
                if (self.model.notifications.items.len == 0) self.hide();
            },
            else => {},
        }
        try self.on_did_change.fire({});
    }
    fn filterChanged(event: model_mod.FilterChange, self: *NotificationsCenter) !void {
        if (event.global == .ERROR) self.hide();
    }
    pub fn clearAll(self: *NotificationsCenter) void {
        self.hide();
        var index = self.model.notifications.items.len;
        while (index > 0) {
            index -= 1;
            if (index >= self.model.notifications.items.len) continue;
            const item = self.model.notifications.items[index];
            if (!item.hasActiveProgress()) item.close();
        }
    }
    pub fn focusedItem(self: *const NotificationsCenter) ?*Item {
        if (!self.is_visible or self.focus_index >= self.model.notifications.items.len) return null;
        return self.model.notifications.items[self.focus_index];
    }
    pub fn focusNext(self: *NotificationsCenter) void {
        self.focus_index = @min(self.focus_index + 1, self.model.notifications.items.len -| 1);
        self.on_did_change.fire({}) catch {};
    }
    pub fn focusPrevious(self: *NotificationsCenter) void {
        self.focus_index -|= 1;
        self.scroll_index = @min(self.scroll_index, self.focus_index);
        self.on_did_change.fire({}) catch {};
    }
};
