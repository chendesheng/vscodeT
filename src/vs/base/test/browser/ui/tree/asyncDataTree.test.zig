// Port of the portable cases from
// `src/vs/base/test/browser/ui/tree/asyncDataTree.test.ts`, adapted to the
// terminal CellGrid/list renderer and the poll-based async contract.

const std = @import("std");
const testing = std.testing;
const ui = @import("ui");
const list = @import("../../../../browser/ui/list/list.zig");
const async_tree = @import("../../../../browser/ui/tree/asyncDataTree.zig");

const Element = struct {
    id: u8,
    children: []const *const Element = &.{},
};

const Ctx = struct {
    calls: usize = 0,
};

fn getChildren(context: *anyopaque, element: async_tree.DataElement(*const Element, *const Element)) async_tree.Children(*const Element) {
    const ctx: *Ctx = @ptrCast(@alignCast(context));
    ctx.calls += 1;
    switch (element) {
        .input => |root| return .{ .items = root.children },
        .item => |item| return .{ .items = item.children },
    }
}

fn hasChildren(_: *anyopaque, element: *const Element) bool {
    return element.children.len > 0;
}

const Job = struct {
    done: bool = false,
    items: []const *const Element = &.{},
    cancelled: bool = false,

    fn poll(context: *anyopaque) ?async_tree.Result(*const Element) {
        const job: *Job = @ptrCast(@alignCast(context));
        if (!job.done) return null;
        return .{ .items = job.items };
    }

    fn cancel(context: *anyopaque) void {
        const job: *Job = @ptrCast(@alignCast(context));
        job.cancelled = true;
    }

    fn pending(self: *Job) async_tree.Children(*const Element) {
        return .{ .pending = .{
            .context = self,
            .poll = poll,
            .cancel = cancel,
        } };
    }
};

const AsyncCtx = struct {
    root_job: *Job,
    a_job: *Job,
};

fn getChildrenAsync(context: *anyopaque, element: async_tree.DataElement(*const Element, *const Element)) async_tree.Children(*const Element) {
    const ctx: *AsyncCtx = @ptrCast(@alignCast(context));
    switch (element) {
        .input => return ctx.root_job.pending(),
        .item => return ctx.a_job.pending(),
    }
}

fn renderNode(
    _: *anyopaque,
    row: *const list.Row,
    node: *async_tree.AsyncDataTree(*const Element, *const Element).Node,
    _: []const *async_tree.AsyncDataTree(*const Element, *const Element).Node,
) void {
    const element = node.element orelse return;
    row.grid.putCodepoint(row.x, row.y, @intCast('a' + element.id), 1, .{});
}

test "AsyncDataTree: setInput resolves loaded children and expand requests only the child" {
    const allocator = testing.allocator;
    var c = Element{ .id = 2 };
    var a_children = [_]*const Element{&c};
    var a = Element{ .id = 0, .children = &a_children };
    var b = Element{ .id = 1 };
    var root_children = [_]*const Element{ &a, &b };
    var root = Element{ .id = 3, .children = &root_children };

    var context = Ctx{};
    const Tree = async_tree.AsyncDataTree(*const Element, *const Element);
    const tree = try Tree.init(allocator, "test", .{
        .context = &context,
        .has_children = hasChildren,
        .get_children = getChildren,
    }, .{
        .context = &context,
        .render = renderNode,
    }, .{});
    defer tree.deinit();

    _ = try tree.setInput(&root);
    try testing.expectEqual(@as(usize, 1), context.calls);
    try testing.expectEqual(@as(usize, 2), tree.count());
    try testing.expect(tree.hasNode(&a));
    try testing.expect(tree.isCollapsed(&a));

    _ = tree.expand(&a, false);
    try testing.expectEqual(@as(usize, 2), context.calls);
    try testing.expect(!tree.isCollapsed(&a));
    try testing.expectEqual(@as(usize, 3), tree.count());

    var grid = try ui.CellGrid.init(allocator, 10, 3);
    defer grid.deinit();
    tree.render(&grid, .{ .x = 0, .y = 0, .w = 10, .h = 3 });
    try testing.expectEqual(@as(u32, 'a'), grid.cluster[grid.index(0, 0)]);
    try testing.expectEqual(@as(u32, 'c'), grid.cluster[grid.index(0, 1)]);
    try testing.expectEqual(@as(u32, 'b'), grid.cluster[grid.index(0, 2)]);
}

test "AsyncDataTree: pending children are applied by poll" {
    const allocator = testing.allocator;
    var c = Element{ .id = 2 };
    var a_children = [_]*const Element{&c};
    var a = Element{ .id = 0, .children = &a_children };
    var b = Element{ .id = 1 };
    var root_children = [_]*const Element{ &a, &b };
    var root = Element{ .id = 3, .children = &root_children };

    var root_job = Job{ .items = &root_children };
    var a_job = Job{ .items = &a_children };
    var context = AsyncCtx{ .root_job = &root_job, .a_job = &a_job };
    const Tree = async_tree.AsyncDataTree(*const Element, *const Element);
    const tree = try Tree.init(allocator, "test", .{
        .context = &context,
        .has_children = hasChildren,
        .get_children = getChildrenAsync,
    }, .{
        .context = &context,
        .render = renderNode,
    }, .{});
    defer tree.deinit();

    _ = try tree.setInput(&root);
    try testing.expectEqual(@as(usize, 0), tree.count());
    try testing.expectEqual(@as(usize, 1), tree.pendingCount());

    root_job.done = true;
    try testing.expect(tree.poll());
    try testing.expectEqual(@as(usize, 2), tree.count());

    _ = tree.expand(&a, false);
    try testing.expectEqual(@as(usize, 1), tree.pendingCount());
    try testing.expectEqual(@as(usize, 2), tree.count());
    a_job.done = true;
    try testing.expect(tree.poll());
    try testing.expectEqual(@as(usize, 3), tree.count());
}

test "AsyncDataTree: refreshing a collapsed node keeps it stale without getChildren" {
    const allocator = testing.allocator;
    var aa = Element{ .id = 1 };
    var a_children = [_]*const Element{&aa};
    var a = Element{ .id = 0, .children = &a_children };
    var root_children = [_]*const Element{&a};
    var root = Element{ .id = 2, .children = &root_children };

    var context = Ctx{};
    const Tree = async_tree.AsyncDataTree(*const Element, *const Element);
    const tree = try Tree.init(allocator, "test", .{
        .context = &context,
        .has_children = hasChildren,
        .get_children = getChildren,
    }, .{
        .context = &context,
        .render = renderNode,
    }, .{});
    defer tree.deinit();

    _ = try tree.setInput(&root);
    const calls_after_input = context.calls;
    _ = tree.expand(&a, false);
    try testing.expectEqual(calls_after_input + 1, context.calls);
    _ = tree.collapse(&a, false);
    _ = try tree.updateChildren(&a, true, false);
    try testing.expectEqual(calls_after_input + 1, context.calls);
    try testing.expect(tree.isCollapsed(&a));

    var navigator = tree.nav(&a);
    try testing.expectEqual(&a, navigator.current().?);
    try testing.expectEqual(&a, navigator.first().?);
    try testing.expectEqual(&a, navigator.last().?);
}
