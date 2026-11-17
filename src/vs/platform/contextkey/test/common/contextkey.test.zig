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
        .{ .input = "!a && !b || !c && !d", .expected = "a && c || a && d || b && c || b && d" },
        .{ .input = "!a && !b || !c && !d || !e && !f", .expected = "a && c && e || a && c && f || a && d && e || a && d && f || b && c && e || b && c && f || b && d && e || b && d && f" },
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

fn expectEval(allocator: std.mem.Allocator, expr_text: []const u8, context: *TestContext, expected: bool) !void {
    _ = allocator;
    const expression = try parse(context.values.allocator, expr_text);
    try std.testing.expectEqual(expected, expression.evaluate(context.context()));
}

test "ContextKeyInExpr and ContextKeyNotInExpr" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const cases = [_]struct { a: contextkey.ContextKeyValue, b: contextkey.ContextKeyValue, in: bool }{
        .{ .a = .{ .number = 3 }, .b = .{ .array = &.{ .{ .number = 3 }, .{ .number = 2 }, .{ .number = 1 } } }, .in = true },
        .{ .a = .{ .number = 3 }, .b = .{ .array = &.{ .{ .number = 1 }, .{ .number = 2 } } }, .in = false },
        .{ .a = .{ .number = 3 }, .b = .null_value, .in = false },
        .{ .a = .{ .string = "x" }, .b = .{ .array = &.{.{ .string = "x" }} }, .in = true },
        .{ .a = .{ .string = "x" }, .b = .{ .array = &.{.{ .string = "y" }} }, .in = false },
        .{ .a = .{ .string = "x" }, .b = .{ .string = "x" }, .in = false },
    };
    for (cases) |case| {
        var context = TestContext.init(arena_allocator);
        try context.put("a", case.a);
        try context.put("b", case.b);
        const in_expr = try parse(arena_allocator, "a in b");
        try std.testing.expectEqual(case.in, in_expr.evaluate(context.context()));
        const not_in_expr = try parse(arena_allocator, "a not in b");
        try std.testing.expectEqual(!case.in, not_in_expr.evaluate(context.context()));
    }

    {
        var object = std.StringHashMap(contextkey.ContextKeyValue).init(arena_allocator);
        try object.put("x", .{ .boolean = false });
        var context = TestContext.init(arena_allocator);
        try context.put("a", .{ .string = "x" });
        try context.put("b", .{ .object = &object });
        const in_expr = try parse(arena_allocator, "a in b");
        try std.testing.expect(in_expr.evaluate(context.context()));
    }
}

test "issue #338834: distributing an OR that collapses to a single AND" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var factory = ContextKeyExpr.init(arena.allocator());
    const actual = (try factory.andExpr(&.{
        try factory.has("a"),
        try factory.has("b"),
        try factory.orExpr(&.{
            try factory.not("b"),
            try factory.andExpr(&.{ try factory.has("a"), try factory.has("c") }),
        }),
    })).?;
    try std.testing.expectEqualStrings("a && b && c", try actual.serialize(arena.allocator()));
    const flat = (try factory.andExpr(&.{ try factory.has("a"), try factory.has("b"), try factory.has("c") })).?;
    try std.testing.expect(actual.equalsExpr(flat));
}

test "distributing AND over OR with in and comparison terms" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var factory = ContextKeyExpr.init(arena.allocator());
    const comparison = (try factory.andExpr(&.{
        try factory.orExpr(&.{ try factory.has("a"), try factory.has("b") }),
        try factory.greater("c", .{ .number = 1 }),
    })).?;
    try std.testing.expectEqualStrings("a && c > 1 || b && c > 1", try comparison.serialize(arena.allocator()));
    const in_expr = (try factory.andExpr(&.{
        try factory.orExpr(&.{ try factory.has("a"), try factory.has("b") }),
        try factory.inKey("c", "d"),
    })).?;
    try std.testing.expectEqualStrings("a && c in 'd' || b && c in 'd'", try in_expr.serialize(arena.allocator()));
}

test "duplicated and constant terms" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var factory = ContextKeyExpr.init(arena.allocator());
    try std.testing.expectEqualStrings("A || B", try (try factory.orExpr(&.{ try factory.has("A"), try factory.has("B"), try factory.has("A") })).?.serialize(arena.allocator()));
    try std.testing.expectEqualStrings("true", try (try factory.orExpr(&.{ try factory.has("A"), try factory.not("A") })).?.serialize(arena.allocator()));
    try std.testing.expectEqualStrings("false", try (try factory.andExpr(&.{ try factory.has("A"), try factory.not("A") })).?.serialize(arena.allocator()));
    try std.testing.expectEqualStrings("A && B", try (try factory.andExpr(&.{ try factory.has("A"), try factory.has("B"), try factory.has("A") })).?.serialize(arena.allocator()));
}

test "issue #129625: duplicated terms when negating" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var factory = ContextKeyExpr.init(arena.allocator());
    const expr = (try factory.andExpr(&.{
        try factory.has("A"),
        try factory.orExpr(&.{ try factory.has("B1"), try factory.has("B2") }),
    })).?;
    try std.testing.expectEqualStrings("A && B1 || A && B2", try expr.serialize(arena.allocator()));
    const negated = try expr.negate(arena.allocator());
    try std.testing.expectEqualStrings("!A || !A && !B1 || !A && !B2 || !B1 && !B2", try negated.serialize(arena.allocator()));
    const double_negated = try negated.negate(arena.allocator());
    try std.testing.expectEqualStrings("A && B1 || A && B2", try double_negated.serialize(arena.allocator()));
}

test "implies" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const cases = [_]struct { p: []const u8, q: []const u8, expected: bool }{
        .{ .p = "a", .q = "a", .expected = true },
        .{ .p = "a", .q = "a || b", .expected = true },
        .{ .p = "a", .q = "a && b", .expected = false },
        .{ .p = "a", .q = "a && b || a && c", .expected = false },
        .{ .p = "a && b", .q = "a", .expected = true },
        .{ .p = "a && b", .q = "b", .expected = true },
        .{ .p = "a && b", .q = "a && b || c", .expected = true },
        .{ .p = "a || b", .q = "a || c", .expected = false },
        .{ .p = "a || b", .q = "a || b", .expected = true },
        .{ .p = "a || b", .q = "a || b || c", .expected = true },
        .{ .p = "c && a && b", .q = "c && a", .expected = true },
    };
    for (cases) |case| {
        const p = try parse(arena.allocator(), case.p);
        const q = try parse(arena.allocator(), case.q);
        try std.testing.expectEqual(case.expected, contextkey.implies(p, q));
    }
}

fn checkEvaluate(allocator: std.mem.Allocator, expr_text: []const u8, value: contextkey.ContextKeyValue, expected: bool) !void {
    var context = TestContext.init(allocator);
    try context.put("a", value);
    const expression = try parse(allocator, expr_text);
    try std.testing.expectEqual(expected, expression.evaluate(context.context()));
}

test "Greater, GreaterEquals, Smaller, SmallerEquals evaluate" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try checkEvaluate(a, "a > 1", .undefined_value, false);
    try checkEvaluate(a, "a > 1", .{ .number = 0 }, false);
    try checkEvaluate(a, "a > 1", .{ .number = 1 }, false);
    try checkEvaluate(a, "a > 1", .{ .number = 2 }, true);
    try checkEvaluate(a, "a > 1", .{ .string = "0" }, false);
    try checkEvaluate(a, "a > 1", .{ .string = "1" }, false);
    try checkEvaluate(a, "a > 1", .{ .string = "2" }, true);
    try checkEvaluate(a, "a > 1", .{ .string = "a" }, false);

    try checkEvaluate(a, "a > 10", .{ .number = 2 }, false);
    try checkEvaluate(a, "a > 10", .{ .number = 11 }, true);
    try checkEvaluate(a, "a > 10", .{ .string = "11" }, true);
    try checkEvaluate(a, "a > 10", .{ .string = "2" }, false);

    try checkEvaluate(a, "a > 1.1", .{ .number = 1 }, false);
    try checkEvaluate(a, "a > 1.1", .{ .number = 2 }, true);
    try checkEvaluate(a, "a > 1.1", .{ .string = "1.1" }, false);
    try checkEvaluate(a, "a > 1.1", .{ .string = "2" }, true);

    try checkEvaluate(a, "a > b", .{ .string = "b" }, false);
    try checkEvaluate(a, "a > b", .{ .string = "c" }, false);
    try checkEvaluate(a, "a > b", .{ .number = 1000 }, false);

    try checkEvaluate(a, "a >= 2", .{ .string = "1" }, false);
    try checkEvaluate(a, "a >= 2", .{ .string = "2" }, true);
    try checkEvaluate(a, "a >= 2", .{ .string = "3" }, true);
    try checkEvaluate(a, "a < 2", .{ .string = "1" }, true);
    try checkEvaluate(a, "a < 2", .{ .string = "2" }, false);
    try checkEvaluate(a, "a < 2", .{ .string = "3" }, false);
    try checkEvaluate(a, "a <= 2", .{ .string = "1" }, true);
    try checkEvaluate(a, "a <= 2", .{ .string = "2" }, true);
    try checkEvaluate(a, "a <= 2", .{ .string = "3" }, false);
}

test "Greater, GreaterEquals, Smaller, SmallerEquals negate" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "a > 1", .expected = "a <= 1" },
        .{ .input = "a > 1.1", .expected = "a <= 1.1" },
        .{ .input = "a > b", .expected = "a <= b" },
        .{ .input = "a >= 1", .expected = "a < 1" },
        .{ .input = "a >= 1.1", .expected = "a < 1.1" },
        .{ .input = "a >= b", .expected = "a < b" },
        .{ .input = "a < 1", .expected = "a >= 1" },
        .{ .input = "a < b", .expected = "a >= b" },
        .{ .input = "a <= 1", .expected = "a > 1" },
        .{ .input = "a <= b", .expected = "a > b" },
    };
    for (cases) |case| {
        const expression = try parse(arena.allocator(), case.input);
        const negated = try expression.negate(arena.allocator());
        try std.testing.expectEqualStrings(case.expected, try negated.serialize(arena.allocator()));
    }
}

test "issue #111899: context keys can use < or >" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const actual = try parse(arena.allocator(), "editorTextFocus && vim.active && vim.use<C-r>");
    var factory = ContextKeyExpr.init(arena.allocator());
    const expected = (try factory.andExpr(&.{
        try factory.has("editorTextFocus"),
        try factory.has("vim.active"),
        try factory.has("vim.use<C-r>"),
    })).?;
    try std.testing.expect(actual.equalsExpr(expected));
}

test "issue #106524: distributing AND should normalize" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var factory = ContextKeyExpr.init(arena.allocator());
    const actual = (try factory.andExpr(&.{
        try factory.orExpr(&.{ try factory.has("a"), try factory.has("b") }),
        try factory.has("c"),
    })).?;
    const expected = (try factory.orExpr(&.{
        try factory.andExpr(&.{ try factory.has("a"), try factory.has("c") }),
        try factory.andExpr(&.{ try factory.has("b"), try factory.has("c") }),
    })).?;
    try std.testing.expect(actual.equalsExpr(expected));
}
