// Regression tests for the ported in-place-replace contribution. Upstream has
// no dedicated suite for this contribution, so these cover the command cursor
// states, the value-set lookup and the editor integration.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Position = @import("../../../../common/core/position.zig").Position;
const Range = @import("../../../../common/core/range.zig").Range;
const Selection = @import("../../../../common/core/selection.zig").Selection;
const languages = @import("../../../../common/languages.zig");
const language_configuration = @import("../../../../common/languages/languageConfiguration.zig");
const TokenizationRegistry = @import("../../../../common/tokenizationRegistry.zig").TokenizationRegistry;
const TokenPacked = @import("../../../../common/tokens/lineTokens.zig").TokenPacked;
const TokenMetadata = @import("../../../../common/encodedTokenAttributes.zig").TokenMetadata;
const NullState = @import("../../../../common/languages/nullTokenize.zig").NullState;
const CancellationToken = @import("../../../../../base/common/cancellation.zig").CancellationToken;
const RegExp = @import("../../../../../../support/regexp.zig").RegExp;
const TestModel = @import("../../../../test/common/port/testSupport.zig").TestModel;
const command_runner = @import("../../../../common/commands/commandRunner.zig");

const in_place_replace = @import("../../../../contrib/inPlaceReplace/browser/inPlaceReplace.zig");
const InPlaceReplaceCommand = @import("../../../../contrib/inPlaceReplace/browser/inPlaceReplaceCommand.zig").InPlaceReplaceCommand;
const Editor = @import("../../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;

const language_id = "inPlaceReplaceTestLanguage";

var test_brackets = [_]language_configuration.CharacterPair{
    .{ "(", ")" },
    .{ "{", "}" },
    .{ "[", "]" },
};

const TokenSupport = struct {
    encoded_language_id: u8,

    fn getInitialState(_: *anyopaque, _: Allocator) anyerror!languages.IState {
        return NullState;
    }

    fn tokenizeEncoded(
        context: *anyopaque,
        _: std.Io,
        allocator: Allocator,
        line: []const u8,
        has_eol: bool,
        state: languages.IState,
    ) anyerror!languages.EncodedTokenizationResult {
        _ = has_eol;
        const self: *TokenSupport = @ptrCast(@alignCast(context));
        const tokens = try allocator.alloc(TokenPacked, 1);
        var metadata = TokenMetadata.default;
        metadata.languageId = self.encoded_language_id;
        metadata.tokenType = .Other;
        metadata.balancedBrackets = true;
        tokens[0] = .{ .endOffset = @intCast(line.len), .metadata = metadata };
        return .{ .tokens = tokens, .endState = state };
    }

    fn interface(self: *TokenSupport) languages.ITokenizationSupport {
        return .{
            .context = self,
            .vtable = &.{
                .getInitialState = getInitialState,
                .tokenizeEncoded = tokenizeEncoded,
            },
        };
    }
};

const Fixture = struct {
    allocator: Allocator,
    ctx: TestModel,
    support: *TokenSupport,

    fn init(allocator: Allocator, text: []const u8) !Fixture {
        var ctx = try TestModel.init(allocator, text, language_id);
        errdefer ctx.deinit();

        const support = try allocator.create(TokenSupport);
        errdefer allocator.destroy(support);
        support.* = .{ .encoded_language_id = try ctx.codec.encodeLanguageId(language_id) };

        try TokenizationRegistry.instance.register(language_id, support.interface());
        errdefer TokenizationRegistry.instance.unregister(language_id);

        const pattern = try RegExp.init(
            "(-?\\d*\\.\\d\\w*)|([^\\`\\~\\!\\@\\#\\$\\%\\^\\&\\*\\(\\)\\=\\+\\[\\{\\]\\}\\\\\\;\\:\\'\\\"\\,\\.\\<\\>\\/\\?\\s]+)",
            .{},
        );
        var config = language_configuration.empty();
        config.brackets = &test_brackets;
        config.wordPattern = pattern;
        try ctx.languageService.registerLanguageConfiguration(language_id, config);

        return .{ .allocator = allocator, .ctx = ctx, .support = support };
    }

    fn deinit(self: *Fixture) void {
        TokenizationRegistry.instance.unregister(language_id);
        self.ctx.deinit();
        self.allocator.destroy(self.support);
    }
};

fn expectValue(expected: []const u8, actual: []const u8) !void {
    try std.testing.expectEqualStrings(expected, actual);
}

test "in-place replace: next and previous value sets" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator, "true");
    defer fixture.deinit();

    var next = (try in_place_replace.compute(allocator, fixture.ctx.model, Selection.init(1, 1, 1, 1), true)).?;
    defer next.deinit(allocator);
    try expectValue("false", next.value);
    try std.testing.expectEqualDeep(Range.init(1, 1, 1, 5), next.range);
    try std.testing.expectEqualDeep(Selection.init(1, 1, 1, 5), next.selection);

    var previous = (try in_place_replace.compute(allocator, fixture.ctx.model, Selection.init(1, 1, 1, 1), false)).?;
    defer previous.deinit(allocator);
    try expectValue("false", previous.value);
}

test "in-place replace: selected value and number increments" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator, "true 1.5");
    defer fixture.deinit();

    var selected = (try in_place_replace.compute(allocator, fixture.ctx.model, Selection.init(1, 1, 1, 5), true)).?;
    defer selected.deinit(allocator);
    try expectValue("false", selected.value);
    try std.testing.expectEqualDeep(Range.init(1, 1, 1, 5), selected.range);

    var number = (try in_place_replace.compute(allocator, fixture.ctx.model, Selection.init(1, 6, 1, 9), true)).?;
    defer number.deinit(allocator);
    try expectValue("2.5", number.value);
    try std.testing.expectEqualDeep(Range.init(1, 6, 1, 9), number.range);
}

test "in-place replace: rejects multiline selections" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator, "true\nfalse");
    defer fixture.deinit();

    try std.testing.expect((try in_place_replace.compute(allocator, fixture.ctx.model, Selection.init(1, 1, 2, 1), true)) == null);
}

test "in-place replace: no word means no result" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator, "...");
    defer fixture.deinit();

    try std.testing.expect((try in_place_replace.compute(allocator, fixture.ctx.model, Selection.init(1, 2, 1, 2), true)) == null);
}

test "InPlaceReplaceCommand: selects the replaced text for a non-empty selection" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator, "true");
    defer fixture.deinit();

    var command = InPlaceReplaceCommand.init(
        Range.init(1, 1, 1, 5),
        Selection.init(1, 1, 1, 5),
        "false",
    );
    const before = [_]Selection{Selection.init(1, 1, 1, 5)};
    const after = try command_runner.executeCommands(
        allocator,
        fixture.ctx.model,
        &[_]?@import("../../../../common/editorCommon.zig").ICommand{command.interface()},
        &before,
    );
    defer if (after) |selections| allocator.free(selections);

    const value = try fixture.ctx.model.getValue(.TextDefined, false);
    defer value.deinit();
    try std.testing.expectEqualStrings("false", value.items);
    try std.testing.expect(after != null);
    try std.testing.expectEqualDeep(Selection.init(1, 1, 1, 6), after.?[0]);
}

test "InPlaceReplaceCommand: keeps the cursor for an empty selection" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator, "true");
    defer fixture.deinit();

    var command = InPlaceReplaceCommand.init(
        Range.init(1, 3, 1, 4),
        Selection.init(1, 3, 1, 3),
        "u",
    );
    const before = [_]Selection{Selection.init(1, 3, 1, 3)};
    const after = try command_runner.executeCommands(
        allocator,
        fixture.ctx.model,
        &[_]?@import("../../../../common/editorCommon.zig").ICommand{command.interface()},
        &before,
    );
    defer if (after) |selections| allocator.free(selections);

    const value = try fixture.ctx.model.getValue(.TextDefined, false);
    defer value.deinit();
    try std.testing.expectEqualStrings("true", value.items);
    try std.testing.expectEqualDeep(Selection.init(1, 3, 1, 3), after.?[0]);
}

test "in-place replace: editor integration and decoration expiry" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var editor = try Editor.createFromText(allocator, io, "true", "test.zig", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    var queue = @import("../../../../../base/common/windowDispatch.zig").Queue{ .io = io };
    editor.attachWindow(&queue);
    try std.testing.expect(try editor.inPlaceReplace(true));
    const value = try editor.model.getValue(.TextDefined, false);
    defer value.deinit();
    try std.testing.expectEqualStrings("false", value.items);

    // The replacement decoration lives until the owner-specific deadline.
    const due = editor.in_place_replace_task.at.?;
    for (0..64) |_| {
        if (queue.nextTimeout(due - 1, 1) != 0) break;
        _ = queue.dispatch(due - 1);
    }
    try std.testing.expectEqual(due, editor.in_place_replace_task.at.?);
    for (0..64) |_| {
        if (editor.in_place_replace_task.at == null) break;
        _ = queue.dispatch(due);
    }
    try std.testing.expect(editor.in_place_replace_task.at == null);
}

test "in-place replace: action metadata matches upstream" {
    const State = struct {
        var ran: bool = false;
        fn run(_: *anyopaque) anyerror!void {
            ran = true;
        }
    };
    var dummy: u8 = 0;
    var up = in_place_replace.InPlaceReplaceUpAction.init(&dummy, State.run);
    const up_action = up.editorAction();
    try std.testing.expectEqualStrings("editor.action.inPlaceReplace.up", up_action.id);
    try std.testing.expectEqualStrings("Replace with Previous Value", up_action.label);
    try std.testing.expectEqualStrings(",", up_action.keybinding.?.key);
    try std.testing.expect(up_action.keybinding.?.ctrl);
    try std.testing.expect(up_action.keybinding.?.shift);

    State.ran = false;
    try up.run();
    try std.testing.expect(State.ran);

    var down = in_place_replace.InPlaceReplaceDownAction.init(&dummy, State.run);
    const down_action = down.editorAction();
    try std.testing.expectEqualStrings("editor.action.inPlaceReplace.down", down_action.id);
    try std.testing.expectEqualStrings(".", down_action.keybinding.?.key);
}
