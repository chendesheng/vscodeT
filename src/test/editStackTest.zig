const std = @import("std");
const Selection = @import("../basics/selection.zig").Selection;
const TextChange = @import("../textModel/textChange.zig").TextChange;
const SingleModelEditStackData = @import("../textModel/editStack.zig").SingleModelEditStackData;

const EditStackTests = struct {
    const allocator = std.testing.allocator;

    test "issue #118041: unicode character undo bug" {
        var stackData = try SingleModelEditStackData.init(
            allocator,
            1,
            2,
            .LF,
            .LF,
            &[_]Selection{Selection.init(10, 2, 10, 2)},
            &[_]Selection{Selection.init(10, 1, 10, 1)},
            &[_]TextChange{TextChange.init(428, .initBorrowed("\u{feff}"), 428, .initBorrowed(""))},
        );
        defer stackData.deinit();

        const buff = try stackData.serialize();
        defer allocator.free(buff);
        var actual = try SingleModelEditStackData.deserialize(allocator, buff);
        defer actual.deinit();

        try std.testing.expectEqual(actual.beforeVersionId, stackData.beforeVersionId);
        try std.testing.expectEqual(actual.afterVersionId, stackData.afterVersionId);
        try std.testing.expectEqual(actual.beforeEOL, stackData.beforeEOL);
        try std.testing.expectEqual(actual.afterEOL, stackData.afterEOL);
        try std.testing.expectEqualDeep(actual.beforeCursorState, stackData.beforeCursorState);
        try std.testing.expectEqualDeep(actual.afterCursorState, stackData.afterCursorState);
        try std.testing.expectEqual(actual.changes.items.len, stackData.changes.items.len);
        for (actual.changes.items, 0..) |change, i| {
            try std.testing.expectEqualDeep(change.oldPosition, stackData.changes.items[i].oldPosition);
            try std.testing.expectEqualDeep(change.newPosition, stackData.changes.items[i].newPosition);

            try std.testing.expect(change.oldText.eql(stackData.changes.items[i].oldText));
            try std.testing.expect(change.newText.eql(stackData.changes.items[i].newText));
        }
    }
};

test "editStack" {
    _ = EditStackTests;
}
