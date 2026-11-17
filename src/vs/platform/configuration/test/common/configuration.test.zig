// Port of the merge/remove/toValuesTree cases of
// `src/vs/platform/configuration/test/common/configuration.test.ts`.
// JavaScript `undefined` values have no JSON representation; the object-merge
// case uses explicit `null` for the missing value. The upstream
// `__proto__`-pollution test is not applicable: Zig maps have no prototype.
const std = @import("std");
const configuration = @import("../../common/configuration.zig");

fn parse(arena: std.mem.Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
}

fn valueEquals(a: std.json.Value, b: std.json.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => |value| value == b.bool,
        .integer => |value| value == b.integer,
        .float => |value| value == b.float,
        .number_string => |value| std.mem.eql(u8, value, b.number_string),
        .string => |value| std.mem.eql(u8, value, b.string),
        .array => |array| blk: {
            if (array.items.len != b.array.items.len) break :blk false;
            for (array.items, b.array.items) |item_a, item_b| {
                if (!valueEquals(item_a, item_b)) break :blk false;
            }
            break :blk true;
        },
        .object => |object| blk: {
            if (object.count() != b.object.count()) break :blk false;
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                const other = b.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!valueEquals(entry.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn expectValue(actual: std.json.Value, expected_text: []const u8, arena: std.mem.Allocator) !void {
    const expected = try parse(arena, expected_text);
    try std.testing.expect(valueEquals(actual, expected));
}

test "simple merge" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    {
        var base = try parse(arena.allocator(), "{\"a\":1,\"b\":2}");
        const add = try parse(arena.allocator(), "{\"a\":3,\"c\":4}");
        try configuration.merge(arena.allocator(), &base, add, true);
        try expectValue(base, "{\"a\":3,\"b\":2,\"c\":4}", arena.allocator());
    }
    {
        var base = try parse(arena.allocator(), "{\"a\":1,\"b\":2}");
        const add = try parse(arena.allocator(), "{\"a\":3,\"c\":4}");
        try configuration.merge(arena.allocator(), &base, add, false);
        try expectValue(base, "{\"a\":1,\"b\":2,\"c\":4}", arena.allocator());
    }
}

test "object and array merge" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    {
        var base = try parse(arena.allocator(), "{\"a\":{\"b\":1,\"c\":true,\"d\":2}}");
        const add = try parse(arena.allocator(), "{\"a\":{\"b\":null,\"c\":false,\"e\":\"a\"}}");
        try configuration.merge(arena.allocator(), &base, add, true);
        try expectValue(base, "{\"a\":{\"b\":null,\"c\":false,\"d\":2,\"e\":\"a\"}}", arena.allocator());
    }
    {
        var base = try parse(arena.allocator(), "{\"a\":[\"b\",\"c\"]}");
        const add = try parse(arena.allocator(), "{\"a\":[\"b\",\"d\"]}");
        try configuration.merge(arena.allocator(), &base, add, true);
        try expectValue(base, "{\"a\":[\"b\",\"d\"]}", arena.allocator());
    }
}

test "removeFromValueTree cases" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const cases = [_]struct { before: []const u8, key: []const u8, after: []const u8 }{
        .{ .before = "{\"a\":{\"b\":2}}", .key = "c", .after = "{\"a\":{\"b\":2}}" },
        .{ .before = "{\"a\":{\"b\":2}}", .key = "a.b.c", .after = "{\"a\":{\"b\":2}}" },
        .{ .before = "{\"a\":1}", .key = "a", .after = "{}" },
        .{ .before = "{\"a\":null}", .key = "a", .after = "{}" },
        .{ .before = "{\"a\":{\"b\":1}}", .key = "a.b", .after = "{}" },
        .{ .before = "{\"a\":{\"b\":[1]}}", .key = "a.b", .after = "{}" },
        .{ .before = "{\"a\":[1]}", .key = "a.0", .after = "{\"a\":[1]}" },
        .{ .before = "{\"a\":{\"b\":1}}", .key = "a", .after = "{}" },
        .{ .before = "{\"a\":{\"b\":{\"c\":1},\"d\":1}}", .key = "a.b.c", .after = "{\"a\":{\"d\":1}}" },
        .{ .before = "{\"a\":{\"b\":{\"c\":{\"d\":1},\"d\":1}}}", .key = "a.b.c.d", .after = "{\"a\":{\"b\":{\"d\":1}}}" },
        .{ .before = "{\"a\":{\"b\":{\"c\":1,\"d\":1}}}", .key = "a.b.c", .after = "{\"a\":{\"b\":{\"d\":1}}}" },
    };
    for (cases) |case| {
        var target = try parse(arena.allocator(), case.before);
        configuration.removeFromValueTree(&target, case.key);
        try expectValue(target, case.after, arena.allocator());
    }
}

test "affectsConfiguration handles language overrides" {
    const keys = [_][]const u8{"other"};
    const override_keys = [_][]const u8{"editor.tabSize"};
    const overrides = [_]configuration.OverrideChange{.{ .identifier = "typescript", .keys = &override_keys }};
    const change = configuration.Change{ .source = .WORKSPACE, .keys = &keys, .overrides = &overrides };
    try std.testing.expect(!configuration.affectsConfigurationWithOverrides(change, "editor.tabSize", null));
    try std.testing.expect(configuration.affectsConfigurationWithOverrides(change, "editor.tabSize", "typescript"));
    try std.testing.expect(!configuration.affectsConfigurationWithOverrides(change, "editor.tabSize", "python"));
    try std.testing.expect(configuration.affectsConfigurationWithOverrides(change, "editor", "typescript"));
}
