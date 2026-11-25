// Port of `src/vs/workbench/test/browser/notificationsToasts.test.ts`.
// The window dispatch queue advances the animation-frame boundary; cell row
// counts replace DOM querySelectorAll and layout measurement.
const std = @import("std");
const t = std.testing;
const a = t.allocator;
const notifications = @import("../../common/notifications.zig");
const Toasts = @import("../../browser/parts/notifications/notificationsToasts.zig").NotificationsToasts;
const Queue = @import("../../../base/common/windowDispatch.zig").Queue;
const time = @import("../../../base/common/timeCompat.zig");

const Harness = struct {
    model: notifications.NotificationsModel,
    queue: Queue,
    toasts: *Toasts,
    fn init(self: *Harness) !void {
        self.model = .init(a);
        errdefer self.model.deinit();
        self.queue = .{ .io = t.io };
        self.toasts = try Toasts.create(a, &self.model, &self.queue);
        errdefer self.toasts.deinit();
        try self.toasts.start();
        self.toasts.layout(56, 1000);
    }
    fn deinit(self: *Harness) void {
        self.toasts.deinit();
        self.model.deinit();
    }
    fn flush(self: *Harness) void {
        _ = self.queue.dispatch(time.milliTimestamp() + 1);
    }
};

test "NotificationsToasts: shows one toast for rapidly added duplicate notifications" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    for (0..15) |_| (try harness.model.addNotification(.{ .severity = .Error, .message = .{ .text = "Hello!" } })).release();
    try t.expectEqual(@as(usize, 1), harness.model.notifications.items.len);
    try t.expectEqual(@as(usize, 0), harness.toasts.visibleCount());
    harness.flush();
    try t.expectEqual(@as(usize, 1), harness.toasts.visibleCount());
    try t.expect(harness.toasts.is_visible);
}

test "NotificationsToasts: limits rapidly added distinct notification toasts" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    for (0..15) |index| {
        var buf: [32]u8 = undefined;
        const message = try std.fmt.bufPrint(&buf, "Message {d}", .{index});
        (try harness.model.addNotification(.{ .severity = .Error, .message = .{ .text = message } })).release();
    }
    harness.flush();
    try t.expectEqual(@as(usize, 15), harness.model.notifications.items.len);
    try t.expectEqual(@as(usize, 3), harness.toasts.visibleCount());
    try t.expect(harness.toasts.is_visible);
}

test "NotificationsToasts: does not show a pending notification removed before rendering" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    const handle = try harness.model.addNotification(.{ .severity = .Error, .message = .{ .text = "Hello!" } });
    handle.close();
    handle.release();
    harness.flush();
    try t.expectEqual(@as(usize, 0), harness.model.notifications.items.len);
    try t.expectEqual(@as(usize, 0), harness.toasts.visibleCount());
    try t.expect(!harness.toasts.is_visible);
    try t.expectEqual(@as(usize, 0), harness.model.all_items.items.len);
}

test "NotificationsToasts: recalculates visible toasts when row height changes" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    harness.toasts.setRowHeight(1);
    (try harness.model.addNotification(.{ .severity = .Error, .message = .{ .text = "First" }, .sticky = true })).release();
    (try harness.model.addNotification(.{ .severity = .Error, .message = .{ .text = "Second" }, .sticky = true })).release();
    harness.flush();
    harness.toasts.layout(56, 3);
    try t.expectEqual(@as(usize, 2), harness.toasts.visibleCount());
    harness.toasts.setRowHeight(2);
    try t.expectEqual(@as(usize, 1), harness.toasts.visibleCount());
    harness.toasts.setRowHeight(1);
    try t.expectEqual(@as(usize, 2), harness.toasts.visibleCount());
}

test "NotificationsToasts: purge is a deadline event, not a model scan" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    (try harness.model.addNotification(.{ .severity = .Info, .message = .{ .text = "Hello!" } })).release();
    harness.flush();
    const toast = harness.toasts.toasts.items[0];
    const due = toast.timer.at.?;
    try t.expect(!harness.queue.dispatch(due - 1));
    try t.expect(harness.queue.dispatch(due));
    try t.expectEqual(@as(usize, 0), harness.toasts.visibleCount());
    try t.expectEqual(@as(usize, 1), harness.model.notifications.items.len);
}
