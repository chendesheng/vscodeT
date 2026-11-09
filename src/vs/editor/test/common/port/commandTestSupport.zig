// Small test harness for contrib commands. Mirrors the shape of VS Code's
// `testCommand` browser helper without pulling in an editor instance.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const Selection = @import("../../../common/core/selection.zig").Selection;
const ICommand = @import("../../../common/editorCommon.zig").ICommand;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const language_configuration = @import("../../../common/languages/languageConfiguration.zig");
const CommentRule = @import("../../../common/languages/languageConfiguration.zig").CommentRule;
const TestModel = @import("./testSupport.zig").TestModel;
const command_runner = @import("../../../common/commands/commandRunner.zig");

pub const TestCommand = struct {
    allocator: Allocator,
    model: TestModel,

    pub fn init(
        allocator: Allocator,
        lines: []const []const u8,
        language_id: []const u8,
        comment_rule: ?CommentRule,
    ) !TestCommand {
        var text = ArrayList(u8).init(allocator);
        defer text.deinit();
        for (lines, 0..) |line, i| {
            if (i > 0) try text.append('\n');
            try text.appendSlice(line);
        }

        var model = try TestModel.init(allocator, text.items, language_id);
        errdefer model.deinit();

        if (comment_rule) |comments| {
            var config = language_configuration.empty();
            config.comments = comments;
            try model.languageService.registerLanguageConfiguration(language_id, config);
        }

        return .{ .allocator = allocator, .model = model };
    }

    pub fn deinit(self: *TestCommand) void {
        self.model.deinit();
    }

    pub fn run(
        self: *TestCommand,
        selections: []const Selection,
        commands: []const ?ICommand,
    ) !?[]Selection {
        return command_runner.executeCommands(self.allocator, self.model.model, commands, selections);
    }

    pub fn expectLines(self: *TestCommand, expected: []const []const u8) !void {
        try std.testing.expectEqual(expected.len, self.model.model.getLineCount());
        for (expected, 0..) |expected_line, i| {
            const line = try self.model.model.getLineContent(i + 1);
            defer line.deinit();
            try std.testing.expectEqualStrings(expected_line, line.items);
        }
    }

    pub fn expectValue(self: *TestCommand, expected: []const u8) !void {
        const value = try self.model.model.getValue(.TextDefined, false);
        defer value.deinit();
        try std.testing.expectEqualStrings(expected, value.items);
    }
};

pub fn expectSelections(actual: ?[]const Selection, expected: []const Selection) !void {
    try std.testing.expect(actual != null);
    try std.testing.expectEqual(expected.len, actual.?.len);
    for (expected, actual.?) |expected_selection, actual_selection| {
        if (!expected_selection.equalsSelection(&actual_selection)) {
            std.debug.print(
                "selection mismatch: expected ({d},{d})->({d},{d}), actual ({d},{d})->({d},{d})\n",
                .{
                    expected_selection.selectionStartLineNumber,
                    expected_selection.selectionStartColumn,
                    expected_selection.positionLineNumber,
                    expected_selection.positionColumn,
                    actual_selection.selectionStartLineNumber,
                    actual_selection.selectionStartColumn,
                    actual_selection.positionLineNumber,
                    actual_selection.positionColumn,
                },
            );
            return error.TestExpectedEqual;
        }
    }
}
