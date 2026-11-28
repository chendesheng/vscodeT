// Port of `src/vs/platform/quickinput/browser/quickAccess.ts`.
//
// The controller decides which provider serves the current value, creates or
// resets the picker, and forwards picker callbacks to the provider. Upstream
// also supports `pick()` promises, anchors and context keys; the TUI only
// needs `show()`.
//
// One persistent picker is reused across showings. Hiding cancels the current
// provider run but does not free the picker, so an accepted item may open
// another picker from inside its own accept callback without using freed
// memory. The next `show()` resets the picker.

const std = @import("std");
const Allocator = std.mem.Allocator;
const cancellation = @import("../../../base/common/cancellation.zig");
const CancellationTokenSource = cancellation.CancellationTokenSource;
const quick_access = @import("../common/quickAccess.zig");
const Provider = quick_access.Provider;
const Registry = quick_access.Registry;
const QuickPick = @import("./quickInput.zig").QuickPick;

pub const Presenter = struct {
    context: *anyopaque,
    show: *const fn (context: *anyopaque, picker: *QuickPick) anyerror!void,
    hide: *const fn (context: *anyopaque) void,
};

pub const ShowOptions = struct {
    /// Keep the value exactly as given, even when switching providers.
    preserve_value: bool = false,
    /// Force this provider prefix instead of resolving from the value.
    prefix: ?[]const u8 = null,
    placeholder: ?[]const u8 = null,
};

pub const QuickAccessController = struct {
    allocator: Allocator,
    registry: *Registry,
    presenter: Presenter,
    picker: QuickPick,
    cts: ?CancellationTokenSource = null,
    visible_provider: ?Provider = null,
    active_prefix: []const u8 = "",
    suppress_change: bool = false,
    error_context: ?*anyopaque = null,
    on_error: ?*const fn (context: *anyopaque, message: []const u8) void = null,

    pub fn init(
        allocator: Allocator,
        io: std.Io,
        registry: *Registry,
        presenter: Presenter,
    ) !*QuickAccessController {
        const self = try allocator.create(QuickAccessController);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .registry = registry,
            .presenter = presenter,
            .picker = QuickPick.init(allocator, io),
        };
        self.picker.on_change_context = self;
        self.picker.on_change = onPickerChanged;
        self.picker.on_accept_context = self;
        self.picker.on_accept = onPickerAccepted;
        self.picker.on_hide_context = self;
        self.picker.on_hide = onPickerHidden;
        return self;
    }

    pub fn deinit(self: *QuickAccessController) void {
        self.cancelRun();
        self.picker.deinit();
        self.allocator.destroy(self);
    }

    pub fn pickerRef(self: *QuickAccessController) *QuickPick {
        return &self.picker;
    }

    pub fn isVisible(self: *const QuickAccessController) bool {
        return self.picker.visible;
    }

    pub fn show(self: *QuickAccessController, value: []const u8, options: ShowOptions) !void {
        const lookup = options.prefix orelse value;
        const provider = self.registry.get(lookup);

        // Same provider already showing: only update the value, as upstream
        // does. The provider receives the change through the picker callback.
        if (self.picker.visible) {
            if (sameProvider(self.visible_provider, provider)) {
                if (!options.preserve_value and
                    !std.mem.eql(u8, self.picker.value.items, value))
                {
                    try self.picker.setValue(value);
                }
                if (options.placeholder) |placeholder| self.picker.setPlaceholder(placeholder);
                return;
            }
        }

        self.cancelRun();
        self.suppress_change = true;
        defer self.suppress_change = false;

        // `value` can alias `picker.value` when this is called from the
        // value-change callback, so copy it before resetting the picker.
        const value_copy = try self.allocator.dupe(u8, value);
        defer self.allocator.free(value_copy);

        self.picker.reset();
        if (value_copy.len > 0) try self.picker.value.appendSlice(value_copy);
        self.picker.setPlaceholder(options.placeholder orelse if (provider) |p| p.placeholder else "");
        self.visible_provider = provider;
        self.active_prefix = if (provider) |p| p.prefix else "";
        self.picker.page_size = 10;

        if (provider) |p| {
            var source = try CancellationTokenSource.init(self.allocator);
            errdefer source.deinit();
            const token = try source.token();
            self.cts = source;
            p.provide(p.context, &self.picker, token) catch |err| {
                self.cancelRun();
                self.visible_provider = null;
                return err;
            };
        }

        try self.picker.setValue(value_copy);
        self.picker.show();
        self.presenter.show(self.presenter.context, &self.picker) catch |err| {
            self.cancelRun();
            self.picker.hide();
            return err;
        };
    }

    pub fn hide(self: *QuickAccessController) void {
        if (!self.picker.visible) return;
        self.picker.hide();
    }

    /// Re-runs the visible provider for the current value. Used when the file
    /// index makes progress while the picker is open.
    pub fn refresh(self: *QuickAccessController) !void {
        if (!self.picker.visible) return;
        if (self.visible_provider) |provider| {
            try provider.refresh(provider.context, &self.picker);
        }
    }

    fn cancelRun(self: *QuickAccessController) void {
        if (self.cts) |*source| {
            source.cancel();
            source.deinit();
            self.cts = null;
        }
    }

    fn onPickerChanged(context: *anyopaque) void {
        const self: *QuickAccessController = @ptrCast(@alignCast(context));
        if (self.suppress_change) return;

        const value = self.picker.value.items;
        const provider = self.registry.get(value);
        if (!sameProvider(self.visible_provider, provider)) {
            self.show(value, .{ .preserve_value = true }) catch |err| self.report(err);
            return;
        }
        if (provider) |p| {
            self.picker.setBusy(false);
            p.refresh(p.context, &self.picker) catch |err| self.report(err);
        }
    }

    fn onPickerAccepted(context: *anyopaque) void {
        const self: *QuickAccessController = @ptrCast(@alignCast(context));
        if (self.visible_provider) |provider| {
            provider.accept(provider.context, &self.picker) catch |err| self.report(err);
        }
    }

    fn onPickerHidden(context: *anyopaque) void {
        const self: *QuickAccessController = @ptrCast(@alignCast(context));
        self.cancelRun();
        self.visible_provider = null;
        self.presenter.hide(self.presenter.context);
    }

    fn report(self: *QuickAccessController, err: anyerror) void {
        if (self.on_error) |on_error| {
            on_error(self.error_context orelse undefined, @errorName(err));
        }
    }
};

fn sameProvider(a: ?Provider, b: ?Provider) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.context == b.?.context and std.mem.eql(u8, a.?.prefix, b.?.prefix);
}

test "QuickAccessController: provider switching and hide" {
    const State = struct {
        provides: usize = 0,
        refreshes: usize = 0,
        accepts: usize = 0,
        hidden: usize = 0,
        picker: ?*QuickPick = null,
        fn provide(context: *anyopaque, picker: *QuickPick, _: cancellation.CancellationToken) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.provides += 1;
            self.picker = picker;
            try picker.setItems(&.{.{ .item = .{ .label = "Default" } }});
        }
        fn refresh(context: *anyopaque, _: *QuickPick) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.refreshes += 1;
        }
        fn accept(context: *anyopaque, _: *QuickPick) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.accepts += 1;
        }
        fn show(_: *anyopaque, _: *QuickPick) anyerror!void {}
        fn hide(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.hidden += 1;
        }
    };

    var presenter_state = State{};
    var provider_state = State{};
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.register(.{
        .context = &provider_state,
        .prefix = "",
        .provide = State.provide,
        .refresh = State.refresh,
        .accept = State.accept,
    });

    const controller = try QuickAccessController.init(std.testing.allocator, std.testing.io, &registry, .{
        .context = &presenter_state,
        .show = State.show,
        .hide = State.hide,
    });
    defer controller.deinit();

    try controller.show("", .{});
    try std.testing.expect(controller.isVisible());
    try std.testing.expectEqual(@as(usize, 1), provider_state.provides);
    try std.testing.expectEqualStrings("Default", controller.picker.activeItem().?.label);

    try controller.picker.setValue("d");
    try std.testing.expectEqual(@as(usize, 1), provider_state.refreshes);

    controller.picker.accept();
    try std.testing.expectEqual(@as(usize, 1), provider_state.accepts);
    controller.hide();
    try std.testing.expect(!controller.isVisible());
    try std.testing.expectEqual(@as(usize, 1), presenter_state.hidden);
}
