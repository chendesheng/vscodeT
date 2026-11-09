const std = @import("std");

const Position = @import("../../../../common/core/position.zig").Position;
const Selection = @import("../../../../common/core/selection.zig").Selection;
const cursor_common = @import("../../../../common/cursorCommon.zig");
const CursorConfiguration = cursor_common.CursorConfiguration;
const CursorState = cursor_common.CursorState;
const CursorContext = @import("../../../../common/cursor/cursorContext.zig").CursorContext;
const CursorCollection = @import("../../../../common/cursor/cursorCollection.zig").CursorCollection;
const TextModelCursorSimpleModel = @import("../../../../common/cursor/textModelCursorSimpleModel.zig").TextModelCursorSimpleModel;
const IdentityCoordinatesConverter = @import("../../../../common/coordinatesConverter.zig").IdentityCoordinatesConverter;
const TestModel = @import("../../port/testSupport.zig").TestModel;
const multicursor = @import("../../../../contrib/multicursor/browser/multicursor.zig");

fn expectSelections(actual: ?[]const Selection, expected: []const Selection) !void {
    try std.testing.expect(actual != null);
    try std.testing.expectEqual(expected.len, actual.?.len);
    for (expected, actual.?) |expected_selection, actual_selection| {
        if (!expected_selection.equalsSelection(&actual_selection)) {
            std.debug.print("multicursor mismatch expected ({d},{d})->({d},{d}) actual ({d},{d})->({d},{d})\n", .{
                expected_selection.selectionStartLineNumber, expected_selection.selectionStartColumn, expected_selection.positionLineNumber, expected_selection.positionColumn,
                actual_selection.selectionStartLineNumber,   actual_selection.selectionStartColumn,   actual_selection.positionLineNumber,   actual_selection.positionColumn,
            });
            return error.TestUnexpectedResult;
        }
    }
}

test "multicursor: add cursor above and below" {
    const allocator = std.testing.allocator;
    var ctx = try TestModel.init(allocator, "a\nb\nc", "nullLanguage");
    defer ctx.deinit();
    var adapter = TextModelCursorSimpleModel.init(allocator, ctx.model);
    defer adapter.deinit();
    var converter = IdentityCoordinatesConverter.init(ctx.model);
    const config = CursorConfiguration{ .tabSize = 4, .indentSize = 4, .insertSpaces = true, .pageSize = 1 };
    var context = CursorContext.init(ctx.model, adapter.interface(), converter.toInterface(), &config);

    var collection = try CursorCollection.init(allocator, &context);
    defer collection.deinit();
    try collection.setSelections(allocator, &[_]Selection{Selection.init(2, 1, 2, 1)});

    const cursors = try collection.getAll(allocator);
    defer allocator.free(cursors);

    const down = try multicursor.addCursorDown(allocator, &config, adapter.interface(), cursors);
    defer allocator.free(down);
    try collection.setStates(down);
    try collection.normalize();
    const after_down = try collection.getAll(allocator);
    defer allocator.free(after_down);
    try std.testing.expectEqual(@as(usize, 2), after_down.len);
    try std.testing.expectEqual(Position.init(2, 1), after_down[0].modelState.position);
    try std.testing.expectEqual(Position.init(3, 1), after_down[1].modelState.position);

    const up = try multicursor.addCursorUp(allocator, &config, adapter.interface(), after_down);
    defer allocator.free(up);
    try collection.setStates(up);
    try collection.normalize();
    const after_up = try collection.getAll(allocator);
    defer allocator.free(after_up);
    try std.testing.expectEqual(@as(usize, 3), after_up.len);
}

test "multicursor: add cursors at line ends and from top/bottom" {
    const allocator = std.testing.allocator;
    var ctx = try TestModel.init(allocator, "a\nbb\nccc\ndddd", "nullLanguage");
    defer ctx.deinit();

    const line_ends = try multicursor.addCursorsAtLineEnds(allocator, ctx.model, &[_]Selection{
        Selection.init(1, 2, 3, 2),
    });
    defer if (line_ends) |value| allocator.free(value);
    try expectSelections(line_ends, &[_]Selection{
        Selection.init(1, 2, 1, 2),
        Selection.init(2, 3, 2, 3),
        Selection.init(3, 2, 3, 2),
    });

    const bottom = try multicursor.addCursorsToBottom(allocator, ctx.model, &[_]Selection{
        Selection.init(3, 1, 3, 2),
    });
    defer if (bottom) |value| allocator.free(value);
    try expectSelections(bottom, &[_]Selection{
        Selection.init(3, 1, 3, 2),
        Selection.init(4, 1, 4, 2),
    });

    const top = try multicursor.addCursorsToTop(allocator, ctx.model, &[_]Selection{
        Selection.init(3, 1, 3, 2),
    });
    defer if (top) |value| allocator.free(value);
    try expectSelections(top, &[_]Selection{
        Selection.init(3, 1, 3, 2),
        Selection.init(2, 1, 2, 2),
        Selection.init(1, 1, 1, 2),
    });
}

test "multicursor: select next occurrences from a collapsed selection" {
    const allocator = std.testing.allocator;
    var ctx = try TestModel.init(allocator, "abc pizza\nabc house\nabc bar", "nullLanguage");
    defer ctx.deinit();

    var selections = [_]Selection{Selection.init(1, 2, 1, 2)};
    var session = (try multicursor.SearchSession.create(allocator, ctx.model, &selections)).?;
    defer session.deinit();

    const first = (try session.addSelectionToNext(ctx.model, &selections)).?;
    defer allocator.free(first);
    try expectSelections(first, &[_]Selection{Selection.init(1, 1, 1, 4)});

    const second = (try session.addSelectionToNext(ctx.model, first)).?;
    defer allocator.free(second);
    try expectSelections(second, &[_]Selection{
        Selection.init(1, 1, 1, 4),
        Selection.init(2, 1, 2, 4),
    });

    const third = (try session.addSelectionToNext(ctx.model, second)).?;
    defer allocator.free(third);
    try expectSelections(third, &[_]Selection{
        Selection.init(1, 1, 1, 4),
        Selection.init(2, 1, 2, 4),
        Selection.init(3, 1, 3, 4),
    });

    try std.testing.expect(try session.addSelectionToNext(ctx.model, third) == null);
}

test "multicursor: select all occurrences, move next, and previous" {
    const allocator = std.testing.allocator;
    var ctx = try TestModel.init(allocator, "foo\nFOO\nfooBar", "nullLanguage");
    defer ctx.deinit();

    const all = try multicursor.selectAllOccurrences(allocator, ctx.model, &[_]Selection{
        Selection.init(1, 1, 1, 4),
    });
    defer if (all) |value| allocator.free(value);
    try expectSelections(all, &[_]Selection{
        Selection.init(1, 1, 1, 4),
        Selection.init(2, 1, 2, 4),
        Selection.init(3, 1, 3, 4),
    });

    const moved = try multicursor.moveSelectionToNextOccurrence(allocator, ctx.model, &[_]Selection{
        Selection.init(1, 1, 1, 4),
        Selection.init(2, 1, 2, 4),
    });
    defer if (moved) |value| allocator.free(value);
    try expectSelections(moved, &[_]Selection{
        Selection.init(1, 1, 1, 4),
        Selection.init(3, 1, 3, 4),
    });

    const prev = try multicursor.addSelectionToPreviousOccurrence(allocator, ctx.model, &[_]Selection{
        Selection.init(3, 1, 3, 4),
    });
    defer if (prev) |value| allocator.free(value);
    try expectSelections(prev, &[_]Selection{
        Selection.init(3, 1, 3, 4),
        Selection.init(2, 1, 2, 4),
    });
}

test "multicursor: empty selection searches whole words case sensitively" {
    const allocator = std.testing.allocator;
    var ctx = try TestModel.init(allocator, "app\napples\napp", "nullLanguage");
    defer ctx.deinit();

    var selections = [_]Selection{Selection.init(1, 2, 1, 2)};
    var session = (try multicursor.SearchSession.create(allocator, ctx.model, &selections)).?;
    defer session.deinit();

    const first = (try session.addSelectionToNext(ctx.model, &selections)).?;
    defer allocator.free(first);
    try expectSelections(first, &[_]Selection{Selection.init(1, 1, 1, 4)});

    const second = (try session.addSelectionToNext(ctx.model, first)).?;
    defer allocator.free(second);
    try expectSelections(second, &[_]Selection{
        Selection.init(1, 1, 1, 4),
        Selection.init(3, 1, 3, 4),
    });
}
