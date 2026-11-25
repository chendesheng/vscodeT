// Port of the split-tree cases in
// `src/vs/base/test/browser/ui/grid/grid.test.ts`, adapted to the terminal
// grid's pointer-view and rect model.

const std = @import("std");
const grid = @import("../../../../browser/ui/grid/grid.zig");
const ui = @import("ui");

fn gap(_: void, _: grid.Orientation, _: ui.Rect) f64 {
    return 0;
}

test "grid: split and assign rects" {
    const allocator = std.testing.allocator;
    var a: u32 = 1;
    var b: u32 = 2;
    var c: u32 = 3;

    var root = try grid.initNode(*u32, allocator, &a);
    defer grid.deinitRoot(*u32, allocator, root);

    try grid.splitRoot(*u32, allocator, &root, &a, .horizontal, &b, false);
    try grid.splitRoot(*u32, allocator, &root, &b, .vertical, &c, false);
    grid.layoutRoot(*u32, root, .{ .x = 0, .y = 0, .w = 100, .h = 20 }, {}, gap);

    const a_node = grid.findLeaf(*u32, root, &a).?;
    const b_node = grid.findLeaf(*u32, root, &b).?;
    const c_node = grid.findLeaf(*u32, root, &c).?;
    try std.testing.expectEqual(@as(f64, 50), a_node.rect.w);
    try std.testing.expectEqual(@as(f64, 10), b_node.rect.h);
    try std.testing.expectEqual(@as(f64, 50), b_node.rect.w);
    try std.testing.expectEqual(@as(f64, 10), c_node.rect.y);
    try std.testing.expectEqual(@as(f64, 10), c_node.rect.h);
}

test "grid: new view can be inserted first" {
    const allocator = std.testing.allocator;
    var a: u32 = 1;
    var b: u32 = 2;
    var root = try grid.initNode(*u32, allocator, &a);
    defer grid.deinitRoot(*u32, allocator, root);

    try grid.splitRoot(*u32, allocator, &root, &a, .horizontal, &b, true);
    const split = switch (root.kind) {
        .split => |*value| value,
        .leaf => return error.TestUnexpectedResult,
    };
    try std.testing.expect(split.first.kind.leaf == &b);
    try std.testing.expect(split.second.kind.leaf == &a);
}

test "grid: branch demotion keeps the sibling" {
    const allocator = std.testing.allocator;
    var a: u32 = 1;
    var b: u32 = 2;
    var root = try grid.initNode(*u32, allocator, &a);
    defer grid.deinitRoot(*u32, allocator, root);

    try grid.splitRoot(*u32, allocator, &root, &a, .horizontal, &b, false);
    try std.testing.expect(grid.removeRoot(*u32, allocator, &root, &a));
    try std.testing.expect(root.kind.leaf == &b);
}

test "grid: moveRoot relocates a live leaf" {
    const allocator = std.testing.allocator;
    var a: u32 = 1;
    var b: u32 = 2;
    var root = try grid.initNode(*u32, allocator, &a);
    defer grid.deinitRoot(*u32, allocator, root);

    try grid.splitRoot(*u32, allocator, &root, &a, .horizontal, &b, false);
    try grid.moveRoot(*u32, allocator, &root, &b, &a, .horizontal, true);
    grid.layoutRoot(*u32, root, .{ .x = 0, .y = 0, .w = 20, .h = 4 }, {}, gap);

    const a_node = grid.findLeaf(*u32, root, &a).?;
    const b_node = grid.findLeaf(*u32, root, &b).?;
    try std.testing.expectEqual(@as(f64, 0), b_node.rect.x);
    try std.testing.expectEqual(@as(f64, 10), a_node.rect.x);
}

const ViewData = struct { name: []const u8 };
const TestGrid = grid.SerializableGrid(*ViewData, ViewData);

fn toJSON(_: void, view: *ViewData) !ViewData {
    return view.*;
}

const TestViewDeserializer = struct {
    views: [5]ViewData = undefined,
    len: usize = 0,

    fn fromJSON(self: *@This(), data: ViewData, _: bool) !*ViewData {
        if (self.len == self.views.len) return error.TooManyViews;
        self.views[self.len] = data;
        self.len += 1;
        return &self.views[self.len - 1];
    }
};

test "SerializableGrid: serialize empty and deserialize empty" {
    const allocator = std.testing.allocator;
    var view = ViewData{ .name = "view1" };
    const root = try grid.initNode(*ViewData, allocator, &view);
    defer grid.deinitRoot(*ViewData, allocator, root);
    grid.layoutRoot(*ViewData, root, .{ .w = 800, .h = 600 }, {}, gap);

    const saved = try TestGrid.serialize(allocator, root, null, {}, toJSON);
    defer saved.root.deinit(allocator);
    try std.testing.expectEqual(@as(u1, 0), saved.orientation);
    try std.testing.expectEqual(@as(f64, 800), saved.width);
    try std.testing.expectEqual(@as(f64, 600), saved.height);
    try std.testing.expectEqual(@as(f64, 800), saved.root.size);
    try std.testing.expectEqual(@as(usize, 1), saved.root.data.branch.len);
    try std.testing.expectEqual(@as(f64, 600), saved.root.data.branch[0].size);
    try std.testing.expectEqualStrings("view1", saved.root.data.branch[0].data.leaf.name);
    var deserializer = TestViewDeserializer{};
    const restored = try TestGrid.deserialize(allocator, saved, &deserializer, TestViewDeserializer.fromJSON);
    defer grid.deinitRoot(*ViewData, allocator, restored);
    try std.testing.expectEqualStrings("view1", restored.kind.leaf.name);
}

test "SerializableGrid: serialize and deserialize simple layout with scaling" {
    const allocator = std.testing.allocator;
    var views = [_]ViewData{ .{ .name = "view1" }, .{ .name = "view2" }, .{ .name = "view3" }, .{ .name = "view4" }, .{ .name = "view5" } };
    var root = try grid.initNode(*ViewData, allocator, &views[0]);
    defer grid.deinitRoot(*ViewData, allocator, root);
    try grid.splitRoot(*ViewData, allocator, &root, &views[0], .vertical, &views[1], true);
    root.kind.split.ratio = 200.0 / 600.0;
    try grid.splitRoot(*ViewData, allocator, &root, &views[0], .horizontal, &views[2], false);
    root.kind.split.second.kind.split.ratio = 600.0 / 800.0;
    try grid.splitRoot(*ViewData, allocator, &root, &views[1], .horizontal, &views[3], true);
    root.kind.split.first.kind.split.ratio = 200.0 / 800.0;
    try grid.splitRoot(*ViewData, allocator, &root, &views[0], .vertical, &views[4], false);
    root.kind.split.second.kind.split.first.kind.split.ratio = 300.0 / 400.0;
    grid.layoutRoot(*ViewData, root, .{ .w = 800, .h = 600 }, {}, gap);

    const saved = try TestGrid.serialize(allocator, root, null, {}, toJSON);
    defer saved.root.deinit(allocator);
    const expected_json =
        \\{"orientation":0,"width":800,"height":600,"root":{"type":"branch","size":800,"data":[
        \\  {"type":"branch","size":200,"data":[{"type":"leaf","size":200,"data":{"name":"view4"}},{"type":"leaf","size":600,"data":{"name":"view2"}}]},
        \\  {"type":"branch","size":400,"data":[
        \\    {"type":"branch","size":600,"data":[{"type":"leaf","size":300,"data":{"name":"view1"}},{"type":"leaf","size":100,"data":{"name":"view5"}}]},
        \\    {"type":"leaf","size":200,"data":{"name":"view3"}}]}]}}
    ;
    const json = try std.json.parseFromSlice(std.json.Value, allocator, expected_json, .{});
    defer json.deinit();
    const expected = try std.json.parseFromValue(grid.SerializedGrid(ViewData), allocator, json.value, .{});
    defer expected.deinit();
    try std.testing.expectEqualDeep(expected.value, saved);

    var deserializer = TestViewDeserializer{};
    const restored = try TestGrid.deserialize(allocator, saved, &deserializer, TestViewDeserializer.fromJSON);
    defer grid.deinitRoot(*ViewData, allocator, restored);
    const order = [_][]const u8{ "view4", "view2", "view1", "view5", "view3" };
    for (order, deserializer.views) |name, view| try std.testing.expectEqualStrings(name, view.name);
    grid.layoutRoot(*ViewData, restored, .{ .w = 800, .h = 600 }, {}, gap);
    try expectViewSizes(restored, &deserializer, &.{ .{ 200, 200 }, .{ 600, 200 }, .{ 600, 300 }, .{ 600, 100 }, .{ 200, 400 } });
    grid.layoutRoot(*ViewData, restored, .{ .w = 400, .h = 800 }, {}, gap);
    try expectViewSizes(restored, &deserializer, &.{ .{ 100, 267 }, .{ 300, 267 }, .{ 300, 400 }, .{ 300, 133 }, .{ 100, 533 } });
}

fn expectViewSizes(root: *grid.Node(*ViewData), deserializer: *TestViewDeserializer, sizes: []const [2]f64) !void {
    for (&deserializer.views, sizes) |*view, size| {
        const rect = grid.findLeaf(*ViewData, root, view).?.rect;
        try std.testing.expectEqual(size[0], rect.w);
        try std.testing.expectEqual(size[1], rect.h);
    }
}

const NeighborLayout = struct {
    views: [5]u8 = .{ 1, 2, 3, 4, 5 },
    root: *grid.Node(*u8) = undefined,
    gutter: f64,

    fn gapWidth(self: *NeighborLayout, _: grid.Orientation, _: ui.Rect) f64 {
        return self.gutter;
    }

    fn layout(self: *NeighborLayout) void {
        // Editor groups can start below the title or beside the sidebar.
        grid.layoutRoot(*u8, self.root, .{ .x = 7, .y = 3, .w = 800, .h = 600 }, self, gapWidth);
    }

    fn addView(self: *NeighborLayout, id: usize, reference: usize, direction: grid.Direction) !void {
        try grid.splitRoot(*u8, std.testing.allocator, &self.root, &self.views[reference - 1], switch (direction) {
            .up, .down => .vertical,
            .left, .right => .horizontal,
        }, &self.views[id - 1], direction == .up or direction == .left);
        self.layout();
    }

    fn expectNeighbors(self: *NeighborLayout, id: usize, direction: grid.Direction, wrap: bool, expected: []const u8) !void {
        const actual = try grid.getNeighborViews(*u8, std.testing.allocator, self.root, &self.views[id - 1], direction, wrap);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqual(expected.len, actual.len);
        for (expected, actual) |value, view| try std.testing.expectEqual(value, view.*);
    }
};

test "getNeighborViews should work on single view layout" {
    for ([_]f64{ 0, 1 }) |gutter| {
        var layout = NeighborLayout{ .gutter = gutter };
        layout.root = try grid.initNode(*u8, std.testing.allocator, &layout.views[0]);
        defer grid.deinitRoot(*u8, std.testing.allocator, layout.root);
        layout.layout();
        try layout.expectNeighbors(1, .up, false, &.{});
        try layout.expectNeighbors(1, .right, false, &.{});
        try layout.expectNeighbors(1, .down, false, &.{});
        try layout.expectNeighbors(1, .left, false, &.{});
        try layout.expectNeighbors(1, .up, true, &.{1});
        try layout.expectNeighbors(1, .right, true, &.{1});
        try layout.expectNeighbors(1, .down, true, &.{1});
        try layout.expectNeighbors(1, .left, true, &.{1});
    }
}

test "getNeighborViews should work on simple layout" {
    for ([_]f64{ 0, 1 }) |gutter| {
        var layout = NeighborLayout{ .gutter = gutter };
        layout.root = try grid.initNode(*u8, std.testing.allocator, &layout.views[0]);
        defer grid.deinitRoot(*u8, std.testing.allocator, layout.root);
        layout.layout();
        try layout.addView(2, 1, .down);
        try layout.addView(3, 2, .down);
        try layout.expectNeighbors(1, .up, false, &.{});
        try layout.expectNeighbors(1, .right, false, &.{});
        try layout.expectNeighbors(1, .down, false, &.{2});
        try layout.expectNeighbors(1, .left, false, &.{});
        try layout.expectNeighbors(1, .up, true, &.{3});
        try layout.expectNeighbors(1, .right, true, &.{1});
        try layout.expectNeighbors(1, .down, true, &.{2});
        try layout.expectNeighbors(1, .left, true, &.{1});
        try layout.expectNeighbors(2, .up, false, &.{1});
        try layout.expectNeighbors(2, .right, false, &.{});
        try layout.expectNeighbors(2, .down, false, &.{3});
        try layout.expectNeighbors(2, .left, false, &.{});
        try layout.expectNeighbors(2, .up, true, &.{1});
        try layout.expectNeighbors(2, .right, true, &.{2});
        try layout.expectNeighbors(2, .down, true, &.{3});
        try layout.expectNeighbors(2, .left, true, &.{2});
        try layout.expectNeighbors(3, .up, false, &.{2});
        try layout.expectNeighbors(3, .right, false, &.{});
        try layout.expectNeighbors(3, .down, false, &.{});
        try layout.expectNeighbors(3, .left, false, &.{});
        try layout.expectNeighbors(3, .up, true, &.{2});
        try layout.expectNeighbors(3, .right, true, &.{3});
        try layout.expectNeighbors(3, .down, true, &.{1});
        try layout.expectNeighbors(3, .left, true, &.{3});
    }
}

test "getNeighborViews should work on a complex layout" {
    for ([_]f64{ 0, 1 }) |gutter| {
        var layout = NeighborLayout{ .gutter = gutter };
        layout.root = try grid.initNode(*u8, std.testing.allocator, &layout.views[0]);
        defer grid.deinitRoot(*u8, std.testing.allocator, layout.root);
        layout.layout();
        try layout.addView(2, 1, .down);
        try layout.addView(3, 2, .down);
        try layout.addView(4, 2, .right);
        try layout.addView(5, 4, .down);
        try layout.expectNeighbors(1, .up, false, &.{});
        try layout.expectNeighbors(1, .right, false, &.{});
        try layout.expectNeighbors(1, .down, false, &.{ 2, 4 });
        try layout.expectNeighbors(1, .left, false, &.{});
        try layout.expectNeighbors(2, .up, false, &.{1});
        try layout.expectNeighbors(2, .right, false, &.{ 4, 5 });
        try layout.expectNeighbors(2, .down, false, &.{3});
        try layout.expectNeighbors(2, .left, false, &.{});
        try layout.expectNeighbors(4, .up, false, &.{1});
        try layout.expectNeighbors(4, .right, false, &.{});
        try layout.expectNeighbors(4, .down, false, &.{5});
        try layout.expectNeighbors(4, .left, false, &.{2});
        try layout.expectNeighbors(5, .up, false, &.{4});
        try layout.expectNeighbors(5, .right, false, &.{});
        try layout.expectNeighbors(5, .down, false, &.{3});
        try layout.expectNeighbors(5, .left, false, &.{2});
        try layout.expectNeighbors(3, .up, false, &.{ 2, 5 });
        try layout.expectNeighbors(3, .right, false, &.{});
        try layout.expectNeighbors(3, .down, false, &.{});
        try layout.expectNeighbors(3, .left, false, &.{});
    }
}

test "getNeighborViews should work on another simple layout" {
    for ([_]f64{ 0, 1 }) |gutter| {
        var layout = NeighborLayout{ .gutter = gutter };
        layout.root = try grid.initNode(*u8, std.testing.allocator, &layout.views[0]);
        defer grid.deinitRoot(*u8, std.testing.allocator, layout.root);
        layout.layout();
        try layout.addView(2, 1, .right);
        try layout.addView(3, 2, .down);
        try layout.addView(4, 2, .right);
        try layout.expectNeighbors(4, .up, false, &.{});
        try layout.expectNeighbors(4, .right, false, &.{});
        try layout.expectNeighbors(4, .down, false, &.{3});
        try layout.expectNeighbors(4, .left, false, &.{2});
    }
}

test "getNeighborViews should only return immediate neighbors" {
    for ([_]f64{ 0, 1 }) |gutter| {
        var layout = NeighborLayout{ .gutter = gutter };
        layout.root = try grid.initNode(*u8, std.testing.allocator, &layout.views[0]);
        defer grid.deinitRoot(*u8, std.testing.allocator, layout.root);
        layout.layout();
        try layout.addView(2, 1, .right);
        try layout.addView(3, 2, .down);
        try layout.addView(4, 2, .right);
        try layout.expectNeighbors(1, .right, false, &.{ 2, 3 });
    }
}

test "getNeighborViews requires a layout and a view belonging to the grid" {
    var layout = NeighborLayout{ .gutter = 0 };
    layout.root = try grid.initNode(*u8, std.testing.allocator, &layout.views[0]);
    defer grid.deinitRoot(*u8, std.testing.allocator, layout.root);
    try std.testing.expectError(error.GridNotLaidOut, grid.getNeighborViews(*u8, std.testing.allocator, layout.root, &layout.views[0], .right, false));
    layout.layout();
    try std.testing.expectError(error.ViewNotFound, grid.getNeighborViews(*u8, std.testing.allocator, layout.root, &layout.views[1], .right, false));
}
