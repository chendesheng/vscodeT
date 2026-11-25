// Port of the core `src/vs/platform/notification/common/notification.ts`
// contract. `isNotificationSource` is represented by the source union.
// the notify/info/warn/error/prompt/status surface, handles, progress, the
// no-op implementations and `withSeverityPrefix` are. `error()` is named
// `err()` because `error` is a Zig keyword.
const std = @import("std");
const Severity = @import("../../../base/common/severity.zig").Severity;
const NotificationText = @import("./notificationMessage.zig").NotificationText;
const Emitter = @import("../../../base/common/event.zig").Emitter;
const LegacyExtensionLinkParsing = @import("./notificationLegacy.zig").LegacyExtensionLinkParsing;
const IAction = @import("../../../base/common/actions.zig").IAction;

pub const NotificationPriority = enum { DEFAULT, OPTIONAL, SILENT, URGENT };
pub const NotificationsFilter = enum { OFF, ERROR };

pub const NotificationMessage = union(enum) {
    text: []const u8,
    content: *const NotificationText,
    error_message: []const u8,
    error_with_actions: struct { message: []const u8, actions: []const IAction },
    cancelled,
};

pub const INotificationSourceFilter = struct { id: []const u8, label: []const u8, filter: NotificationsFilter };

pub const INotificationSource = struct {
    id: []const u8,
    label: []const u8,
};

pub const INotificationProperties = struct {
    sticky: bool = false,
};

pub const INotificationActions = struct {
    primary: []const IAction = &.{},
    secondary: []const IAction = &.{},
};

pub const INotificationProgressProperties = struct {
    infinite: bool = false,
    total: ?i64 = null,
    worked: ?i64 = null,
};

pub const INotification = struct {
    id: ?[]const u8 = null,
    severity: Severity,
    message: NotificationMessage,
    source: ?union(enum) { text: []const u8, source: INotificationSource } = null,
    actions: ?INotificationActions = null,
    progress: ?INotificationProgressProperties = null,
    sticky: bool = false,
    priority: NotificationPriority = .DEFAULT,
    legacy_extension_link_parsing: ?LegacyExtensionLinkParsing = null,
};

pub const INotificationProgress = struct {
    context: *anyopaque,
    infinite_fn: *const fn (context: *anyopaque) void,
    total_fn: *const fn (context: *anyopaque, value: i64) void,
    worked_fn: *const fn (context: *anyopaque, value: i64) void,
    done_fn: *const fn (context: *anyopaque) void,

    pub fn infinite(self: INotificationProgress) void {
        self.infinite_fn(self.context);
    }
    pub fn total(self: INotificationProgress, value: i64) void {
        self.total_fn(self.context, value);
    }
    pub fn worked(self: INotificationProgress, value: i64) void {
        self.worked_fn(self.context, value);
    }
    pub fn done(self: INotificationProgress) void {
        self.done_fn(self.context);
    }
};

pub const INotificationHandle = struct {
    context: *anyopaque,
    progress: INotificationProgress,
    update_severity_fn: *const fn (context: *anyopaque, severity: Severity) void,
    update_message_fn: *const fn (context: *anyopaque, message: NotificationMessage) void,
    update_actions_fn: *const fn (context: *anyopaque, actions: ?INotificationActions) void,
    close_fn: *const fn (context: *anyopaque) void,
    // Zig adaptation: explicit release of caller-owned handle storage.
    release_fn: ?*const fn (context: *anyopaque) void = null,
    visible_fn: ?*const fn (context: *anyopaque) bool = null,
    on_did_close: ?*Emitter(void) = null,
    on_did_change_visibility: ?*Emitter(bool) = null,

    pub fn release(self: INotificationHandle) void {
        if (self.release_fn) |call| call(self.context);
    }
    pub fn visible(self: INotificationHandle) ?bool {
        return if (self.visible_fn) |call| call(self.context) else null;
    }

    pub fn updateSeverity(self: INotificationHandle, severity: Severity) void {
        self.update_severity_fn(self.context, severity);
    }
    pub fn updateMessage(self: INotificationHandle, message: NotificationMessage) void {
        self.update_message_fn(self.context, message);
    }
    pub fn updateActions(self: INotificationHandle, actions: ?INotificationActions) void {
        self.update_actions_fn(self.context, actions);
    }
    pub fn close(self: INotificationHandle) void {
        self.close_fn(self.context);
    }
};

pub const IPromptChoice = struct {
    label: []const u8,
    keep_open: bool = false,
    is_secondary: bool = false,
    context: *anyopaque,
    run_fn: *const fn (context: *anyopaque) void,

    pub fn run(self: IPromptChoice) void {
        self.run_fn(self.context);
    }
};

pub const PromptCancel = struct {
    context: *anyopaque,
    run_fn: *const fn (*anyopaque) void,
    pub fn run(self: PromptCancel) void {
        self.run_fn(self.context);
    }
};
pub const IPromptOptions = struct {
    sticky: bool = false,
    priority: NotificationPriority = .DEFAULT,
    legacy_extension_link_parsing: ?LegacyExtensionLinkParsing = null,
    on_cancel: ?PromptCancel = null,
};

pub const IStatusHandle = struct {
    context: *anyopaque,
    close_fn: *const fn (context: *anyopaque) void,
    release_fn: ?*const fn (context: *anyopaque) void = null,

    pub fn release(self: IStatusHandle) void {
        if (self.release_fn) |call| call(self.context);
    }
    pub fn close(self: IStatusHandle) void {
        self.close_fn(self.context);
    }
};

pub const notification_service_id = @import("../../instantiation/common/instantiation.zig").ServiceIdentifier(INotificationService, "notificationService");

pub const INotificationService = struct {
    context: *anyopaque,
    notify_fn: *const fn (context: *anyopaque, notification: INotification) INotificationHandle,
    info_fn: *const fn (context: *anyopaque, message: NotificationMessage) void,
    warn_fn: *const fn (context: *anyopaque, message: NotificationMessage) void,
    error_fn: *const fn (context: *anyopaque, message: NotificationMessage) void,
    prompt_fn: *const fn (context: *anyopaque, severity: Severity, message: NotificationMessage, choices: []const IPromptChoice, options: ?IPromptOptions) INotificationHandle,
    status_fn: *const fn (context: *anyopaque, message: NotificationMessage, options: ?IStatusMessageOptions) IStatusHandle,

    pub fn notify(self: INotificationService, notification: INotification) INotificationHandle {
        return self.notify_fn(self.context, notification);
    }
    pub fn info(self: INotificationService, message: NotificationMessage) void {
        self.info_fn(self.context, message);
    }
    pub fn warn(self: INotificationService, message: NotificationMessage) void {
        self.warn_fn(self.context, message);
    }
    pub fn err(self: INotificationService, message: NotificationMessage) void {
        self.error_fn(self.context, message);
    }
    pub fn prompt(
        self: INotificationService,
        severity: Severity,
        message: NotificationMessage,
        choices: []const IPromptChoice,
        options: ?IPromptOptions,
    ) INotificationHandle {
        return self.prompt_fn(self.context, severity, message, choices, options);
    }
    pub fn status(self: INotificationService, message: NotificationMessage, options: ?IStatusMessageOptions) IStatusHandle {
        return self.status_fn(self.context, message, options);
    }
};

pub const IStatusMessageOptions = struct {
    show_after: ?i64 = null,
    hide_after: ?i64 = null,
};

pub const NoOpProgress = struct {
    fn noInfinite(_: *anyopaque) void {}
    fn noNumber(_: *anyopaque, _: i64) void {}

    pub fn interface(self: *NoOpProgress) INotificationProgress {
        return .{
            .context = self,
            .infinite_fn = noInfinite,
            .total_fn = noNumber,
            .worked_fn = noNumber,
            .done_fn = noInfinite,
        };
    }
};

pub const NoOpNotification = struct {
    progress: NoOpProgress = .{},

    pub fn interface(self: *NoOpNotification) INotificationHandle {
        return .{
            .context = self,
            .progress = self.progress.interface(),
            .update_severity_fn = noSeverity,
            .update_message_fn = noMessage,
            .update_actions_fn = noActions,
            .close_fn = noClose,
        };
    }

    fn noSeverity(_: *anyopaque, _: Severity) void {}
    fn noMessage(_: *anyopaque, _: NotificationMessage) void {}
    fn noActions(_: *anyopaque, _: ?INotificationActions) void {}
    fn noClose(_: *anyopaque) void {}
};

pub fn withSeverityPrefix(allocator: std.mem.Allocator, label: []const u8, severity: Severity) ![]u8 {
    return switch (severity) {
        .Error => std.fmt.allocPrint(allocator, "Error: {s}", .{label}),
        .Warning => std.fmt.allocPrint(allocator, "Warning: {s}", .{label}),
        else => std.fmt.allocPrint(allocator, "Info: {s}", .{label}),
    };
}

test "no-op notification accepts all updates" {
    var handle = NoOpNotification{};
    var iface = handle.interface();
    iface.updateSeverity(.Error);
    iface.updateMessage(.{ .text = "message" });
    iface.updateActions(null);
    iface.progress.infinite();
    iface.progress.total(2);
    iface.progress.worked(1);
    iface.progress.done();
    iface.close();
}

test "severity prefixes match the accessibility labels" {
    const allocator = std.testing.allocator;
    const error_text = try withSeverityPrefix(allocator, "Failed", .Error);
    defer allocator.free(error_text);
    try std.testing.expectEqualStrings("Error: Failed", error_text);

    const warning_text = try withSeverityPrefix(allocator, "Careful", .Warning);
    defer allocator.free(warning_text);
    try std.testing.expectEqualStrings("Warning: Careful", warning_text);

    const info_text = try withSeverityPrefix(allocator, "Hello", .Info);
    defer allocator.free(info_text);
    try std.testing.expectEqualStrings("Info: Hello", info_text);
}
