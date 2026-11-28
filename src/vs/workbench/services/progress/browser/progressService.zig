// Port of `src/vs/workbench/services/progress/browser/progressService.ts`.
// A deadline task replaces browser timers. The Window and Notification
// locations use the existing status-bar and notification services; named
// view/pane and dialog progress locations are not yet ported.
const std = @import("std");
const progress = @import("../../../../platform/progress/common/progress.zig");
const notifications = @import("../../../../platform/notification/common/notification.zig");
const actions = @import("../../../../base/common/actions.zig");
const dispatch = @import("../../../../base/common/windowDispatch.zig");
const time = @import("../../../../base/common/timeCompat.zig");
const statusbar = @import("../../../browser/parts/statusbar/statusbarPart.zig");
const Allocator = std.mem.Allocator;

pub const ProgressService = struct {
    allocator: Allocator,
    notifications: notifications.INotificationService,
    statusbar: *statusbar.StatusbarService,
    window: *dispatch.Queue,
    changed: Changed,
    tasks: std.ArrayList(*Task) = .empty,
    window_progress: ?statusbar.EntryAccessor = null,

    pub const Changed = struct {
        context: *anyopaque,
        run: *const fn (*anyopaque) void,
    };

    pub const Cancel = struct {
        context: *anyopaque,
        run: *const fn (*anyopaque) void,
    };

    pub const Options = struct {
        location: progress.ProgressLocation,
        title: ?[]const u8 = null,
        source: ?notifications.INotificationSource = null,
        cancellable: bool = false,
        urgent: bool = false,
    };

    pub fn deinit(self: *ProgressService) void {
        while (self.tasks.items.len > 0) self.tasks.items[self.tasks.items.len - 1].dispose();
        self.tasks.deinit(self.allocator);
    }

    pub fn start(self: *ProgressService, options: Options, cancel: ?Cancel) !*Task {
        switch (options.location) {
            .Window, .Notification => {},
            else => return error.UnsupportedProgressLocation,
        }
        const task = try self.allocator.create(Task);
        errdefer self.allocator.destroy(task);
        task.* = .{
            .service = self,
            .arena = .init(self.allocator),
            .location = options.location,
            .cancel = if (options.cancellable) cancel else null,
            .urgent = options.urgent,
            .started = time.milliTimestamp(self.window.io),
        };
        errdefer task.arena.deinit();
        const a = task.arena.allocator();
        if (options.title) |title| task.title = try a.dupe(u8, title);
        if (options.source) |source| task.source = .{ .id = try a.dupe(u8, source.id), .label = try a.dupe(u8, source.label) };
        task.timer = .{ .queue = self.window, .context = task, .run = onTimer };
        task.cancel_action = actions.Action.init(self.allocator, "progress.cancel", "Cancel", null, true, cancelAction, task);
        errdefer task.cancel_action.deinit();
        try self.tasks.append(self.allocator, task);
        errdefer _ = self.tasks.pop();
        try task.updateMessage(null);
        if (task.location == .Window) {
            task.timer.schedule(task.started + 150);
        } else {
            task.showNotification();
        }
        return task;
    }

    fn onTimer(context: *anyopaque, _: i64, _: bool) bool {
        const task: *Task = @ptrCast(@alignCast(context));
        if (task.ended) {
            task.dispose();
        } else {
            task.showNotification();
        }
        return true;
    }

    fn cancelAction(context: *anyopaque, _: ?*const anyopaque) !void {
        const task: *Task = @ptrCast(@alignCast(context));
        if (task.cancel) |cancel| cancel.run(cancel.context);
        task.cancel = null; // cancellation is idempotent until the host ends
        task.cancel_action.enabled_state = false;
    }

    fn updateWindowProgress(self: *ProgressService) void {
        // A stack, newest visible task first. Hidden notifications retain a
        // window entry until they become visible or finish.
        var index = self.tasks.items.len;
        while (index > 0) {
            index -= 1;
            const task = self.tasks.items[index];
            if (!task.window_visible or task.text.len == 0) continue;
            const entry: @import("../../statusbar/browser/statusbar.zig").StatusbarEntry = .{
                .name = "Progress Message",
                .text = task.text,
                .aria_label = task.text,
                .tooltip = task.text,
                .show_progress = .loading,
                .command = .{ .id = "notifications.showList" },
            };
            if (self.window_progress) |accessor| {
                accessor.update(entry);
            } else {
                self.window_progress = self.statusbar.addEntry(entry, "status.progress", .left, .{ .number = -std.math.floatMax(f64) }) catch null;
            }
            self.changed.run(self.changed.context);
            return;
        }
        if (self.window_progress) |accessor| accessor.dispose();
        self.window_progress = null;
        self.changed.run(self.changed.context);
    }

    pub const Task = struct {
        service: *ProgressService,
        arena: std.heap.ArenaAllocator,
        location: progress.ProgressLocation,
        title: ?[]const u8 = null,
        source: ?notifications.INotificationSource = null,
        text: []const u8 = "",
        text_owned: ?[]u8 = null,
        notification: ?notifications.INotificationHandle = null,
        visibility_listener: ?usize = null,
        close_listener: ?usize = null,
        window_visible: bool = false,
        urgent: bool,
        cancel: ?Cancel,
        cancel_action: actions.Action = undefined,
        timer: dispatch.Task = .{},
        started: i64,
        ended: bool = false,
        increment: ?i64 = null,

        fn updateMessage(self: *Task, message: ?[]const u8) !void {
            const a = self.service.allocator;
            const title = self.title orelse "";
            const detail = message orelse "";
            const old = self.text_owned;
            const text = if (title.len > 0 and detail.len > 0)
                try std.fmt.allocPrint(a, "{s}: {s}", .{ title, detail })
            else
                try a.dupe(u8, if (title.len > 0) title else detail);
            self.text_owned = text;
            self.text = text;
            if (self.notification) |handle| handle.updateMessage(.{ .text = text });
            self.service.updateWindowProgress();
            if (old) |s| a.free(s);
        }

        fn showNotification(self: *Task) void {
            if (self.ended or self.notification != null or self.text.len == 0) return;
            var primary = [1]actions.IAction{self.cancel_action.interface()};
            const opts: notifications.INotification = .{
                .severity = .Info,
                .message = .{ .text = self.text },
                .source = if (self.source) |source| .{ .source = source } else null,
                .actions = if (self.cancel != null) .{ .primary = &primary } else null,
                .progress = if (self.increment) |increment| .{ .total = 100, .worked = increment } else .{ .infinite = true },
                .priority = if (self.urgent) .URGENT else if (self.location == .Window or self.service.notifications.getFilter(null) == .ERROR or self.service.notifications.getFilter(self.source) == .ERROR) .SILENT else .DEFAULT,
                .legacy_extension_link_parsing = .legacyExtensionLinkParsing,
            };
            self.notification = self.service.notifications.notify(opts);
            const handle = self.notification.?;
            if (handle.on_did_change_visibility) |emitter| self.visibility_listener = emitter.listen(self, onVisibility) catch null;
            if (handle.on_did_close) |emitter| self.close_listener = emitter.listen(self, onClosed) catch null;
            self.window_visible = !(handle.visible() orelse false);
            self.service.updateWindowProgress();
        }

        fn onVisibility(visible: bool, self: *Task) !void {
            self.window_visible = !visible and !self.ended;
            self.service.updateWindowProgress();
        }

        fn onClosed(_: void, self: *Task) !void {
            self.window_visible = false;
            self.service.updateWindowProgress();
        }

        pub fn report(self: *Task, message: ?[]const u8, increment: ?i64) !void {
            if (self.ended) return;
            try self.updateMessage(message);
            self.increment = if (increment) |i| if (i >= 0) i else null else null;
            if (self.notification) |handle| {
                if (self.increment) |value| {
                    handle.progress.total(100);
                    handle.progress.worked(value);
                } else handle.progress.infinite();
            } else if (self.location == .Notification or time.milliTimestamp(self.service.window.io) >= self.started + 150) self.showNotification();
        }

        pub fn end(self: *Task) void {
            self.ended = true;
            self.cancel = null;
            self.timer.schedule(null);
            // Delayed window progress must not flash for a short operation.
            // Notification progress without a delay remains shown for 800ms.
            if (self.location == .Notification and self.notification != null and time.milliTimestamp(self.service.window.io) < self.started + 800) {
                self.timer.schedule(self.started + 800);
                return;
            }
            self.dispose();
        }

        pub fn dispose(self: *Task) void {
            const service = self.service;
            self.timer.schedule(null);
            if (self.notification) |handle| {
                if (self.visibility_listener) |id| if (handle.on_did_change_visibility) |emitter| emitter.unlisten(id);
                if (self.close_listener) |id| if (handle.on_did_close) |emitter| emitter.unlisten(id);
                handle.progress.done();
                handle.close();
                handle.release();
            }
            for (service.tasks.items, 0..) |task, i| if (task == self) {
                _ = service.tasks.orderedRemove(i);
                break;
            };
            service.updateWindowProgress();
            if (self.text_owned) |text| service.allocator.free(text);
            self.cancel_action.deinit();
            self.arena.deinit();
            service.allocator.destroy(self);
        }
    };
};
