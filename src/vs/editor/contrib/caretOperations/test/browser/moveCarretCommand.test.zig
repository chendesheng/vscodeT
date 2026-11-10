// Port of `src/vs/editor/contrib/caretOperations/test/browser/moveCarretCommand.test.ts`.
const std = @import("std");
const Selection = @import("../../../../common/core/selection.zig").Selection;
const editor_common = @import("../../../../common/editorCommon.zig");
const MoveCaretCommand = @import("../../browser/moveCaretCommand.zig").MoveCaretCommand;
const support = @import("../../../../test/common/port/commandTestSupport.zig");

fn testMoveCaret(allocator: std.mem.Allocator, lines: []const []const u8, selection: Selection, is_left: bool, expected_lines: []const []const u8, expected_selection: Selection) !void {
    var ctx = try support.TestCommand.init(allocator, lines, "nullLanguage", null);
    defer ctx.deinit();
    var command = MoveCaretCommand.init(selection, is_left);
    const result = try ctx.run(&[_]Selection{selection}, &[_]?editor_common.ICommand{command.interface()});
    defer if (result) |value| allocator.free(value);
    try ctx.expectLines(expected_lines);
    if (result) |value| {
        try support.expectSelections(value, &[_]Selection{expected_selection});
    } else {
        try std.testing.expect(selection.equalsSelection(&expected_selection));
    }
}

test "Editor Contrib - Move Caret Command" {
    const allocator = std.testing.allocator;
    const lines = [_][]const u8{"012345"};

    try testMoveCaret(allocator, &lines, Selection.init(1, 3, 1, 5), true, &[_][]const u8{"023145"}, Selection.init(1, 2, 1, 4));
    try testMoveCaret(allocator, &lines, Selection.init(1, 3, 1, 5), false, &[_][]const u8{"014235"}, Selection.init(1, 4, 1, 6));
    try testMoveCaret(allocator, &lines, Selection.init(1, 1, 1, 1), true, &lines, Selection.init(1, 1, 1, 1));
    try testMoveCaret(allocator, &lines, Selection.init(1, 5, 1, 7), false, &lines, Selection.init(1, 5, 1, 7));
}
