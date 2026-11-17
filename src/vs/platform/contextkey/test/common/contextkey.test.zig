// Port of the expression-model cases of
// `src/vs/platform/contextkey/test/common/contextkey.test.ts`.
const std = @import("std");
const contextkey = @import("../../common/contextkey.zig");

const Expr = contextkey.Expr;
const ContextKeyExpr = contextkey.ContextKeyExpr;
const Parser = contextkey.Parser;

fn parse(allocator: std.mem.Allocator, text: []const u8) !*const Expr {
    var parser = Parser.init(allocator, .{});
    defer parser.deinit();
    return (try parser.parse(text)) orelse error.ParseFailed;
}

const TestContext = struct {
    values: std.StringHashMap(contextkey.ContextKeyValue),

    fn init(allocator: std.mem.Allocator) TestContext {
        return .{ .values = std.StringHashMap(contextkey.ContextKeyValue).init(allocator) };
    }
    fn deinit(self: *TestContext) void {
        self.values.deinit();
    }
    fn put(self: *TestContext, key: []const u8, value: contextkey.ContextKeyValue) !void {
        try self.values.put(key, value);
    }
    fn context(self: *TestContext) contextkey.IContext {
        return .{ .context = self, .get_value = getValue };
    }
    fn getValue(raw: *anyopaque, key: []const u8) contextkey.ContextKeyValue {
        const self: *TestContext = @ptrCast(@alignCast(raw));
        return self.values.get(key) orelse .undefined_value;
    }
};

test "ContextKeyExpr.equals" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var factory = ContextKeyExpr.init(arena.allocator());
    const a = (try factory.andExpr(&.{
        try factory.has("a1"),
        try factory.has("and.a"),
        try factory.has("a2"),
        try factory.regex("d3", "d.*", ""),
        try factory.regex("d4", "\\*\\*3*", ""),
        try factory.equals("b1", .{ .string = "bb1" }),
        try factory.equals("b2", .{ .string = "bb2" }),
        try factory.notEquals("c1", .{ .string = "cc1" }),
        try factory.notEquals("c2", .{ .string = "cc2" }),
        try factory.not("d1"),
        try factory.not("d2"),
    })).?;
    const b = (try factory.andExpr(&.{
        try factory.equals("b2", .{ .string = "bb2" }),
        try factory.notEquals("c1", .{ .string = "cc1" }),
        try factory.not("d1"),
        try factory.regex("d4", "\\*\\*3*", ""),
        try factory.notEquals("c2", .{ .string = "cc2" }),
        try factory.has("a2"),
        try factory.equals("b1", .{ .string = "bb1" }),
        try factory.regex("d3", "d.*", ""),
        try factory.has("a1"),
        try factory.andExpr(&.{try factory.equals("and.a", .{ .boolean = true })}),
        try factory.not("d2"),
    })).?;
    try std.testing.expect(a.equalsExpr(b));
}

test "issue #134942: Equals in comparator expressions" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var factory = ContextKeyExpr.init(arena.allocator());
    try std.testing.expect((try factory.greater("value", .{ .number = 0 })).equalsExpr(try parse(arena.allocator(), "value > 0")));
    try std.testing.expect((try factory.greaterEquals("value", .{ .number = 0 })).equalsExpr(try parse(arena.allocator(), "value >= 0")));
    try std.testing.expect((try factory.smaller("value", .{ .number = 0 })).equalsExpr(try parse(arena.allocator(), "value < 0")));
    try std.testing.expect((try factory.smallerEquals("value", .{ .number = 0 })).equalsExpr(try parse(arena.allocator(), "value <= 0")));
}

test "normalize" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var factory = ContextKeyExpr.init(arena.allocator());
    try std.testing.expect((try factory.equals("key1", .{ .boolean = true })).equalsExpr(try factory.has("key1")));
    try std.testing.expect((try factory.notEquals("key1", .{ .boolean = false })).equalsExpr(try factory.has("key1")));
    try std.testing.expect((try factory.equals("key1", .{ .boolean = false })).equalsExpr(try factory.not("key1")));
    try std.testing.expect((try factory.notEquals("key1", .{ .boolean = true })).equalsExpr(try factory.not("key1")));
}

test "evaluate" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var context = TestContext.init(arena.allocator());
    defer context.deinit();
    try context.put("a", .{ .boolean = true });
    try context.put("b", .{ .boolean = false });
    try context.put("c", .{ .string = "5" });
    try context.put("d", .{ .string = "d" });

    const cases = [_]struct { expr: []const u8, expected: bool }{
        .{ .expr = "true", .expected = true },
        .{ .expr = "false", .expected = false },
        .{ .expr = "a && !b", .expected = true },
        .{ .expr = "a && b", .expected = false },
        .{ .expr = "a && !b && c == 5", .expected = true },
        .{ .expr = "d =~ /e.*/", .expected = false },
        .{ .expr = "b && a || a", .expected = true },
        .{ .expr = "a || b", .expected = true },
        .{ .expr = "b || b", .expected = false },
        .{ .expr = "b && a || a && b", .expected = false },
    };
    for (cases) |case| {
        const expression = try parse(arena.allocator(), case.expr);
        try std.testing.expectEqual(case.expected, expression.evaluate(context.context()));
    }
}

test "negate" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "true", .expected = "false" },
        .{ .input = "false", .expected = "true" },
        .{ .input = "a", .expected = "!a" },
        .{ .input = "a && b || c", .expected = "!a && !c || !b && !c" },
        .{ .input = "a && b || c || d", .expected = "!a && !c && !d || !b && !c && !d" },
    };
    for (cases) |case| {
        const expression = try parse(arena.allocator(), case.input);
        const negated = try expression.negate(arena.allocator());
        const serialized = try negated.serialize(arena.allocator());
        try std.testing.expectEqualStrings(case.expected, serialized);
    }
}

test "false, true" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "true", .expected = "true" },
        .{ .input = "!true", .expected = "false" },
        .{ .input = "false", .expected = "false" },
        .{ .input = "!false", .expected = "true" },
        .{ .input = "a && true", .expected = "a" },
        .{ .input = "a && false", .expected = "false" },
        .{ .input = "a || true", .expected = "true" },
        .{ .input = "a || false", .expected = "a" },
    };
    for (cases) |case| {
        const expression = try parse(arena.allocator(), case.input);
        try std.testing.expectEqualStrings(case.expected, try expression.serialize(arena.allocator()));
    }
}

test "issue #101015: distribute OR" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const cases = [_]struct { left: []const u8, right: []const u8, expected: []const u8 }{
        .{ .left = "a", .right = "b", .expected = "a && b" },
        .{ .left = "a || b", .right = "c", .expected = "a && c || b && c" },
        .{ .left = "a || b", .right = "c || d", .expected = "a && c || a && d || b && c || b && d" },
        .{ .left = "a || b", .right = "c && d", .expected = "a && c && d || b && c && d" },
        .{ .left = "a || b", .right = "c && d || e", .expected = "a && e || b && e || a && c && d || b && c && d" },
    };
    var factory = ContextKeyExpr.init(arena.allocator());
    for (cases) |case| {
        const left = try parse(arena.allocator(), case.left);
        const right = try parse(arena.allocator(), case.right);
        const combined = (try factory.andExpr(&.{ left, right })).?;
        try std.testing.expectEqualStrings(case.expected, try combined.serialize(arena.allocator()));
    }
}
