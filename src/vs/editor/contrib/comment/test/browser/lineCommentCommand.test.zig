const std = @import("std");
const Selection = @import("../../../../common/core/selection.zig").Selection;
const CommentRule = @import("../../../../common/languages/languageConfiguration.zig").CommentRule;
const LineCommentConfig = @import("../../../../common/languages/languageConfiguration.zig").LineCommentConfig;
const editor_common = @import("../../../../common/editorCommon.zig");
const line_comment = @import("../../../../contrib/comment/browser/lineCommentCommand.zig");
const LineCommentCommand = line_comment.LineCommentCommand;
const Type = line_comment.Type;
const support = @import("../../../../test/common/port/commandTestSupport.zig");

const language_id = "commentMode";

fn lineTestCommand(
    comment_rule: CommentRule,
    comment_type: Type,
    ignored_first_line: bool,
    lines: []const []const u8,
    selection: Selection,
    expected_lines: []const []const u8,
    expected_selection: Selection,
) !void {
    const allocator = std.testing.allocator;
    var ctx = try support.TestCommand.init(allocator, lines, language_id, comment_rule);
    defer ctx.deinit();

    var command = LineCommentCommand.init(
        allocator,
        ctx.model.languageService,
        selection,
        4,
        comment_type,
        true,
        true,
        ignored_first_line,
    );
    const result = try ctx.run(
        &[_]Selection{selection},
        &[_]?editor_common.ICommand{editor_common.commandOf(LineCommentCommand).of(&command)},
    );
    defer if (result) |value| allocator.free(value);

    try ctx.expectLines(expected_lines);
    try support.expectSelections(result, &[_]Selection{expected_selection});
}

const line_rule = CommentRule{
    .lineComment = LineCommentConfig{ .comment = "!@#", .noIndent = null },
    .blockComment = null,
};

const no_indent_rule = CommentRule{
    .lineComment = LineCommentConfig{ .comment = "!@#", .noIndent = true },
    .blockComment = null,
};

const rem_rule = CommentRule{
    .lineComment = LineCommentConfig{ .comment = "rem", .noIndent = null },
    .blockComment = null,
};

test "line comment: comment and uncomment a single line" {
    try lineTestCommand(
        line_rule,
        .Toggle,
        false,
        &[_][]const u8{ "some text", "\tsome more text" },
        Selection.init(1, 1, 1, 1),
        &[_][]const u8{ "!@# some text", "\tsome more text" },
        Selection.init(1, 5, 1, 5),
    );

    try lineTestCommand(
        line_rule,
        .Toggle,
        false,
        &[_][]const u8{"!@# some text"},
        Selection.init(1, 1, 1, 1),
        &[_][]const u8{"some text"},
        Selection.init(1, 1, 1, 1),
    );
}

test "line comment: case insensitive token" {
    try lineTestCommand(
        rem_rule,
        .Toggle,
        false,
        &[_][]const u8{"REM some text"},
        Selection.init(1, 1, 1, 1),
        &[_][]const u8{"some text"},
        Selection.init(1, 1, 1, 1),
    );
}

test "line comment: noIndent token goes to column 1" {
    try lineTestCommand(
        no_indent_rule,
        .Toggle,
        false,
        &[_][]const u8{ "some text", "\tsome more text" },
        Selection.init(2, 1, 2, 1),
        &[_][]const u8{ "some text", "!@# \tsome more text" },
        Selection.init(2, 5, 2, 5),
    );
}

test "line comment: toggle multiple lines" {
    try lineTestCommand(
        line_rule,
        .Toggle,
        false,
        &[_][]const u8{ "a", "b", "c" },
        Selection.init(1, 1, 3, 2),
        &[_][]const u8{ "!@# a", "!@# b", "!@# c" },
        Selection.init(1, 5, 3, 6),
    );
}

test "line comment: force add and force remove" {
    try lineTestCommand(
        line_rule,
        .ForceAdd,
        false,
        &[_][]const u8{ "some text", "!@# already" },
        Selection.init(1, 1, 2, 1),
        &[_][]const u8{ "!@# some text", "!@# already" },
        Selection.init(1, 5, 2, 1),
    );

    try lineTestCommand(
        line_rule,
        .ForceRemove,
        false,
        &[_][]const u8{ "!@# a", "plain" },
        Selection.init(1, 1, 2, 1),
        &[_][]const u8{ "a", "plain" },
        Selection.init(1, 1, 2, 1),
    );
}

test "line comment: whitespace-only lines stay untouched when ignored" {
    try lineTestCommand(
        line_rule,
        .Toggle,
        false,
        &[_][]const u8{ "a", "   ", "b" },
        Selection.init(1, 1, 3, 1),
        &[_][]const u8{ "!@# a", "   ", "b" },
        Selection.init(1, 5, 3, 1),
    );
}

test "line comment: all whitespace lines get comments" {
    try lineTestCommand(
        line_rule,
        .Toggle,
        false,
        &[_][]const u8{ "   ", "\t" },
        Selection.init(1, 1, 2, 1),
        &[_][]const u8{ "!@#    ", "\t" },
        Selection.init(1, 5, 2, 1),
    );
}

test "line comment: falls back to block comment when line comments are unsupported" {
    const block_only = CommentRule{
        .lineComment = LineCommentConfig{ .comment = "", .noIndent = null },
        .blockComment = .{ "(", ")" },
    };
    try lineTestCommand(
        block_only,
        .Toggle,
        false,
        &[_][]const u8{"first"},
        Selection.init(1, 1, 1, 1),
        &[_][]const u8{"( first )"},
        Selection.init(1, 3, 1, 3),
    );
}

test "line comment: cross-line selection ending at column 1 moves end down" {
    try lineTestCommand(
        line_rule,
        .Toggle,
        false,
        &[_][]const u8{ "a", "b", "c" },
        Selection.init(1, 1, 3, 1),
        &[_][]const u8{ "!@# a", "!@# b", "c" },
        Selection.init(1, 5, 3, 1),
    );
}
