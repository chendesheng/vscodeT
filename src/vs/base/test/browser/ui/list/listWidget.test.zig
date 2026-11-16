// Port of the core selection/keyboard/wheel cases of
// `src/vs/base/test/browser/ui/list/listWidget.test.ts`.

const std = @import("std");
const testing = std.testing;
const ui = @import("ui");
const list = @import("../../../../browser/ui/list/list.zig");
const ListWidget = @import("../../../../browser/ui/list/listWidget.zig").ListWidget;

const Item = struct {
    label: u21,
};

fn getHeight(_: *anyopaque, _: list.Element) f64 {
    return 1;
}

fn getTemplateId(_: *anyopaque, _: list.Element) usize {
    return 0;
}

fn renderRow(_: *anyopaque, row: *const list.Row, element: list.Element) void {
    const item: *const Item = @ptrCast(@alignCast(element));
    row.grid.putCodepoint(row.x, row.y, item.label, 1, .{});
}

fn makeWidget(allocator: std.mem.Allocator) ListWidget {
    var context: u8 = 0;
    _ = &context;
    return ListWidget.init(allocator, .{
        .context = @ptrCast(&context),
        .get_height = getHeight,
        .get_template_id = getTemplateId,
    }, .{
        .context = @ptrCast(&context),
        .render = renderRow,
    });
}

fn refs(items: []Item) []list.Element {
    _ = items;
    return &.{};
}

test "ListWidget: keyboard selection and activation" {
    const allocator = testing.allocator;
    var widget = makeWidget(allocator);
    defer widget.deinit();

    var items = [_]Item{
        .{ .label = 'a' },
        .{ .label = 'b' },
        .{ .label = 'c' },
        .{ .label = 'd' },
        .{ .label = 'e' },
    };
    var elements: [items.len]list.Element = undefined;
    for (&items, 0..) |*item, i| elements[i] = @ptrCast(item);
    try widget.splice(0, 0, &elements);

    widget.setFocus(true);
    try testing.expectEqual(@as(?usize, null), widget.selection());

    var down = ui.KeyEvent{ .key = .down };
    try testing.expect(widget.handleKey(&down));
    try testing.expectEqual(@as(usize, 1), widget.selection().?);

    var end = ui.KeyEvent{ .key = .end };
    try testing.expect(widget.handleKey(&end));
    try testing.expectEqual(@as(usize, 4), widget.selection().?);

    var up = ui.KeyEvent{ .key = .up };
    try testing.expect(widget.handleKey(&up));
    try testing.expectEqual(@as(usize, 3), widget.selection().?);

    var home = ui.KeyEvent{ .key = .home };
    try testing.expect(widget.handleKey(&home));
    try testing.expectEqual(@as(usize, 0), widget.selection().?);
}

test "ListWidget: wheel scrolls independently and click selects" {
    const allocator = testing.allocator;
    var widget = makeWidget(allocator);
    defer widget.deinit();

    var items = [_]Item{
        .{ .label = 'a' },
        .{ .label = 'b' },
        .{ .label = 'c' },
        .{ .label = 'd' },
        .{ .label = 'e' },
    };
    var elements: [items.len]list.Element = undefined;
    for (&items, 0..) |*item, i| elements[i] = @ptrCast(item);
    try widget.splice(0, 0, &elements);
    widget.setFocus(true);

    var grid = try ui.CellGrid.init(allocator, 10, 3);
    defer grid.deinit();
    widget.render(&grid, .{ .x = 0, .y = 0, .w = 10, .h = 3 });
    try testing.expectEqual(@as(f64, 0), widget.view.scroll_top);

    var wheel = ui.MouseEvent{ .kind = .wheel, .x = 1, .y = 1, .delta_y = 1 };
    try testing.expect(widget.handleMouse(&wheel));
    try testing.expectEqual(@as(f64, 2), widget.view.scroll_top);
    try testing.expectEqual(@as(?usize, null), widget.selection());

    widget.view.setScrollTop(0);
    var down = ui.MouseEvent{ .kind = .down, .x = 1, .y = 1, .button = .left };
    try testing.expect(widget.handleMouse(&down));
    try testing.expectEqual(@as(usize, 1), widget.selection().?);
}

test "ListWidget: activation callback runs on Enter" {
    const allocator = testing.allocator;
    var widget = makeWidget(allocator);
    defer widget.deinit();

    var item = Item{ .label = 'a' };
    var elements = [_]list.Element{@ptrCast(&item)};
    try widget.splice(0, 0, &elements);
    widget.setFocus(true);
    widget.setSelection(0);

    const State = struct {
        activated: ?usize = null,
        fn activate(context: ?*anyopaque, index: usize) void {
            const state: *@This() = @ptrCast(@alignCast(context orelse return));
            state.activated = index;
        }
    };
    var state = State{};
    widget.activation_context = &state;
    widget.on_activate = State.activate;

    var enter = ui.KeyEvent{ .key = .enter };
    try testing.expect(widget.handleKey(&enter));
    try testing.expectEqual(@as(?usize, 0), state.activated);
}
