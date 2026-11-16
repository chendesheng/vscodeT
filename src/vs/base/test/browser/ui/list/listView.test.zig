// Port of the core viewport cases of
// `src/vs/base/test/browser/ui/list/listView.test.ts`, adapted to the terminal
// CellGrid renderer.

const std = @import("std");
const testing = std.testing;
const ui = @import("ui");
const list = @import("../../../../browser/ui/list/list.zig");
const ListView = @import("../../../../browser/ui/list/listView.zig").ListView;

const Item = struct {
    label: u21,
    height: f64 = 1,
};

fn getHeight(_: *anyopaque, element: list.Element) f64 {
    const item: *const Item = @ptrCast(@alignCast(element));
    return item.height;
}

fn getTemplateId(_: *anyopaque, _: list.Element) usize {
    return 0;
}

fn renderRow(_: *anyopaque, row: *const list.Row, element: list.Element) void {
    const item: *const Item = @ptrCast(@alignCast(element));
    row.grid.putCodepoint(row.x, row.y, item.label, 1, .{});
}

fn makeView(allocator: std.mem.Allocator) ListView {
    var context: u8 = 0;
    _ = &context;
    return ListView.init(allocator, .{
        .context = @ptrCast(&context),
        .get_height = getHeight,
        .get_template_id = getTemplateId,
    }, .{
        .context = @ptrCast(&context),
        .render = renderRow,
    });
}

fn elements(items: []Item) []const list.Element {
    comptime {
        @setEvalBranchQuota(1000);
    }
    _ = items;
    return &.{};
}

test "ListView: empty viewport" {
    const allocator = testing.allocator;
    var view = makeView(allocator);
    defer view.deinit();
    try testing.expectEqual(@as(usize, 0), view.count());
    try testing.expectEqual(@as(f64, 0), view.maxScroll());
    try testing.expectEqual(@as(?list.Element, null), view.elementAt(0));

    var grid = try ui.CellGrid.init(allocator, 10, 3);
    defer grid.deinit();
    view.render(&grid, .{ .x = 0, .y = 0, .w = 10, .h = 3 });
}

test "ListView: renders visible rows and clips the viewport" {
    const allocator = testing.allocator;
    var view = makeView(allocator);
    defer view.deinit();

    var items = [_]Item{
        .{ .label = 'a' },
        .{ .label = 'b' },
        .{ .label = 'c' },
        .{ .label = 'd' },
    };
    var refs: [items.len]list.Element = undefined;
    for (&items, 0..) |*item, i| refs[i] = @ptrCast(item);
    try view.splice(0, 0, &refs);

    try testing.expectEqual(@as(usize, 4), view.count());
    view.setViewportHeight(3);
    try testing.expectEqual(@as(f64, 1), view.maxScroll());
    try testing.expectEqual(items[1].label, @as(*const Item, @ptrCast(@alignCast(view.elementAt(1).?))).label);

    var grid = try ui.CellGrid.init(allocator, 10, 3);
    defer grid.deinit();
    view.render(&grid, .{ .x = 0, .y = 0, .w = 10, .h = 3 });
    try testing.expectEqual(@as(u32, 'a'), grid.cluster[grid.index(0, 0)]);
    try testing.expectEqual(@as(u32, 'b'), grid.cluster[grid.index(0, 1)]);
    try testing.expectEqual(@as(u32, 'c'), grid.cluster[grid.index(0, 2)]);

    view.scrollBy(1);
    var grid2 = try ui.CellGrid.init(allocator, 10, 3);
    defer grid2.deinit();
    view.render(&grid2, .{ .x = 0, .y = 0, .w = 10, .h = 3 });
    try testing.expectEqual(@as(u32, 'b'), grid2.cluster[grid2.index(0, 0)]);
    try testing.expectEqual(@as(u32, 'c'), grid2.cluster[grid2.index(0, 1)]);
    try testing.expectEqual(@as(u32, 'd'), grid2.cluster[grid2.index(0, 2)]);
}

test "ListView: selection reveals the row" {
    const allocator = testing.allocator;
    var view = makeView(allocator);
    defer view.deinit();

    var items = [_]Item{
        .{ .label = 'a' },
        .{ .label = 'b' },
        .{ .label = 'c' },
        .{ .label = 'd' },
        .{ .label = 'e' },
    };
    var refs: [items.len]list.Element = undefined;
    for (&items, 0..) |*item, i| refs[i] = @ptrCast(item);
    try view.splice(0, 0, &refs);

    var grid = try ui.CellGrid.init(allocator, 10, 3);
    defer grid.deinit();
    view.render(&grid, .{ .x = 0, .y = 0, .w = 10, .h = 3 });
    try testing.expectEqual(@as(f64, 0), view.scroll_top);

    view.setSelection(4);
    try testing.expectEqual(@as(usize, 4), view.selection().?);
    try testing.expectEqual(@as(f64, 2), view.scroll_top);

    var grid2 = try ui.CellGrid.init(allocator, 10, 3);
    defer grid2.deinit();
    view.render(&grid2, .{ .x = 0, .y = 0, .w = 10, .h = 3 });
    try testing.expectEqual(@as(u32, 'c'), grid2.cluster[grid2.index(0, 0)]);
    try testing.expectEqual(@as(u32, 'e'), grid2.cluster[grid2.index(0, 2)]);
}

test "ListView: dynamic row heights participate in geometry" {
    const allocator = testing.allocator;
    var view = makeView(allocator);
    defer view.deinit();

    var items = [_]Item{
        .{ .label = 'a', .height = 2 },
        .{ .label = 'b', .height = 2 },
        .{ .label = 'c', .height = 2 },
    };
    var refs: [items.len]list.Element = undefined;
    for (&items, 0..) |*item, i| refs[i] = @ptrCast(item);
    try view.splice(0, 0, &refs);

    view.setViewportHeight(5);
    try testing.expectEqual(@as(f64, 1), view.maxScroll());
    var grid = try ui.CellGrid.init(allocator, 10, 5);
    defer grid.deinit();
    view.render(&grid, .{ .x = 0, .y = 0, .w = 10, .h = 5 });
    try testing.expectEqual(@as(u32, 'a'), grid.cluster[grid.index(0, 0)]);
    try testing.expectEqual(@as(u32, 'b'), grid.cluster[grid.index(0, 2)]);
    try testing.expectEqual(@as(u32, 'c'), grid.cluster[grid.index(0, 4)]);

    view.scrollBy(2);
    try testing.expectEqual(@as(f64, 1), view.scroll_top);
    var grid2 = try ui.CellGrid.init(allocator, 10, 5);
    defer grid2.deinit();
    view.render(&grid2, .{ .x = 0, .y = 0, .w = 10, .h = 5 });
    try testing.expectEqual(@as(u32, 'b'), grid2.cluster[grid2.index(0, 1)]);
    try testing.expectEqual(@as(u32, 'c'), grid2.cluster[grid2.index(0, 3)]);
}

test "ListView: splice replaces and deletes rows" {
    const allocator = testing.allocator;
    var view = makeView(allocator);
    defer view.deinit();

    var a = Item{ .label = 'a' };
    var b = Item{ .label = 'b' };
    var c = Item{ .label = 'c' };
    var refs = [_]list.Element{ @ptrCast(&a), @ptrCast(&b) };
    try view.splice(0, 0, &refs);
    try testing.expectEqual(@as(usize, 2), view.count());

    var replacement = [_]list.Element{@ptrCast(&c)};
    try view.splice(1, 1, &replacement);
    try testing.expectEqual(@as(usize, 2), view.count());
    try testing.expectEqual(c.label, @as(*const Item, @ptrCast(@alignCast(view.elementAt(1).?))).label);

    try view.splice(0, 2, &.{});
    try testing.expectEqual(@as(usize, 0), view.count());
}
