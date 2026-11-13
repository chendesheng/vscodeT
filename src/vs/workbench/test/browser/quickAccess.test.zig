// Adapted quick-access cases from
// `src/vs/workbench/test/browser/quickAccess.test.ts` for the terminal
// controller: provider registry, prefix switching, value refresh, no-results
// and accept/hide.

const std = @import("std");
const cancellation = @import("../../../base/common/cancellation.zig");
const quick_input = @import("../../../platform/quickinput/common/quickInput.zig");
const quick_access = @import("../../../platform/quickinput/common/quickAccess.zig");
const controller_mod = @import("../../../platform/quickinput/browser/quickAccess.zig");
const QuickPick = @import("../../../platform/quickinput/browser/quickInput.zig").QuickPick;
const picker_mod = @import("../../../platform/quickinput/browser/pickerQuickAccess.zig");

const TestProvider = struct {
    picks: []const quick_input.QuickPickItem = &.{},
    provides: usize = 0,
    refreshes: usize = 0,
    accepts: usize = 0,

    fn provider(self: *TestProvider, prefix: []const u8) quick_access.Provider {
        return .{
            .context = self,
            .prefix = prefix,
            .provide = provideFn,
            .refresh = refreshFn,
            .accept = acceptFn,
        };
    }

    fn provideFn(context: *anyopaque, picker: *QuickPick, _: cancellation.CancellationToken) anyerror!void {
        const self: *TestProvider = @ptrCast(@alignCast(context));
        self.provides += 1;
        try picker.setItems(self.picks);
    }

    fn refreshFn(context: *anyopaque, picker: *QuickPick) anyerror!void {
        const self: *TestProvider = @ptrCast(@alignCast(context));
        self.refreshes += 1;
        try picker.setItems(self.picks);
    }

    fn acceptFn(context: *anyopaque, _: *QuickPick) anyerror!void {
        const self: *TestProvider = @ptrCast(@alignCast(context));
        self.accepts += 1;
    }
};

const TestPresenter = struct {
    shows: usize = 0,
    hides: usize = 0,

    fn presenter(self: *TestPresenter) controller_mod.Presenter {
        return .{
            .context = self,
            .show = showFn,
            .hide = hideFn,
        };
    }

    fn showFn(context: *anyopaque, _: *QuickPick) anyerror!void {
        const self: *TestPresenter = @ptrCast(@alignCast(context));
        self.shows += 1;
    }

    fn hideFn(context: *anyopaque) void {
        const self: *TestPresenter = @ptrCast(@alignCast(context));
        self.hides += 1;
    }
};

test "quickAccess: registry prefers the longest prefix and falls back to default" {
    var registry = quick_access.Registry.init(std.testing.allocator);
    defer registry.deinit();

    var default = TestProvider{};
    var short = TestProvider{};
    var long = TestProvider{};
    try registry.register(default.provider(""));
    try registry.register(short.provider("ext"));
    try registry.register(long.provider("ext install"));

    try std.testing.expectEqualStrings("", registry.get("anything").?.prefix);
    try std.testing.expectEqualStrings("ext", registry.get("ext foo").?.prefix);
    try std.testing.expectEqualStrings("ext install", registry.get("ext install foo").?.prefix);
}

test "quickAccess: controller switches providers on the typed prefix" {
    var registry = quick_access.Registry.init(std.testing.allocator);
    defer registry.deinit();

    const file_items = [_]quick_input.QuickPickItem{
        .{ .item = .{ .id = "file", .label = "file.txt" } },
    };
    const command_items = [_]quick_input.QuickPickItem{
        .{ .item = .{ .id = "save", .label = "Save" } },
    };
    var files = TestProvider{ .picks = &file_items };
    var commands = TestProvider{ .picks = &command_items };
    try registry.register(files.provider(""));
    try registry.register(commands.provider(">"));

    var presenter = TestPresenter{};
    const controller = try controller_mod.QuickAccessController.init(
        std.testing.allocator,
        &registry,
        presenter.presenter(),
    );
    defer controller.deinit();

    try controller.show("", .{});
    try std.testing.expectEqualStrings("file.txt", controller.picker.activeItem().?.label);
    try std.testing.expectEqual(@as(usize, 1), files.provides);

    try controller.picker.setValue(">");
    try std.testing.expectEqualStrings(">", controller.active_prefix);
    try std.testing.expectEqualStrings("Save", controller.picker.activeItem().?.label);

    try controller.picker.setValue(">sa");
    try std.testing.expectEqual(@as(usize, 1), commands.refreshes);

    controller.picker.accept();
    try std.testing.expectEqual(@as(usize, 1), commands.accepts);

    controller.hide();
    try std.testing.expect(!controller.isVisible());
    try std.testing.expectEqual(@as(usize, 1), presenter.hides);
}

test "quickAccess: picker provider adds the no-results pick and preserves the active item" {
    const State = struct {
        filter: []const u8 = "",
        items: [2]quick_input.QuickPickItem = .{
            .{ .item = .{ .id = "a", .label = "Alpha" } },
            .{ .item = .{ .id = "b", .label = "Beta" } },
        },
        empty: [0]quick_input.QuickPickItem = .{},
        fn getPicks(context: *anyopaque, filter: []const u8, _: std.mem.Allocator) anyerror!?[]quick_input.QuickPickItem {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.filter = filter;
            if (std.mem.eql(u8, filter, "none")) return self.empty[0..];
            return self.items[0..];
        }
    };
    var state = State{};
    var picker = QuickPick.init(std.testing.allocator);
    defer picker.deinit();

    var source = try cancellation.CancellationTokenSource.init(std.testing.allocator);
    defer source.deinit();
    const token = try source.token();

    const options = picker_mod.PickerOptions{
        .prefix = "",
        .no_results_pick = .{ .item = .{ .label = "No matching results" } },
    };
    const impl = picker_mod.PickerImpl{ .context = &state, .get_picks = State.getPicks };

    picker.show();
    try picker_mod.provide(impl, options, &picker, token);
    try std.testing.expectEqualStrings("a", picker.activeItem().?.id);
    picker.focusNext();
    try std.testing.expectEqualStrings("b", picker.activeItem().?.id);

    try picker.setValue("none");
    try picker_mod.refresh(impl, options, &picker);
    try std.testing.expectEqualStrings("none", state.filter);
    try std.testing.expectEqualStrings("No matching results", picker.activeItem().?.label);
}
