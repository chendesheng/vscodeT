const std = @import("std");
const Selection = @import("../../../../common/core/selection.zig").Selection;
const editor_common = @import("../../../../common/editorCommon.zig");
const InsertFinalNewLineCommand = @import("../../../../contrib/insertFinalNewLine/browser/insertFinalNewLineCommand.zig").InsertFinalNewLineCommand;
const support = @import("../../../../test/common/port/commandTestSupport.zig");
const TestModel = @import("../../../../test/common/port/testSupport.zig").TestModel;
const command_runner = @import("../../../../common/commands/commandRunner.zig");

test "insert final newline with LF" {
    const allocator = std.testing.allocator;
    var ctx = try support.TestCommand.init(allocator, &[_][]const u8{"hello"}, "nullLanguage", null);
    defer ctx.deinit();

    const selection = Selection.init(1, 3, 1, 3);
    var command = InsertFinalNewLineCommand.init(selection);
    const result = try ctx.run(
        &[_]Selection{selection},
        &[_]?editor_common.ICommand{editor_common.commandOf(InsertFinalNewLineCommand).of(&command)},
    );
    defer if (result) |value| allocator.free(value);

    try ctx.expectValue("hello\n");
    try support.expectSelections(result, &[_]Selection{selection});
}

test "insert final newline with CRLF" {
    const allocator = std.testing.allocator;
    var ctx = try TestModel.init(allocator, "hello\r\nworld", "nullLanguage");
    defer ctx.deinit();

    const selection = Selection.init(2, 3, 2, 3);
    var command = InsertFinalNewLineCommand.init(selection);
    const result = try command_runner.executeCommands(
        allocator,
        ctx.model,
        &[_]?editor_common.ICommand{editor_common.commandOf(InsertFinalNewLineCommand).of(&command)},
        &[_]Selection{selection},
    );
    defer if (result) |value| allocator.free(value);

    const value = try ctx.model.getValue(.TextDefined, false);
    defer value.deinit();
    try std.testing.expectEqualStrings("hello\r\nworld\r\n", value.items);
}

test "insert final newline on an empty model" {
    const allocator = std.testing.allocator;
    var ctx = try support.TestCommand.init(allocator, &[_][]const u8{""}, "nullLanguage", null);
    defer ctx.deinit();
    const selection = Selection.init(1, 1, 1, 1);
    var command = InsertFinalNewLineCommand.init(selection);
    const result = try ctx.run(
        &[_]Selection{selection},
        &[_]?editor_common.ICommand{editor_common.commandOf(InsertFinalNewLineCommand).of(&command)},
    );
    defer if (result) |value| allocator.free(value);
    try ctx.expectValue("\n");
}
