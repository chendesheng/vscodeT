const std = @import("std");
const ArrayList = std.array_list.Managed;
const Allocator = std.mem.Allocator;
const TestModel = @import("../port/testSupport.zig").TestModel;
const Range = @import("../../../common/core/range.zig").Range;
const Position = @import("../../../common/core/position.zig").Position;
const IState = @import("../../../common/languages.zig").IState;
const ITokenizationSupport = @import("../../../common/languages.zig").ITokenizationSupport;
const EncodedTokenizationResult = @import("../../../common/languages.zig").EncodedTokenizationResult;
const TokenizationRegistry = @import("../../../common/tokenizationRegistry.zig").TokenizationRegistry;
const TokenPacked = @import("../../../common/tokens/lineTokens.zig").TokenPacked;

const CallLog = struct {
    allocator: Allocator,
    lines: ArrayList(ArrayList(u8)),

    fn init(allocator: Allocator) CallLog {
        return .{ .allocator = allocator, .lines = ArrayList(ArrayList(u8)).init(allocator) };
    }

    fn deinit(self: *CallLog) void {
        for (self.lines.items) |*line| line.deinit();
        self.lines.deinit();
    }

    fn add(self: *CallLog, line: []const u8) !void {
        var copy = ArrayList(u8).init(self.allocator);
        errdefer copy.deinit();
        try copy.appendSlice(line);
        try self.lines.append(copy);
    }

    fn take(self: *CallLog) ArrayList(ArrayList(u8)) {
        const result = self.lines;
        self.lines = ArrayList(ArrayList(u8)).init(self.allocator);
        return result;
    }
};

fn expectCalls(log: *CallLog, expected: []const []const u8) !void {
    var actual = log.take();
    defer {
        for (actual.items) |*line| line.deinit();
        actual.deinit();
    }
    try std.testing.expectEqual(expected.len, actual.items.len);
    for (expected, actual.items) |want, got| {
        try std.testing.expectEqualStrings(want, got.items);
    }
}

// ---------- Stateless support used by the first upstream suite ----------

const StatelessSupport = struct {
    log: *CallLog,

    fn getInitialState(ctx: *anyopaque, allocator: Allocator) anyerror!IState {
        _ = ctx;
        return createState(allocator, "");
    }

    fn tokenizeEncoded(ctx: *anyopaque, _: std.Io, allocator: Allocator, line: []const u8, hasEOL: bool, state: IState) anyerror!EncodedTokenizationResult {
        _ = hasEOL;
        const self: *StatelessSupport = @ptrCast(@alignCast(ctx));
        try self.log.add(line);
        return .{ .tokens = try arenaTokens(allocator), .endState = state };
    }

    fn interface(self: *StatelessSupport) ITokenizationSupport {
        return .{
            .context = self,
            .vtable = &.{
                .getInitialState = getInitialState,
                .tokenizeEncoded = tokenizeEncoded,
            },
        };
    }
};

// ---------- Stateful support used by the second upstream suite ----------

const StatefulSupport = struct {
    log: *CallLog,

    fn getInitialState(ctx: *anyopaque, allocator: Allocator) anyerror!IState {
        _ = ctx;
        return createState(allocator, "");
    }

    fn tokenizeEncoded(ctx: *anyopaque, _: std.Io, allocator: Allocator, line: []const u8, hasEOL: bool, state: IState) anyerror!EncodedTokenizationResult {
        _ = hasEOL;
        const self: *StatefulSupport = @ptrCast(@alignCast(ctx));
        try self.log.add(line);
        const newState = try createState(allocator, line);
        _ = state;
        return .{ .tokens = try arenaTokens(allocator), .endState = newState };
    }

    fn interface(self: *StatefulSupport) ITokenizationSupport {
        return .{
            .context = self,
            .vtable = &.{
                .getInitialState = getInitialState,
                .tokenizeEncoded = tokenizeEncoded,
            },
        };
    }
};

const FakeState = struct {
    prevLineContent: []const u8,
};

fn createState(allocator: Allocator, prevLineContent: []const u8) !IState {
    const state = try allocator.create(FakeState);
    state.* = .{ .prevLineContent = try allocator.dupe(u8, prevLineContent) };
    return .{ .context = state, .vtable = &state_vtable };
}

fn stateClone(ctx: *anyopaque, allocator: Allocator) anyerror!IState {
    const state: *FakeState = @ptrCast(@alignCast(ctx));
    return createState(allocator, state.prevLineContent);
}

fn stateEquals(ctx: *anyopaque, other: IState) bool {
    if (other.vtable != &state_vtable) return false;
    const self: *FakeState = @ptrCast(@alignCast(ctx));
    const otherState: *FakeState = @ptrCast(@alignCast(other.context));
    return std.mem.eql(u8, self.prevLineContent, otherState.prevLineContent);
}

const state_vtable: IState.VTable = .{
    .clone = stateClone,
    .equals = stateEquals,
};

fn arenaTokens(allocator: Allocator) ![]TokenPacked {
    return try allocator.alloc(TokenPacked, 0);
}

// ---------- Tests ----------

const MODES_1_TEXT = "1\r\n2\n3\n4\r\n5";
const MODES_2_TEXT = "Line1\r\nLine2\nLine3\nLine4\r\nLine5";

test "model modes 1: model calls syntax highlighter 1" {
    const allocator = std.testing.allocator;
    var log = CallLog.init(allocator);
    defer log.deinit();
    var support = StatelessSupport{ .log = &log };
    try TokenizationRegistry.instance.register("modelModeTest1", support.interface());
    defer TokenizationRegistry.instance.unregister("modelModeTest1");

    var ctx = try TestModel.init(allocator, MODES_1_TEXT, "modelModeTest1");
    defer ctx.deinit();

    ctx.model.forceTokenization(1);
    try expectCalls(&log, &.{"1"});
}

test "model modes 1: model caches states" {
    const allocator = std.testing.allocator;
    var log = CallLog.init(allocator);
    defer log.deinit();
    var support = StatelessSupport{ .log = &log };
    try TokenizationRegistry.instance.register("modelModeTest1b", support.interface());
    defer TokenizationRegistry.instance.unregister("modelModeTest1b");

    var ctx = try TestModel.init(allocator, MODES_1_TEXT, "modelModeTest1b");
    defer ctx.deinit();

    ctx.model.forceTokenization(1);
    try expectCalls(&log, &.{"1"});
    ctx.model.forceTokenization(2);
    try expectCalls(&log, &.{"2"});
    ctx.model.forceTokenization(2);
    try expectCalls(&log, &.{});
}

test "model modes 1: invalidates states for one line insert" {
    const allocator = std.testing.allocator;
    var log = CallLog.init(allocator);
    defer log.deinit();
    var support_modelModeTest1c = StatelessSupport{ .log = &log };
    try TokenizationRegistry.instance.register("modelModeTest1c", support_modelModeTest1c.interface());
    defer TokenizationRegistry.instance.unregister("modelModeTest1c");

    var ctx = try TestModel.init(allocator, MODES_1_TEXT, "modelModeTest1c");
    defer ctx.deinit();

    ctx.model.forceTokenization(5);
    try expectCalls(&log, &.{ "1", "2", "3", "4", "5" });
    try ctx.applyEdit(Range.init(1, 1, 1, 1), "-");
    ctx.model.forceTokenization(5);
    try expectCalls(&log, &.{"-1"});
}

test "model modes 2: one text insert" {
    const allocator = std.testing.allocator;
    var log = CallLog.init(allocator);
    defer log.deinit();
    var support_modelModeTest2a = StatefulSupport{ .log = &log };
    try TokenizationRegistry.instance.register("modelModeTest2a", support_modelModeTest2a.interface());
    defer TokenizationRegistry.instance.unregister("modelModeTest2a");

    var ctx = try TestModel.init(allocator, MODES_2_TEXT, "modelModeTest2a");
    defer ctx.deinit();

    ctx.model.forceTokenization(5);
    try expectCalls(&log, &.{ "Line1", "Line2", "Line3", "Line4", "Line5" });
    try ctx.applyEdit(Range.init(1, 6, 1, 6), "-");
    ctx.model.forceTokenization(5);
    try expectCalls(&log, &.{ "Line1-", "Line2" });
}

test "model modes 2: two text inserts" {
    const allocator = std.testing.allocator;
    var log = CallLog.init(allocator);
    defer log.deinit();
    var support_modelModeTest2b = StatefulSupport{ .log = &log };
    try TokenizationRegistry.instance.register("modelModeTest2b", support_modelModeTest2b.interface());
    defer TokenizationRegistry.instance.unregister("modelModeTest2b");

    var ctx = try TestModel.init(allocator, MODES_2_TEXT, "modelModeTest2b");
    defer ctx.deinit();

    ctx.model.forceTokenization(5);
    try expectCalls(&log, &.{ "Line1", "Line2", "Line3", "Line4", "Line5" });

    var ops = [_]@import("../../../common/model.zig").IdentifiedSingleEditOperation{
        .init(Range.init(1, 6, 1, 6), @import("../../../../base/common/strings.zig").String.initBorrowed("-")),
        .init(Range.init(3, 6, 3, 6), @import("../../../../base/common/strings.zig").String.initBorrowed("-")),
    };
    _ = try ctx.model.applyEdits(&ops, false);

    ctx.model.forceTokenization(5);
    try expectCalls(&log, &.{ "Line1-", "Line2", "Line3-", "Line4" });
}

test "model modes 2: one line delete" {
    const allocator = std.testing.allocator;
    var log = CallLog.init(allocator);
    defer log.deinit();
    var support_modelModeTest2c = StatefulSupport{ .log = &log };
    try TokenizationRegistry.instance.register("modelModeTest2c", support_modelModeTest2c.interface());
    defer TokenizationRegistry.instance.unregister("modelModeTest2c");

    var ctx = try TestModel.init(allocator, MODES_2_TEXT, "modelModeTest2c");
    defer ctx.deinit();

    ctx.model.forceTokenization(5);
    try expectCalls(&log, &.{ "Line1", "Line2", "Line3", "Line4", "Line5" });
    try ctx.applyEdit(Range.init(1, 1, 2, 1), "");
    ctx.model.forceTokenization(4);
    try expectCalls(&log, &.{"Line2"});
}

test "model modes 1: model calls syntax highlighter 2" {
    const allocator = std.testing.allocator;
    var log = CallLog.init(allocator);
    defer log.deinit();
    var support = StatelessSupport{ .log = &log };
    try TokenizationRegistry.instance.register("modelModeTest1d", support.interface());
    defer TokenizationRegistry.instance.unregister("modelModeTest1d");

    var ctx = try TestModel.init(allocator, MODES_1_TEXT, "modelModeTest1d");
    defer ctx.deinit();

    ctx.model.forceTokenization(2);
    try expectCalls(&log, &.{ "1", "2" });
    ctx.model.forceTokenization(2);
    try expectCalls(&log, &.{});
}

test "model modes 1: invalidates states for many lines insert" {
    const allocator = std.testing.allocator;
    var log = CallLog.init(allocator);
    defer log.deinit();
    var support = StatelessSupport{ .log = &log };
    try TokenizationRegistry.instance.register("modelModeTest1e", support.interface());
    defer TokenizationRegistry.instance.unregister("modelModeTest1e");

    var ctx = try TestModel.init(allocator, MODES_1_TEXT, "modelModeTest1e");
    defer ctx.deinit();

    ctx.model.forceTokenization(5);
    try expectCalls(&log, &.{ "1", "2", "3", "4", "5" });
    try ctx.applyEdit(Range.init(1, 1, 1, 1), "0\n-\n+");
    try std.testing.expectEqual(7, ctx.model.getLineCount());
    ctx.model.forceTokenization(7);
    try expectCalls(&log, &.{ "0", "-", "+1" });
}

test "model modes 1: invalidates states for one new line" {
    const allocator = std.testing.allocator;
    var log = CallLog.init(allocator);
    defer log.deinit();
    var support = StatelessSupport{ .log = &log };
    try TokenizationRegistry.instance.register("modelModeTest1f", support.interface());
    defer TokenizationRegistry.instance.unregister("modelModeTest1f");

    var ctx = try TestModel.init(allocator, MODES_1_TEXT, "modelModeTest1f");
    defer ctx.deinit();

    ctx.model.forceTokenization(5);
    try expectCalls(&log, &.{ "1", "2", "3", "4", "5" });
    try ctx.applyEdit(Range.init(1, 2, 1, 2), "\n");
    try ctx.applyEdit(Range.init(2, 1, 2, 1), "a");
    ctx.model.forceTokenization(6);
    try expectCalls(&log, &.{ "1", "a" });
}

test "model modes 1: invalidates states for one line delete" {
    const allocator = std.testing.allocator;
    var log = CallLog.init(allocator);
    defer log.deinit();
    var support = StatelessSupport{ .log = &log };
    try TokenizationRegistry.instance.register("modelModeTest1g", support.interface());
    defer TokenizationRegistry.instance.unregister("modelModeTest1g");

    var ctx = try TestModel.init(allocator, MODES_1_TEXT, "modelModeTest1g");
    defer ctx.deinit();

    ctx.model.forceTokenization(5);
    try expectCalls(&log, &.{ "1", "2", "3", "4", "5" });
    try ctx.applyEdit(Range.init(1, 2, 1, 2), "-");
    ctx.model.forceTokenization(5);
    try expectCalls(&log, &.{"1-"});
    try ctx.applyEdit(Range.init(1, 1, 1, 2), "");
    ctx.model.forceTokenization(5);
    try expectCalls(&log, &.{"-"});
}

test "model modes 1: invalidates states for many lines delete" {
    const allocator = std.testing.allocator;
    var log = CallLog.init(allocator);
    defer log.deinit();
    var support = StatelessSupport{ .log = &log };
    try TokenizationRegistry.instance.register("modelModeTest1h", support.interface());
    defer TokenizationRegistry.instance.unregister("modelModeTest1h");

    var ctx = try TestModel.init(allocator, MODES_1_TEXT, "modelModeTest1h");
    defer ctx.deinit();

    ctx.model.forceTokenization(5);
    try expectCalls(&log, &.{ "1", "2", "3", "4", "5" });
    try ctx.applyEdit(Range.init(1, 1, 3, 1), "");
    ctx.model.forceTokenization(3);
    try expectCalls(&log, &.{"3"});
}

test "model modes 2: multi-line insert plus small insert" {
    const allocator = std.testing.allocator;
    var log = CallLog.init(allocator);
    defer log.deinit();
    var support = StatefulSupport{ .log = &log };
    try TokenizationRegistry.instance.register("modelModeTest2d", support.interface());
    defer TokenizationRegistry.instance.unregister("modelModeTest2d");

    var ctx = try TestModel.init(allocator, MODES_2_TEXT, "modelModeTest2d");
    defer ctx.deinit();

    ctx.model.forceTokenization(5);
    try expectCalls(&log, &.{ "Line1", "Line2", "Line3", "Line4", "Line5" });
    try ctx.applyEdit(Range.init(1, 6, 1, 6), "\nNew line\nAnother new line");
    try ctx.applyEdit(Range.init(5, 6, 5, 6), "-");
    ctx.model.forceTokenization(7);
    try expectCalls(&log, &.{ "Line1", "New line", "Another new line", "Line2", "Line3-", "Line4" });
}

test "model modes 2: one delete text" {
    const allocator = std.testing.allocator;
    var log = CallLog.init(allocator);
    defer log.deinit();
    var support = StatefulSupport{ .log = &log };
    try TokenizationRegistry.instance.register("modelModeTest2e", support.interface());
    defer TokenizationRegistry.instance.unregister("modelModeTest2e");

    var ctx = try TestModel.init(allocator, MODES_2_TEXT, "modelModeTest2e");
    defer ctx.deinit();

    ctx.model.forceTokenization(5);
    try expectCalls(&log, &.{ "Line1", "Line2", "Line3", "Line4", "Line5" });
    try ctx.applyEdit(Range.init(1, 1, 1, 5), "");
    ctx.model.forceTokenization(5);
    try expectCalls(&log, &.{ "1", "Line2" });
}

test "model modes 2: multiple lines delete" {
    const allocator = std.testing.allocator;
    var log = CallLog.init(allocator);
    defer log.deinit();
    var support = StatefulSupport{ .log = &log };
    try TokenizationRegistry.instance.register("modelModeTest2f", support.interface());
    defer TokenizationRegistry.instance.unregister("modelModeTest2f");

    var ctx = try TestModel.init(allocator, MODES_2_TEXT, "modelModeTest2f");
    defer ctx.deinit();

    ctx.model.forceTokenization(5);
    try expectCalls(&log, &.{ "Line1", "Line2", "Line3", "Line4", "Line5" });
    try ctx.applyEdit(Range.init(1, 1, 3, 3), "");
    ctx.model.forceTokenization(3);
    try expectCalls(&log, &.{ "ne3", "Line4" });
}
