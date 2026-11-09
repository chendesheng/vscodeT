const std = @import("std");
const Selection = @import("../../../../common/core/selection.zig").Selection;
const editor_common = @import("../../../../common/editorCommon.zig");
const SortLinesCommand = @import("../../../../contrib/linesOperations/browser/sortLinesCommand.zig").SortLinesCommand;
const support = @import("../../port/commandTestSupport.zig");

fn testSortLines(
    descending: bool,
    lines: []const []const u8,
    selection: Selection,
    expected_lines: []const []const u8,
    expected_selection: Selection,
) !void {
    const allocator = std.testing.allocator;
    var ctx = try support.TestCommand.init(allocator, lines, "nullLanguage", null);
    defer ctx.deinit();

    var command = SortLinesCommand.init(allocator, selection, descending);
    const result = try ctx.run(
        &[_]Selection{selection},
        &[_]?editor_common.ICommand{editor_common.commandOf(SortLinesCommand).of(&command)},
    );
    defer if (result) |value| allocator.free(value);

    try ctx.expectLines(expected_lines);
    if (result) |value| {
        try support.expectSelections(value, &[_]Selection{expected_selection});
    } else {
        try support.expectSelections(&[_]Selection{selection}, &[_]Selection{expected_selection});
    }
}

test "sort lines ascending" {
    const lines = [_][]const u8{ "omicron", "beta", "alpha" };
    try testSortLines(false, &lines, Selection.init(1, 1, 3, 5), &[_][]const u8{ "alpha", "beta", "omicron" }, Selection.init(1, 1, 3, 7));
}

test "sort lines descending" {
    const lines = [_][]const u8{ "alpha", "beta", "omicron" };
    try testSortLines(true, &lines, Selection.init(1, 1, 3, 7), &[_][]const u8{ "omicron", "beta", "alpha" }, Selection.init(1, 1, 3, 5));
}

test "sort lines no-op when already sorted" {
    const lines = [_][]const u8{ "alpha", "beta", "omicron" };
    var ctx = try support.TestCommand.init(std.testing.allocator, &lines, "nullLanguage", null);
    defer ctx.deinit();

    var command = SortLinesCommand.init(std.testing.allocator, Selection.init(1, 1, 3, 7), false);
    try std.testing.expect(!try command.canRun(ctx.model.model));
}

test "sort excludes last line when selection ends at column 1" {
    const lines = [_][]const u8{ "c", "a", "b", "d" };
    try testSortLines(false, &lines, Selection.init(1, 1, 4, 1), &[_][]const u8{ "a", "b", "c", "d" }, Selection.init(1, 1, 4, 1));
}
