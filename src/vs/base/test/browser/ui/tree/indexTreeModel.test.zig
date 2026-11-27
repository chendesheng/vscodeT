// Port of the core insert/delete/collapse cases of
// `src/vs/base/test/browser/ui/tree/indexTreeModel.test.ts`.

const std = @import("std");
const testing = std.testing;
const tree = @import("../../../../browser/ui/tree/tree.zig");
const index_tree = @import("../../../../browser/ui/tree/indexTreeModel.zig");
const Model = index_tree.IndexTreeModel(i32);
const Element = tree.TreeElement(i32);

fn collect(model: *Model, allocator: std.mem.Allocator) ![]*Model.Node {
    var list = std.array_list.Managed(*Model.Node).init(allocator);
    errdefer list.deinit();
    try model.collectRendered(&list);
    return list.toOwnedSlice();
}

test "IndexTreeModel: insert and deep insert" {
    const allocator = testing.allocator;
    var model = try Model.init(allocator, "test", -1, .{});
    defer model.deinit();

    const children = [_]Element{
        .{ .element = 10 },
        .{ .element = 11 },
        .{ .element = 12 },
    };
    const elements = [_]Element{
        .{ .element = 0, .children = &children },
        .{ .element = 1 },
        .{ .element = 2 },
    };
    try model.splice(&.{0}, 0, &elements);

    const rendered = try collect(&model, allocator);
    defer allocator.free(rendered);
    try testing.expectEqual(@as(usize, 6), rendered.len);
    try testing.expectEqual(@as(i32, 0), rendered[0].element);
    try testing.expectEqual(@as(usize, 1), rendered[0].depth);
    try testing.expectEqual(@as(i32, 10), rendered[1].element);
    try testing.expectEqual(@as(usize, 2), rendered[1].depth);
    try testing.expectEqual(@as(i32, 12), rendered[3].element);
    try testing.expectEqual(@as(i32, 1), rendered[4].element);
    try testing.expectEqual(@as(usize, 6), model.root.render_node_count);
}

test "IndexTreeModel: deep insert collapsed" {
    const allocator = testing.allocator;
    var model = try Model.init(allocator, "test", -1, .{});
    defer model.deinit();

    const children = [_]Element{
        .{ .element = 10 },
        .{ .element = 11 },
        .{ .element = 12 },
    };
    const elements = [_]Element{
        .{ .element = 0, .children = &children, .collapsed = true },
        .{ .element = 1 },
        .{ .element = 2 },
    };
    try model.splice(&.{0}, 0, &elements);

    const rendered = try collect(&model, allocator);
    defer allocator.free(rendered);
    try testing.expectEqual(@as(usize, 3), rendered.len);
    try testing.expect(rendered[0].collapsed);
    try testing.expectEqual(@as(i32, 0), rendered[0].element);
    try testing.expectEqual(@as(i32, 1), rendered[1].element);
    try testing.expectEqual(@as(i32, 2), rendered[2].element);
}

test "IndexTreeModel: delete and render indexes" {
    const allocator = testing.allocator;
    var model = try Model.init(allocator, "test", -1, .{});
    defer model.deinit();

    const elements = [_]Element{
        .{ .element = 0 },
        .{ .element = 1 },
        .{ .element = 2 },
        .{ .element = 3 },
    };
    try model.splice(&.{0}, 0, &elements);
    const node1 = try model.getNode(&.{1});
    try testing.expectEqual(@as(?usize, 1), model.getListIndex(node1));

    try model.splice(&.{1}, 2, &.{});
    const rendered = try collect(&model, allocator);
    defer allocator.free(rendered);
    try testing.expectEqual(@as(usize, 2), rendered.len);
    try testing.expectEqual(@as(i32, 0), rendered[0].element);
    try testing.expectEqual(@as(i32, 3), rendered[1].element);
    try testing.expect(!model.has(&.{2}));
}

test "IndexTreeModel: recursive collapse skips the root and non-collapsible leaves" {
    const allocator = testing.allocator;
    var model = try Model.init(allocator, "test", -1, .{});
    defer model.deinit();
    const children = [_]Element{.{ .element = 10 }};
    const elements = [_]Element{ .{ .element = 0, .children = &children }, .{ .element = 1 } };
    try model.splice(&.{0}, 0, &elements);

    try testing.expect(try model.setCollapsed(&.{}, true, true));
    try testing.expect(!model.root.collapsed);
    try testing.expect(model.isCollapsed(&.{0}));
    try testing.expect(!model.isCollapsed(&.{ 0, 0 }));
    try testing.expect(!model.isCollapsed(&.{1}));
    try testing.expectEqual(@as(usize, 2), model.root.render_node_count);
    try testing.expect(!try model.setCollapsed(&.{}, true, true));
    try testing.expect(try model.setCollapsed(&.{}, false, true));
    try testing.expectEqual(@as(usize, 3), model.root.render_node_count);
}

test "IndexTreeModel: collapse and expand" {
    const allocator = testing.allocator;
    var model = try Model.init(allocator, "test", -1, .{});
    defer model.deinit();

    const children = [_]Element{
        .{ .element = 10 },
        .{ .element = 11 },
    };
    const elements = [_]Element{
        .{ .element = 0, .children = &children },
        .{ .element = 1 },
    };
    try model.splice(&.{0}, 0, &elements);

    try testing.expect(model.isCollapsible(&.{0}));
    try testing.expect(try model.setCollapsed(&.{0}, true, false));
    try testing.expect(model.isCollapsed(&.{0}));
    try testing.expectEqual(@as(usize, 2), model.root.render_node_count);

    try testing.expect(try model.setCollapsed(&.{0}, false, false));
    try testing.expectEqual(@as(usize, 4), model.root.render_node_count);

    try testing.expect(try model.setCollapsed(&.{0}, true, false));
    try model.expandTo(&.{ 0, 0 });
    try testing.expect(!model.isCollapsed(&.{0}));
    try testing.expectEqual(@as(usize, 4), model.root.render_node_count);
}

test "IndexTreeModel: setCollapsible" {
    const allocator = testing.allocator;
    var model = try Model.init(allocator, "test", -1, .{});
    defer model.deinit();

    try model.splice(&.{0}, 0, &.{.{ .element = 7 }});
    try testing.expect(!model.isCollapsible(&.{0}));
    try testing.expect(model.setCollapsible(&.{0}, true));
    try testing.expect(model.isCollapsible(&.{0}));
    try testing.expect(model.setCollapsible(&.{0}, false));
    try testing.expect(!model.isCollapsible(&.{0}));
}

test "IndexTreeModel: collapseByDefault and first/last element" {
    const allocator = testing.allocator;
    var model = try Model.init(allocator, "test", -1, .{ .collapse_by_default = true });
    defer model.deinit();

    const children = [_]Element{.{ .element = 2 }};
    try model.splice(&.{0}, 0, &.{.{ .element = 1, .children = &children }});
    try testing.expect(model.isCollapsed(&.{0}));

    const node = try model.getNode(&.{0});
    try testing.expectEqual(@as(?i32, null), model.getFirstElementChild(node));
    _ = try model.setCollapsed(&.{0}, false, false);
    try testing.expectEqual(@as(?i32, 2), model.getFirstElementChild(node));
    try testing.expectEqual(@as(?i32, -1), model.getLastElementAncestor(node));
}

const FilterState = struct {
    hidden: i32 = -1,
    recurse: i32 = -2,
    hide_all_children: bool = false,
    fn filter(context: *anyopaque, element: i32, parent: tree.TreeVisibility) tree.TreeVisibility {
        _ = parent;
        const state: *FilterState = @ptrCast(@alignCast(context));
        if (state.hide_all_children and element >= 10) return .hidden;
        if (element == state.hidden) return .hidden;
        if (element == state.recurse) return .recurse;
        return .visible;
    }
};

test "IndexTreeModel: simple filter hides rows" {
    const allocator = testing.allocator;
    var state = FilterState{ .hidden = 1 };
    var model = try Model.init(allocator, "test", -1, .{
        .filter = .{ .context = &state, .filter = FilterState.filter },
    });
    defer model.deinit();

    try model.splice(&.{0}, 0, &.{
        .{ .element = 0 },
        .{ .element = 1 },
        .{ .element = 2 },
    });
    const rendered = try collect(&model, allocator);
    defer allocator.free(rendered);
    try testing.expectEqual(@as(usize, 2), rendered.len);
    try testing.expectEqual(@as(i32, 0), rendered[0].element);
    try testing.expectEqual(@as(i32, 2), rendered[1].element);

    state.hidden = 2;
    try model.refilter();
    const refreshed = try collect(&model, allocator);
    defer allocator.free(refreshed);
    try testing.expectEqual(@as(usize, 2), refreshed.len);
    try testing.expectEqual(@as(i32, 1), refreshed[1].element);
}

test "IndexTreeModel: recursive filter keeps ancestors of visible children" {
    const allocator = testing.allocator;
    var state = FilterState{ .hidden = 10, .recurse = 0 };
    var model = try Model.init(allocator, "test", -1, .{
        .filter = .{ .context = &state, .filter = FilterState.filter },
    });
    defer model.deinit();

    const children = [_]Element{
        .{ .element = 10 },
        .{ .element = 11 },
    };
    try model.splice(&.{0}, 0, &.{.{ .element = 0, .children = &children }});
    const rendered = try collect(&model, allocator);
    defer allocator.free(rendered);
    try testing.expectEqual(@as(usize, 2), rendered.len);
    try testing.expectEqual(@as(i32, 0), rendered[0].element);
    try testing.expectEqual(@as(i32, 11), rendered[1].element);

    state.hide_all_children = true;
    try model.refilter();
    const hidden_all = try collect(&model, allocator);
    defer allocator.free(hidden_all);
    try testing.expectEqual(@as(usize, 0), hidden_all.len);
}

test "IndexTreeModel: collapsed recursive filter still shows its row" {
    const allocator = testing.allocator;
    var state = FilterState{ .hidden = 10, .recurse = 0 };
    var model = try Model.init(allocator, "test", -1, .{
        .filter = .{ .context = &state, .filter = FilterState.filter },
    });
    defer model.deinit();

    const children = [_]Element{
        .{ .element = 10 },
        .{ .element = 11 },
    };
    try model.splice(&.{0}, 0, &.{.{ .element = 0, .children = &children, .collapsed = true }});
    const rendered = try collect(&model, allocator);
    defer allocator.free(rendered);
    try testing.expectEqual(@as(usize, 1), rendered.len);
    try testing.expectEqual(@as(i32, 0), rendered[0].element);
}

const SmartIds = struct {
    fn getId(_: *anyopaque, element: i32) []const u8 {
        return switch (element) {
            0 => "0",
            1 => "1",
            2 => "2",
            3 => "3",
            else => "?",
        };
    }
};

test "IndexTreeModel: smart splice preserves node identity and collapse state" {
    const allocator = testing.allocator;
    var model = try Model.init(allocator, "test", -1, .{});
    defer model.deinit();

    const children1 = [_]Element{.{ .element = 10 }};
    try model.splice(&.{0}, 0, &.{
        .{ .element = 0 },
        .{ .element = 1, .children = &children1 },
        .{ .element = 2 },
    });
    try testing.expect(try model.setCollapsed(&.{1}, true, false));
    const node1 = try model.getNode(&.{1});

    var context: u8 = 0;
    const provider = tree.IdentityProvider(i32){
        .context = @ptrCast(&context),
        .get_id = SmartIds.getId,
    };
    try model.spliceWithOptions(&.{0}, 3, &.{
        .{ .element = 0 },
        .{ .element = 1, .children = &children1 },
        .{ .element = 2 },
    }, .{ .identity_provider = provider, .diff_depth = 1 });

    try testing.expect((try model.getNode(&.{1})) == node1);
    try testing.expect(model.isCollapsed(&.{1}));
    const rendered = try collect(&model, allocator);
    defer allocator.free(rendered);
    try testing.expectEqual(@as(usize, 3), rendered.len);

    try model.spliceWithOptions(&.{0}, 3, &.{
        .{ .element = 0 },
        .{ .element = 1, .children = &children1 },
        .{ .element = 3 },
    }, .{ .identity_provider = provider, .diff_depth = 1 });
    try testing.expect((try model.getNode(&.{1})) == node1);
    try testing.expect(model.isCollapsed(&.{1}));
    const changed = try collect(&model, allocator);
    defer allocator.free(changed);
    try testing.expectEqual(@as(usize, 3), changed.len);
    try testing.expectEqual(@as(i32, 3), changed[2].element);
}

test "IndexTreeModel: explicit expanded element overrides collapseByDefault" {
    const a = testing.allocator;
    var model = try Model.init(a, "test", -1, .{ .collapse_by_default = true });
    defer model.deinit();
    try model.splice(&.{0}, 0, &.{
        .{ .element = 1, .children = &.{.{ .element = 10 }}, .collapsed = false },
        .{ .element = 2, .children = &.{.{ .element = 20 }} },
    });
    try testing.expect(!(try model.getNode(&.{0})).collapsed);
    try testing.expect((try model.getNode(&.{1})).collapsed);
    const rendered = try collect(&model, a);
    defer a.free(rendered);
    try testing.expectEqual(@as(usize, 3), rendered.len);
    try testing.expectEqual(@as(i32, 10), rendered[1].element);
}
