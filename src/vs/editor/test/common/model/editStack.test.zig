// Port of `src/vs/editor/test/common/model/editStack.test.ts`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const Selection = @import("../../../common/core/selection.zig").Selection;
const EOL = @import("../../../common/core/misc/eolCounter.zig").EOL;
const TextChange = @import("../../../common/core/textChange.zig").TextChange;
const String = @import("../../../../base/common/strings.zig").String;
const editStack = @import("../../../common/model/editStack.zig");
const SingleModelEditStackDataUnserialized = editStack.SingleModelEditStackDataUnserialized;

fn dupeSelections(allocator: Allocator, selections: []const Selection) ![]Selection {
    return try allocator.dupe(Selection, selections);
}

test "EditStack: issue #118041: unicode character undo bug" {
    const allocator = std.testing.allocator;

    var changes = ArrayList(TextChange).init(allocator);
    try changes.append(TextChange.init(
        428,
        String.initBorrowed("\u{feff}"),
        428,
        String.initBorrowed(""),
    ));

    var data = SingleModelEditStackDataUnserialized{
        .beforeVersionId = 1,
        .afterVersionId = 2,
        .beforeEOL = .LF,
        .afterEOL = .LF,
        .beforeCursorState = try dupeSelections(allocator, &[_]Selection{Selection.init(10, 2, 10, 2)}),
        .afterCursorState = try dupeSelections(allocator, &[_]Selection{Selection.init(10, 1, 10, 1)}),
        .changes = changes,
    };
    defer data.deinit();

    const buff = try data.serialize();
    defer buff.deinit();

    var actual = try SingleModelEditStackDataUnserialized.deserialize(allocator, buff.items);
    defer actual.deinit();

    try std.testing.expectEqual(@as(u32, 1), actual.beforeVersionId);
    try std.testing.expectEqual(@as(u32, 2), actual.afterVersionId);
    try std.testing.expectEqual(EOL.LF, actual.beforeEOL);
    try std.testing.expectEqual(EOL.LF, actual.afterEOL);
    try std.testing.expectEqual(@as(usize, 1), actual.changes.items.len);
    try std.testing.expectEqualStrings("\u{feff}", actual.changes.items[0].oldText.items());
    try std.testing.expectEqualStrings("", actual.changes.items[0].newText.items());

    const before = actual.beforeCursorState.?;
    try std.testing.expectEqual(@as(usize, 1), before.len);
    try std.testing.expectEqual(@as(usize, 10), before[0].startLineNumber);
    try std.testing.expectEqual(@as(usize, 2), before[0].startColumn);
    try std.testing.expectEqual(@as(usize, 10), before[0].endLineNumber);
    try std.testing.expectEqual(@as(usize, 2), before[0].endColumn);
    try std.testing.expectEqual(@as(usize, 10), before[0].selectionStartLineNumber);
    try std.testing.expectEqual(@as(usize, 2), before[0].selectionStartColumn);
    try std.testing.expectEqual(@as(usize, 10), before[0].positionLineNumber);
    try std.testing.expectEqual(@as(usize, 2), before[0].positionColumn);

    const after = actual.afterCursorState.?;
    try std.testing.expectEqual(@as(usize, 1), after.len);
    try std.testing.expectEqual(@as(usize, 10), after[0].startLineNumber);
    try std.testing.expectEqual(@as(usize, 1), after[0].startColumn);
    try std.testing.expectEqual(@as(usize, 10), after[0].endLineNumber);
    try std.testing.expectEqual(@as(usize, 1), after[0].endColumn);
}
