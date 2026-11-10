const std = @import("std");
const Selection = @import("../../../../common/core/selection.zig").Selection;
const editor_common = @import("../../../../common/editorCommon.zig");
const MoveLinesCommand = @import("../../../../contrib/linesOperations/browser/moveLinesCommand.zig").MoveLinesCommand;
const support = @import("../../../../test/common/port/commandTestSupport.zig");

fn testMoveLines(
    down: bool,
    lines: []const []const u8,
    selection: Selection,
    expected_lines: []const []const u8,
    expected_selection: Selection,
) !void {
    const allocator = std.testing.allocator;
    var ctx = try support.TestCommand.init(allocator, lines, "nullLanguage", null);
    defer ctx.deinit();

    var command = MoveLinesCommand.init(allocator, selection, down, .Advanced);
    const result = try ctx.run(
        &[_]Selection{selection},
        &[_]?editor_common.ICommand{editor_common.commandOf(MoveLinesCommand).of(&command)},
    );
    defer if (result) |value| allocator.free(value);

    try ctx.expectLines(expected_lines);
    if (result) |value| {
        try support.expectSelections(value, &[_]Selection{expected_selection});
    } else {
        try support.expectSelections(&[_]Selection{selection}, &[_]Selection{expected_selection});
    }
}

test "move first up / last down disabled" {
    const lines = [_][]const u8{ "first", "second line", "third line", "fourth line", "fifth" };
    try testMoveLines(false, &lines, Selection.init(1, 1, 1, 1), &lines, Selection.init(1, 1, 1, 1));
    try testMoveLines(true, &lines, Selection.init(5, 1, 5, 1), &lines, Selection.init(5, 1, 5, 1));
}

test "move first line down and second line up" {
    const lines = [_][]const u8{ "first", "second line", "third line", "fourth line", "fifth" };
    try testMoveLines(true, &lines, Selection.init(1, 4, 1, 1), &[_][]const u8{ "second line", "first", "third line", "fourth line", "fifth" }, Selection.init(2, 4, 2, 1));
    try testMoveLines(false, &lines, Selection.init(2, 1, 2, 1), &[_][]const u8{ "second line", "first", "third line", "fourth line", "fifth" }, Selection.init(1, 1, 1, 1));
}

test "move line up/down with cursor at line end" {
    const lines = [_][]const u8{ "first", "second line", "third line", "fourth line", "fifth" };
    try testMoveLines(false, &lines, Selection.init(2, 12, 2, 12), &[_][]const u8{ "second line", "first", "third line", "fourth line", "fifth" }, Selection.init(1, 12, 1, 12));
    try testMoveLines(false, &lines, Selection.init(5, 6, 5, 6), &[_][]const u8{ "first", "second line", "third line", "fifth", "fourth line" }, Selection.init(4, 6, 4, 6));
}

test "move last line down is disabled" {
    const lines = [_][]const u8{ "first", "second line", "third line", "fourth line", "fifth" };
    try testMoveLines(true, &lines, Selection.init(5, 3, 5, 3), &lines, Selection.init(5, 3, 5, 3));
}

test "move selection spanning lines down" {
    const lines = [_][]const u8{ "first", "second line", "third line", "fourth line", "fifth" };
    try testMoveLines(true, &lines, Selection.init(2, 1, 3, 1), &[_][]const u8{ "first", "third line", "second line", "fourth line", "fifth" }, Selection.init(3, 1, 4, 1));
}

test "move onto empty line" {
    const lines = [_][]const u8{ "first", "", "third" };
    try testMoveLines(true, &lines, Selection.init(2, 1, 2, 1), &[_][]const u8{ "first", "third", "" }, Selection.init(3, 1, 3, 1));
    try testMoveLines(false, &lines, Selection.init(2, 1, 2, 1), &[_][]const u8{ "", "first", "third" }, Selection.init(1, 1, 1, 1));
}

test "move empty line past content line" {
    const lines = [_][]const u8{ "first", "", "third" };
    try testMoveLines(false, &lines, Selection.init(2, 1, 2, 1), &[_][]const u8{ "", "first", "third" }, Selection.init(1, 1, 1, 1));
    try testMoveLines(true, &lines, Selection.init(2, 1, 2, 1), &[_][]const u8{ "first", "third", "" }, Selection.init(3, 1, 3, 1));
}
