// Port of `src/vs/workbench/contrib/multiDiffEditor/test/browser/multiDiffEditorLayoutDebug.test.ts`.
const std = @import("std");
const testing = std.testing;
const debug = @import("../../browser/multiDiffEditorLayoutDebug.zig");

fn parse(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{ .allocate = .alloc_always });
}
fn expectPatch(previous: []const u8, next: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const patch = try debug.createJsonPatch(a, try parse(a, previous), try parse(a, next));
    const operations = try std.json.Stringify.valueAlloc(a, patch.operations, .{ .emit_null_optional_fields = false });
    try testing.expectEqualStrings(expected, operations);
    const result = try debug.applyJsonPatchToText(a, previous, patch);
    const normalized = try std.json.Stringify.valueAlloc(a, try parse(a, result), .{});
    try testing.expectEqualStrings(next, normalized);
}

test "MultiDiffEditorLayoutDebug: creates and applies structural JSON patches" {
    try expectPatch(
        \\{"scrollTop":10,"items":[{"label":"a","height":20,"visible":true},{"label":"b","height":30,"visible":false}],"obsolete":true}
    ,
        \\{"scrollTop":15,"items":[{"label":"a","height":25,"visible":true},{"label":"b","height":30,"visible":true}],"added":"value"}
    ,
        \\[{"op":"remove","path":"/obsolete"},{"op":"replace","path":"/scrollTop","value":15},{"op":"replace","path":"/items/0/height","value":25},{"op":"replace","path":"/items/1/visible","value":true},{"op":"add","path":"/added","value":"value"}]
    );
}

test "MultiDiffEditorLayoutDebug: escapes JSON pointer segments" {
    try expectPatch(
        \\{"a/b":{"~key":1}}
    ,
        \\{"a/b":{"~key":2}}
    ,
        \\[{"op":"replace","path":"/a~1b/~0key","value":2}]
    );
}

test "MultiDiffEditorLayoutDebug: treats undefined object properties as absent JSON properties" {
    // Zig JSON objects represent undefined by omitting the field.
    try expectPatch(
        \\{"removed":{"value":1},"nested":{"removed":{"value":2}}}
    ,
        \\{"nested":{"added":{"value":4}},"added":{"value":3}}
    ,
        \\[{"op":"remove","path":"/removed"},{"op":"remove","path":"/nested/removed"},{"op":"add","path":"/nested/added","value":{"value":4}},{"op":"add","path":"/added","value":{"value":3}}]
    );
    // Preserve upstream next-object traversal order even when the added
    // property is enumerated before the nested property.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const patch = try debug.createJsonPatch(a, try parse(a,
        \\{"removed":{"value":1},"nested":{"removed":{"value":2}}}
    ), try parse(a,
        \\{"added":{"value":3},"nested":{"added":{"value":4}}}
    ));
    const actual = try std.json.Stringify.valueAlloc(a, patch.operations, .{ .emit_null_optional_fields = false });
    try testing.expectEqualStrings(
        \\[{"op":"remove","path":"/removed"},{"op":"add","path":"/added","value":{"value":3}},{"op":"remove","path":"/nested/removed"},{"op":"add","path":"/nested/added","value":{"value":4}}]
    , actual);
}

test "MultiDiffEditorLayoutDebug: composes nested patches" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const initial = "{\"value\":1,\"nested\":{\"enabled\":false}}";
    const updated = "{\"value\":2,\"nested\":{\"enabled\":false}}";
    const final = "{\"value\":2,\"nested\":{\"enabled\":true}}";
    const first = try debug.createJsonPatch(a, try parse(a, initial), try parse(a, updated));
    const second = try debug.createJsonPatch(a, try parse(a, updated), try parse(a, final));
    const result = try debug.applyJsonPatchToText(a, initial, .{ .children = &.{ first, .{ .children = &.{second} } } });
    const normalized = try std.json.Stringify.valueAlloc(a, try parse(a, result), .{});
    try testing.expectEqualStrings(final, normalized);
}
