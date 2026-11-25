// Port of `src/vs/workbench/browser/parts/notifications/notificationsStatus.ts`.
// Status entry accessors and window deadlines replace DOM/JS timers. The
// terminal has no title-bar status region, so top-right keeps the bell at the
// right edge of its status bar rather than making notifications unreachable.
const std = @import("std");
const model_mod = @import("../../../common/notifications.zig");
const service_mod = @import("../../../services/notification/common/notificationService.zig");
const statusbar_mod = @import("../statusbar/statusbarPart.zig");
const statusbar = @import("../../../services/statusbar/browser/statusbar.zig");
const queue_mod = @import("../../../../base/common/windowDispatch.zig");
const time = @import("../../../../base/common/timeCompat.zig");

pub const NotificationsStatus = struct {
    allocator: std.mem.Allocator,
    service: *service_mod.NotificationService,
    statusbar_service: *statusbar_mod.StatusbarService,
    center_visible: bool = false,
    toasts_visible: bool = false,
    new_count: usize = 0,
    position: model_mod.NotificationsPosition = .bottom_right,
    notification_listener: usize,
    status_listener: usize,
    filter_listener: usize,
    bell: ?statusbar_mod.EntryAccessor = null,
    alignment: ?statusbar.StatusbarAlignment = null,
    status_entry: ?statusbar_mod.EntryAccessor = null,
    current_status: ?*const model_mod.StatusMessageViewItem = null,
    show_task: queue_mod.Task,
    hide_task: queue_mod.Task,
    tooltip: [160]u8 = undefined,
    request_frame: *const fn (*anyopaque) void,
    frame_context: *anyopaque,

    pub fn create(allocator: std.mem.Allocator, service: *service_mod.NotificationService, bar: *statusbar_mod.StatusbarService, queue: *queue_mod.Queue, frame_context: *anyopaque, request_frame: *const fn (*anyopaque) void) !*NotificationsStatus {
        const self = try allocator.create(NotificationsStatus);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .service = service,
            .statusbar_service = bar,
            .notification_listener = undefined,
            .status_listener = undefined,
            .filter_listener = undefined,
            .show_task = .{ .queue = queue, .context = self, .run = showDeadline },
            .hide_task = .{ .queue = queue, .context = self, .run = hideDeadline },
            .request_frame = request_frame,
            .frame_context = frame_context,
        };
        self.notification_listener = try service.model.on_did_change_notification.listen(self, notificationChanged);
        errdefer service.model.on_did_change_notification.unlisten(self.notification_listener);
        self.status_listener = try service.model.on_did_change_status_message.listen(self, statusChanged);
        errdefer service.model.on_did_change_status_message.unlisten(self.status_listener);
        self.filter_listener = try service.on_did_change_filter.listen(self, filterChanged);
        errdefer service.on_did_change_filter.unlisten(self.filter_listener);
        try self.updateNotificationsCenterStatusItem();
        if (service.model.status_message) |item| self.doSetStatusMessage(item);
        return self;
    }
    pub fn deinit(self: *NotificationsStatus) void {
        self.service.model.on_did_change_notification.unlisten(self.notification_listener);
        self.service.model.on_did_change_status_message.unlisten(self.status_listener);
        self.service.on_did_change_filter.unlisten(self.filter_listener);
        self.disposeStatusMessage();
        if (self.bell) |entry| entry.dispose();
        self.allocator.destroy(self);
    }
    fn notificationChanged(event: model_mod.INotificationChangeEvent, self: *NotificationsStatus) !void {
        if (!self.center_visible) {
            if (event.kind == .ADD) self.new_count += 1 else if (event.kind == .REMOVE) self.new_count -|= 1;
        }
        try self.updateNotificationsCenterStatusItem();
    }
    fn filterChanged(_: void, self: *NotificationsStatus) !void {
        try self.updateNotificationsCenterStatusItem();
    }
    pub fn update(self: *NotificationsStatus, center_visible: bool, toasts_visible: bool) void {
        if (self.center_visible == center_visible and self.toasts_visible == toasts_visible) return;
        if (self.center_visible != center_visible) self.new_count = 0;
        self.center_visible = center_visible;
        self.toasts_visible = toasts_visible;
        self.updateNotificationsCenterStatusItem() catch {};
    }
    pub fn setPosition(self: *NotificationsStatus, position: model_mod.NotificationsPosition) void {
        if (self.position == position) return;
        self.position = position;
        self.updateNotificationsCenterStatusItem() catch {};
    }
    fn updateNotificationsCenterStatusItem(self: *NotificationsStatus) !void {
        var in_progress: usize = 0;
        if (!self.center_visible and !self.toasts_visible) for (self.service.model.notifications.items) |item| {
            if (item.hasActiveProgress()) in_progress += 1;
        };
        const unread = self.new_count != 0 or in_progress != 0;
        const blocked = self.service.getFilter(null) == .ERROR;
        const icon = if (blocked) (if (unread) "🔕•" else "🔕") else (if (unread) "🔔•" else "🔔");
        const tooltip = if (blocked) "Do Not Disturb Mode is Enabled" else try self.getTooltip(in_progress);
        const entry: statusbar.StatusbarEntry = .{ .name = "Notifications", .text = icon, .aria_label = if (blocked) "Do Not Disturb" else "Notifications", .command = .{ .id = if (self.center_visible) "notifications.hideList" else "notifications.showList" }, .tooltip = tooltip, .show_beak = self.center_visible };
        const desired: statusbar.StatusbarAlignment = if (self.position == .bottom_left) .left else .right;
        if (self.alignment != desired) {
            if (self.bell) |accessor| accessor.dispose();
            self.bell = null;
            self.alignment = desired;
        }
        if (self.bell) |accessor| accessor.update(entry) else self.bell = try self.statusbar_service.addEntry(entry, "status.notifications", desired, .{ .number = if (desired == .left) 9007199254740991 else -std.math.inf(f64) });
        self.request_frame(self.frame_context);
    }
    fn getTooltip(self: *NotificationsStatus, progress: usize) ![]const u8 {
        if (self.center_visible) return "Hide Notifications";
        if (self.service.model.notifications.items.len == 0) return "No Notifications";
        if (progress == 0) return switch (self.new_count) {
            0 => "No New Notifications",
            1 => "1 New Notification",
            else => std.fmt.bufPrint(&self.tooltip, "{d} New Notifications", .{self.new_count}),
        };
        return switch (self.new_count) {
            0 => std.fmt.bufPrint(&self.tooltip, "No New Notifications ({d} in progress)", .{progress}),
            1 => std.fmt.bufPrint(&self.tooltip, "1 New Notification ({d} in progress)", .{progress}),
            else => std.fmt.bufPrint(&self.tooltip, "{d} New Notifications ({d} in progress)", .{ self.new_count, progress }),
        };
    }
    fn statusChanged(event: model_mod.IStatusMessageChangeEvent, self: *NotificationsStatus) !void {
        switch (event.kind) {
            .ADD => self.doSetStatusMessage(event.item),
            .REMOVE => if (self.current_status == event.item) self.disposeStatusMessage(),
        }
    }
    fn doSetStatusMessage(self: *NotificationsStatus, item: *const model_mod.StatusMessageViewItem) void {
        self.disposeStatusMessage();
        self.current_status = item;
        const options = item.options;
        const now = time.milliTimestamp();
        self.show_task.schedule(now + @max(0, if (options) |value| value.show_after orelse 0 else 0));
        if (options) |value| if (value.hide_after) |hide| if (hide > 0) {
            self.hide_task.schedule(now + hide);
        };
    }
    fn disposeStatusMessage(self: *NotificationsStatus) void {
        self.show_task.schedule(null);
        self.hide_task.schedule(null);
        if (self.status_entry) |entry| entry.dispose();
        self.status_entry = null;
        self.current_status = null;
        self.request_frame(self.frame_context);
    }
    fn showDeadline(ctx: *anyopaque, _: i64, _: bool) bool {
        const self: *NotificationsStatus = @ptrCast(@alignCast(ctx));
        const item = self.current_status orelse return false;
        self.status_entry = self.statusbar_service.addEntry(.{ .name = "Status Message", .text = item.message, .aria_label = item.message }, "status.message", .left, .{ .number = -std.math.inf(f64) }) catch return false;
        self.request_frame(self.frame_context);
        return true;
    }
    fn hideDeadline(ctx: *anyopaque, _: i64, _: bool) bool {
        const self: *NotificationsStatus = @ptrCast(@alignCast(ctx));
        self.disposeStatusMessage();
        return true;
    }
};
