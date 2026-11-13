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
