const std = @import("std");
const Allocator = std.mem.Allocator;

const Range = @import("../../../../common/core/range.zig").Range;
const Selection = @import("../../../../common/core/selection.zig").Selection;
const language_configuration = @import("../../../../common/languages/languageConfiguration.zig");
const IndentationRule = language_configuration.IndentationRule;
const registry = @import("../../../../common/languages/languageConfigurationRegistry.zig");
const ResolvedLanguageConfiguration = registry.ResolvedLanguageConfiguration;
const ILanguageConfigurationService = registry.ILanguageConfigurationService;
const LanguageConfigurationServiceChangeEvent = registry.LanguageConfigurationServiceChangeEvent;
const regexp = @import("../../../../../../support/regexp.zig");
const RegExp = regexp.RegExp;
const CharacterPairSupport = @import("../../../../common/languages/supports/characterPair.zig");
const LanguageBracketsConfiguration = @import("../../../../common/languages/supports/languageBracketsConfiguration.zig").LanguageBracketsConfiguration;
const OpeningBracketKind = @import("../../../../common/languages/supports/languageBracketsConfiguration.zig").OpeningBracketKind;
const ClosingBracketKind = @import("../../../../common/languages/supports/languageBracketsConfiguration.zig").ClosingBracketKind;
const defaultWordRegExp = @import("../../../../common/core/wordHelper.zig").defaultWordRegExp;
const IndentRulesSupport = @import("../../../../common/languages/supports/indentRules.zig").IndentRulesSupport;

const indent_utils = @import("../../../../contrib/indentation/common/indentUtils.zig");
const indentation = @import("../../../../contrib/indentation/common/indentation.zig");
const ISingleEditOperation = @import("../../../../common/core/editOperation.zig").ISingleEditOperation;
const indentation_browser = @import("../../../../contrib/indentation/browser/indentation.zig");
const IndentationToSpacesCommand = indentation_browser.IndentationToSpacesCommand;
const IndentationToTabsCommand = indentation_browser.IndentationToTabsCommand;
const TestModel = @import("../../port/testSupport.zig").TestModel;
const command_runner = @import("../../../../common/commands/commandRunner.zig");
const editor_common = @import("../../../../common/editorCommon.zig");

var test_configuration: ResolvedLanguageConfiguration = undefined;

fn testGetLanguageConfiguration(_: []const u8) ResolvedLanguageConfiguration {
    return test_configuration;
}

fn testOnDidChange(_: LanguageConfigurationServiceChangeEvent) void {}
fn testRegister(_: []const u8, _: language_configuration.LanguageConfiguration, _: ?usize) void {}

fn testService() ILanguageConfigurationService {
    return .{
        .onDidChange = testOnDidChange,
        .register = testRegister,
        .getLanguageConfiguration = testGetLanguageConfiguration,
    };
}

fn setupConfiguration(allocator: Allocator, rules: IndentationRule) !void {
    var configuration = language_configuration.empty();
    configuration.indentationRules = rules;
    test_configuration = .{
        .languageId = "indentTestLanguage",
        .comments = null,
        .characterPair = try CharacterPairSupport.init(configuration),
        .wordDefinition = defaultWordRegExp(),
        .indentationRules = rules,
        .indentRulesSupport = IndentRulesSupport.init(rules),
        .foldingRules = .{ .offSide = null, .markers = null },
        .bracketsNew = LanguageBracketsConfiguration{
            .id = 0,
            ._openingBrackets = std.StringHashMap(OpeningBracketKind).init(allocator),
            ._closingBrackets = std.StringHashMap(ClosingBracketKind).init(allocator),
            .languageId = "indentTestLanguage",
            .config = configuration,
        },
        .underlyingConfig = configuration,
    };
}

fn applyEdits(model: *TestModel, operations: []const ISingleEditOperation) !void {
    var edits = std.array_list.Managed(@import("../../port/testSupport.zig").Edit).init(model.allocator);
    defer edits.deinit();
    for (operations) |op| {
        try edits.append(.{ .range = op.range, .text = op.text orelse "" });
    }
    try model.applyEdits(edits.items);
}

test "indentation: reindent lines using indentation rules" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const increase = try RegExp.init("\\{$", .{});
    defer increase.deinit();
    const decrease = try RegExp.init("^\\s*\\}", .{});
    defer decrease.deinit();

    try setupConfiguration(arena, .{
        .decreaseIndentPattern = decrease,
        .increaseIndentPattern = increase,
        .indentNextLinePattern = null,
        .unIndentedLinePattern = null,
    });

    var ctx = try TestModel.init(allocator, "if (a) {\nb\n}", "indentTestLanguage");
    defer ctx.deinit();

    var edits = try indentation.getReindentEditOperations(arena, ctx.model, testService(), 1, 3);
    defer edits.deinit();
    try applyEdits(&ctx, edits.items);

    const line2 = try ctx.model.getLineContent(2);
    defer line2.deinit();
    try std.testing.expectEqualStrings("    b", line2.items);

    const line3 = try ctx.model.getLineContent(3);
    defer line3.deinit();
    try std.testing.expectEqualStrings("}", line3.items);
}

test "indentation: reindent selected lines includes the line above" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const increase = try RegExp.init("\\{$", .{});
    defer increase.deinit();
    const decrease = try RegExp.init("^\\s*\\}", .{});
    defer decrease.deinit();

    try setupConfiguration(arena, .{
        .decreaseIndentPattern = decrease,
        .increaseIndentPattern = increase,
        .indentNextLinePattern = null,
        .unIndentedLinePattern = null,
    });

    var ctx = try TestModel.init(allocator, "if (a) {\nb\n}", "indentTestLanguage");
    defer ctx.deinit();

    const selections = [_]Selection{Selection.init(2, 1, 2, 2)};
    var edits = try indentation_browser.reindentSelectedLines(arena, ctx.model, testService(), &selections);
    defer edits.deinit();
    try applyEdits(&ctx, edits.items);

    const line2 = try ctx.model.getLineContent(2);
    defer line2.deinit();
    try std.testing.expectEqualStrings("    b", line2.items);
}

test "indentation: convert indentation to spaces and tabs" {
    const allocator = std.testing.allocator;

    {
        var ctx = try TestModel.init(allocator, "  a\n\tb", "nullLanguage");
        defer ctx.deinit();
        const selection = Selection.init(1, 1, 1, 1);
        var command = IndentationToSpacesCommand.init(allocator, selection, 4);
        const result = try command_runner.executeCommands(
            allocator,
            ctx.model,
            &[_]?editor_common.ICommand{editor_common.commandOf(IndentationToSpacesCommand).of(&command)},
            &[_]Selection{selection},
        );
        defer if (result) |value| allocator.free(value);

        const line1 = try ctx.model.getLineContent(1);
        defer line1.deinit();
        const line2 = try ctx.model.getLineContent(2);
        defer line2.deinit();
        try std.testing.expectEqualStrings("  a", line1.items);
        try std.testing.expectEqualStrings("    b", line2.items);
    }

    {
        var ctx = try TestModel.init(allocator, "    a\n  b", "nullLanguage");
        defer ctx.deinit();
        const selection = Selection.init(1, 1, 1, 1);
        var command = IndentationToTabsCommand.init(allocator, selection, 4);
        const result = try command_runner.executeCommands(
            allocator,
            ctx.model,
            &[_]?editor_common.ICommand{editor_common.commandOf(IndentationToTabsCommand).of(&command)},
            &[_]Selection{selection},
        );
        defer if (result) |value| allocator.free(value);

        const line1 = try ctx.model.getLineContent(1);
        defer line1.deinit();
        const line2 = try ctx.model.getLineContent(2);
        defer line2.deinit();
        try std.testing.expectEqualStrings("\ta", line1.items);
        try std.testing.expectEqualStrings("  b", line2.items);
    }
}

test "indentation: utility helpers and option changes" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 6), indent_utils.getSpaceCnt("  \t", 4));

    var ctx = try TestModel.init(allocator, "a", "nullLanguage");
    defer ctx.deinit();

    indentation_browser.changeIndentation(ctx.model, 2, false, false);
    try std.testing.expectEqual(@as(usize, 2), ctx.model.getOptions().tabSize);
    try std.testing.expectEqual(@as(usize, 2), ctx.model.getOptions().indentSize);
    try std.testing.expect(!ctx.model.getOptions().insertSpaces);

    indentation_browser.detectIndentation(ctx.model);
    try std.testing.expect(ctx.model.getOptions().tabSize >= 1);
}
