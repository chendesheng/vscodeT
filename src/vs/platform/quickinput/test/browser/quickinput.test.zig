// Adapted cases from `src/vs/platform/quickinput/test/browser/quickinput.test.ts`
// for the portable quick-pick model used by quick open.

const std = @import("std");
const quick_input = @import("../../common/quickInput.zig");
const QuickPick = @import("../../browser/quickInput.zig").QuickPick;

fn items() [4]quick_input.QuickPickItem {
    return .{
        .{ .separator = .{ .label = "group" } },
        .{ .item = .{ .id = "a", .label = "Alpha" } },
        .{ .item = .{ .id = "b", .label = "Beta" } },
        .{ .item = .{ .id = "c", .label = "Gamma" } },
    };
}

test "quickinput: first and second activation are one-shot" {
    var picker = QuickPick.init(std.testing.allocator);
    defer picker.deinit();

    const values = items();
    try picker.setItems(&values);
    try std.testing.expectEqualStrings("a", picker.activeItem().?.id);
    try std.testing.expectEqual(quick_input.ItemActivation.first, picker.item_activation);

    picker.item_activation = .second;
    try picker.setItems(&values);
    try std.testing.expectEqualStrings("b", picker.activeItem().?.id);
    try std.testing.expectEqual(quick_input.ItemActivation.first, picker.item_activation);
}

test "quickinput: navigation skips separators and wraps" {
    var picker = QuickPick.init(std.testing.allocator);
    defer picker.deinit();
    const values = items();
    try picker.setItems(&values);

    picker.focusPrevious();
    try std.testing.expectEqualStrings("c", picker.activeItem().?.id);
    picker.focusNext();
    try std.testing.expectEqualStrings("a", picker.activeItem().?.id);
    picker.focusLast();
    try std.testing.expectEqualStrings("c", picker.activeItem().?.id);
    picker.focusFirst();
    try std.testing.expectEqualStrings("a", picker.activeItem().?.id);
}

test "quickinput: page navigation clamps to items" {
    var picker = QuickPick.init(std.testing.allocator);
    defer picker.deinit();
    const values = items();
    try picker.setItems(&values);
    picker.page_size = 2;
    picker.focusNextPage();
    try std.testing.expectEqualStrings("c", picker.activeItem().?.id);
    picker.focusNextPage();
    try std.testing.expectEqualStrings("c", picker.activeItem().?.id);
    picker.focusPreviousPage();
    try std.testing.expectEqualStrings("a", picker.activeItem().?.id);
}

test "quickinput: accept selects the active item and hides" {
    const State = struct {
        accepts: usize = 0,
        fn accept(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.accepts += 1;
        }
    };
    var state = State{};
    var picker = QuickPick.init(std.testing.allocator);
    defer picker.deinit();
    picker.on_accept_context = &state;
    picker.on_accept = State.accept;
    const values = items();
    try picker.setItems(&values);
    picker.show();
    picker.accept();
    try std.testing.expectEqual(@as(usize, 1), state.accepts);
    try std.testing.expectEqualStrings("a", picker.selectedItem().?.id);
    picker.hide();
    try std.testing.expect(!picker.visible);
}

test "QuickInputService pick resolves acceptance, cancellation and disposal exactly once" {
    const QuickInputService = @import("../../browser/quickInputService.zig").QuickInputService;
    const State = struct {
        accepted: usize = 0,
        cancelled: usize = 0,
        fn show(_: *anyopaque, _: *QuickPick) !void {}
        fn hide(_: *anyopaque) void {}
        fn result(context: *anyopaque, item: ?*const quick_input.Item) !void {
            const state: *@This() = @ptrCast(@alignCast(context));
            if (item) |value| {
                try std.testing.expectEqualStrings("b", value.id);
                state.accepted += 1;
            } else state.cancelled += 1;
        }
    };
    var state = State{};
    const service = try QuickInputService.init(std.testing.allocator, .{ .context = &state, .show = State.show, .hide = State.hide });
    var disposed = false;
    defer if (!disposed) service.deinit();
    const values = items();
    try service.pick(&values, .{ .active_id = "b" }, State.result, &state);
    service.pickerRef().accept();
    try std.testing.expectEqual(@as(usize, 1), state.accepted);
    try std.testing.expectEqual(@as(usize, 0), state.cancelled);

    try service.pick(&values, .{}, State.result, &state);
    service.hide();
    try std.testing.expectEqual(@as(usize, 1), state.cancelled);
    service.hide();
    try std.testing.expectEqual(@as(usize, 1), state.cancelled);

    try service.pick(&values, .{}, State.result, &state);
    service.deinit();
    disposed = true;
    try std.testing.expectEqual(@as(usize, 1), state.accepted);
    try std.testing.expectEqual(@as(usize, 2), state.cancelled);
}
