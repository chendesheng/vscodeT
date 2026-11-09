const std = @import("std");
const Selection = @import("../../../../common/core/selection.zig").Selection;
const CommentRule = @import("../../../../common/languages/languageConfiguration.zig").CommentRule;
const editor_common = @import("../../../../common/editorCommon.zig");
const BlockCommentCommand = @import("../../../../contrib/comment/browser/blockCommentCommand.zig").BlockCommentCommand;
const support = @import("../../port/commandTestSupport.zig");

const language_id = "commentMode";
const block_rule = CommentRule{
    .lineComment = null,
    .blockComment = .{ "<0", "0>" },
};

fn testBlockComment(
    lines: []const []const u8,
    selection: Selection,
    expected_lines: []const []const u8,
    expected_selection: Selection,
) !void {
    const allocator = std.testing.allocator;
    var ctx = try support.TestCommand.init(allocator, lines, language_id, block_rule);
    defer ctx.deinit();

    var command = BlockCommentCommand.init(allocator, selection, true, ctx.model.languageService);
    const result = try ctx.run(
        &[_]Selection{selection},
        &[_]?editor_common.ICommand{editor_common.commandOf(BlockCommentCommand).of(&command)},
    );
    defer if (result) |value| allocator.free(value);

    try ctx.expectLines(expected_lines);
    if (result) |value| {
        try support.expectSelections(value, &[_]Selection{expected_selection});
    } else {
        try support.expectSelections(&[_]Selection{selection}, &[_]Selection{expected_selection});
    }
}

test "block comment: empty selection wraps itself" {
    try testBlockComment(
        &[_][]const u8{ "first", "\tsecond line" },
        Selection.init(1, 3, 1, 3),
        &[_][]const u8{ "fi<0  0>rst", "\tsecond line" },
        Selection.init(1, 6, 1, 6),
    );
}

test "block comment: invisible reversed selection" {
    try testBlockComment(
        &[_][]const u8{ "first", "\tsecond line" },
        Selection.init(2, 1, 1, 1),
        &[_][]const u8{ "<0 first", " 0>\tsecond line" },
        Selection.init(1, 4, 2, 1),
    );
}

test "block comment: one line selection" {
    try testBlockComment(
        &[_][]const u8{ "first", "\tsecond line" },
        Selection.init(1, 6, 1, 3),
        &[_][]const u8{ "fi<0 rst 0>", "\tsecond line" },
        Selection.init(1, 6, 1, 9),
    );
}

test "block comment: one line selection toggle" {
    try testBlockComment(
        &[_][]const u8{ "fi<0rst0>", "\tsecond line" },
        Selection.init(1, 8, 1, 5),
        &[_][]const u8{ "first", "\tsecond line" },
        Selection.init(1, 3, 1, 6),
    );
}

test "block comment: multi line selection" {
    try testBlockComment(
        &[_][]const u8{ "first", "\tsecond line" },
        Selection.init(2, 4, 1, 1),
        &[_][]const u8{ "<0 first", "\tse 0>cond line" },
        Selection.init(1, 4, 2, 4),
    );
}

test "block comment: multi line selection toggle" {
    try testBlockComment(
        &[_][]const u8{ "<0first", "\tse0>cond line" },
        Selection.init(2, 4, 1, 3),
        &[_][]const u8{ "first", "\tsecond line" },
        Selection.init(1, 1, 2, 4),
    );
}

test "block comment: no configuration is a no-op" {
    const allocator = std.testing.allocator;
    var ctx = try support.TestCommand.init(allocator, &[_][]const u8{"first"}, language_id, null);
    defer ctx.deinit();

    const selection = Selection.init(1, 1, 1, 1);
    var command = BlockCommentCommand.init(allocator, selection, true, ctx.model.languageService);
    const result = try ctx.run(
        &[_]Selection{selection},
        &[_]?editor_common.ICommand{editor_common.commandOf(BlockCommentCommand).of(&command)},
    );
    defer if (result) |value| allocator.free(value);

    try std.testing.expect(result == null);
    try ctx.expectLines(&[_][]const u8{"first"});
}
