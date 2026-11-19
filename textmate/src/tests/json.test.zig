// Port of `vscode-textmate/src/tests/json.test.ts`
// (microsoft/vscode-textmate v9.3.2).
const std = @import("std");
const json = @import("../json.zig");
const rawGrammar = @import("../rawGrammar.zig");

fn expectJsonValue(expected: std.json.Value, actual: rawGrammar.Value) !void {
    switch (expected) {
        .null => try std.testing.expect(actual == .null),
        .bool => |value| try std.testing.expect(actual == .boolean and actual.boolean == value),
        .integer => |value| {
            try std.testing.expect(actual == .number);
            try std.testing.expectEqual(@as(f64, @floatFromInt(value)), actual.number);
        },
        .float => |value| {
            try std.testing.expect(actual == .number);
            try std.testing.expectEqual(value, actual.number);
        },
        .number_string => |value| {
            try std.testing.expect(actual == .number);
            try std.testing.expectEqual(try std.fmt.parseFloat(f64, value), actual.number);
        },
        .string => |value| {
            try std.testing.expect(actual == .string);
            try std.testing.expectEqualStrings(value, actual.string);
        },
        .array => |values| {
            try std.testing.expect(actual == .array);
            try std.testing.expectEqual(values.items.len, actual.array.len);
            for (values.items, actual.array) |expected_item, actual_item| {
                try expectJsonValue(expected_item, actual_item);
            }
        },
        .object => |object| {
            try std.testing.expect(actual == .object);
            try std.testing.expectEqual(object.count(), actual.object.map.count());
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                const actual_value = actual.object.get(entry.key_ptr.*) orelse return error.TestUnexpectedResult;
                try expectJsonValue(entry.value_ptr.*, actual_value);
            }
        },
    }
}

fn isValid(allocator: std.mem.Allocator, source: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, source, .{ .duplicate_field_behavior = .use_last });
    defer parsed.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const actual = try json.parseJSON(arena.allocator(), source, null, false);
    try expectJsonValue(parsed.value, actual);
}

fn isInvalid(allocator: std.mem.Allocator, source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidJson, json.parseJSON(arena.allocator(), source, null, false));
}

test "JSON Invalid body" {
    const allocator = std.testing.allocator;
    try isInvalid(allocator, "{}[]");
    try isInvalid(allocator, "*");
}

test "JSON Trailing Whitespace" {
    try isValid(std.testing.allocator, "{}\n\n");
}

test "JSON Objects" {
    const allocator = std.testing.allocator;
    try isValid(allocator, "{}");
    try isValid(allocator, "{\"key\": \"value\"}");
    try isValid(allocator, "{\"key1\": true, \"key2\": 3, \"key3\": [null], \"key4\": { \"nested\": {}}}");
    try isValid(allocator, "{\"constructor\": true }");

    try isInvalid(allocator, "{");
    try isInvalid(allocator, "{3:3}");
    try isInvalid(allocator, "{'key': 3}");
    try isInvalid(allocator, "{\"key\" 3}");
    try isInvalid(allocator, "{\"key\":3 \"key2\": 4}");
    try isInvalid(allocator, "{\"key\":42, }");
    try isInvalid(allocator, "{\"key:42");
}

test "JSON Arrays" {
    const allocator = std.testing.allocator;
    try isValid(allocator, "[]");
    try isValid(allocator, "[1, 2]");
    try isValid(allocator, "[1, \"string\", false, {}, [null]]");

    try isInvalid(allocator, "[");
    try isInvalid(allocator, "[,]");
    try isInvalid(allocator, "[1 2]");
    try isInvalid(allocator, "[true false]");
    try isInvalid(allocator, "[1, ]");
    try isInvalid(allocator, "[[]");
    try isInvalid(allocator, "[\"something\"");
    try isInvalid(allocator, "[magic]");
}

test "JSON Strings" {
    const allocator = std.testing.allocator;
    try isValid(allocator, "[\"string\"]");
    try isValid(allocator, "[\"\\\"\\\\\\/\\b\\f\\n\\r\\t\\u1234\\u12AB\"]");
    try isValid(allocator, "[\"\\\\\"]");

    try isInvalid(allocator, "[\"");
    try isInvalid(allocator, "[\"]");
    try isInvalid(allocator, "[\"\\z\"]");
    try isInvalid(allocator, "[\"\\u\"]");
    try isInvalid(allocator, "[\"\\u123\"]");
    try isInvalid(allocator, "[\"\\u123Z\"]");
    try isInvalid(allocator, "['string']");
}

test "Numbers" {
    try isValid(std.testing.allocator, "[0, -1, 186.1, 0.123, -1.583e+4, 1.583E-4, 5e8]");
}

test "JSON misc" {
    const allocator = std.testing.allocator;
    try isValid(allocator, "{}");
    try isValid(allocator, "[null]");
    try isValid(allocator, "{\"a\":true}");
    try isValid(allocator, "{\n\t\"key\" : {\n\t\"key2\": 42\n\t}\n}");
    try isValid(allocator, "{\"key\":[{\"key2\":42}]}");
    try isValid(allocator, "{\n\t\n}");
    try isValid(allocator, "{\n\"first\":true\n\n}");
    try isValid(allocator, "{\n\"key\":32,\n\n\"key2\":45}");
    try isValid(allocator, "{\"a\": 1,\n\n\"d\": 2}");
    try isValid(allocator, "{\"a\": 1, \"a\": 2}");
    try isValid(allocator, "{\"a\": { \"a\": 2, \"a\": 3}}");
    try isValid(allocator, "[{ \"a\": 2, \"a\": 3}]");
    try isValid(allocator, "{\"key1\":\"first string\", \"key2\":[\"second string\"]}");

    try isInvalid(allocator, "{\n\"key\":32,\nerror\n}");
}
