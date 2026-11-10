const std = @import("std");
const Position = @import("../../../../common/core/position.zig").Position;
const Range = @import("../../../../common/core/range.zig").Range;
const Selection = @import("../../../../common/core/selection.zig").Selection;
const cursorCommon = @import("../../../../common/cursorCommon.zig");
const CursorState = cursorCommon.CursorState;
const SingleCursorState = cursorCommon.SingleCursorState;
const TextModelCursorSimpleModel = @import("../../../../common/cursor/textModelCursorSimpleModel.zig").TextModelCursorSimpleModel;
const expandLineSelection = @import("../../../../contrib/lineSelection/browser/lineSelection.zig").expandLineSelection;
const TestModel = @import("../../port/testSupport.zig").TestModel;
const Editor = @import("../../../../../../tui/editor.zig").Editor;
const Io = std.Io;

fn cursorAt(line: usize, column: usize) CursorState {
    const state = SingleCursorState.init(Range.init(line, column, line, column), .Simple, 0, Position.init(line, column), 0);
    return .{ .modelState = state, .viewState = state };
}

test "expand line selection" {
    const allocator = std.testing.allocator;
    const text = "    \tMy First Line\t \r\n\tMy Second Line\n    Third Line🐶\n\n1";
    var ctx = try TestModel.init(allocator, text, "nullLanguage");
    defer ctx.deinit();
    var adapter = TextModelCursorSimpleModel.init(allocator, ctx.model);
    defer adapter.deinit();
    const model = adapter.interface();

    const cases = [_]struct {
        line: usize,
        column: usize,
        expected_start_line: usize,
        expected_end_line: usize,
        expected_end_column: usize,
    }{
        .{ .line = 1, .column = 1, .expected_start_line = 1, .expected_end_line = 2, .expected_end_column = 1 },
        .{ .line = 1, .column = 2, .expected_start_line = 1, .expected_end_line = 2, .expected_end_column = 1 },
        .{ .line = 1, .column = 5, .expected_start_line = 1, .expected_end_line = 2, .expected_end_column = 1 },
        .{ .line = 1, .column = 19, .expected_start_line = 1, .expected_end_line = 2, .expected_end_column = 1 },
        .{ .line = 1, .column = 21, .expected_start_line = 1, .expected_end_line = 2, .expected_end_column = 1 },
    };

    for (cases) |case| {
        const cursor = cursorAt(case.line, case.column);
        const result = try expandLineSelection(allocator, model, &[_]CursorState{cursor});
        defer allocator.free(result);
        const state = result[0].modelState.?;
        try std.testing.expectEqual(case.expected_start_line, state.selection.startLineNumber);
        try std.testing.expectEqual(@as(usize, 1), state.selection.startColumn);
        try std.testing.expectEqual(case.expected_end_line, state.selection.endLineNumber);
        try std.testing.expectEqual(case.expected_end_column, state.selection.endColumn);
    }

    // Expanding repeatedly grows the selection one line at a time.
    var state = cursorAt(1, 21);
    inline for (.{ 2, 3, 4 }) |expected_end_line| {
        const result = try expandLineSelection(allocator, model, &[_]CursorState{state});
        defer allocator.free(result);
        state = .{ .modelState = result[0].modelState.?, .viewState = result[0].viewState orelse result[0].modelState.? };
        try std.testing.expectEqual(@as(usize, 1), state.modelState.selection.startLineNumber);
        try std.testing.expectEqual(expected_end_line, state.modelState.selection.endLineNumber);
    }
    {
        const result = try expandLineSelection(allocator, model, &[_]CursorState{state});
        defer allocator.free(result);
        state = .{ .modelState = result[0].modelState.?, .viewState = result[0].viewState orelse result[0].modelState.? };
    }
    {
        const result = try expandLineSelection(allocator, model, &[_]CursorState{state});
        defer allocator.free(result);
        state = .{ .modelState = result[0].modelState.?, .viewState = result[0].viewState orelse result[0].modelState.? };
    }
    try std.testing.expectEqual(@as(usize, 5), state.modelState.selection.endLineNumber);
    try std.testing.expectEqual(@as(usize, 2), state.modelState.selection.endColumn);
}

test "ExpandLineSelectionAction: matches upstream action behavior" {
    const allocator = std.testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();

    const LINE1 = "    \tMy First Line\t ";
    const LINE2 = "\tMy Second Line";
    const LINE3 = "    Third Line🐶";
    const LINE4 = "";
    const LINE5 = "1";
    const text = LINE1 ++ "\r\n" ++ LINE2 ++ "\n" ++ LINE3 ++ "\n" ++ LINE4 ++ "\r\n" ++ LINE5;

    var editor = try Editor.createFromText(allocator, io, text, "test.txt", 80, 10);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    var action = editor.expandLineSelectionAction();
    const check = struct {
        fn expectSelection(ed: *Editor, start_line: usize, end_line: usize, end_column: usize) !void {
            const selection = ed.modelSelection();
            try std.testing.expectEqual(@as(usize, 1), selection.startLineNumber);
            try std.testing.expectEqual(start_line, selection.startLineNumber);
            try std.testing.expectEqual(@as(usize, 1), selection.startColumn);
            try std.testing.expectEqual(end_line, selection.endLineNumber);
            try std.testing.expectEqual(end_column, selection.endColumn);
        }
    };

    try editor.setCursorPosition(Position.init(1, 1));
    try action.run();
    try check.expectSelection(editor, 1, 2, 1);

    try editor.setCursorPosition(Position.init(1, 2));
    try action.run();
    try check.expectSelection(editor, 1, 2, 1);

    try editor.setCursorPosition(Position.init(1, 5));
    try action.run();
    try check.expectSelection(editor, 1, 2, 1);

    try editor.setCursorPosition(Position.init(1, 19));
    try action.run();
    try check.expectSelection(editor, 1, 2, 1);

    try editor.setCursorPosition(Position.init(1, 20));
    try action.run();
    try check.expectSelection(editor, 1, 2, 1);

    try editor.setCursorPosition(Position.init(1, 21));
    try action.run();
    try check.expectSelection(editor, 1, 2, 1);
    try action.run();
    try check.expectSelection(editor, 1, 3, 1);
    try action.run();
    try check.expectSelection(editor, 1, 4, 1);
    try action.run();
    try check.expectSelection(editor, 1, 5, 1);
    try action.run();
    try check.expectSelection(editor, 1, 5, LINE5.len + 1);
    try action.run();
    try check.expectSelection(editor, 1, 5, LINE5.len + 1);
}
