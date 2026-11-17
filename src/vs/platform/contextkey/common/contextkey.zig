// Port of the expression model of `src/vs/platform/contextkey/common/contextkey.ts`.
//
// Terminal adaptations and current scope:
// - Expressions are a tagged union allocated from a `ContextKeyExpr` arena
//   (upstream relies on JS object identity/GC). `ContextKeyExpr.deinit` frees
//   every node.
// - Regex expressions (`=~`, `/.../`) and the parser are not ported yet: they
//   land with the `when`-clause parser slice. `ContextKeyExpr.in` is spelled
//   `inKey` (`in` is a Zig keyword).
// - Late-bound constants (`setConstant`/`substituteConstants`) are not ported;
//   `substituteConstants` returns the expression unchanged. The TUI sets plain
//   context keys directly.
// - `ContextKeyValue` carries arrays and objects so `in`/`not in` evaluate like
//   upstream; JS loose equality is implemented for the scalar combinations the
//   expressions use.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

pub const ExprType = enum(u8) {
    False = 0,
    True = 1,
    Defined = 2,
    Not = 3,
    Equals = 4,
    NotEquals = 5,
    And = 6,
    Or = 9,
    In = 10,
    NotIn = 11,
    Greater = 12,
    GreaterEquals = 13,
    Smaller = 14,
    SmallerEquals = 15,
};

pub const ContextKeyValue = union(enum) {
    null_value,
    undefined_value,
    boolean: bool,
    number: f64,
    string: []const u8,
    array: []const ContextKeyValue,
    object: *const std.StringHashMap(ContextKeyValue),
};

pub const IContext = struct {
    context: *anyopaque,
    get_value: *const fn (context: *anyopaque, key: []const u8) ContextKeyValue,

    pub fn getValue(self: IContext, key: []const u8) ContextKeyValue {
        return self.get_value(self.context, key);
    }
};

pub const KeyValue = struct { key: []const u8, value: ContextKeyValue };
pub const KeyPair = struct { key: []const u8, value_key: []const u8 };
pub const NumericValue = struct { key: []const u8, value: f64 };

pub const Expr = union(ExprType) {
    False: void,
    True: void,
    Defined: []const u8,
    Not: []const u8,
    Equals: KeyValue,
    NotEquals: KeyValue,
    And: []*const Expr,
    Or: []*const Expr,
    In: KeyPair,
    NotIn: KeyPair,
    Greater: NumericValue,
    GreaterEquals: NumericValue,
    Smaller: NumericValue,
    SmallerEquals: NumericValue,

    pub fn evaluate(self: *const Expr, context: IContext) bool {
        return switch (self.*) {
            .False => false,
            .True => true,
            .Defined => |key| isTruthy(context.getValue(key)),
            .Not => |key| !isTruthy(context.getValue(key)),
            .Equals => |entry| looseEquals(context.getValue(entry.key), entry.value),
            .NotEquals => |entry| !looseEquals(context.getValue(entry.key), entry.value),
            .And => |items| blk: {
                for (items) |item| {
                    if (!item.evaluate(context)) break :blk false;
                }
                break :blk true;
            },
            .Or => |items| blk: {
                for (items) |item| {
                    if (item.evaluate(context)) break :blk true;
                }
                break :blk false;
            },
            .In => |entry| inExpression(context, entry, false),
            .NotIn => |entry| inExpression(context, entry, true),
            .Greater => |entry| compareNumber(context.getValue(entry.key), entry.value, .gt),
            .GreaterEquals => |entry| compareNumber(context.getValue(entry.key), entry.value, .gte),
            .Smaller => |entry| compareNumber(context.getValue(entry.key), entry.value, .lt),
            .SmallerEquals => |entry| compareNumber(context.getValue(entry.key), entry.value, .lte),
        };
    }

    pub fn serialize(self: *const Expr, allocator: Allocator) Allocator.Error![]u8 {
        var result = ArrayList(u8).init(allocator);
        errdefer result.deinit();
        try self.appendSerialized(&result);
        return result.toOwnedSlice();
    }

    fn appendSerialized(self: *const Expr, result: *ArrayList(u8)) Allocator.Error!void {
        switch (self.*) {
            .False => try result.appendSlice("false"),
            .True => try result.appendSlice("true"),
            .Defined => |key| try result.appendSlice(key),
            .Not => |key| {
                try result.append('!');
                try result.appendSlice(key);
            },
            .Equals => |entry| try appendKeyValue(result, entry, "=="),
            .NotEquals => |entry| try appendKeyValue(result, entry, "!="),
            .And => |items| try appendJoined(result, items, " && "),
            .Or => |items| try appendJoined(result, items, " || "),
            .In => |entry| {
                try result.appendSlice(entry.key);
                try result.appendSlice(" in '");
                try result.appendSlice(entry.value_key);
                try result.append('\'');
            },
            .NotIn => |entry| {
                try result.appendSlice(entry.key);
                try result.appendSlice(" not in '");
                try result.appendSlice(entry.value_key);
                try result.append('\'');
            },
            .Greater => |entry| try appendNumber(result, entry, ">"),
            .GreaterEquals => |entry| try appendNumber(result, entry, ">="),
            .Smaller => |entry| try appendNumber(result, entry, "<"),
            .SmallerEquals => |entry| try appendNumber(result, entry, "<="),
        }
    }

    /// The caller owns the outer slice; the key strings are borrowed.
    pub fn keys(self: *const Expr, allocator: Allocator) Allocator.Error![]const []const u8 {
        var result = ArrayList([]const u8).init(allocator);
        errdefer result.deinit();
        try self.appendKeys(&result);
        return result.toOwnedSlice();
    }

    fn appendKeys(self: *const Expr, result: *ArrayList([]const u8)) Allocator.Error!void {
        switch (self.*) {
            .False, .True => {},
            .Defined => |key| try result.append(key),
            .Not => |key| try result.append(key),
            .Equals => |entry| try result.append(entry.key),
            .NotEquals => |entry| try result.append(entry.key),
            .And => |items| for (items) |item| try item.appendKeys(result),
            .Or => |items| for (items) |item| try item.appendKeys(result),
            .In => |entry| {
                try result.append(entry.key);
                try result.append(entry.value_key);
            },
            .NotIn => |entry| {
                try result.append(entry.key);
                try result.append(entry.value_key);
            },
            .Greater, .GreaterEquals, .Smaller, .SmallerEquals => |entry| try result.append(entry.key),
        }
    }

    /// Returns the negated expression, allocated with `allocator`.
    pub fn negate(self: *const Expr, allocator: Allocator) Allocator.Error!*const Expr {
        return switch (self.*) {
            .False => createExpr(allocator, .True),
            .True => createExpr(allocator, .False),
            .Defined => |key| createExpr(allocator, .{ .Not = key }),
            .Not => |key| createExpr(allocator, .{ .Defined = key }),
            .Equals => |entry| createExpr(allocator, .{ .NotEquals = entry }),
            .NotEquals => |entry| createExpr(allocator, .{ .Equals = entry }),
            .In => |entry| createExpr(allocator, .{ .NotIn = entry }),
            .NotIn => |entry| createExpr(allocator, .{ .In = entry }),
            .Greater => |entry| createExpr(allocator, .{ .SmallerEquals = entry }),
            .GreaterEquals => |entry| createExpr(allocator, .{ .Smaller = entry }),
            .Smaller => |entry| createExpr(allocator, .{ .GreaterEquals = entry }),
            .SmallerEquals => |entry| createExpr(allocator, .{ .Greater = entry }),
            .And => |items| blk: {
                var negated = ArrayList(?*const Expr).init(allocator);
                defer negated.deinit();
                for (items) |item| try negated.append(try item.negate(allocator));
                break :blk (try normalizeOr(allocator, negated.items, true)).?;
            },
            .Or => |items| blk: {
                var negated = ArrayList(*const Expr).init(allocator);
                defer negated.deinit();
                for (items) |item| try negated.append(try item.negate(allocator));

                // Distribute AND over the OR terminals (no parens in the
                // serialized form).
                while (negated.items.len > 1) {
                    const left = negated.orderedRemove(0);
                    const right = negated.orderedRemove(0);
                    var left_single = [_]*const Expr{left};
                    var right_single = [_]*const Expr{right};
                    const left_terms: []const *const Expr = if (std.meta.activeTag(left.*) == .Or) left.Or else &left_single;
                    const right_terms: []const *const Expr = if (std.meta.activeTag(right.*) == .Or) right.Or else &right_single;
                    var all = ArrayList(?*const Expr).init(allocator);
                    defer all.deinit();
                    for (left_terms) |left_term| {
                        for (right_terms) |right_term| {
                            try all.append(try normalizeAnd(allocator, &.{ left_term, right_term }, false));
                        }
                    }
                    const combined = (try normalizeOr(allocator, all.items, false)).?;
                    try negated.insert(0, combined);
                }
                break :blk (try normalizeOr(allocator, negated.items, true)).?;
            },
        };
    }

    pub fn substituteConstants(self: *const Expr) *const Expr {
        // See the file header: late-bound constants are not ported.
        return self;
    }

    pub fn equalsExpr(self: *const Expr, other: *const Expr) bool {
        if (std.meta.activeTag(self.*) != std.meta.activeTag(other.*)) return false;
        return switch (self.*) {
            .False, .True => true,
            .Defined => |key| std.mem.eql(u8, key, other.Defined),
            .Not => |key| std.mem.eql(u8, key, other.Not),
            .Equals => |entry| entry.key.len == other.Equals.key.len and std.mem.eql(u8, entry.key, other.Equals.key) and strictEquals(entry.value, other.Equals.value),
            .NotEquals => |entry| entry.key.len == other.NotEquals.key.len and std.mem.eql(u8, entry.key, other.NotEquals.key) and strictEquals(entry.value, other.NotEquals.value),
            .In => |entry| std.mem.eql(u8, entry.key, other.In.key) and std.mem.eql(u8, entry.value_key, other.In.value_key),
            .NotIn => |entry| std.mem.eql(u8, entry.key, other.NotIn.key) and std.mem.eql(u8, entry.value_key, other.NotIn.value_key),
            .Greater => |entry| numericEquals(entry, other.Greater),
            .GreaterEquals => |entry| numericEquals(entry, other.GreaterEquals),
            .Smaller => |entry| numericEquals(entry, other.Smaller),
            .SmallerEquals => |entry| numericEquals(entry, other.SmallerEquals),
            .And => |items| expressionListEquals(items, other.And),
            .Or => |items| expressionListEquals(items, other.Or),
        };
    }

    pub fn cmp(self: *const Expr, other: *const Expr) i32 {
        const self_type = @backingInt(std.meta.activeTag(self.*));
        const other_type = @backingInt(std.meta.activeTag(other.*));
        if (self_type != other_type) return @as(i32, @intCast(self_type)) - @as(i32, @intCast(other_type));

        return switch (self.*) {
            .False, .True => 0,
            .Defined => |key| cmpStrings(key, other.Defined),
            .Not => |key| cmpStrings(key, other.Not),
            .Equals => |entry| cmpKeyValues(entry, other.Equals),
            .NotEquals => |entry| cmpKeyValues(entry, other.NotEquals),
            .In => |entry| cmpKeyPairs(entry, other.In),
            .NotIn => |entry| cmpKeyPairs(entry, other.NotIn),
            .Greater => |entry| cmpNumerics(entry, other.Greater),
            .GreaterEquals => |entry| cmpNumerics(entry, other.GreaterEquals),
            .Smaller => |entry| cmpNumerics(entry, other.Smaller),
            .SmallerEquals => |entry| cmpNumerics(entry, other.SmallerEquals),
            .And => |items| cmpExpressionLists(items, other.And),
            .Or => |items| cmpExpressionLists(items, other.Or),
        };
    }
};

fn createExpr(allocator: Allocator, expr: Expr) Allocator.Error!*const Expr {
    const result = try allocator.create(Expr);
    result.* = expr;
    return result;
}

fn exprLessThan(_: void, a: *const Expr, b: *const Expr) bool {
    return a.cmp(b) < 0;
}

fn dedupe(list: *ArrayList(*const Expr)) void {
    var index: usize = 1;
    while (index < list.items.len) {
        if (list.items[index - 1].equalsExpr(list.items[index])) {
            _ = list.orderedRemove(index);
        } else {
            index += 1;
        }
    }
}

fn normalizeAnd(allocator: Allocator, exprs: []const ?*const Expr, extra_redundant_check: bool) Allocator.Error!?*const Expr {
    var list = ArrayList(*const Expr).init(allocator);
    defer list.deinit();
    var has_true = false;

    for (exprs) |maybe| {
        const expr = maybe orelse continue;
        switch (expr.*) {
            .True => {
                has_true = true;
                continue;
            },
            .False => return try createExpr(allocator, .False),
            .And => |items| try list.appendSlice(items),
            else => try list.append(expr),
        }
    }

    if (list.items.len == 0) {
        return if (has_true) try createExpr(allocator, .True) else null;
    }
    if (list.items.len == 1) return list.items[0];

    std.mem.sort(*const Expr, list.items, {}, exprLessThan);
    dedupe(&list);
    if (list.items.len == 1) return list.items[0];

    // Distribute any OR expression because the serialized form has no parens.
    while (list.items.len > 1) {
        var or_index: ?usize = null;
        var index = list.items.len;
        while (index > 0) {
            index -= 1;
            if (std.meta.activeTag(list.items[index].*) == .Or) {
                or_index = index;
                break;
            }
        }
        const last_index = or_index orelse break;
        const last = list.orderedRemove(last_index);
        const second = list.pop().?;
        const is_finished = list.items.len == 0;

        var distributed = ArrayList(?*const Expr).init(allocator);
        defer distributed.deinit();
        for (last.Or) |element| {
            try distributed.append(try normalizeAnd(allocator, &.{ element, second }, extra_redundant_check));
        }

        const result = (try normalizeOr(allocator, distributed.items, is_finished)) orelse continue;
        if (std.meta.activeTag(result.*) == .False) return result;
        try list.append(result);
        std.mem.sort(*const Expr, list.items, {}, exprLessThan);
    }
    if (list.items.len == 1) return list.items[0];

    // A distributed OR that collapsed into a single AND must not stay nested.
    var has_and = false;
    for (list.items) |expr| {
        if (std.meta.activeTag(expr.*) == .And) {
            has_and = true;
            break;
        }
    }
    if (has_and) {
        var flattened = ArrayList(*const Expr).init(allocator);
        defer flattened.deinit();
        for (list.items) |expr| {
            switch (expr.*) {
                .And => |items| try flattened.appendSlice(items),
                else => try flattened.append(expr),
            }
        }
        std.mem.sort(*const Expr, flattened.items, {}, exprLessThan);
        dedupe(&flattened);
        if (flattened.items.len == 1) return flattened.items[0];
        list.clearRetainingCapacity();
        try list.appendSlice(flattened.items);
        if (list.items.len == 1) return list.items[0];
    }

    if (extra_redundant_check) {
        for (list.items, 0..) |left, left_index| {
            for (list.items[left_index + 1 ..]) |right| {
                const negated = try left.negate(allocator);
                if (negated.equalsExpr(right)) {
                    return try createExpr(allocator, .False);
                }
            }
        }
        if (list.items.len == 1) return list.items[0];
    }

    const items = try allocator.dupe(*const Expr, list.items);
    return try createExpr(allocator, .{ .And = items });
}

fn normalizeOr(allocator: Allocator, exprs: []const ?*const Expr, extra_redundant_check: bool) Allocator.Error!?*const Expr {
    var list = ArrayList(*const Expr).init(allocator);
    defer list.deinit();
    var has_false = false;

    for (exprs) |maybe| {
        const expr = maybe orelse continue;
        switch (expr.*) {
            .False => {
                has_false = true;
                continue;
            },
            .True => return try createExpr(allocator, .True),
            .Or => |items| try list.appendSlice(items),
            else => try list.append(expr),
        }
    }

    if (list.items.len == 0 and has_false) {
        return try createExpr(allocator, .False);
    }
    if (list.items.len == 0) return null;

    std.mem.sort(*const Expr, list.items, {}, exprLessThan);
    if (list.items.len == 1) return list.items[0];
    dedupe(&list);
    if (list.items.len == 1) return list.items[0];

    if (extra_redundant_check) {
        for (list.items, 0..) |left, left_index| {
            for (list.items[left_index + 1 ..]) |right| {
                const negated = try left.negate(allocator);
                if (negated.equalsExpr(right)) {
                    return try createExpr(allocator, .True);
                }
            }
        }
        if (list.items.len == 1) return list.items[0];
    }

    const items = try allocator.dupe(*const Expr, list.items);
    return try createExpr(allocator, .{ .Or = items });
}

/// Returns true if it is provable that `p` implies `q`.
pub fn implies(p: *const Expr, q: *const Expr) bool {
    if (std.meta.activeTag(p.*) == .False or std.meta.activeTag(q.*) == .True) return true;

    if (std.meta.activeTag(p.*) == .Or) {
        if (q.* == .Or) return allElementsIncluded(p.Or, q.Or);
        return false;
    }

    if (std.meta.activeTag(q.*) == .Or) {
        for (q.Or) |element| {
            if (implies(p, element)) return true;
        }
        return false;
    }

    if (std.meta.activeTag(p.*) == .And) {
        if (std.meta.activeTag(q.*) == .And) return allElementsIncluded(q.And, p.And);
        for (p.And) |element| {
            if (implies(element, q)) return true;
        }
        return false;
    }

    return p.equalsExpr(q);
}

fn allElementsIncluded(p: []const *const Expr, q: []const *const Expr) bool {
    var p_index: usize = 0;
    var q_index: usize = 0;
    while (p_index < p.len and q_index < q.len) {
        const ordering = p[p_index].cmp(q[q_index]);
        if (ordering < 0) return false;
        if (ordering == 0) {
            p_index += 1;
            q_index += 1;
        } else {
            q_index += 1;
        }
    }
    return p_index == p.len;
}

const Comparison = enum { gt, gte, lt, lte };

fn compareNumber(value: ContextKeyValue, expected: f64, comparison: Comparison) bool {
    const number = toNumber(value) orelse return false;
    return switch (comparison) {
        .gt => number > expected,
        .gte => number >= expected,
        .lt => number < expected,
        .lte => number <= expected,
    };
}

fn inExpression(context: IContext, entry: KeyPair, negated: bool) bool {
    const source = context.getValue(entry.value_key);
    const item = context.getValue(entry.key);

    const found = switch (source) {
        .array => |values| blk: {
            for (values) |value| {
                if (looseEquals(value, item)) break :blk true;
            }
            break :blk false;
        },
        .object => |values| blk: {
            if (std.meta.activeTag(item) == .string) {
                break :blk values.contains(item.string);
            }
            break :blk false;
        },
        else => false,
    };
    return if (negated) !found else found;
}

fn isTruthy(entry: ContextKeyValue) bool {
    return switch (entry) {
        .null_value, .undefined_value => false,
        .boolean => |boolean| boolean,
        .number => |number| number != 0 and !std.math.isNan(number),
        .string => |text| text.len > 0,
        .array => |items| items.len > 0,
        .object => true,
    };
}

fn toNumber(value: ContextKeyValue) ?f64 {
    return switch (value) {
        .number => |number| number,
        .string => |string| blk: {
            const trimmed = std.mem.trim(u8, string, " \t\r\n");
            if (trimmed.len == 0) break :blk 0;
            break :blk std.fmt.parseFloat(f64, trimmed) catch null;
        },
        .boolean => |boolean| if (boolean) 1 else 0,
        .null_value => 0,
        else => null,
    };
}

fn looseEquals(a: ContextKeyValue, b: ContextKeyValue) bool {
    if (std.meta.activeTag(a) == .null_value and std.meta.activeTag(b) == .undefined_value) return true;
    if (std.meta.activeTag(a) == .undefined_value and std.meta.activeTag(b) == .null_value) return true;
    if (std.meta.activeTag(a) == std.meta.activeTag(b)) {
        return strictEquals(a, b);
    }
    if (std.meta.activeTag(a) == .null_value or std.meta.activeTag(a) == .undefined_value) return false;
    if (std.meta.activeTag(b) == .null_value or std.meta.activeTag(b) == .undefined_value) return false;

    const a_number = toNumber(a) orelse return false;
    const b_number = toNumber(b) orelse return false;
    return a_number == b_number;
}

fn strictEquals(a: ContextKeyValue, b: ContextKeyValue) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null_value, .undefined_value => true,
        .boolean => |value| value == b.boolean,
        .number => |value| value == b.number,
        .string => |value| std.mem.eql(u8, value, b.string),
        .array => |values| blk: {
            if (values.len != b.array.len) break :blk false;
            for (values, b.array) |left, right| {
                if (!strictEquals(left, right)) break :blk false;
            }
            break :blk true;
        },
        .object => |value| value == b.object,
    };
}

fn compareValues(a: ContextKeyValue, b: ContextKeyValue) i32 {
    const a_number = toNumber(a);
    const b_number = toNumber(b);
    if (a_number != null and b_number != null) {
        if (a_number.? < b_number.?) return -1;
        if (a_number.? > b_number.?) return 1;
        return 0;
    }
    if (std.meta.activeTag(a) == .string and std.meta.activeTag(b) == .string) {
        return cmpStrings(a.string, b.string);
    }
    return 0;
}

fn cmpStrings(a: []const u8, b: []const u8) i32 {
    const order = std.mem.order(u8, a, b);
    return switch (order) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

fn cmpKeyValues(a: KeyValue, b: KeyValue) i32 {
    const key_order = cmpStrings(a.key, b.key);
    if (key_order != 0) return key_order;
    return compareValues(a.value, b.value);
}

fn cmpKeyPairs(a: KeyPair, b: KeyPair) i32 {
    const key_order = cmpStrings(a.key, b.key);
    if (key_order != 0) return key_order;
    return cmpStrings(a.value_key, b.value_key);
}

fn cmpNumerics(a: NumericValue, b: NumericValue) i32 {
    const key_order = cmpStrings(a.key, b.key);
    if (key_order != 0) return key_order;
    if (a.value < b.value) return -1;
    if (a.value > b.value) return 1;
    return 0;
}

fn numericEquals(a: NumericValue, b: NumericValue) bool {
    return std.mem.eql(u8, a.key, b.key) and a.value == b.value;
}

fn expressionListEquals(a: []const *const Expr, b: []const *const Expr) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!left.equalsExpr(right)) return false;
    }
    return true;
}

fn cmpExpressionLists(a: []const *const Expr, b: []const *const Expr) i32 {
    if (a.len < b.len) return -1;
    if (a.len > b.len) return 1;
    for (a, b) |left, right| {
        const ordering = left.cmp(right);
        if (ordering != 0) return ordering;
    }
    return 0;
}

fn appendJoined(result: *ArrayList(u8), items: []const *const Expr, separator: []const u8) Allocator.Error!void {
    for (items, 0..) |item, index| {
        if (index > 0) try result.appendSlice(separator);
        try item.appendSerialized(result);
    }
}

fn appendKeyValue(result: *ArrayList(u8), entry: KeyValue, operator: []const u8) Allocator.Error!void {
    try result.appendSlice(entry.key);
    try result.appendSlice(" ");
    try result.appendSlice(operator);
    try result.appendSlice(" '");
    try appendValue(result, entry.value);
    try result.append('\'');
}

fn appendNumber(result: *ArrayList(u8), entry: NumericValue, operator: []const u8) Allocator.Error!void {
    try result.appendSlice(entry.key);
    try result.append(' ');
    try result.appendSlice(operator);
    try result.append(' ');
    try result.print("{d}", .{entry.value});
}

fn appendValue(result: *ArrayList(u8), value: ContextKeyValue) Allocator.Error!void {
    switch (value) {
        .null_value => try result.appendSlice("null"),
        .undefined_value => try result.appendSlice("undefined"),
        .boolean => |boolean| try result.appendSlice(if (boolean) "true" else "false"),
        .number => |number| try result.print("{d}", .{number}),
        .string => |string| try result.appendSlice(string),
        .array => |values| {
            for (values, 0..) |item, index| {
                if (index > 0) try result.append(',');
                try appendValue(result, item);
            }
        },
        .object => try result.appendSlice("[object Object]"),
    }
}

/// Expression factory; nodes are allocated from its arena and freed by
/// `deinit`.
pub const ContextKeyExpr = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: Allocator) ContextKeyExpr {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *ContextKeyExpr) void {
        self.arena.deinit();
    }

    fn arenaAllocator(self: *ContextKeyExpr) Allocator {
        return self.arena.allocator();
    }

    pub fn falseExpr(self: *ContextKeyExpr) Allocator.Error!*const Expr {
        return createExpr(self.arenaAllocator(), .False);
    }

    pub fn trueExpr(self: *ContextKeyExpr) Allocator.Error!*const Expr {
        return createExpr(self.arenaAllocator(), .True);
    }

    pub fn has(self: *ContextKeyExpr, key: []const u8) Allocator.Error!*const Expr {
        return createExpr(self.arenaAllocator(), .{ .Defined = key });
    }

    pub fn equals(self: *ContextKeyExpr, key: []const u8, value: ContextKeyValue) Allocator.Error!*const Expr {
        return createExpr(self.arenaAllocator(), .{ .Equals = .{ .key = key, .value = value } });
    }

    pub fn notEquals(self: *ContextKeyExpr, key: []const u8, value: ContextKeyValue) Allocator.Error!*const Expr {
        return createExpr(self.arenaAllocator(), .{ .NotEquals = .{ .key = key, .value = value } });
    }

    pub fn not(self: *ContextKeyExpr, key: []const u8) Allocator.Error!*const Expr {
        return createExpr(self.arenaAllocator(), .{ .Not = key });
    }

    pub fn inKey(self: *ContextKeyExpr, key: []const u8, value_key: []const u8) Allocator.Error!*const Expr {
        return createExpr(self.arenaAllocator(), .{ .In = .{ .key = key, .value_key = value_key } });
    }

    pub fn notInKey(self: *ContextKeyExpr, key: []const u8, value_key: []const u8) Allocator.Error!*const Expr {
        return createExpr(self.arenaAllocator(), .{ .NotIn = .{ .key = key, .value_key = value_key } });
    }

    pub fn greater(self: *ContextKeyExpr, key: []const u8, value: f64) Allocator.Error!*const Expr {
        return createExpr(self.arenaAllocator(), .{ .Greater = .{ .key = key, .value = value } });
    }

    pub fn greaterEquals(self: *ContextKeyExpr, key: []const u8, value: f64) Allocator.Error!*const Expr {
        return createExpr(self.arenaAllocator(), .{ .GreaterEquals = .{ .key = key, .value = value } });
    }

    pub fn smaller(self: *ContextKeyExpr, key: []const u8, value: f64) Allocator.Error!*const Expr {
        return createExpr(self.arenaAllocator(), .{ .Smaller = .{ .key = key, .value = value } });
    }

    pub fn smallerEquals(self: *ContextKeyExpr, key: []const u8, value: f64) Allocator.Error!*const Expr {
        return createExpr(self.arenaAllocator(), .{ .SmallerEquals = .{ .key = key, .value = value } });
    }

    pub fn andExpr(self: *ContextKeyExpr, exprs: []const ?*const Expr) Allocator.Error!?*const Expr {
        return normalizeAnd(self.arenaAllocator(), exprs, true);
    }

    pub fn orExpr(self: *ContextKeyExpr, exprs: []const ?*const Expr) Allocator.Error!?*const Expr {
        return normalizeOr(self.arenaAllocator(), exprs, true);
    }
};

const TestContext = struct {
    values: std.StringHashMap(ContextKeyValue),

    fn init(allocator: Allocator) TestContext {
        return .{ .values = std.StringHashMap(ContextKeyValue).init(allocator) };
    }

    fn deinit(self: *TestContext) void {
        self.values.deinit();
    }

    fn context(self: *TestContext) IContext {
        return .{ .context = self, .get_value = getValue };
    }

    fn getValue(context_ptr: *anyopaque, key: []const u8) ContextKeyValue {
        const self: *TestContext = @ptrCast(@alignCast(context_ptr));
        return self.values.get(key) orelse .undefined_value;
    }
};

fn expectSerialized(expr: *const Expr, expected: []const u8) !void {
    const serialized = try expr.serialize(std.testing.allocator);
    defer std.testing.allocator.free(serialized);
    try std.testing.expectEqualStrings(expected, serialized);
}

test "equals and has evaluate against a context" {
    var factory = ContextKeyExpr.init(std.testing.allocator);
    defer factory.deinit();
    var context = TestContext.init(std.testing.allocator);
    defer context.deinit();

    const equals = try factory.equals("bar", .{ .string = "baz" });
    try std.testing.expect(!equals.evaluate(context.context()));
    try context.values.put("bar", .{ .string = "baz" });
    try std.testing.expect(equals.evaluate(context.context()));
    try std.testing.expect(!(try factory.notEquals("bar", .{ .string = "baz" })).evaluate(context.context()));
    try std.testing.expect((try factory.has("bar")).evaluate(context.context()));
    try std.testing.expect(!(try factory.not("bar")).evaluate(context.context()));
    try std.testing.expect((try factory.greater("count", 1)).evaluate(context.context()) == false);
    try context.values.put("count", .{ .number = 2 });
    try std.testing.expect((try factory.greater("count", 1)).evaluate(context.context()));
}

test "and/or normalize sort, flatten and dedupe" {
    var factory = ContextKeyExpr.init(std.testing.allocator);
    defer factory.deinit();

    const a = try factory.has("a");
    const b = try factory.has("b");
    const c = try factory.has("c");
    const and_expr = (try factory.andExpr(&.{ c, a, b, a })).?;
    try expectSerialized(and_expr, "a && b && c");

    const or_expr = (try factory.orExpr(&.{ c, a, b })).?;
    try expectSerialized(or_expr, "a || b || c");

    const with_true = (try factory.andExpr(&.{ a, try factory.trueExpr() })).?;
    try expectSerialized(with_true, "a");

    try std.testing.expect(std.meta.activeTag((try factory.andExpr(&.{ a, try factory.falseExpr() })).?.*) == .False);
    try std.testing.expect(std.meta.activeTag((try factory.orExpr(&.{ a, try factory.trueExpr() })).?.*) == .True);
}

test "and distributes OR terms" {
    var factory = ContextKeyExpr.init(std.testing.allocator);
    defer factory.deinit();
    var context = TestContext.init(std.testing.allocator);
    defer context.deinit();

    const a = try factory.has("a");
    const b = try factory.has("b");
    const c = try factory.has("c");
    const expr = (try factory.andExpr(&.{ try factory.orExpr(&.{ a, b }), c })).?;

    try context.values.put("a", .{ .boolean = false });
    try context.values.put("b", .{ .boolean = false });
    try context.values.put("c", .{ .boolean = true });
    try std.testing.expect(!expr.evaluate(context.context()));

    try context.values.put("b", .{ .boolean = true });
    try std.testing.expect(expr.evaluate(context.context()));
    const serialized = try expr.serialize(std.testing.allocator);
    defer std.testing.allocator.free(serialized);
    try std.testing.expectEqualStrings("a && c || b && c", serialized);
}

test "negation and implies" {
    var factory = ContextKeyExpr.init(std.testing.allocator);
    defer factory.deinit();

    const a = try factory.has("a");
    const b = try factory.has("b");
    const and_expr = (try factory.andExpr(&.{ a, b })).?;
    const negated = try and_expr.negate(factory.arenaAllocator());
    try expectSerialized(negated, "!a || !b");

    try std.testing.expect(implies(and_expr, a));
    try std.testing.expect(implies(and_expr, b));
    try std.testing.expect(!implies(a, and_expr));
    try std.testing.expect(implies(a, (try factory.orExpr(&.{ a, b })).?));
}

test "comparisons evaluate and negate like upstream" {
    var factory = ContextKeyExpr.init(std.testing.allocator);
    defer factory.deinit();
    var context = TestContext.init(std.testing.allocator);
    defer context.deinit();

    const greater = try factory.greater("a", 1.1);
    try std.testing.expect(!greater.evaluate(context.context()));
    try context.values.put("a", .{ .string = "2" });
    try std.testing.expect(greater.evaluate(context.context()));
    try context.values.put("a", .{ .string = "1.1" });
    try std.testing.expect(!greater.evaluate(context.context()));

    const negated = try greater.negate(factory.arenaAllocator());
    try expectSerialized(negated, "a <= 1.1");

    const smaller = try factory.smaller("a", 2);
    try context.values.put("a", .{ .string = "3" });
    try std.testing.expect(!smaller.evaluate(context.context()));
    try std.testing.expect(std.meta.activeTag((try smaller.negate(factory.arenaAllocator())).*) == .GreaterEquals);
}

test "in and not in evaluate arrays and objects" {
    var factory = ContextKeyExpr.init(std.testing.allocator);
    defer factory.deinit();
    var context = TestContext.init(std.testing.allocator);
    defer context.deinit();

    const values = [_]ContextKeyValue{ .{ .string = "a" }, .{ .string = "b" } };
    try context.values.put("supported", .{ .array = &values });
    try context.values.put("lang", .{ .string = "b" });

    const in_expr = try factory.inKey("lang", "supported");
    try std.testing.expect(in_expr.evaluate(context.context()));
    try std.testing.expect(!(try factory.notInKey("lang", "supported")).evaluate(context.context()));

    var object = std.StringHashMap(ContextKeyValue).init(std.testing.allocator);
    defer object.deinit();
    try object.put("key", .{ .boolean = true });
    try context.values.put("map", .{ .object = &object });

    const key_expr = try factory.inKey("lang", "map");
    try std.testing.expect(!key_expr.evaluate(context.context()));
    try context.values.put("lang", .{ .string = "key" });
    try std.testing.expect(key_expr.evaluate(context.context()));
}

test "expression equality and keys" {
    var factory = ContextKeyExpr.init(std.testing.allocator);
    defer factory.deinit();

    const first = (try factory.andExpr(&.{ try factory.has("a"), try factory.equals("b", .{ .string = "c" }) })).?;
    const second = (try factory.andExpr(&.{ try factory.equals("b", .{ .string = "c" }), try factory.has("a") })).?;
    try std.testing.expect(first.equalsExpr(second));

    const keys = try first.keys(std.testing.allocator);
    defer std.testing.allocator.free(keys);
    try std.testing.expectEqual(@as(usize, 2), keys.len);
    try std.testing.expectEqualStrings("a", keys[0]);
    try std.testing.expectEqualStrings("b", keys[1]);
}
