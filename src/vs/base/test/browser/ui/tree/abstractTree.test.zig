// Port of the core expand/collapse/selection cases of
// `src/vs/base/test/browser/ui/tree/objectTree.test.ts`, adapted to CellGrid.

const std = @import("std");
const testing = std.testing;
const ui = @import("ui");
const list = @import("../../../../browser/ui/list/list.zig");
const object_tree = @import("../../../../browser/ui/tree/objectTreeModel.zig");
const abstract_tree = @import("../../../../browser/ui/tree/abstractTree.zig");

const Model = object_tree.ObjectTreeModel(i32);
const Tree = abstract_tree.AbstractTree(i32);
const Element = object_tree.ObjectTreeElement(i32);

fn renderRow(_: *anyopaque, row: *const list.Row, node: *const Model.Node) void {
    const element = node.element orelse return;
    const glyph: u21 = @intCast('0' + @as(u8, @intCast(element)));
    row.grid.putCodepoint(row.x, row.y, glyph, 1, .{});
}

fn setup(allocator: std.mem.Allocator) !struct { model: *Model, tree: *Tree } {
    const model = try allocator.create(Model);
    model.* = try Model.init(allocator, "test", false);
    var context: u8 = 0;
    _ = &context;
    const tree = try Tree.init(allocator, model, .{
        .context = @ptrCast(&context),
        .render = renderRow,
    });
    return .{ .model = model, .tree = tree };
}

test "AbstractTree: renders the initial projection" {
    const allocator = testing.allocator;
    const model = try allocator.create(Model);
    model.* = try Model.init(allocator, "test", false);
    defer {
        model.deinit();
        allocator.destroy(model);
    }

    const nested = [_]Element{.{ .element = 2 }};
    try model.setChildren(null, &.{
        .{ .element = 0 },
        .{ .element = 1, .children = &nested },
    });

    var context: u8 = 0;
    _ = &context;
    const tree = try Tree.init(allocator, model, .{
        .context = @ptrCast(&context),
        .render = renderRow,
    });
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 3), tree.count());
    try testing.expectEqual(@as(i32, 0), tree.selectedElement().?);

    var grid = try ui.CellGrid.init(allocator, 10, 3);
    defer grid.deinit();
    tree.render(&grid, .{ .x = 0, .y = 0, .w = 10, .h = 3 });
    try testing.expectEqual(@as(u32, '0'), grid.cluster[grid.index(0, 0)]);
    try testing.expectEqual(@as(u32, '1'), grid.cluster[grid.index(0, 1)]);
    try testing.expectEqual(@as(u32, '2'), grid.cluster[grid.index(0, 2)]);
}

test "AbstractTree: collapse and expand keys" {
    const allocator = testing.allocator;
    const model = try allocator.create(Model);
    model.* = try Model.init(allocator, "test", false);
    defer {
        model.deinit();
        allocator.destroy(model);
    }

    const nested = [_]Element{.{ .element = 2 }};
    try model.setChildren(null, &.{
        .{ .element = 0 },
        .{ .element = 1, .children = &nested },
    });

    var context: u8 = 0;
    _ = &context;
    const tree = try Tree.init(allocator, model, .{
        .context = @ptrCast(&context),
        .render = renderRow,
    });
    defer tree.deinit();
    tree.setFocus(true);

    tree.setSelectionNode(try model.getNode(1));
    var left = ui.KeyEvent{ .key = .left };
    try testing.expect(tree.handleKey(&left));
    try testing.expectEqual(@as(usize, 2), tree.count());
    try testing.expect(model.isCollapsed(1));

    var right = ui.KeyEvent{ .key = .right };
    try testing.expect(tree.handleKey(&right));
    try testing.expectEqual(@as(usize, 3), tree.count());
    try testing.expect(!model.isCollapsed(1));
}

test "AbstractTree: enter activates the selected element" {
    const allocator = testing.allocator;
    const model = try allocator.create(Model);
    model.* = try Model.init(allocator, "test", false);
    defer {
        model.deinit();
        allocator.destroy(model);
    }

    try model.setChildren(null, &.{.{ .element = 7 }});
    var context: u8 = 0;
    _ = &context;
    const tree = try Tree.init(allocator, model, .{
        .context = @ptrCast(&context),
        .render = renderRow,
    });
    defer tree.deinit();
    tree.setFocus(true);

    const State = struct {
        activated: ?i32 = null,
        fn activate(ctx: ?*anyopaque, element: i32) void {
            const state: *@This() = @ptrCast(@alignCast(ctx orelse return));
            state.activated = element;
        }
    };
    var state = State{};
    tree.setActivateHandler(&state, State.activate);

    var enter = ui.KeyEvent{ .key = .enter };
    try testing.expect(tree.handleKey(&enter));
    try testing.expectEqual(@as(?i32, 7), state.activated);
}
