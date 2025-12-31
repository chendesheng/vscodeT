const std = @import("std");
const usizeSub = @import("../basics/utils.zig").usizeSub;
const usizeAdd = @import("../basics/utils.zig").usizeAdd;
const json = std.json;
const Allocator = std.mem.Allocator;
const IntervalTree = @import("../textModel/intervalTree.zig").IntervalTree;
const intervalCompare = @import("../textModel/intervalTree.zig").intervalCompare;
const ArrayList = std.array_list.Managed;
const IntervalNode = @import("../textModel/intervalTree.zig").IntervalNode;
const TrackedRangeStickiness = @import("../textModel/model.zig").TrackedRangeStickiness;
const nodeAcceptEdit = @import("../textModel/intervalTree.zig").nodeAcceptEdit;

const GENERATE_TESTS = false;
const TEST_COUNT = if (GENERATE_TESTS) 10000 else 100;
const PRINT_TREE = false;
const MIN_INTERVAL_START = 1;
const MAX_INTERVAL_END = 100;
const MIN_INSERTS = 1;
const MAX_INSERTS = 30;
const MIN_CHANGE_CNT = 10;
const MAX_CHANGE_CNT = 20;

var pcg = std.Random.Pcg.init(0);
var rand = pcg.random();
var SENTINEL = @import("../textModel/intervalTree.zig").SENTINEL;

const IntervalTree1Tests = struct {
    const Interval = struct {
        _intervalBrand: void = {},

        start: usize,
        end: usize,

        pub fn init(start: usize, end: usize) Interval {
            return .{
                .start = start,
                .end = end,
            };
        }

        pub fn eql(self: Interval, other: Interval) bool {
            return self.start == other.start and self.end == other.end;
        }
    };

    const Oracle = struct {
        intervals: ArrayList(Interval),

        fn init(allocator: Allocator) Oracle {
            return .{
                .intervals = ArrayList(Interval).init(allocator),
            };
        }

        fn deinit(self: *Oracle) void {
            self.intervals.deinit();
        }

        fn compare(_: *Oracle, a: Interval, b: Interval) bool {
            if (a.start == b.start) {
                return a.end < b.end;
            }
            return a.start < b.start;
        }

        fn insert(self: *Oracle, interval: Interval) !Interval {
            try self.intervals.append(interval);
            std.sort.block(Interval, self.intervals.items, self, Oracle.compare);
            return interval;
        }

        fn delete(self: *Oracle, interval: Interval) void {
            for (self.intervals.items, 0..) |item, i| {
                if (item.eql(interval)) {
                    _ = self.intervals.orderedRemove(i);
                    return;
                }
            }
        }

        fn search(self: *Oracle, interval: Interval) !ArrayList(Interval) {
            var result = ArrayList(Interval).init(self.intervals.allocator);
            for (self.intervals.items) |it| {
                if (it.start <= interval.end and it.end >= interval.start) {
                    try result.append(it);
                }
            }
            return result;
        }
    };

    const TestState = struct {
        _oracle: Oracle,
        _tree: IntervalTree,
        _lastNodeId: isize,
        _treeNodes: ArrayList(?*IntervalNode),
        _oracleNodes: ArrayList(?Interval),

        pub fn init(allocator: Allocator) TestState {
            return .{
                ._oracle = Oracle.init(allocator),
                ._tree = IntervalTree.init(allocator),
                ._lastNodeId = -1,
                ._treeNodes = ArrayList(?*IntervalNode).init(allocator),
                ._oracleNodes = ArrayList(?Interval).init(allocator),
            };
        }

        pub fn deinit(self: *TestState) void {
            self._oracle.deinit();
            self._treeNodes.deinit();
            self._oracleNodes.deinit();
            self._tree.deinit();
        }

        pub fn acceptOp(self: *TestState, _op: Operation) !void {
            switch (_op) {
                .insert => |op| {
                    if (PRINT_TREE) {
                        // console.log(`insert: {${JSON.stringify(new Interval(op.begin, op.end))}}`);
                    }
                    self._lastNodeId += 1;
                    const node = try IntervalNode.init(self._tree.allocator, 0, op.begin, op.end);
                    try self._treeNodes.append(node);
                    self._tree.insert(node);
                    try self._oracleNodes.append(try self._oracle.insert(Interval.init(op.begin, op.end)));
                },
                .delete => |op| {
                    if (PRINT_TREE) {
                        // std.debug.print("delete: {s}\n", .{json.Stringify.encodeJsonString(self._oracleNodes.items[op.id].?)});
                    }

                    const node = self._treeNodes.items[op.id].?;
                    defer node.deinit(self._tree.allocator);
                    self._tree.delete(node);
                    self._oracle.delete(self._oracleNodes.items[op.id].?);

                    self._treeNodes.items[op.id] = null;
                    self._oracleNodes.items[op.id] = null;
                },
                .change => |op| {
                    var node = self._treeNodes.items[op.id].?;
                    self._tree.delete(node);
                    node.reset(0, op.begin, op.end, null);
                    self._tree.insert(node);

                    self._oracle.delete(self._oracleNodes.items[op.id].?);
                    self._oracleNodes.items[op.id].?.start = op.begin;
                    self._oracleNodes.items[op.id].?.end = op.end;
                    _ = try self._oracle.insert(self._oracleNodes.items[op.id].?);
                },
                .search => |op| {
                    const actualNodes = try self._tree.intervalSearch(op.begin, op.end, 0, false, 0, false);
                    defer actualNodes.deinit();
                    var expected = try self._oracle.search(Interval.init(op.begin, op.end));
                    defer expected.deinit();
                    for (expected.items, 0..) |expectedItem, i| {
                        try std.testing.expectEqual(expectedItem.start, actualNodes.items[i].cachedAbsoluteStart);
                        try std.testing.expectEqual(expectedItem.end, actualNodes.items[i].cachedAbsoluteEnd);
                    }
                    return;
                },
            }

            if (PRINT_TREE) {
                try printTree(&self._tree);
            }

            try assertTreeInvariants(&self._tree);

            const actual = try self._tree.getAllInOrder();
            defer actual.deinit();
            const expected = self._oracle.intervals;
            for (expected.items, 0..) |expectedItem, i| {
                try std.testing.expectEqual(expectedItem.start, actual.items[i].cachedAbsoluteStart);
                try std.testing.expectEqual(expectedItem.end, actual.items[i].cachedAbsoluteEnd);
            }
        }

        fn getExistingNodeId(self: *TestState, index: usize) !usize {
            var currIndex: isize = -1;
            for (self._treeNodes.items, 0..) |item, i| {
                if (item) |_| {
                    currIndex += 1;
                    if (currIndex == index) {
                        return @as(usize, i);
                    }
                }
            }
            return error.Unexpected;
        }
    };

    const InsertOperation = struct {
        begin: usize,
        end: usize,
    };

    const DeleteOperation = struct {
        id: usize,
    };

    const ChangeOperation = struct {
        id: usize,
        begin: usize,
        end: usize,
    };

    const SearchOperation = struct {
        begin: usize,
        end: usize,
    };

    const Operation = union(enum) {
        insert: InsertOperation,
        delete: DeleteOperation,
        change: ChangeOperation,
        search: SearchOperation,
    };

    fn testIntervalTree(ops: []const Operation) !void {
        const allocator = std.testing.allocator;
        var state = TestState.init(allocator);
        defer state.deinit();
        for (ops) |op| {
            try state.acceptOp(op);
        }
    }

    fn getRandomInt(min: usize, max: usize) usize {
        const bound = max - min + 1;
        return @as(usize, @intFromFloat(@floor(rand.float(f64) * @as(f64, @floatFromInt(bound))))) + min;
    }

    fn getRandomRange(min: usize, max: usize) struct { usize, usize } {
        const begin = getRandomInt(min, max);
        var length: usize = undefined;
        if (getRandomInt(1, 10) <= 2) {
            // large range
            length = getRandomInt(0, max - begin);
        } else {
            // small range
            length = getRandomInt(0, @min(max - begin, 10));
        }
        return .{ begin, begin + length };
    }

    const AutoTest = struct {
        _ops: ArrayList(Operation),
        _state: TestState,
        _insertCnt: usize,
        _deleteCnt: usize,
        _changeCnt: usize,

        fn init(allocator: Allocator) AutoTest {
            return .{
                ._ops = ArrayList(Operation).init(allocator),
                ._state = TestState.init(allocator),
                ._insertCnt = getRandomInt(MIN_INSERTS, MAX_INSERTS),
                ._changeCnt = getRandomInt(MIN_CHANGE_CNT, MAX_CHANGE_CNT),
                ._deleteCnt = 0,
            };
        }

        fn deinit(self: *AutoTest) void {
            self._ops.deinit();
            self._state.deinit();
        }

        fn _doRandomInsert(self: *AutoTest) !void {
            const range = getRandomRange(MIN_INTERVAL_START, MAX_INTERVAL_END);
            try self._run(.{ .insert = .{
                .begin = range.@"0",
                .end = range.@"1",
            } });
        }

        fn _doRandomDelete(self: *AutoTest) !void {
            const idx = getRandomInt(self._deleteCnt / 2, self._deleteCnt - 1);
            try self._run(.{ .delete = .{ .id = try self._state.getExistingNodeId(idx) } });
        }

        fn _doRandomChange(self: *AutoTest) !void {
            const idx = getRandomInt(0, self._deleteCnt - 1);
            const range = getRandomRange(MIN_INTERVAL_START, MAX_INTERVAL_END);
            try self._run(.{ .change = .{
                .id = try self._state.getExistingNodeId(idx),
                .begin = range.@"0",
                .end = range.@"1",
            } });
        }

        fn run(self: *AutoTest) !void {
            while (self._insertCnt > 0 or self._deleteCnt > 0 or self._changeCnt > 0) {
                if (self._insertCnt > 0) {
                    try self._doRandomInsert();
                    self._insertCnt -= 1;
                    self._deleteCnt += 1;
                } else if (self._changeCnt > 0) {
                    try self._doRandomChange();
                    self._changeCnt -= 1;
                } else {
                    try self._doRandomDelete();
                    self._deleteCnt -= 1;
                }

                // Let's also search for something...
                const searchRange = getRandomRange(MIN_INTERVAL_START, MAX_INTERVAL_END);
                try self._run(.{ .search = .{
                    .begin = searchRange.@"0",
                    .end = searchRange.@"1",
                } });
            }
        }

        fn _run(self: *AutoTest, op: Operation) !void {
            try self._ops.append(op);
            try self._state.acceptOp(op);
        }

        fn print(self: *AutoTest) void {
            std.debug.print("testIntervalTree({s})\n", .{json.Stringify.encodeJsonString(self._ops.items)});
        }
    };

    test "gen01" {
        try testIntervalTree(&[_]Operation{
            .{ .insert = .{
                .begin = 28,
                .end = 35,
            } },
            .{ .insert = .{
                .begin = 52,
                .end = 54,
            } },
            .{ .insert = .{
                .begin = 63,
                .end = 69,
            } },
        });
    }

    test "gen02" {
        try testIntervalTree(&[_]Operation{
            .{ .insert = .{
                .begin = 80,
                .end = 89,
            } },
            .{ .insert = .{
                .begin = 92,
                .end = 100,
            } },
            .{ .insert = .{
                .begin = 99,
                .end = 99,
            } },
        });
    }

    test "gen03" {
        try testIntervalTree(&[_]Operation{
            .{ .insert = .{
                .begin = 89,
                .end = 96,
            } },
            .{ .insert = .{
                .begin = 71,
                .end = 74,
            } },
            .{ .delete = .{ .id = 1 } },
        });
    }

    test "gen04" {
        try testIntervalTree(&[_]Operation{
            .{ .insert = .{
                .begin = 44,
                .end = 46,
            } },
            .{ .insert = .{
                .begin = 85,
                .end = 88,
            } },
            .{ .delete = .{ .id = 0 } },
        });
    }

    test "gen05" {
        try testIntervalTree(&[_]Operation{
            .{ .insert = .{ .begin = 82, .end = 90 } },
            .{ .insert = .{ .begin = 69, .end = 73 } },
            .{ .delete = .{ .id = 0 } },
            .{ .delete = .{ .id = 1 } },
        });
    }

    test "gen06" {
        try testIntervalTree(&[_]Operation{
            .{ .insert = .{ .begin = 41, .end = 63 } },
            .{ .insert = .{ .begin = 98, .end = 98 } },
            .{ .insert = .{ .begin = 47, .end = 51 } },
            .{ .delete = .{ .id = 2 } },
        });
    }

    test "gen07" {
        try testIntervalTree(&[_]Operation{
            .{ .insert = .{ .begin = 24, .end = 26 } },
            .{ .insert = .{ .begin = 11, .end = 28 } },
            .{ .insert = .{ .begin = 27, .end = 30 } },
            .{ .insert = .{ .begin = 80, .end = 85 } },
            .{ .delete = .{ .id = 1 } },
        });
    }

    test "gen08" {
        try testIntervalTree(&[_]Operation{
            .{ .insert = .{ .begin = 100, .end = 100 } },
            .{ .insert = .{ .begin = 100, .end = 100 } },
        });
    }

    test "gen09" {
        try testIntervalTree(&[_]Operation{
            .{ .insert = .{ .begin = 58, .end = 65 } },
            .{ .insert = .{ .begin = 82, .end = 96 } },
            .{ .insert = .{ .begin = 58, .end = 65 } },
        });
    }

    test "gen10" {
        try testIntervalTree(&[_]Operation{
            .{ .insert = .{ .begin = 32, .end = 40 } },
            .{ .insert = .{ .begin = 25, .end = 29 } },
            .{ .insert = .{ .begin = 24, .end = 32 } },
        });
    }

    test "gen11" {
        try testIntervalTree(&[_]Operation{
            .{ .insert = .{ .begin = 25, .end = 70 } },
            .{ .insert = .{ .begin = 99, .end = 100 } },
            .{ .insert = .{ .begin = 46, .end = 51 } },
            .{ .insert = .{ .begin = 57, .end = 57 } },
            .{ .delete = .{ .id = 2 } },
        });
    }

    test "gen12" {
        try testIntervalTree(&[_]Operation{
            .{ .insert = .{ .begin = 20, .end = 26 } },
            .{ .insert = .{ .begin = 10, .end = 18 } },
            .{ .insert = .{ .begin = 99, .end = 99 } },
            .{ .insert = .{ .begin = 37, .end = 59 } },
            .{ .delete = .{ .id = 2 } },
        });
    }

    test "gen13" {
        try testIntervalTree(&[_]Operation{
            .{ .insert = .{ .begin = 3, .end = 91 } },
            .{ .insert = .{ .begin = 57, .end = 57 } },
            .{ .insert = .{ .begin = 35, .end = 44 } },
            .{ .insert = .{ .begin = 72, .end = 81 } },
            .{ .delete = .{ .id = 2 } },
        });
    }

    test "gen14" {
        try testIntervalTree(&[_]Operation{
            .{ .insert = .{ .begin = 58, .end = 61 } },
            .{ .insert = .{ .begin = 34, .end = 35 } },
            .{ .insert = .{ .begin = 56, .end = 62 } },
            .{ .insert = .{ .begin = 69, .end = 78 } },
            .{ .delete = .{ .id = 0 } },
        });
    }

    test "gen15" {
        try testIntervalTree(&[_]Operation{
            .{ .insert = .{ .begin = 63, .end = 69 } },
            .{ .insert = .{ .begin = 17, .end = 24 } },
            .{ .insert = .{ .begin = 3, .end = 13 } },
            .{ .insert = .{ .begin = 84, .end = 94 } },
            .{ .insert = .{ .begin = 18, .end = 23 } },
            .{ .insert = .{ .begin = 96, .end = 98 } },
            .{ .delete = .{ .id = 1 } },
        });
    }

    test "gen16" {
        try testIntervalTree(&[_]Operation{
            .{ .insert = .{ .begin = 27, .end = 27 } },
            .{ .insert = .{ .begin = 42, .end = 87 } },
            .{ .insert = .{ .begin = 42, .end = 49 } },
            .{ .insert = .{ .begin = 69, .end = 71 } },
            .{ .insert = .{ .begin = 20, .end = 27 } },
            .{ .insert = .{ .begin = 8, .end = 9 } },
            .{ .insert = .{ .begin = 42, .end = 49 } },
            .{ .delete = .{ .id = 1 } },
        });
    }

    test "gen17" {
        try testIntervalTree(&[_]Operation{
            .{ .insert = .{ .begin = 21, .end = 23 } },
            .{ .insert = .{ .begin = 83, .end = 87 } },
            .{ .insert = .{ .begin = 56, .end = 58 } },
            .{ .insert = .{ .begin = 1, .end = 55 } },
            .{ .insert = .{ .begin = 56, .end = 59 } },
            .{ .insert = .{ .begin = 58, .end = 60 } },
            .{ .insert = .{ .begin = 56, .end = 65 } },
            .{ .delete = .{ .id = 1 } },
            .{ .delete = .{ .id = 0 } },
            .{ .delete = .{ .id = 6 } },
        });
    }

    test "gen18" {
        try testIntervalTree(&[_]Operation{
            .{ .insert = .{ .begin = 25, .end = 25 } },
            .{ .insert = .{ .begin = 67, .end = 79 } },
            .{ .delete = .{ .id = 0 } },
            .{ .search = .{ .begin = 65, .end = 75 } },
        });
    }

    test "force delta overflow" {
        // Search the IntervalNode.init method for FORCE_OVERFLOWING_TEST
        // to force that this test leads to a delta normalization
        try testIntervalTree(&[_]Operation{
            .{ .insert = .{ .begin = 686081138593427, .end = 733009856502260 } },
            .{ .insert = .{ .begin = 591031326181669, .end = 591031326181672 } },
            .{ .insert = .{ .begin = 940037682731896, .end = 940037682731903 } },
            .{ .insert = .{ .begin = 598413641151120, .end = 598413641151128 } },
            .{ .insert = .{ .begin = 800564156553344, .end = 800564156553351 } },
            .{ .insert = .{ .begin = 894198957565481, .end = 894198957565491 } },
        });
    }

    // TEST_COUNT = 0;
    // PRINT_TREE = true;

    test "auto test" {
        for (0..TEST_COUNT) |i| {
            if (i % 100 == 0) {
                std.debug.print("TEST {d}/{d}\n", .{ i + 1, TEST_COUNT });
            }
            var autoTest = AutoTest.init(std.testing.allocator);
            defer autoTest.deinit();
            try autoTest.run();
        }
    }
};

const SearchingTests = struct {
    fn createCormenTree(allocator: Allocator) !IntervalTree {
        var r = IntervalTree.init(allocator);
        const data = [_][2]usize{
            .{ 16, 21 },
            .{ 8, 9 },
            .{ 25, 30 },
            .{ 5, 8 },
            .{ 15, 23 },
            .{ 17, 19 },
            .{ 26, 26 },
            .{ 0, 3 },
            .{ 6, 10 },
            .{ 19, 20 },
        };
        for (data) |rg| {
            const node = try IntervalNode.init(std.testing.allocator, 0, rg[0], rg[1]);
            r.insert(node);
        }
        return r;
    }

    fn assertIntervalSearch(start: usize, end: usize, expected: []const [2]usize) !void {
        var tree = try createCormenTree(std.testing.allocator);
        defer tree.deinit();

        const actualNodes = try tree.intervalSearch(start, end, 0, false, 0, false);
        defer actualNodes.deinit();
        for (expected, 0..) |expectedItem, i| {
            try std.testing.expectEqual(expectedItem[0], actualNodes.items[i].cachedAbsoluteStart);
            try std.testing.expectEqual(expectedItem[1], actualNodes.items[i].cachedAbsoluteEnd);
        }
    }

    test "cormen 1->2" {
        try assertIntervalSearch(1, 2, &[_][2]usize{.{ 0, 3 }});
    }

    test "cormen 4->8" {
        try assertIntervalSearch(4, 8, &[_][2]usize{
            .{ 5, 8 },
            .{ 6, 10 },
            .{ 8, 9 },
        });
    }

    test "cormen 10->15" {
        try assertIntervalSearch(10, 15, &[_][2]usize{
            .{ 6, 10 },
            .{ 15, 23 },
        });
    }

    test "cormen 21->25" {
        try assertIntervalSearch(21, 25, &[_][2]usize{
            .{ 15, 23 },
            .{ 16, 21 },
            .{ 25, 30 },
        });
    }

    test "cormen 24->24" {
        try assertIntervalSearch(24, 24, &[_][2]usize{});
    }
};

const IntervalTree2Tests = struct {
    const allocator = std.testing.allocator;
    fn assertNodeAcceptEdit(msg: []const u8, nodeStart: usize, nodeEnd: usize, nodeStickiness: TrackedRangeStickiness, start: usize, end: usize, textLength: usize, forceMoveMarkers: bool, expectedNodeStart: usize, expectedNodeEnd: usize) !void {
        const node = try IntervalNode.init(allocator, 0, nodeStart, nodeEnd);
        defer node.deinit(allocator);
        node.metadata.stickiness = nodeStickiness;
        nodeAcceptEdit(node, start, end, textLength, forceMoveMarkers);

        errdefer {
            std.debug.print("test case: {s}\n", .{msg});
        }
        try std.testing.expectEqual(expectedNodeStart, node.start);
        try std.testing.expectEqual(expectedNodeEnd, node.end);
    }

    test "nodeAcceptEdit" {
        // A. collapsed decoration
        {
            // no-op
            try assertNodeAcceptEdit("A.000", 0, 0, .AlwaysGrowsWhenTypingAtEdges, 0, 0, 0, false, 0, 0);
            try assertNodeAcceptEdit("A.001", 0, 0, .NeverGrowsWhenTypingAtEdges, 0, 0, 0, false, 0, 0);
            try assertNodeAcceptEdit("A.002", 0, 0, .GrowsOnlyWhenTypingBefore, 0, 0, 0, false, 0, 0);
            try assertNodeAcceptEdit("A.003", 0, 0, .GrowsOnlyWhenTypingAfter, 0, 0, 0, false, 0, 0);
            try assertNodeAcceptEdit("A.004", 0, 0, .AlwaysGrowsWhenTypingAtEdges, 0, 0, 0, true, 0, 0);
            try assertNodeAcceptEdit("A.005", 0, 0, .NeverGrowsWhenTypingAtEdges, 0, 0, 0, true, 0, 0);
            try assertNodeAcceptEdit("A.006", 0, 0, .GrowsOnlyWhenTypingBefore, 0, 0, 0, true, 0, 0);
            try assertNodeAcceptEdit("A.007", 0, 0, .GrowsOnlyWhenTypingAfter, 0, 0, 0, true, 0, 0);
            // insertion
            try assertNodeAcceptEdit("A.008", 0, 0, .AlwaysGrowsWhenTypingAtEdges, 0, 0, 1, false, 0, 1);
            try assertNodeAcceptEdit("A.009", 0, 0, .NeverGrowsWhenTypingAtEdges, 0, 0, 1, false, 1, 1);
            try assertNodeAcceptEdit("A.010", 0, 0, .GrowsOnlyWhenTypingBefore, 0, 0, 1, false, 0, 0);
            try assertNodeAcceptEdit("A.011", 0, 0, .GrowsOnlyWhenTypingAfter, 0, 0, 1, false, 1, 1);
            try assertNodeAcceptEdit("A.012", 0, 0, .AlwaysGrowsWhenTypingAtEdges, 0, 0, 1, true, 1, 1);
            try assertNodeAcceptEdit("A.013", 0, 0, .NeverGrowsWhenTypingAtEdges, 0, 0, 1, true, 1, 1);
            try assertNodeAcceptEdit("A.014", 0, 0, .GrowsOnlyWhenTypingBefore, 0, 0, 1, true, 1, 1);
            try assertNodeAcceptEdit("A.015", 0, 0, .GrowsOnlyWhenTypingAfter, 0, 0, 1, true, 1, 1);
        }

        // B. non collapsed decoration
        {
            // no-op
            try assertNodeAcceptEdit("B.000", 0, 5, .AlwaysGrowsWhenTypingAtEdges, 0, 0, 0, false, 0, 5);
            try assertNodeAcceptEdit("B.001", 0, 5, .NeverGrowsWhenTypingAtEdges, 0, 0, 0, false, 0, 5);
            try assertNodeAcceptEdit("B.002", 0, 5, .GrowsOnlyWhenTypingBefore, 0, 0, 0, false, 0, 5);
            try assertNodeAcceptEdit("B.003", 0, 5, .GrowsOnlyWhenTypingAfter, 0, 0, 0, false, 0, 5);
            try assertNodeAcceptEdit("B.004", 0, 5, .AlwaysGrowsWhenTypingAtEdges, 0, 0, 0, true, 0, 5);
            try assertNodeAcceptEdit("B.005", 0, 5, .NeverGrowsWhenTypingAtEdges, 0, 0, 0, true, 0, 5);
            try assertNodeAcceptEdit("B.006", 0, 5, .GrowsOnlyWhenTypingBefore, 0, 0, 0, true, 0, 5);
            try assertNodeAcceptEdit("B.007", 0, 5, .GrowsOnlyWhenTypingAfter, 0, 0, 0, true, 0, 5);
            // insertion at start
            try assertNodeAcceptEdit("B.008", 0, 5, .AlwaysGrowsWhenTypingAtEdges, 0, 0, 1, false, 0, 6);
            try assertNodeAcceptEdit("B.009", 0, 5, .NeverGrowsWhenTypingAtEdges, 0, 0, 1, false, 1, 6);
            try assertNodeAcceptEdit("B.010", 0, 5, .GrowsOnlyWhenTypingBefore, 0, 0, 1, false, 0, 6);
            try assertNodeAcceptEdit("B.011", 0, 5, .GrowsOnlyWhenTypingAfter, 0, 0, 1, false, 1, 6);
            try assertNodeAcceptEdit("B.012", 0, 5, .AlwaysGrowsWhenTypingAtEdges, 0, 0, 1, true, 1, 6);
            try assertNodeAcceptEdit("B.013", 0, 5, .NeverGrowsWhenTypingAtEdges, 0, 0, 1, true, 1, 6);
            try assertNodeAcceptEdit("B.014", 0, 5, .GrowsOnlyWhenTypingBefore, 0, 0, 1, true, 1, 6);
            try assertNodeAcceptEdit("B.015", 0, 5, .GrowsOnlyWhenTypingAfter, 0, 0, 1, true, 1, 6);
            // insertion in middle
            try assertNodeAcceptEdit("B.016", 0, 5, .AlwaysGrowsWhenTypingAtEdges, 2, 2, 1, false, 0, 6);
            try assertNodeAcceptEdit("B.017", 0, 5, .NeverGrowsWhenTypingAtEdges, 2, 2, 1, false, 0, 6);
            try assertNodeAcceptEdit("B.018", 0, 5, .GrowsOnlyWhenTypingBefore, 2, 2, 1, false, 0, 6);
            try assertNodeAcceptEdit("B.019", 0, 5, .GrowsOnlyWhenTypingAfter, 2, 2, 1, false, 0, 6);
            try assertNodeAcceptEdit("B.020", 0, 5, .AlwaysGrowsWhenTypingAtEdges, 2, 2, 1, true, 0, 6);
            try assertNodeAcceptEdit("B.021", 0, 5, .NeverGrowsWhenTypingAtEdges, 2, 2, 1, true, 0, 6);
            try assertNodeAcceptEdit("B.022", 0, 5, .GrowsOnlyWhenTypingBefore, 2, 2, 1, true, 0, 6);
            try assertNodeAcceptEdit("B.023", 0, 5, .GrowsOnlyWhenTypingAfter, 2, 2, 1, true, 0, 6);
            // insertion at end
            try assertNodeAcceptEdit("B.024", 0, 5, .AlwaysGrowsWhenTypingAtEdges, 5, 5, 1, false, 0, 6);
            try assertNodeAcceptEdit("B.025", 0, 5, .NeverGrowsWhenTypingAtEdges, 5, 5, 1, false, 0, 5);
            try assertNodeAcceptEdit("B.026", 0, 5, .GrowsOnlyWhenTypingBefore, 5, 5, 1, false, 0, 5);
            try assertNodeAcceptEdit("B.027", 0, 5, .GrowsOnlyWhenTypingAfter, 5, 5, 1, false, 0, 6);
            try assertNodeAcceptEdit("B.028", 0, 5, .AlwaysGrowsWhenTypingAtEdges, 5, 5, 1, true, 0, 6);
            try assertNodeAcceptEdit("B.029", 0, 5, .NeverGrowsWhenTypingAtEdges, 5, 5, 1, true, 0, 6);
            try assertNodeAcceptEdit("B.030", 0, 5, .GrowsOnlyWhenTypingBefore, 5, 5, 1, true, 0, 6);
            try assertNodeAcceptEdit("B.031", 0, 5, .GrowsOnlyWhenTypingAfter, 5, 5, 1, true, 0, 6);

            // replace with larger text until start
            try assertNodeAcceptEdit("B.032", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 4, 5, 2, false, 5, 11);
            try assertNodeAcceptEdit("B.033", 5, 10, .NeverGrowsWhenTypingAtEdges, 4, 5, 2, false, 6, 11);
            try assertNodeAcceptEdit("B.034", 5, 10, .GrowsOnlyWhenTypingBefore, 4, 5, 2, false, 5, 11);
            try assertNodeAcceptEdit("B.035", 5, 10, .GrowsOnlyWhenTypingAfter, 4, 5, 2, false, 6, 11);
            try assertNodeAcceptEdit("B.036", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 4, 5, 2, true, 6, 11);
            try assertNodeAcceptEdit("B.037", 5, 10, .NeverGrowsWhenTypingAtEdges, 4, 5, 2, true, 6, 11);
            try assertNodeAcceptEdit("B.038", 5, 10, .GrowsOnlyWhenTypingBefore, 4, 5, 2, true, 6, 11);
            try assertNodeAcceptEdit("B.039", 5, 10, .GrowsOnlyWhenTypingAfter, 4, 5, 2, true, 6, 11);
            // replace with smaller text until start
            try assertNodeAcceptEdit("B.040", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 3, 5, 1, false, 4, 9);
            try assertNodeAcceptEdit("B.041", 5, 10, .NeverGrowsWhenTypingAtEdges, 3, 5, 1, false, 4, 9);
            try assertNodeAcceptEdit("B.042", 5, 10, .GrowsOnlyWhenTypingBefore, 3, 5, 1, false, 4, 9);
            try assertNodeAcceptEdit("B.043", 5, 10, .GrowsOnlyWhenTypingAfter, 3, 5, 1, false, 4, 9);
            try assertNodeAcceptEdit("B.044", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 3, 5, 1, true, 4, 9);
            try assertNodeAcceptEdit("B.045", 5, 10, .NeverGrowsWhenTypingAtEdges, 3, 5, 1, true, 4, 9);
            try assertNodeAcceptEdit("B.046", 5, 10, .GrowsOnlyWhenTypingBefore, 3, 5, 1, true, 4, 9);
            try assertNodeAcceptEdit("B.047", 5, 10, .GrowsOnlyWhenTypingAfter, 3, 5, 1, true, 4, 9);

            // replace with larger text select start
            try assertNodeAcceptEdit("B.048", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 4, 6, 3, false, 5, 11);
            try assertNodeAcceptEdit("B.049", 5, 10, .NeverGrowsWhenTypingAtEdges, 4, 6, 3, false, 5, 11);
            try assertNodeAcceptEdit("B.050", 5, 10, .GrowsOnlyWhenTypingBefore, 4, 6, 3, false, 5, 11);
            try assertNodeAcceptEdit("B.051", 5, 10, .GrowsOnlyWhenTypingAfter, 4, 6, 3, false, 5, 11);
            try assertNodeAcceptEdit("B.052", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 4, 6, 3, true, 7, 11);
            try assertNodeAcceptEdit("B.053", 5, 10, .NeverGrowsWhenTypingAtEdges, 4, 6, 3, true, 7, 11);
            try assertNodeAcceptEdit("B.054", 5, 10, .GrowsOnlyWhenTypingBefore, 4, 6, 3, true, 7, 11);
            try assertNodeAcceptEdit("B.055", 5, 10, .GrowsOnlyWhenTypingAfter, 4, 6, 3, true, 7, 11);
            // replace with smaller text select start
            try assertNodeAcceptEdit("B.056", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 4, 6, 1, false, 5, 9);
            try assertNodeAcceptEdit("B.057", 5, 10, .NeverGrowsWhenTypingAtEdges, 4, 6, 1, false, 5, 9);
            try assertNodeAcceptEdit("B.058", 5, 10, .GrowsOnlyWhenTypingBefore, 4, 6, 1, false, 5, 9);
            try assertNodeAcceptEdit("B.059", 5, 10, .GrowsOnlyWhenTypingAfter, 4, 6, 1, false, 5, 9);
            try assertNodeAcceptEdit("B.060", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 4, 6, 1, true, 5, 9);
            try assertNodeAcceptEdit("B.061", 5, 10, .NeverGrowsWhenTypingAtEdges, 4, 6, 1, true, 5, 9);
            try assertNodeAcceptEdit("B.062", 5, 10, .GrowsOnlyWhenTypingBefore, 4, 6, 1, true, 5, 9);
            try assertNodeAcceptEdit("B.063", 5, 10, .GrowsOnlyWhenTypingAfter, 4, 6, 1, true, 5, 9);

            // replace with larger text from start
            try assertNodeAcceptEdit("B.064", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 5, 6, 2, false, 5, 11);
            try assertNodeAcceptEdit("B.065", 5, 10, .NeverGrowsWhenTypingAtEdges, 5, 6, 2, false, 5, 11);
            try assertNodeAcceptEdit("B.066", 5, 10, .GrowsOnlyWhenTypingBefore, 5, 6, 2, false, 5, 11);
            try assertNodeAcceptEdit("B.067", 5, 10, .GrowsOnlyWhenTypingAfter, 5, 6, 2, false, 5, 11);
            try assertNodeAcceptEdit("B.068", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 5, 6, 2, true, 7, 11);
            try assertNodeAcceptEdit("B.069", 5, 10, .NeverGrowsWhenTypingAtEdges, 5, 6, 2, true, 7, 11);
            try assertNodeAcceptEdit("B.070", 5, 10, .GrowsOnlyWhenTypingBefore, 5, 6, 2, true, 7, 11);
            try assertNodeAcceptEdit("B.071", 5, 10, .GrowsOnlyWhenTypingAfter, 5, 6, 2, true, 7, 11);
            // replace with smaller text from start
            try assertNodeAcceptEdit("B.072", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 5, 7, 1, false, 5, 9);
            try assertNodeAcceptEdit("B.073", 5, 10, .NeverGrowsWhenTypingAtEdges, 5, 7, 1, false, 5, 9);
            try assertNodeAcceptEdit("B.074", 5, 10, .GrowsOnlyWhenTypingBefore, 5, 7, 1, false, 5, 9);
            try assertNodeAcceptEdit("B.075", 5, 10, .GrowsOnlyWhenTypingAfter, 5, 7, 1, false, 5, 9);
            try assertNodeAcceptEdit("B.076", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 5, 7, 1, true, 6, 9);
            try assertNodeAcceptEdit("B.077", 5, 10, .NeverGrowsWhenTypingAtEdges, 5, 7, 1, true, 6, 9);
            try assertNodeAcceptEdit("B.078", 5, 10, .GrowsOnlyWhenTypingBefore, 5, 7, 1, true, 6, 9);
            try assertNodeAcceptEdit("B.079", 5, 10, .GrowsOnlyWhenTypingAfter, 5, 7, 1, true, 6, 9);

            // replace with larger text to end
            try assertNodeAcceptEdit("B.080", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 9, 10, 2, false, 5, 11);
            try assertNodeAcceptEdit("B.081", 5, 10, .NeverGrowsWhenTypingAtEdges, 9, 10, 2, false, 5, 10);
            try assertNodeAcceptEdit("B.082", 5, 10, .GrowsOnlyWhenTypingBefore, 9, 10, 2, false, 5, 10);
            try assertNodeAcceptEdit("B.083", 5, 10, .GrowsOnlyWhenTypingAfter, 9, 10, 2, false, 5, 11);
            try assertNodeAcceptEdit("B.084", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 9, 10, 2, true, 5, 11);
            try assertNodeAcceptEdit("B.085", 5, 10, .NeverGrowsWhenTypingAtEdges, 9, 10, 2, true, 5, 11);
            try assertNodeAcceptEdit("B.086", 5, 10, .GrowsOnlyWhenTypingBefore, 9, 10, 2, true, 5, 11);
            try assertNodeAcceptEdit("B.087", 5, 10, .GrowsOnlyWhenTypingAfter, 9, 10, 2, true, 5, 11);
            // replace with smaller text to end
            try assertNodeAcceptEdit("B.088", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 8, 10, 1, false, 5, 9);
            try assertNodeAcceptEdit("B.089", 5, 10, .NeverGrowsWhenTypingAtEdges, 8, 10, 1, false, 5, 9);
            try assertNodeAcceptEdit("B.090", 5, 10, .GrowsOnlyWhenTypingBefore, 8, 10, 1, false, 5, 9);
            try assertNodeAcceptEdit("B.091", 5, 10, .GrowsOnlyWhenTypingAfter, 8, 10, 1, false, 5, 9);
            try assertNodeAcceptEdit("B.092", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 8, 10, 1, true, 5, 9);
            try assertNodeAcceptEdit("B.093", 5, 10, .NeverGrowsWhenTypingAtEdges, 8, 10, 1, true, 5, 9);
            try assertNodeAcceptEdit("B.094", 5, 10, .GrowsOnlyWhenTypingBefore, 8, 10, 1, true, 5, 9);
            try assertNodeAcceptEdit("B.095", 5, 10, .GrowsOnlyWhenTypingAfter, 8, 10, 1, true, 5, 9);

            // replace with larger text select end
            try assertNodeAcceptEdit("B.096", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 9, 11, 3, false, 5, 10);
            try assertNodeAcceptEdit("B.097", 5, 10, .NeverGrowsWhenTypingAtEdges, 9, 11, 3, false, 5, 10);
            try assertNodeAcceptEdit("B.098", 5, 10, .GrowsOnlyWhenTypingBefore, 9, 11, 3, false, 5, 10);
            try assertNodeAcceptEdit("B.099", 5, 10, .GrowsOnlyWhenTypingAfter, 9, 11, 3, false, 5, 10);
            try assertNodeAcceptEdit("B.100", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 9, 11, 3, true, 5, 12);
            try assertNodeAcceptEdit("B.101", 5, 10, .NeverGrowsWhenTypingAtEdges, 9, 11, 3, true, 5, 12);
            try assertNodeAcceptEdit("B.102", 5, 10, .GrowsOnlyWhenTypingBefore, 9, 11, 3, true, 5, 12);
            try assertNodeAcceptEdit("B.103", 5, 10, .GrowsOnlyWhenTypingAfter, 9, 11, 3, true, 5, 12);
            // replace with smaller text select end
            try assertNodeAcceptEdit("B.104", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 9, 11, 1, false, 5, 10);
            try assertNodeAcceptEdit("B.105", 5, 10, .NeverGrowsWhenTypingAtEdges, 9, 11, 1, false, 5, 10);
            try assertNodeAcceptEdit("B.106", 5, 10, .GrowsOnlyWhenTypingBefore, 9, 11, 1, false, 5, 10);
            try assertNodeAcceptEdit("B.107", 5, 10, .GrowsOnlyWhenTypingAfter, 9, 11, 1, false, 5, 10);
            try assertNodeAcceptEdit("B.108", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 9, 11, 1, true, 5, 10);
            try assertNodeAcceptEdit("B.109", 5, 10, .NeverGrowsWhenTypingAtEdges, 9, 11, 1, true, 5, 10);
            try assertNodeAcceptEdit("B.110", 5, 10, .GrowsOnlyWhenTypingBefore, 9, 11, 1, true, 5, 10);
            try assertNodeAcceptEdit("B.111", 5, 10, .GrowsOnlyWhenTypingAfter, 9, 11, 1, true, 5, 10);

            // replace with larger text from end
            try assertNodeAcceptEdit("B.112", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 10, 11, 3, false, 5, 10);
            try assertNodeAcceptEdit("B.113", 5, 10, .NeverGrowsWhenTypingAtEdges, 10, 11, 3, false, 5, 10);
            try assertNodeAcceptEdit("B.114", 5, 10, .GrowsOnlyWhenTypingBefore, 10, 11, 3, false, 5, 10);
            try assertNodeAcceptEdit("B.115", 5, 10, .GrowsOnlyWhenTypingAfter, 10, 11, 3, false, 5, 10);
            try assertNodeAcceptEdit("B.116", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 10, 11, 3, true, 5, 13);
            try assertNodeAcceptEdit("B.117", 5, 10, .NeverGrowsWhenTypingAtEdges, 10, 11, 3, true, 5, 13);
            try assertNodeAcceptEdit("B.118", 5, 10, .GrowsOnlyWhenTypingBefore, 10, 11, 3, true, 5, 13);
            try assertNodeAcceptEdit("B.119", 5, 10, .GrowsOnlyWhenTypingAfter, 10, 11, 3, true, 5, 13);
            // replace with smaller text from end
            try assertNodeAcceptEdit("B.120", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 10, 12, 1, false, 5, 10);
            try assertNodeAcceptEdit("B.121", 5, 10, .NeverGrowsWhenTypingAtEdges, 10, 12, 1, false, 5, 10);
            try assertNodeAcceptEdit("B.122", 5, 10, .GrowsOnlyWhenTypingBefore, 10, 12, 1, false, 5, 10);
            try assertNodeAcceptEdit("B.123", 5, 10, .GrowsOnlyWhenTypingAfter, 10, 12, 1, false, 5, 10);
            try assertNodeAcceptEdit("B.124", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 10, 12, 1, true, 5, 11);
            try assertNodeAcceptEdit("B.125", 5, 10, .NeverGrowsWhenTypingAtEdges, 10, 12, 1, true, 5, 11);
            try assertNodeAcceptEdit("B.126", 5, 10, .GrowsOnlyWhenTypingBefore, 10, 12, 1, true, 5, 11);
            try assertNodeAcceptEdit("B.127", 5, 10, .GrowsOnlyWhenTypingAfter, 10, 12, 1, true, 5, 11);

            // delete until start
            try assertNodeAcceptEdit("B.128", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 4, 5, 0, false, 4, 9);
            try assertNodeAcceptEdit("B.129", 5, 10, .NeverGrowsWhenTypingAtEdges, 4, 5, 0, false, 4, 9);
            try assertNodeAcceptEdit("B.130", 5, 10, .GrowsOnlyWhenTypingBefore, 4, 5, 0, false, 4, 9);
            try assertNodeAcceptEdit("B.131", 5, 10, .GrowsOnlyWhenTypingAfter, 4, 5, 0, false, 4, 9);
            try assertNodeAcceptEdit("B.132", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 4, 5, 0, true, 4, 9);
            try assertNodeAcceptEdit("B.133", 5, 10, .NeverGrowsWhenTypingAtEdges, 4, 5, 0, true, 4, 9);
            try assertNodeAcceptEdit("B.134", 5, 10, .GrowsOnlyWhenTypingBefore, 4, 5, 0, true, 4, 9);
            try assertNodeAcceptEdit("B.135", 5, 10, .GrowsOnlyWhenTypingAfter, 4, 5, 0, true, 4, 9);

            // delete select start
            try assertNodeAcceptEdit("B.136", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 4, 6, 0, false, 4, 8);
            try assertNodeAcceptEdit("B.137", 5, 10, .NeverGrowsWhenTypingAtEdges, 4, 6, 0, false, 4, 8);
            try assertNodeAcceptEdit("B.138", 5, 10, .GrowsOnlyWhenTypingBefore, 4, 6, 0, false, 4, 8);
            try assertNodeAcceptEdit("B.139", 5, 10, .GrowsOnlyWhenTypingAfter, 4, 6, 0, false, 4, 8);
            try assertNodeAcceptEdit("B.140", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 4, 6, 0, true, 4, 8);
            try assertNodeAcceptEdit("B.141", 5, 10, .NeverGrowsWhenTypingAtEdges, 4, 6, 0, true, 4, 8);
            try assertNodeAcceptEdit("B.142", 5, 10, .GrowsOnlyWhenTypingBefore, 4, 6, 0, true, 4, 8);
            try assertNodeAcceptEdit("B.143", 5, 10, .GrowsOnlyWhenTypingAfter, 4, 6, 0, true, 4, 8);

            // delete from start
            try assertNodeAcceptEdit("B.144", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 5, 6, 0, false, 5, 9);
            try assertNodeAcceptEdit("B.145", 5, 10, .NeverGrowsWhenTypingAtEdges, 5, 6, 0, false, 5, 9);
            try assertNodeAcceptEdit("B.146", 5, 10, .GrowsOnlyWhenTypingBefore, 5, 6, 0, false, 5, 9);
            try assertNodeAcceptEdit("B.147", 5, 10, .GrowsOnlyWhenTypingAfter, 5, 6, 0, false, 5, 9);
            try assertNodeAcceptEdit("B.148", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 5, 6, 0, true, 5, 9);
            try assertNodeAcceptEdit("B.149", 5, 10, .NeverGrowsWhenTypingAtEdges, 5, 6, 0, true, 5, 9);
            try assertNodeAcceptEdit("B.150", 5, 10, .GrowsOnlyWhenTypingBefore, 5, 6, 0, true, 5, 9);
            try assertNodeAcceptEdit("B.151", 5, 10, .GrowsOnlyWhenTypingAfter, 5, 6, 0, true, 5, 9);

            // delete to end
            try assertNodeAcceptEdit("B.152", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 9, 10, 0, false, 5, 9);
            try assertNodeAcceptEdit("B.153", 5, 10, .NeverGrowsWhenTypingAtEdges, 9, 10, 0, false, 5, 9);
            try assertNodeAcceptEdit("B.154", 5, 10, .GrowsOnlyWhenTypingBefore, 9, 10, 0, false, 5, 9);
            try assertNodeAcceptEdit("B.155", 5, 10, .GrowsOnlyWhenTypingAfter, 9, 10, 0, false, 5, 9);
            try assertNodeAcceptEdit("B.156", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 9, 10, 0, true, 5, 9);
            try assertNodeAcceptEdit("B.157", 5, 10, .NeverGrowsWhenTypingAtEdges, 9, 10, 0, true, 5, 9);
            try assertNodeAcceptEdit("B.158", 5, 10, .GrowsOnlyWhenTypingBefore, 9, 10, 0, true, 5, 9);
            try assertNodeAcceptEdit("B.159", 5, 10, .GrowsOnlyWhenTypingAfter, 9, 10, 0, true, 5, 9);

            // delete select end
            try assertNodeAcceptEdit("B.160", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 9, 11, 0, false, 5, 9);
            try assertNodeAcceptEdit("B.161", 5, 10, .NeverGrowsWhenTypingAtEdges, 9, 11, 0, false, 5, 9);
            try assertNodeAcceptEdit("B.162", 5, 10, .GrowsOnlyWhenTypingBefore, 9, 11, 0, false, 5, 9);
            try assertNodeAcceptEdit("B.163", 5, 10, .GrowsOnlyWhenTypingAfter, 9, 11, 0, false, 5, 9);
            try assertNodeAcceptEdit("B.164", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 9, 11, 0, true, 5, 9);
            try assertNodeAcceptEdit("B.165", 5, 10, .NeverGrowsWhenTypingAtEdges, 9, 11, 0, true, 5, 9);
            try assertNodeAcceptEdit("B.166", 5, 10, .GrowsOnlyWhenTypingBefore, 9, 11, 0, true, 5, 9);
            try assertNodeAcceptEdit("B.167", 5, 10, .GrowsOnlyWhenTypingAfter, 9, 11, 0, true, 5, 9);

            // delete from end
            try assertNodeAcceptEdit("B.168", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 10, 11, 0, false, 5, 10);
            try assertNodeAcceptEdit("B.169", 5, 10, .NeverGrowsWhenTypingAtEdges, 10, 11, 0, false, 5, 10);
            try assertNodeAcceptEdit("B.170", 5, 10, .GrowsOnlyWhenTypingBefore, 10, 11, 0, false, 5, 10);
            try assertNodeAcceptEdit("B.171", 5, 10, .GrowsOnlyWhenTypingAfter, 10, 11, 0, false, 5, 10);
            try assertNodeAcceptEdit("B.172", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 10, 11, 0, true, 5, 10);
            try assertNodeAcceptEdit("B.173", 5, 10, .NeverGrowsWhenTypingAtEdges, 10, 11, 0, true, 5, 10);
            try assertNodeAcceptEdit("B.174", 5, 10, .GrowsOnlyWhenTypingBefore, 10, 11, 0, true, 5, 10);
            try assertNodeAcceptEdit("B.175", 5, 10, .GrowsOnlyWhenTypingAfter, 10, 11, 0, true, 5, 10);

            // replace with larger text entire
            try assertNodeAcceptEdit("B.176", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 5, 10, 3, false, 5, 8);
            try assertNodeAcceptEdit("B.177", 5, 10, .NeverGrowsWhenTypingAtEdges, 5, 10, 3, false, 5, 8);
            try assertNodeAcceptEdit("B.178", 5, 10, .GrowsOnlyWhenTypingBefore, 5, 10, 3, false, 5, 8);
            try assertNodeAcceptEdit("B.179", 5, 10, .GrowsOnlyWhenTypingAfter, 5, 10, 3, false, 5, 8);
            try assertNodeAcceptEdit("B.180", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 5, 10, 3, true, 8, 8);
            try assertNodeAcceptEdit("B.181", 5, 10, .NeverGrowsWhenTypingAtEdges, 5, 10, 3, true, 8, 8);
            try assertNodeAcceptEdit("B.182", 5, 10, .GrowsOnlyWhenTypingBefore, 5, 10, 3, true, 8, 8);
            try assertNodeAcceptEdit("B.183", 5, 10, .GrowsOnlyWhenTypingAfter, 5, 10, 3, true, 8, 8);
            // replace with smaller text entire
            try assertNodeAcceptEdit("B.184", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 5, 10, 7, false, 5, 12);
            try assertNodeAcceptEdit("B.185", 5, 10, .NeverGrowsWhenTypingAtEdges, 5, 10, 7, false, 5, 10);
            try assertNodeAcceptEdit("B.186", 5, 10, .GrowsOnlyWhenTypingBefore, 5, 10, 7, false, 5, 10);
            try assertNodeAcceptEdit("B.187", 5, 10, .GrowsOnlyWhenTypingAfter, 5, 10, 7, false, 5, 12);
            try assertNodeAcceptEdit("B.188", 5, 10, .AlwaysGrowsWhenTypingAtEdges, 5, 10, 7, true, 12, 12);
            try assertNodeAcceptEdit("B.189", 5, 10, .NeverGrowsWhenTypingAtEdges, 5, 10, 7, true, 12, 12);
            try assertNodeAcceptEdit("B.190", 5, 10, .GrowsOnlyWhenTypingBefore, 5, 10, 7, true, 12, 12);
            try assertNodeAcceptEdit("B.191", 5, 10, .GrowsOnlyWhenTypingAfter, 5, 10, 7, true, 12, 12);
        }
    }
};

fn printTree(T: *const IntervalTree) !void {
    const allocator = T.allocator;

    if (T.root == SENTINEL) {
        std.debug.print("~~ empty\n", .{});
        return;
    }
    var out = ArrayList([]const u8).init(allocator);
    defer out.deinit();
    defer for (out.items) |item| {
        allocator.free(item);
    };

    try _printTree(T, T.root, 0, 0, &out);

    for (out.items) |item| {
        std.debug.print("{s}", .{item});
    }
    std.debug.print("\n", .{});
}

fn repeatSpaces(allocator: Allocator, count: u8) []const u8 {
    const s = allocator.alloc(u8, count) catch unreachable;
    @memset(s, ' ');
    return s;
}

fn _printTree(T: *const IntervalTree, n: *const IntervalNode, indent: u8, delta: isize, out: *ArrayList([]const u8)) !void {
    const allocator = T.allocator;
    try out.append(try std.fmt.allocPrint(allocator, "[{s},{d}, {d}->{d}, {d}] : {d}->{d}, maxEnd: {d}\n", .{
        if (n.metadata.color == .Red) "R" else "B",
        n.delta,
        n.start,
        n.end,
        n.maxEnd,
        usizeAdd(n.start, delta),
        usizeAdd(n.end, delta),
        usizeAdd(n.maxEnd, delta),
    }));
    if (n.left != SENTINEL) {
        try _printTree(T, n.left, indent + 4, delta, out);
    } else {
        const indentString = repeatSpaces(allocator, indent);
        defer allocator.free(indentString);
        try out.append(try std.fmt.allocPrint(allocator, "{s}    NIL\n", .{indentString}));
    }
    if (n.right != SENTINEL) {
        try _printTree(T, n.right, indent + 4, delta + n.delta, out);
    } else {
        const indentString = repeatSpaces(allocator, indent);
        defer allocator.free(indentString);
        try out.append(try std.fmt.allocPrint(allocator, "{s}    NIL\n", .{indentString}));
    }
}

//#region Assertion

fn assertTreeInvariants(T: *const IntervalTree) !void {
    try std.testing.expectEqual(.Black, SENTINEL.metadata.color);
    try std.testing.expectEqual(SENTINEL, SENTINEL.parent);
    try std.testing.expectEqual(SENTINEL, SENTINEL.left);
    try std.testing.expectEqual(SENTINEL, SENTINEL.right);
    try std.testing.expectEqual(0, SENTINEL.start);
    try std.testing.expectEqual(0, SENTINEL.end);
    try std.testing.expectEqual(0, SENTINEL.delta);
    try std.testing.expectEqual(SENTINEL, T.root.parent);
    try assertValidTree(T);
}

fn depth(n: *const IntervalNode) !usize {
    if (n == SENTINEL) {
        // The leafs are black
        return 1;
    }
    try std.testing.expectEqual(try depth(n.left), try depth(n.right));
    return (if (n.metadata.color == .Black) @as(usize, 1) else @as(usize, 0)) + try depth(n.left);
}

fn assertValidNode(n: *const IntervalNode, delta: isize) !void {
    if (n == SENTINEL) {
        return;
    }

    const l = n.left;
    const r = n.right;

    if (n.metadata.color == .Red) {
        try std.testing.expectEqual(.Black, l.metadata.color);
        try std.testing.expectEqual(.Black, r.metadata.color);
    }

    var expectedMaxEnd = n.end;
    if (l != SENTINEL) {
        try std.testing.expect(intervalCompare(usizeAdd(l.start, delta), usizeAdd(l.end, delta), usizeAdd(n.start, delta), usizeAdd(n.end, delta)) <= 0);
        expectedMaxEnd = @max(expectedMaxEnd, l.maxEnd);
    }
    if (r != SENTINEL) {
        try std.testing.expect(intervalCompare(usizeAdd(n.start, delta), usizeAdd(n.end, delta), usizeAdd(r.start, delta + n.delta), usizeAdd(r.end, delta + n.delta)) <= 0);
        expectedMaxEnd = @max(expectedMaxEnd, usizeAdd(r.maxEnd, n.delta));
    }
    try std.testing.expectEqual(expectedMaxEnd, n.maxEnd);

    try assertValidNode(l, delta);
    try assertValidNode(r, delta + n.delta);
}

fn assertValidTree(T: *const IntervalTree) !void {
    if (T.root == SENTINEL) {
        return;
    }
    try std.testing.expectEqual(.Black, T.root.metadata.color);
    try std.testing.expectEqual(try depth(T.root.left), try depth(T.root.right));
    try assertValidNode(T.root, 0);
}

//#endregion

test "intervalTree" {
    _ = IntervalTree1Tests;
    _ = SearchingTests;
    _ = IntervalTree2Tests;
}
