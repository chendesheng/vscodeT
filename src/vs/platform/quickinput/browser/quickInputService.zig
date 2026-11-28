// Port of the one-shot `pick()` flow from
// `src/vs/platform/quickinput/browser/quickInputService.ts`.
//
// The browser service owns the quick-input UI and the many input box/tree
// variants. The terminal port keeps the portable part used by workbench
// selectors: a filtered quick pick, a presenter callback for the TUI widget,
// and the "hide then accept" ordering. Free input is the terminal equivalent of
// `input()` used by Go to Line/Column; buttons, validation and tree picks are
// not ported.

const std = @import("std");
const Allocator = std.mem.Allocator;
const filters = @import("../../../base/common/filters.zig");
const quick_input = @import("../common/quickInput.zig");
const QuickPickItem = quick_input.QuickPickItem;
const picker_quick_access = @import("./pickerQuickAccess.zig");
const QuickPick = @import("./quickInput.zig").QuickPick;

pub const PickHandler = *const fn (context: *anyopaque, picker: *QuickPick) anyerror!void;

pub const PickOptions = struct {
    placeholder: []const u8 = "",
    active_id: ?[]const u8 = null,
    /// Keep the picker open with an empty list and accept the typed value.
    /// This is the quick-input prompt used by Go to Line/Column.
    allow_free_input: bool = false,
    no_results_label: ?[]const u8 = null,
    /// Called after the picker hides (accept or dismiss), so callers can free
    /// labels/descriptions they handed to `showPick`.
    cleanup: ?*const fn (context: *anyopaque) void = null,
    cleanup_context: ?*anyopaque = null,
};

pub const Presenter = struct {
    context: *anyopaque,
    show: *const fn (context: *anyopaque, picker: *QuickPick) anyerror!void,
    hide: *const fn (context: *anyopaque) void,
};

pub const QuickInputService = struct {
    allocator: Allocator,
    presenter: Presenter,
    picker: QuickPick,
    master: std.array_list.Managed(QuickPickItem),
    filtered: std.array_list.Managed(QuickPickItem),
    handler: ?PickHandler = null,
    handler_context: ?*anyopaque = null,
    allow_free_input: bool = false,
    no_results: ?QuickPickItem = null,
    cleanup: ?*const fn (context: *anyopaque) void = null,
    cleanup_context: ?*anyopaque = null,
    error_context: ?*anyopaque = null,
    on_error: ?*const fn (context: *anyopaque, message: []const u8) void = null,

    pub fn init(allocator: Allocator, io: std.Io, presenter: Presenter) !*QuickInputService {
        const self = try allocator.create(QuickInputService);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .presenter = presenter,
            .picker = QuickPick.init(allocator, io),
            .master = std.array_list.Managed(QuickPickItem).init(allocator),
            .filtered = std.array_list.Managed(QuickPickItem).init(allocator),
        };
        self.picker.on_change_context = self;
        self.picker.on_change = onPickerChanged;
        self.picker.on_accept_context = self;
        self.picker.on_accept = onPickerAccepted;
        self.picker.on_hide_context = self;
        self.picker.on_hide = onPickerHidden;
        return self;
    }

    pub fn deinit(self: *QuickInputService) void {
        self.hide();
        self.filtered.deinit();
        self.master.deinit();
        self.picker.deinit();
        self.allocator.destroy(self);
    }

    pub fn isVisible(self: *const QuickInputService) bool {
        return self.picker.visible;
    }

    pub fn pickerRef(self: *QuickInputService) *QuickPick {
        return &self.picker;
    }

    const PickBridge = struct {
        allocator: Allocator,
        handler: quick_input.PickResultHandler,
        context: *anyopaque,
        accepted: bool = false,

        fn invoke(context: *anyopaque, picker: *QuickPick) anyerror!void {
            const state: *PickBridge = @ptrCast(@alignCast(context));
            state.accepted = true;
            try state.handler(state.context, picker.selectedItem());
        }

        fn cleanup(context: *anyopaque) void {
            const state: *PickBridge = @ptrCast(@alignCast(context));
            defer state.allocator.destroy(state);
            if (!state.accepted) state.handler(state.context, null) catch {};
        }
    };

    /// Service-facing pick() result, independent of the terminal picker widget.
    pub fn pick(self: *QuickInputService, items: []const QuickPickItem, options: quick_input.IPickOptions, handler: quick_input.PickResultHandler, context: *anyopaque) !void {
        const state = try self.allocator.create(PickBridge);
        errdefer self.allocator.destroy(state);
        state.* = .{ .allocator = self.allocator, .handler = handler, .context = context };
        try self.showPick(items, .{
            .placeholder = options.placeholder,
            .active_id = options.active_id,
            .cleanup = PickBridge.cleanup,
            .cleanup_context = state,
        }, PickBridge.invoke, state);
    }

    const InputBridge = struct {
        allocator: Allocator,
        handler: quick_input.InputResultHandler,
        context: *anyopaque,
        accepted: bool = false,

        fn invoke(context: *anyopaque, picker: *QuickPick) !void {
            const state: *InputBridge = @ptrCast(@alignCast(context));
            state.accepted = true;
            try state.handler(state.context, picker.value.items);
        }

        fn cleanup(context: *anyopaque) void {
            const state: *InputBridge = @ptrCast(@alignCast(context));
            defer state.allocator.destroy(state);
            if (!state.accepted) state.handler(state.context, null) catch {};
        }
    };

    pub fn input(self: *QuickInputService, placeholder: []const u8, handler: quick_input.InputResultHandler, context: *anyopaque) !void {
        const state = try self.allocator.create(InputBridge);
        errdefer self.allocator.destroy(state);
        state.* = .{ .allocator = self.allocator, .handler = handler, .context = context };
        try self.showPick(&.{}, .{ .placeholder = placeholder, .allow_free_input = true, .cleanup = InputBridge.cleanup, .cleanup_context = state }, InputBridge.invoke, state);
    }

    /// Shows a one-shot picker. Items are copied into the service; labels and
    /// descriptions must stay alive until the picker is accepted or hidden.
    pub fn showPick(
        self: *QuickInputService,
        items: []const QuickPickItem,
        options: PickOptions,
        handler: PickHandler,
        context: *anyopaque,
    ) !void {
        if (self.picker.visible) self.hide();
        self.picker.reset();
        self.master.clearRetainingCapacity();
        try self.master.appendSlice(items);
        self.filtered.clearRetainingCapacity();
        self.handler = handler;
        self.handler_context = context;
        self.allow_free_input = options.allow_free_input;
        self.cleanup = options.cleanup;
        self.cleanup_context = options.cleanup_context;
        errdefer {
            self.cleanup = null;
            self.cleanup_context = null;
        }
        self.no_results = if (options.no_results_label) |label|
            .{ .item = .{ .label = label } }
        else
            null;
        self.picker.setPlaceholder(options.placeholder);

        try self.refresh();
        if (options.active_id) |id| self.selectItem(id);
        self.picker.show();
        self.presenter.show(self.presenter.context, &self.picker) catch |err| {
            self.cleanup = null;
            self.cleanup_context = null;
            self.picker.hide();
            return err;
        };
    }

    /// Complete an asynchronous pick source, retaining the filter typed while pending.
    pub fn setPickItems(self: *QuickInputService, items: []const QuickPickItem, active_id: ?[]const u8) !void {
        try self.master.ensureTotalCapacity(items.len);
        self.master.clearRetainingCapacity();
        self.master.appendSliceAssumeCapacity(items);
        try self.refresh();
        if (active_id) |id| self.selectItem(id);
    }

    pub fn hide(self: *QuickInputService) void {
        if (!self.picker.visible) return;
        self.picker.hide();
    }

    fn refresh(self: *QuickInputService) !void {
        try picker_quick_access.refresh(
            .{ .context = self, .get_picks = pickGetPicks },
            .{ .prefix = "", .no_results_pick = self.no_results },
            &self.picker,
        );
    }

    fn selectItem(self: *QuickInputService, id: []const u8) void {
        for (self.picker.items.items, 0..) |item, index| {
            if (!std.mem.eql(u8, item.id(), id)) continue;
            self.picker.setActiveIndex(index);
            return;
        }
    }

    fn onPickerChanged(context: *anyopaque) void {
        const self: *QuickInputService = @ptrCast(@alignCast(context));
        if (self.allow_free_input) return;
        self.refresh() catch |err| self.report(err);
    }

    fn onPickerAccepted(context: *anyopaque) void {
        const self: *QuickInputService = @ptrCast(@alignCast(context));
        const handler = self.handler orelse return;
        const handler_context = self.handler_context orelse return;
        // Hiding the picker must leave the accepted item's data available
        // until the command finishes using it.
        const cleanup = self.cleanup;
        const cleanup_context = self.cleanup_context;
        self.cleanup = null;
        self.cleanup_context = null;
        defer if (cleanup) |callback| {
            if (cleanup_context) |value| callback(value);
        };
        if (self.picker.visible) self.hide();
        handler(handler_context, &self.picker) catch |err| self.report(err);
    }

    fn onPickerHidden(context: *anyopaque) void {
        const self: *QuickInputService = @ptrCast(@alignCast(context));
        self.presenter.hide(self.presenter.context);
        const cleanup = self.cleanup;
        const cleanup_context = self.cleanup_context;
        self.cleanup = null;
        self.cleanup_context = null;
        if (cleanup) |callback| {
            if (cleanup_context) |value| callback(value);
        }
    }

    fn pickGetPicks(
        context: *anyopaque,
        filter: []const u8,
        _: Allocator,
    ) anyerror!?[]QuickPickItem {
        const self: *QuickInputService = @ptrCast(@alignCast(context));
        self.filtered.clearRetainingCapacity();
        if (self.allow_free_input) return self.filtered.items;
        for (self.master.items) |item| {
            switch (item) {
                .separator => if (filter.len == 0) try self.filtered.append(item),
                .item => |value| {
                    if (filter.len == 0 or
                        filters.matchesBaseContiguousSubString(filter, value.label) != null)
                    {
                        try self.filtered.append(item);
                    }
                },
            }
        }
        return self.filtered.items;
    }

    fn report(self: *QuickInputService, err: anyerror) void {
        if (self.on_error) |on_error| {
            on_error(self.error_context orelse undefined, @errorName(err));
        }
    }
};

test "QuickInputService: one-shot picker filters, scrolls and accepts" {
    const State = struct {
        hidden: usize = 0,
        accepted: usize = 0,
        accepted_id: [16]u8 = std.mem.zeroes([16]u8),
        accepted_len: usize = 0,
        cleaned_after_accept: bool = false,
        fn show(_: *anyopaque, _: *QuickPick) anyerror!void {}
        fn hide(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.hidden += 1;
        }
        fn accept(context: *anyopaque, picker: *QuickPick) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.accepted += 1;
            if (picker.selectedItem()) |item| {
                const length = @min(item.id.len, self.accepted_id.len);
                @memcpy(self.accepted_id[0..length], item.id[0..length]);
                self.accepted_len = length;
            }
        }
        fn clean(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.cleaned_after_accept = self.accepted == 1;
        }
    };

    var state = State{};
    const service = try QuickInputService.init(std.testing.allocator, std.testing.io, .{
        .context = &state,
        .show = State.show,
        .hide = State.hide,
    });
    defer service.deinit();

    const items = [_]QuickPickItem{
        .{ .item = .{ .id = "spaces", .label = "Indent Using Spaces" } },
        .{ .item = .{ .id = "tabs", .label = "Indent Using Tabs" } },
    };
    try service.showPick(&items, .{
        .placeholder = "Select Action",
        .cleanup = State.clean,
        .cleanup_context = &state,
    }, State.accept, &state);
    try std.testing.expect(service.isVisible());
    try std.testing.expectEqualStrings("Indent Using Spaces", service.picker.activeItem().?.label);

    try service.picker.setValue("tabs");
    try std.testing.expectEqual(@as(usize, 1), service.picker.items.items.len);
    try std.testing.expectEqualStrings("tabs", service.picker.activeItem().?.id);

    service.picker.accept();
    try std.testing.expect(!service.isVisible());
    try std.testing.expectEqual(@as(usize, 1), state.accepted);
    try std.testing.expectEqualStrings("tabs", state.accepted_id[0..state.accepted_len]);
    try std.testing.expectEqual(@as(usize, 1), state.hidden);
    try std.testing.expect(state.cleaned_after_accept);
}

test "QuickInputService: input accepts the typed value and dismisses with null" {
    const State = struct {
        accepted: bool = false,
        dismissed: bool = false,
        fn show(_: *anyopaque, _: *QuickPick) !void {}
        fn hide(_: *anyopaque) void {}
        fn result(context: *anyopaque, value: ?[]const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (value) |text| {
                try std.testing.expectEqualStrings("package.vsix", text);
                self.accepted = true;
            } else self.dismissed = true;
        }
    };
    var state: State = .{};
    const service = try QuickInputService.init(std.testing.allocator, std.testing.io, .{ .context = &state, .show = State.show, .hide = State.hide });
    defer service.deinit();
    try service.input("Path", State.result, &state);
    try service.picker.setValue("package.vsix");
    service.picker.accept();
    try std.testing.expect(state.accepted);
    try service.input("Path", State.result, &state);
    service.hide();
    try std.testing.expect(state.dismissed);
}
