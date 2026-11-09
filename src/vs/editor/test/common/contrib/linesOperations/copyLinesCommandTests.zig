const std = @import("std");
const Selection = @import("../../../../common/core/selection.zig").Selection;
const editor_common = @import("../../../../common/editorCommon.zig");
const CopyLinesCommand = @import("../../../../contrib/linesOperations/browser/copyLinesCommand.zig").CopyLinesCommand;
const support = @import("../../port/commandTestSupport.zig");

fn testCopyLines(
    down: bool,
    lines: []const []const u8,
    selection: Selection,
    expected_lines: []const []const u8,
    expected_selection: Selection,
) !void {
    const allocator = std.testing.allocator;
    var ctx = try support.TestCommand.init(allocator, lines, "nullLanguage", null);
    defer ctx.deinit();

    var command = CopyLinesCommand.init(allocator, selection, down, false);
    const result = try ctx.run(
        &[_]Selection{selection},
        &[_]?editor_common.ICommand{editor_common.commandOf(CopyLinesCommand).of(&command)},
    );
    defer if (result) |value| allocator.free(value);

    try ctx.expectLines(expected_lines);
    if (result) |value| {
        try support.expectSelections(value, &[_]Selection{expected_selection});
    } else {
        try support.expectSelections(&[_]Selection{selection}, &[_]Selection{expected_selection});
    }
}

test "copy line down/up basics" {
    const lines = [_][]const u8{ "first", "second line", "third line", "fourth line", "fifth" };

    try testCopyLines(true, &lines, Selection.init(1, 3, 1, 1), &[_][]const u8{ "first", "first", "second line", "third line", "fourth line", "fifth" }, Selection.init(2, 3, 2, 1));
    try testCopyLines(false, &lines, Selection.init(1, 3, 1, 1), &[_][]const u8{ "first", "first", "second line", "third line", "fourth line", "fifth" }, Selection.init(1, 3, 1, 1));
    try testCopyLines(true, &lines, Selection.init(5, 3, 5, 1), &[_][]const u8{ "first", "second line", "third line", "fourth line", "fifth", "fifth" }, Selection.init(6, 3, 6, 1));
    try testCopyLines(false, &lines, Selection.init(5, 3, 5, 1), &[_][]const u8{ "first", "second line", "third line", "fourth line", "fifth", "fifth" }, Selection.init(5, 3, 5, 1));
}

test "copy line up issue #1322" {
    const lines = [_][]const u8{ "first", "second line", "third line", "fourth line", "fifth" };
    try testCopyLines(false, &lines, Selection.init(3, 11, 3, 11), &[_][]const u8{ "first", "second line", "third line", "third line", "fourth line", "fifth" }, Selection.init(3, 11, 3, 11));
    try testCopyLines(false, &lines, Selection.init(5, 6, 5, 6), &[_][]const u8{ "first", "second line", "third line", "fourth line", "fifth", "fifth" }, Selection.init(5, 6, 5, 6));
}

test "copy many lines up" {
    const lines = [_][]const u8{ "first", "second line", "third line", "fourth line", "fifth" };
    try testCopyLines(false, &lines, Selection.init(4, 3, 2, 1), &[_][]const u8{ "first", "second line", "third line", "fourth line", "second line", "third line", "fourth line", "fifth" }, Selection.init(4, 3, 2, 1));
}

test "copy empty selection at line start" {
    const lines = [_][]const u8{ "first", "second line", "third line", "fourth line", "fifth" };
    try testCopyLines(false, &lines, Selection.init(2, 1, 1, 1), &[_][]const u8{ "first", "first", "second line", "third line", "fourth line", "fifth" }, Selection.init(2, 1, 1, 1));
}

test "copy empty line down adjusts selection" {
    const lines = [_][]const u8{ "first", "", "third" };
    try testCopyLines(true, &lines, Selection.init(2, 1, 2, 1), &[_][]const u8{ "first", "", "", "third" }, Selection.init(3, 1, 3, 1));
}

test "copy last empty line up" {
    const lines = [_][]const u8{ "first", "" };
    try testCopyLines(false, &lines, Selection.init(2, 1, 2, 1), &[_][]const u8{ "first", "", "" }, Selection.init(2, 1, 2, 1));
}

test "copy line leaves model unchanged when selection spans whole line" {
    const lines = [_][]const u8{ "a", "b", "c" };
    try testCopyLines(true, &lines, Selection.init(2, 1, 3, 1), &[_][]const u8{ "a", "b", "b", "c" }, Selection.init(3, 1, 4, 1));
}
