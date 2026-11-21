// Tests for the history helpers ported from
// `vscode/extensions/git/src/util.ts`.
const std = @import("std");
const testing = std.testing;
const util = @import("../util.zig");
const history = @import("../../../../vs/workbench/contrib/scm/common/history.zig");

fn makeRef(id: []const u8, revision: ?[]const u8) history.ISCMHistoryItemRef {
    return .{ .id = id, .name = id, .revision = revision };
}

test "util: subject and truncate" {
    const allocator = testing.allocator;
    try testing.expectEqualStrings("first", util.subject("first\nsecond"));
    try testing.expectEqualStrings("whole", util.subject("whole"));

    const short = try util.truncate(allocator, "abcdef1234", 7);
    defer allocator.free(short);
    try testing.expectEqualStrings("abcdef1", short);

    const untouched = try util.truncate(allocator, "abc", 7);
    defer allocator.free(untouched);
    try testing.expectEqualStrings("abc", untouched);
}

test "util: deltaHistoryItemRefs added, removed and modified" {
    const allocator = testing.allocator;
    const before = [_]history.ISCMHistoryItemRef{
        makeRef("a", "1"),
        makeRef("b", "2"),
        makeRef("d", "4"),
    };
    const after = [_]history.ISCMHistoryItemRef{
        makeRef("a", "1"),
        makeRef("b", "3"),
        makeRef("c", "5"),
    };

    var delta = try util.deltaHistoryItemRefs(allocator, &before, &after);
    defer delta.deinit();

    try testing.expectEqual(@as(usize, 1), delta.added.items.len);
    try testing.expectEqualStrings("c", delta.added.items[0].id);
    try testing.expectEqual(@as(usize, 1), delta.removed.items.len);
    try testing.expectEqualStrings("d", delta.removed.items[0].id);
    try testing.expectEqual(@as(usize, 1), delta.modified.items.len);
    try testing.expectEqualStrings("b", delta.modified.items[0].id);
    try testing.expectEqualStrings("3", delta.modified.items[0].revision.?);

    var empty_delta = try util.deltaHistoryItemRefs(allocator, &.{}, &after);
    defer empty_delta.deinit();
    try testing.expectEqual(@as(usize, 3), empty_delta.added.items.len);
}
