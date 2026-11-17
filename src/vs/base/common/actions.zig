// Port of the portable parts of `src/vs/base/common/actions.ts`.
//
// Terminal adaptations:
// - `IAction` is an interface struct (context + vtable), matching the
//   repository's `I*` convention. Getters are used instead of JS properties;
//   label/tooltip/enabled/checked setters are optional vtable entries.
// - `run` takes an opaque event/data pointer and returns an error instead of a
//   promise. `ActionRunner` fires before/after events synchronously and records
//   the error.
// - `Separator.join` is not ported: it needs owned separator storage, and the
//   menu service concatenates lists itself (documented in the actions port).
const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("event.zig").Emitter;
const platform = @import("platform.zig");

pub const ITelemetryData = struct {
    from: ?[]const u8 = null,
    target: ?[]const u8 = null,
};

pub const IAction = struct {
    context: *anyopaque,
    get_id: *const fn (context: *anyopaque) []const u8,
    get_label: *const fn (context: *anyopaque) []const u8,
    get_tooltip: *const fn (context: *anyopaque) []const u8,
    get_class: *const fn (context: *anyopaque) ?[]const u8,
    get_enabled: *const fn (context: *anyopaque) bool,
    get_checked: *const fn (context: *anyopaque) ?bool,
    set_enabled: ?*const fn (context: *anyopaque, enabled: bool) void = null,
    set_checked: ?*const fn (context: *anyopaque, checked: ?bool) void = null,
    alt: ?*const IAction = null,
    run: *const fn (context: *anyopaque, event: ?*const anyopaque) anyerror!void,

    pub fn id(self: IAction) []const u8 {
        return self.get_id(self.context);
    }

    pub fn label(self: IAction) []const u8 {
        return self.get_label(self.context);
    }

    pub fn tooltip(self: IAction) []const u8 {
        return self.get_tooltip(self.context);
    }

    pub fn cssClass(self: IAction) ?[]const u8 {
        return self.get_class(self.context);
    }

    pub fn enabled(self: IAction) bool {
        return self.get_enabled(self.context);
    }

    pub fn checked(self: IAction) ?bool {
        return self.get_checked(self.context);
    }

    pub fn execute(self: IAction, event: ?*const anyopaque) anyerror!void {
        return self.run(self.context, event);
    }
};

/// Upstream `getActionForAltMode`.
pub fn getActionForAltMode(action: IAction, alt_key: bool, shift_key: bool) IAction {
    const use_alternative = alt_key or ((platform.isWindows() or platform.isLinux()) and shift_key);
    if (use_alternative and action.enabled() and action.alt != null and action.alt.?.enabled()) {
        return action.alt.?.*;
    }
    return action;
}

pub const ActionChangeEvent = union(enum) {
    label: []const u8,
    tooltip: []const u8,
    css_class: ?[]const u8,
    enabled: bool,
    checked: ?bool,
};

pub const ActionCallback = *const fn (context: *anyopaque, event: ?*const anyopaque) anyerror!void;

/// Upstream `Action`.
pub const Action = struct {
    allocator: Allocator,
    id: []const u8,
    label: []const u8,
    tooltip_text: []const u8 = "",
    css_class: ?[]const u8 = null,
    enabled_state: bool = true,
    checked_state: ?bool = null,
    alt: ?*const IAction = null,
    callback: ?ActionCallback = null,
    callback_context: *anyopaque = undefined,
    on_did_change: Emitter(ActionChangeEvent),

    pub fn init(
        allocator: Allocator,
        id: []const u8,
        label: []const u8,
        css_class: ?[]const u8,
        enabled: bool,
        callback: ?ActionCallback,
        callback_context: *anyopaque,
    ) Action {
        return .{
            .allocator = allocator,
            .id = id,
            .label = label,
            .css_class = css_class,
            .enabled_state = enabled,
            .callback = callback,
            .callback_context = callback_context,
            .on_did_change = Emitter(ActionChangeEvent).init(allocator),
        };
    }

    pub fn deinit(self: *Action) void {
        self.on_did_change.deinit();
    }

    pub fn interface(self: *Action) IAction {
        return .{
            .context = self,
            .get_id = getId,
            .get_label = getLabel,
            .get_tooltip = getTooltip,
            .get_class = getClass,
            .get_enabled = getEnabled,
            .get_checked = getChecked,
            .set_enabled = setEnabledFn,
            .set_checked = setCheckedFn,
            .alt = self.alt,
            .run = run,
        };
    }

    pub fn setLabel(self: *Action, value: []const u8) void {
        if (!std.mem.eql(u8, self.label, value)) {
            self.label = value;
            self.on_did_change.fire(.{ .label = value }) catch {};
        }
    }

    pub fn setTooltip(self: *Action, value: []const u8) void {
        if (!std.mem.eql(u8, self.tooltip_text, value)) {
            self.tooltip_text = value;
            self.on_did_change.fire(.{ .tooltip = value }) catch {};
        }
    }

    pub fn setEnabled(self: *Action, value: bool) void {
        if (self.enabled_state != value) {
            self.enabled_state = value;
            self.on_did_change.fire(.{ .enabled = value }) catch {};
        }
    }

    pub fn setChecked(self: *Action, value: ?bool) void {
        if (self.checked_state != value) {
            self.checked_state = value;
            self.on_did_change.fire(.{ .checked = value }) catch {};
        }
    }

    fn getId(context: *anyopaque) []const u8 {
        const self: *Action = @ptrCast(@alignCast(context));
        return self.id;
    }

    fn getLabel(context: *anyopaque) []const u8 {
        const self: *Action = @ptrCast(@alignCast(context));
        return self.label;
    }

    fn getTooltip(context: *anyopaque) []const u8 {
        const self: *Action = @ptrCast(@alignCast(context));
        return self.tooltip_text;
    }

    fn getClass(context: *anyopaque) ?[]const u8 {
        const self: *Action = @ptrCast(@alignCast(context));
        return self.css_class;
    }

    fn getEnabled(context: *anyopaque) bool {
        const self: *Action = @ptrCast(@alignCast(context));
        return self.enabled_state;
    }

    fn getChecked(context: *anyopaque) ?bool {
        const self: *Action = @ptrCast(@alignCast(context));
        return self.checked_state;
    }

    fn setEnabledFn(context: *anyopaque, value: bool) void {
        const self: *Action = @ptrCast(@alignCast(context));
        self.setEnabled(value);
    }

    fn setCheckedFn(context: *anyopaque, value: ?bool) void {
        const self: *Action = @ptrCast(@alignCast(context));
        self.setChecked(value);
    }

    fn run(context: *anyopaque, event: ?*const anyopaque) anyerror!void {
        const self: *Action = @ptrCast(@alignCast(context));
        if (self.callback) |callback| {
            return callback(self.callback_context, event);
        }
    }
};

pub const RunEvent = struct {
    action: IAction,
    error_value: ?anyerror = null,
};

/// Upstream `ActionRunner`. Events are synchronous (no promise/await).
pub const ActionRunner = struct {
    allocator: Allocator,
    on_will_run: Emitter(RunEvent),
    on_did_run: Emitter(RunEvent),

    pub fn init(allocator: Allocator) ActionRunner {
        return .{
            .allocator = allocator,
            .on_will_run = Emitter(RunEvent).init(allocator),
            .on_did_run = Emitter(RunEvent).init(allocator),
        };
    }

    pub fn deinit(self: *ActionRunner) void {
        self.on_will_run.deinit();
        self.on_did_run.deinit();
    }

    pub fn run(self: *ActionRunner, action: IAction, event: ?*const anyopaque) !void {
        if (!action.enabled()) return;

        try self.on_will_run.fire(.{ .action = action });

        var error_value: ?anyerror = null;
        action.execute(event) catch |err| {
            error_value = err;
        };

        self.on_did_run.fire(.{ .action = action, .error_value = error_value }) catch {};
    }
};

/// A separator, optionally with a section label.
pub const Separator = struct {
    label_text: ?[]const u8 = null,

    pub fn interface(self: *Separator) IAction {
        return .{
            .context = self,
            .get_id = getId,
            .get_label = getLabel,
            .get_tooltip = getTooltip,
            .get_class = getClass,
            .get_enabled = getEnabled,
            .get_checked = getChecked,
            .run = run,
        };
    }

    fn getId(_: *anyopaque) []const u8 {
        return "sep";
    }

    fn getLabel(context: *anyopaque) []const u8 {
        const self: *Separator = @ptrCast(@alignCast(context));
        return self.label_text orelse "";
    }

    fn getTooltip(_: *anyopaque) []const u8 {
        return "";
    }

    fn getClass(_: *anyopaque) ?[]const u8 {
        return "separator";
    }

    fn getEnabled(_: *anyopaque) bool {
        return false;
    }

    fn getChecked(_: *anyopaque) ?bool {
        return null;
    }

    fn run(_: *anyopaque, _: ?*const anyopaque) anyerror!void {}
};

/// A submenu rendered as a single action that expands to `actions`.
pub const SubmenuAction = struct {
    id: []const u8 = "submenu",
    label: []const u8,
    actions: []const IAction,

    pub fn interface(self: *SubmenuAction) IAction {
        return .{
            .context = self,
            .get_id = getId,
            .get_label = getLabel,
            .get_tooltip = getTooltip,
            .get_class = getClass,
            .get_enabled = getEnabled,
            .get_checked = getChecked,
            .run = run,
        };
    }

    fn getId(context: *anyopaque) []const u8 {
        const self: *SubmenuAction = @ptrCast(@alignCast(context));
        return self.id;
    }

    fn getLabel(context: *anyopaque) []const u8 {
        const self: *SubmenuAction = @ptrCast(@alignCast(context));
        return self.label;
    }

    fn getTooltip(_: *anyopaque) []const u8 {
        return "";
    }

    fn getClass(_: *anyopaque) ?[]const u8 {
        return null;
    }

    fn getEnabled(_: *anyopaque) bool {
        return true;
    }

    fn getChecked(_: *anyopaque) ?bool {
        return null;
    }

    fn run(_: *anyopaque, _: ?*const anyopaque) anyerror!void {}
};

/// The disabled "No Actions" submenu entry.
pub const EmptySubmenuAction = struct {
    inner: Action,

    pub fn init(allocator: Allocator) EmptySubmenuAction {
        return .{ .inner = Action.init(allocator, "empty", "No Actions", null, false, null, undefined) };
    }

    pub fn deinit(self: *EmptySubmenuAction) void {
        self.inner.deinit();
    }

    pub fn interface(self: *EmptySubmenuAction) IAction {
        return self.inner.interface();
    }
};

pub const ToActionProps = struct {
    id: []const u8,
    label: []const u8 = "",
    tooltip: ?[]const u8 = null,
    enabled: bool = true,
    checked: ?bool = null,
    css_class: ?[]const u8 = null,
    alt: ?*const IAction = null,
    callback: ?ActionCallback = null,
    callback_context: *anyopaque = undefined,
};

/// Upstream `toAction`.
pub fn toAction(allocator: Allocator, props: ToActionProps) !Action {
    var action = Action.init(allocator, props.id, props.label, props.css_class, props.enabled, props.callback, props.callback_context);
    action.tooltip_text = props.tooltip orelse "";
    action.checked_state = props.checked;
    action.alt = props.alt;
    return action;
}

test "Action setters fire change events" {
    const allocator = std.testing.allocator;
    var action = Action.init(allocator, "a", "Label", null, true, null, undefined);
    defer action.deinit();

    var changes: usize = 0;
    try action.on_did_change.event(&changes, struct {
        fn callback(_: ActionChangeEvent, count: *usize) !void {
            count.* += 1;
        }
    }.callback);

    action.setLabel("Other");
    action.setTooltip("Tip");
    action.setEnabled(false);
    action.setChecked(true);
    action.setLabel("Other"); // unchanged
    try std.testing.expectEqual(@as(usize, 4), changes);

    const iface = action.interface();
    try std.testing.expectEqualStrings("Other", iface.label());
    try std.testing.expect(!iface.enabled());
    try std.testing.expect(iface.checked().?);
}

test "ActionRunner fires will/did events and records errors" {
    const allocator = std.testing.allocator;
    const Callback = struct {
        should_fail: bool = false,
        fn cb(context: *anyopaque, _: ?*const anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.should_fail) return error.Failed;
        }
    };
    var action_callback = Callback{ .should_fail = true };
    var action = Action.init(allocator, "a", "A", null, true, Callback.cb, &action_callback);
    defer action.deinit();

    var runner = ActionRunner.init(allocator);
    defer runner.deinit();

    var will: usize = 0;
    var did: usize = 0;
    var did_error: ?anyerror = null;
    try runner.on_will_run.event(&will, struct {
        fn callback(_: RunEvent, count: *usize) !void {
            count.* += 1;
        }
    }.callback);
    try runner.on_did_run.event(&did_error, struct {
        fn callback(event: RunEvent, error_ptr: *?anyerror) !void {
            error_ptr.* = event.error_value;
        }
    }.callback);
    try runner.on_did_run.event(&did, struct {
        fn callback(_: RunEvent, count: *usize) !void {
            count.* += 1;
        }
    }.callback);

    try runner.run(action.interface(), null);
    try std.testing.expectEqual(@as(usize, 1), will);
    try std.testing.expectEqual(@as(usize, 1), did);
    try std.testing.expect(did_error.? == error.Failed);

    action.setEnabled(false);
    try runner.run(action.interface(), null);
    try std.testing.expectEqual(@as(usize, 1), will);
}

test "separator and empty submenu interfaces" {
    var separator = Separator{ .label_text = "Group" };
    const separator_action = separator.interface();
    try std.testing.expectEqualStrings("sep", separator_action.id());
    try std.testing.expectEqualStrings("Group", separator_action.label());
    try std.testing.expect(!separator_action.enabled());

    const allocator = std.testing.allocator;
    var empty = EmptySubmenuAction.init(allocator);
    defer empty.deinit();
    try std.testing.expectEqualStrings("No Actions", empty.interface().label());
    try std.testing.expect(!empty.interface().enabled());
}

test "getActionForAltMode prefers the alternative when enabled" {
    const allocator = std.testing.allocator;
    var alt = Action.init(allocator, "alt", "Alt", null, true, null, undefined);
    defer alt.deinit();
    var primary = Action.init(allocator, "primary", "Primary", null, true, null, undefined);
    defer primary.deinit();
    var alt_interface = alt.interface();
    primary.alt = &alt_interface;

    try std.testing.expectEqualStrings("alt", getActionForAltMode(primary.interface(), true, false).id());
    try std.testing.expectEqualStrings("primary", getActionForAltMode(primary.interface(), false, false).id());

    alt.setEnabled(false);
    try std.testing.expectEqualStrings("primary", getActionForAltMode(primary.interface(), true, false).id());
}
