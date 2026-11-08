const std = @import("std");
const Position = @import("../../../common/core/position.zig").Position;
const Range = @import("../../../common/core/range.zig").Range;
const TestModel = @import("../port/testSupport.zig").TestModel;
const IdentityCoordinatesConverter = @import("../../../common/coordinatesConverter.zig").IdentityCoordinatesConverter;
const cursorCommon = @import("../../../common/cursorCommon.zig");
const CursorConfiguration = cursorCommon.CursorConfiguration;
const SingleCursorState = cursorCommon.SingleCursorState;
const CursorContext = @import("../../../common/cursor/cursorContext.zig").CursorContext;
const Cursor = @import("../../../common/cursor/oneCursor.zig").Cursor;
const TextModelCursorSimpleModel = @import("../../../common/cursor/textModelCursorSimpleModel.zig").TextModelCursorSimpleModel;

test "oneCursor: initializes and updates model/view state" {
    const allocator = std.testing.allocator;
    var test_model = try TestModel.init(allocator, "abc\ndef", "nullLanguage");
    defer test_model.deinit();
    var adapter = TextModelCursorSimpleModel.init(allocator, test_model.model);
    defer adapter.deinit();

    var converter = IdentityCoordinatesConverter.init(test_model.model);
    const config = CursorConfiguration{ .tabSize = 4, .indentSize = 4, .insertSpaces = true, .pageSize = 1 };
    var context = CursorContext.init(test_model.model, adapter.interface(), converter.toInterface(), &config);

    var cursor = try Cursor.init(&context);
    defer cursor.dispose(&context);
    try std.testing.expectEqual(@as(usize, 1), cursor.modelState.position.lineNumber);
    try std.testing.expectEqual(@as(usize, 1), cursor.modelState.position.column);

    try cursor.setState(&context, SingleCursorState.init(Range.init(2, 2, 2, 2), .Simple, 0, Position.init(2, 2), 0), null);
    try std.testing.expectEqual(@as(usize, 2), cursor.modelState.position.lineNumber);
    try std.testing.expectEqual(@as(usize, 2), cursor.modelState.position.column);
    try std.testing.expectEqual(@as(usize, 2), cursor.viewState.position.lineNumber);
    try std.testing.expectEqual(@as(usize, 2), cursor.viewState.position.column);
}

const CursorCollection = @import("../../../common/cursor/cursorCollection.zig").CursorCollection;
const Selection = @import("../../../common/core/selection.zig").Selection;

test "cursorCollection: adds, replaces, and normalizes cursors" {
    const allocator = std.testing.allocator;
    var test_model = try TestModel.init(allocator, "abc\ndef\nghi", "nullLanguage");
    defer test_model.deinit();
    var adapter = TextModelCursorSimpleModel.init(allocator, test_model.model);
    defer adapter.deinit();

    var converter = IdentityCoordinatesConverter.init(test_model.model);
    const config = CursorConfiguration{ .tabSize = 4, .indentSize = 4, .insertSpaces = true, .pageSize = 1 };
    var context = CursorContext.init(test_model.model, adapter.interface(), converter.toInterface(), &config);

    var collection = try CursorCollection.init(allocator, &context);
    defer collection.deinit();

    const selections = [_]Selection{
        Selection.init(1, 1, 1, 1),
        Selection.init(2, 1, 2, 2),
    };
    try collection.setSelections(allocator, &selections);
    const all = try collection.getAll(allocator);
    defer allocator.free(all);
    try std.testing.expectEqual(@as(usize, 2), all.len);

    const overlapping = [_]Selection{
        Selection.init(1, 1, 1, 3),
        Selection.init(1, 2, 1, 4),
    };
    try collection.setSelections(allocator, &overlapping);
    try collection.normalize();
    const merged = try collection.getAll(allocator);
    defer allocator.free(merged);
    try std.testing.expectEqual(@as(usize, 1), merged.len);

    try collection.killSecondaryCursors();
    const single = try collection.getAll(allocator);
    defer allocator.free(single);
    try std.testing.expectEqual(@as(usize, 1), single.len);
}

const CursorMoveCommands = @import("../../../common/cursor/cursorMoveCommands.zig").CursorMoveCommands;
const CursorState = cursorCommon.CursorState;

test "cursorMoveCommands: select all, expand line, and buffer boundaries" {
    const allocator = std.testing.allocator;
    var test_model = try TestModel.init(allocator, "abc\ndef", "nullLanguage");
    defer test_model.deinit();
    var adapter = TextModelCursorSimpleModel.init(allocator, test_model.model);
    defer adapter.deinit();
    const model = adapter.interface();
    const config = CursorConfiguration{ .tabSize = 4, .indentSize = 4, .insertSpaces = true, .pageSize = 1 };

    const all = CursorMoveCommands.selectAll(model);
    try std.testing.expectEqual(@as(usize, 2), all.modelState.?.position.lineNumber);
    try std.testing.expectEqual(@as(usize, 4), all.modelState.?.position.column);

    var cursor = CursorState{
        .modelState = SingleCursorState.init(Range.init(1, 2, 1, 2), .Simple, 0, Position.init(1, 2), 0),
        .viewState = SingleCursorState.init(Range.init(1, 2, 1, 2), .Simple, 0, Position.init(1, 2), 0),
    };
    const expanded = try CursorMoveCommands.expandLineSelection(allocator, model, &[_]CursorState{cursor});
    defer allocator.free(expanded);
    try std.testing.expectEqual(@as(usize, 2), expanded[0].modelState.?.position.lineNumber);
    try std.testing.expectEqual(@as(usize, 1), expanded[0].modelState.?.position.column);

    cursor.modelState = SingleCursorState.init(Range.init(1, 1, 1, 2), .Simple, 0, Position.init(1, 2), 0);
    cursor.viewState = cursor.modelState;
    const no_selection = CursorMoveCommands.cancelSelection(cursor);
    try std.testing.expect(no_selection.viewState.?.selection.isEmpty());

    const beginning = try CursorMoveCommands.moveToBeginningOfBuffer(allocator, &config, model, &[_]CursorState{cursor}, false);
    defer allocator.free(beginning);
    try std.testing.expectEqual(@as(usize, 1), beginning[0].modelState.?.position.lineNumber);
    try std.testing.expectEqual(@as(usize, 1), beginning[0].modelState.?.position.column);

    const end = try CursorMoveCommands.moveToEndOfBuffer(allocator, &config, model, &[_]CursorState{cursor}, false);
    defer allocator.free(end);
    try std.testing.expectEqual(@as(usize, 2), end[0].modelState.?.position.lineNumber);
    try std.testing.expectEqual(@as(usize, 4), end[0].modelState.?.position.column);
}
