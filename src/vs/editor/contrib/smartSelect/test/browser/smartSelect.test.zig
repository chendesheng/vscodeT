// Port of `src/vs/editor/contrib/smartSelect/test/browser/smartSelect.test.ts`.
//
// Browser setup is replaced by the repository's `TestModel` harness. The test
// language registers brackets and the same word pattern the upstream suite
// uses, and the tokenizer marks the whole line as balanced brackets so the
// ported bracket-pair model sees the test brackets.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Position = @import("../../../../common/core/position.zig").Position;
const Range = @import("../../../../common/core/range.zig").Range;
const Selection = @import("../../../../common/core/selection.zig").Selection;
const languages = @import("../../../../common/languages.zig");
const SelectionRange = languages.SelectionRange;
const SelectionRangeProvider = languages.SelectionRangeProvider;
const language_configuration = @import("../../../../common/languages/languageConfiguration.zig");
const TokenizationRegistry = @import("../../../../common/tokenizationRegistry.zig").TokenizationRegistry;
const TokenPacked = @import("../../../../common/tokens/lineTokens.zig").TokenPacked;
const TokenMetadata = @import("../../../../common/encodedTokenAttributes.zig").TokenMetadata;
const NullState = @import("../../../../common/languages/nullTokenize.zig").NullState;
const CancellationToken = @import("../../../../../base/common/cancellation.zig").CancellationToken;
const RegExp = @import("../../../../../../support/regexp.zig").RegExp;

const smart_select = @import("../../../../contrib/smartSelect/browser/smartSelect.zig");
const SelectionRangesOptions = smart_select.SelectionRangesOptions;
const provideSelectionRanges = smart_select.provideSelectionRanges;
const freeSelectionRanges = smart_select.freeSelectionRanges;
const BracketSelectionRangeProvider = @import("../../../../contrib/smartSelect/browser/bracketSelections.zig").BracketSelectionRangeProvider;
const WordSelectionRangeProvider = @import("../../../../contrib/smartSelect/browser/wordSelections.zig").WordSelectionRangeProvider;
const TestModel = @import("../../../../test/common/port/testSupport.zig").TestModel;

const language_id = "smartSelectTestLanguage";

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

        return .{
            .allocator = allocator,
            .ctx = ctx,
            .support = support,
        };
    }

    fn deinit(self: *Fixture) void {
        TokenizationRegistry.instance.unregister(language_id);
        self.ctx.deinit();
        self.allocator.destroy(self.support);
    }

    fn model(self: *Fixture) *@import("../../../../common/model/textModel.zig").TextModel {
        return self.ctx.model;
    }
};

fn expectRange(actual: Range, expected: Range) !void {
    if (!Range.equalsRange(actual, expected)) {
        std.debug.print("range mismatch: actual {d}:{d}-{d}:{d}, expected {d}:{d}-{d}:{d}\n", .{
            actual.startLineNumber,   actual.startColumn,   actual.endLineNumber,   actual.endColumn,
            expected.startLineNumber, expected.startColumn, expected.endLineNumber, expected.endColumn,
        });
        return error.TestUnexpectedResult;
    }
}

fn assertGetRangesToPosition(
    fixture: *Fixture,
    line_number: usize,
    column: usize,
    expected_outer_to_inner: []const Range,
    select_leading_and_trailing_whitespace: bool,
) !void {
    const allocator = fixture.allocator;
    const positions = [_]Position{Position.init(line_number, column)};
    const actual = try provideSelectionRanges(
        allocator,
        fixture.model(),
        &positions,
        &.{},
        .{
            .select_leading_and_trailing_whitespace = select_leading_and_trailing_whitespace,
            .select_subwords = true,
        },
        CancellationToken.None,
    );
    defer freeSelectionRanges(allocator, actual);

    try std.testing.expectEqual(expected_outer_to_inner.len, actual[0].len);
    for (actual[0], 0..) |range, index| {
        const expected = expected_outer_to_inner[expected_outer_to_inner.len - 1 - index];
        try expectRange(range, expected);
    }
}

fn assertRanges(
    provider: SelectionRangeProvider,
    fixture: *Fixture,
    value: []const u8,
    expected: []const Range,
) !void {
    const allocator = fixture.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    const pipe = std.mem.indexOfScalar(u8, value, '|') orelse return error.TestUnexpectedResult;
    const text = try std.mem.concat(arena_state.allocator(), u8, &.{ value[0..pipe], value[pipe + 1 ..] });
    try fixture.ctx.applyEdit(fixture.model().getFullModelRange(), text);

    const position = fixture.model().getPositionAt(pipe);
    const positions = [_]Position{position};
    const all = try provider.provide_selection_ranges(
        provider.context,
        arena_state.allocator(),
        fixture.model(),
        &positions,
        CancellationToken.None,
    );
    const ranges = all[0];

    try std.testing.expectEqual(expected.len, ranges.len);
    for (expected, 0..) |expected_range, index| {
        try expectRange(ranges[index].range, expected_range);
    }
}

test "SmartSelect: getRangesToPosition #1" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator, "function a(bar, foo){\n\tif (bar) {\n\t\treturn (bar + (2 * foo))\n\t}\n}");
    defer fixture.deinit();

    try assertGetRangesToPosition(&fixture, 3, 20, &.{
        Range.init(1, 1, 5, 2),
        Range.init(1, 21, 5, 2),
        Range.init(1, 22, 5, 1),
        Range.init(2, 1, 4, 3),
        Range.init(2, 1, 4, 3),
        Range.init(2, 2, 4, 3),
        Range.init(2, 11, 4, 3),
        Range.init(2, 12, 4, 2),
        Range.init(3, 1, 3, 27),
        Range.init(3, 3, 3, 27),
        Range.init(3, 10, 3, 27),
        Range.init(3, 11, 3, 26),
        Range.init(3, 17, 3, 26),
        Range.init(3, 18, 3, 25),
    }, true);
}

test "SmartSelect: config selectLeadingAndTrailingWhitespace" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator, "aaa\n\tbbb\n");
    defer fixture.deinit();

    try assertGetRangesToPosition(&fixture, 2, 3, &.{
        Range.init(1, 1, 3, 1),
        Range.init(2, 1, 2, 5),
        Range.init(2, 2, 2, 5),
    }, true);
}

test "SmartSelect: #56886 skip empty lines" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator, "function a(bar, foo){\n\tif (bar) {\n\n\t}\n}");
    defer fixture.deinit();

    try assertGetRangesToPosition(&fixture, 3, 1, &.{
        Range.init(1, 1, 5, 2),
        Range.init(1, 21, 5, 2),
        Range.init(1, 22, 5, 1),
        Range.init(2, 1, 4, 3),
        Range.init(2, 1, 4, 3),
        Range.init(2, 2, 4, 3),
        Range.init(2, 11, 4, 3),
        Range.init(2, 12, 4, 2),
    }, true);
}

test "SmartSelect: #56886 do not skip whitespace-only lines" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator, "function a(bar, foo){\n\tif (bar) {\n \n\t}\n}");
    defer fixture.deinit();

    try assertGetRangesToPosition(&fixture, 3, 1, &.{
        Range.init(1, 1, 5, 2),
        Range.init(1, 21, 5, 2),
        Range.init(1, 22, 5, 1),
        Range.init(2, 1, 4, 3),
        Range.init(2, 1, 4, 3),
        Range.init(2, 2, 4, 3),
        Range.init(2, 11, 4, 3),
        Range.init(2, 12, 4, 2),
        Range.init(3, 1, 3, 2),
        Range.init(3, 1, 3, 2),
    }, true);
}

test "SmartSelect: #40658 first position inside brackets selects line inside" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator, " [ ]\n { } \n( ) ");
    defer fixture.deinit();

    try assertGetRangesToPosition(&fixture, 2, 3, &.{
        Range.init(1, 1, 3, 5),
        Range.init(2, 1, 2, 6),
        Range.init(2, 2, 2, 5),
        Range.init(2, 3, 2, 4),
    }, true);
}

test "SmartSelect: #40658 empty brackets reveal brackets first" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator, " [] \n { } \n  ( ) ");
    defer fixture.deinit();

    try assertGetRangesToPosition(&fixture, 1, 3, &.{
        Range.init(1, 1, 3, 7),
        Range.init(1, 1, 1, 5),
        Range.init(1, 2, 1, 4),
        Range.init(1, 3, 1, 3),
    }, true);
}

test "SmartSelect: #40658 tokens before bracket revealed first" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator, "  [] \n { } \nselectthis( ) ");
    defer fixture.deinit();

    try assertGetRangesToPosition(&fixture, 3, 11, &.{
        Range.init(1, 1, 3, 15),
        Range.init(3, 1, 3, 15),
        Range.init(3, 1, 3, 14),
        Range.init(3, 1, 3, 11),
    }, true);
}

test "SmartSelect: bracket selection" {
    const allocator = std.testing.allocator;
    var bracket_provider = BracketSelectionRangeProvider{};
    var fixture = try Fixture.init(allocator, "");
    defer fixture.deinit();

    try assertRanges(bracket_provider.interface(), &fixture, "(|)", &.{
        Range.init(1, 2, 1, 2),
        Range.init(1, 1, 1, 3),
    });
    try assertRanges(bracket_provider.interface(), &fixture, "[[[](|)]]", &.{
        Range.init(1, 6, 1, 6),
        Range.init(1, 5, 1, 7),
        Range.init(1, 3, 1, 7),
        Range.init(1, 2, 1, 8),
        Range.init(1, 2, 1, 8),
        Range.init(1, 1, 1, 9),
    });
    try assertRanges(bracket_provider.interface(), &fixture, "[a[](|)a]", &.{
        Range.init(1, 6, 1, 6),
        Range.init(1, 5, 1, 7),
        Range.init(1, 2, 1, 8),
        Range.init(1, 1, 1, 9),
    });
    try assertRanges(bracket_provider.interface(), &fixture, "fofof|fofo", &.{});
    try assertRanges(bracket_provider.interface(), &fixture, "[[[]()]]|", &.{});
    try assertRanges(bracket_provider.interface(), &fixture, "|[[[]()]]", &.{});
    try assertRanges(bracket_provider.interface(), &fixture, "[|[[]()]]", &.{
        Range.init(1, 2, 1, 8),
        Range.init(1, 1, 1, 9),
    });
    try assertRanges(bracket_provider.interface(), &fixture, "[[[]()]|]", &.{
        Range.init(1, 2, 1, 8),
        Range.init(1, 1, 1, 9),
    });
    try assertRanges(bracket_provider.interface(), &fixture, "aaa(aaa)bbb(b|b)ccc(ccc)", &.{
        Range.init(1, 13, 1, 15),
        Range.init(1, 12, 1, 16),
    });
    try assertRanges(bracket_provider.interface(), &fixture, "(aaa(aaa)bbb(b|b)ccc(ccc))", &.{
        Range.init(1, 14, 1, 16),
        Range.init(1, 13, 1, 17),
        Range.init(1, 2, 1, 25),
        Range.init(1, 1, 1, 26),
    });
}

test "SmartSelect: bracket with leading/trailing" {
    const allocator = std.testing.allocator;
    var provider = BracketSelectionRangeProvider{};
    var fixture = try Fixture.init(allocator, "");
    defer fixture.deinit();

    try assertRanges(provider.interface(), &fixture, "for(a of b){\n  foo(|);\n}", &.{
        Range.init(2, 7, 2, 7),
        Range.init(2, 6, 2, 8),
        Range.init(1, 13, 3, 1),
        Range.init(1, 12, 3, 2),
        Range.init(1, 1, 3, 2),
        Range.init(1, 1, 3, 2),
    });
    try assertRanges(provider.interface(), &fixture, "for(a of b)\n{\n  foo(|);\n}", &.{
        Range.init(3, 7, 3, 7),
        Range.init(3, 6, 3, 8),
        Range.init(2, 2, 4, 1),
        Range.init(2, 1, 4, 2),
        Range.init(1, 1, 4, 2),
        Range.init(1, 1, 4, 2),
    });
}

test "SmartSelect: in-word ranges" {
    const allocator = std.testing.allocator;
    var provider = WordSelectionRangeProvider.init(true);
    var fixture = try Fixture.init(allocator, "");
    defer fixture.deinit();

    try assertRanges(provider.interface(), &fixture, "f|ooBar", &.{
        Range.init(1, 1, 1, 4),
        Range.init(1, 1, 1, 7),
        Range.init(1, 1, 1, 7),
    });
    try assertRanges(provider.interface(), &fixture, "f|oo_Ba", &.{
        Range.init(1, 1, 1, 4),
        Range.init(1, 1, 1, 7),
        Range.init(1, 1, 1, 7),
    });
    try assertRanges(provider.interface(), &fixture, "f|oo-Ba", &.{
        Range.init(1, 1, 1, 4),
        Range.init(1, 1, 1, 7),
        Range.init(1, 1, 1, 7),
    });
}

test "SmartSelect: in-word ranges with selectSubwords=false" {
    const allocator = std.testing.allocator;
    var provider = WordSelectionRangeProvider.init(false);
    var fixture = try Fixture.init(allocator, "");
    defer fixture.deinit();

    try assertRanges(provider.interface(), &fixture, "f|ooBar", &.{
        Range.init(1, 1, 1, 7),
        Range.init(1, 1, 1, 7),
    });
    try assertRanges(provider.interface(), &fixture, "f|oo_Ba", &.{
        Range.init(1, 1, 1, 7),
        Range.init(1, 1, 1, 7),
    });
    try assertRanges(provider.interface(), &fixture, "f|oo-Ba", &.{
        Range.init(1, 1, 1, 7),
        Range.init(1, 1, 1, 7),
    });
}

test "SmartSelect: #67493 camelCase" {
    const allocator = std.testing.allocator;
    var provider = WordSelectionRangeProvider.init(true);
    var fixture = try Fixture.init(allocator, "");
    defer fixture.deinit();

    try assertRanges(provider.interface(), &fixture, "Abs|tractSmartSelect", &.{
        Range.init(1, 1, 1, 9),
        Range.init(1, 1, 1, 20),
        Range.init(1, 1, 1, 20),
    });
    try assertRanges(provider.interface(), &fixture, "AbstractSma|rtSelect", &.{
        Range.init(1, 9, 1, 14),
        Range.init(1, 1, 1, 20),
        Range.init(1, 1, 1, 20),
    });
    try assertRanges(provider.interface(), &fixture, "Abstrac-Sma|rt-elect", &.{
        Range.init(1, 9, 1, 14),
        Range.init(1, 1, 1, 20),
        Range.init(1, 1, 1, 20),
    });
    try assertRanges(provider.interface(), &fixture, "Abstrac_Sma|rt_elect", &.{
        Range.init(1, 9, 1, 14),
        Range.init(1, 1, 1, 20),
        Range.init(1, 1, 1, 20),
    });
    try assertRanges(provider.interface(), &fixture, "Abstrac_Sma|rt-elect", &.{
        Range.init(1, 9, 1, 14),
        Range.init(1, 1, 1, 20),
        Range.init(1, 1, 1, 20),
    });
    try assertRanges(provider.interface(), &fixture, "Abstrac_Sma|rtSelect", &.{
        Range.init(1, 9, 1, 14),
        Range.init(1, 1, 1, 20),
        Range.init(1, 1, 1, 20),
    });
}

test "SmartSelect: #90589 underscores" {
    const allocator = std.testing.allocator;
    var provider = WordSelectionRangeProvider.init(true);
    var fixture = try Fixture.init(allocator, "");
    defer fixture.deinit();

    try assertRanges(provider.interface(), &fixture, "Hel|lo_World", &.{
        Range.init(1, 1, 1, 6),
        Range.init(1, 1, 1, 12),
        Range.init(1, 1, 1, 12),
    });
    try assertRanges(provider.interface(), &fixture, "Hello_Wo|rld", &.{
        Range.init(1, 7, 1, 12),
        Range.init(1, 1, 1, 12),
        Range.init(1, 1, 1, 12),
    });
    try assertRanges(provider.interface(), &fixture, "Hello|_World", &.{
        Range.init(1, 1, 1, 6),
        Range.init(1, 1, 1, 12),
        Range.init(1, 1, 1, 12),
    });
    try assertRanges(provider.interface(), &fixture, "Hello_|World", &.{
        Range.init(1, 7, 1, 12),
        Range.init(1, 1, 1, 12),
        Range.init(1, 1, 1, 12),
    });
    try assertRanges(provider.interface(), &fixture, "Hello|-World", &.{
        Range.init(1, 1, 1, 6),
        Range.init(1, 1, 1, 12),
        Range.init(1, 1, 1, 12),
    });
    try assertRanges(provider.interface(), &fixture, "Hello-|World", &.{
        Range.init(1, 7, 1, 12),
        Range.init(1, 1, 1, 12),
        Range.init(1, 1, 1, 12),
    });
    try assertRanges(provider.interface(), &fixture, "Hello|World", &.{
        Range.init(1, 6, 1, 11),
        Range.init(1, 1, 1, 11),
        Range.init(1, 1, 1, 11),
    });
}

const CustomRangeProvider = struct {
    fn provide(
        _: *anyopaque,
        allocator: Allocator,
        _: *@import("../../../../common/model/textModel.zig").TextModel,
        positions: []const Position,
        _: CancellationToken,
    ) anyerror![]const []const SelectionRange {
        const outer = try allocator.alloc([]const SelectionRange, positions.len);
        for (outer) |*bucket| {
            const ranges = try allocator.alloc(SelectionRange, 3);
            ranges[0] = .{ .range = Range.init(1, 10, 1, 11) };
            ranges[1] = .{ .range = Range.init(1, 10, 3, 2) };
            ranges[2] = .{ .range = Range.init(1, 1, 3, 2) };
            bucket.* = ranges;
        }
        return outer;
    }
};

test "SmartSelect: #73850 only add line ranges contained by the next range" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator, "type T = {\n\tx: number\n}");
    defer fixture.deinit();

    var dummy: u8 = 0;
    const custom = SelectionRangeProvider{
        .context = &dummy,
        .provide_selection_ranges = CustomRangeProvider.provide,
    };
    const positions = [_]Position{Position.init(1, 10)};
    const actual = try provideSelectionRanges(
        allocator,
        fixture.model(),
        &positions,
        &[_]SelectionRangeProvider{custom},
        .{ .select_leading_and_trailing_whitespace = true, .select_subwords = true },
        CancellationToken.None,
    );
    defer freeSelectionRanges(allocator, actual);

    try std.testing.expectEqual(@as(usize, 3), actual[0].len);
    try expectRange(actual[0][0], Range.init(1, 10, 1, 11));
    try expectRange(actual[0][1], Range.init(1, 10, 3, 2));
    try expectRange(actual[0][2], Range.init(1, 1, 3, 2));
}

test "SmartSelect: action metadata matches upstream" {
    const smart = @import("../../../../contrib/smartSelect/browser/smartSelect.zig");
    const State = struct {
        var ran: bool = false;
        fn run(_: *anyopaque) anyerror!void {
            ran = true;
        }
    };
    State.ran = false;
    var dummy: u8 = 0;
    var expand = smart.ExpandSelectionAction.init(&dummy, State.run);
    const expand_action = expand.editorAction();
    try std.testing.expectEqualStrings("editor.action.smartSelect.expand", expand_action.id);
    try std.testing.expectEqualStrings("Expand Selection", expand_action.label);
    try std.testing.expectEqualStrings("right", expand_action.keybinding.?.key);
    try std.testing.expect(expand_action.keybinding.?.shift);
    try std.testing.expect(expand_action.keybinding.?.alt);
    try expand.run();
    try std.testing.expect(State.ran);

    var shrink = smart.ShrinkSelectionAction.init(&dummy, State.run);
    const shrink_action = shrink.editorAction();
    try std.testing.expectEqualStrings("editor.action.smartSelect.shrink", shrink_action.id);
    try std.testing.expectEqualStrings("left", shrink_action.keybinding.?.key);
}

test "SmartSelectController: expands, shrinks and invalidates its cache" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator, "fooBar");
    defer fixture.deinit();

    var controller = smart_select.SmartSelectController.init(allocator, &.{}, .{});
    defer controller.deinit();

    var selections = [_]Selection{Selection.init(1, 2, 1, 2)};
    const first = (try controller.run(fixture.model(), &selections, true)).?;
    defer allocator.free(first);
    try std.testing.expectEqualDeep(Selection.init(1, 1, 1, 4), first[0]);

    const second = (try controller.run(fixture.model(), first, true)).?;
    defer allocator.free(second);
    try std.testing.expectEqualDeep(Selection.init(1, 1, 1, 7), second[0]);

    const third = (try controller.run(fixture.model(), second, false)).?;
    defer allocator.free(third);
    try std.testing.expectEqualDeep(Selection.init(1, 1, 1, 4), third[0]);

    // Mounted editors receive the invalidation through onDidChangeCursorPosition.
    // The focused model harness delivers the same transition explicitly.
    controller.invalidate();
    try std.testing.expect(controller.state == null);
    selections[0] = Selection.init(1, 6, 1, 6);
    const fourth = (try controller.run(fixture.model(), &selections, true)).?;
    defer allocator.free(fourth);
    try std.testing.expectEqualDeep(Selection.init(1, 4, 1, 7), fourth[0]);
}

test "SmartSelectController: expands every cursor" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator, "fooBar");
    defer fixture.deinit();

    var controller = smart_select.SmartSelectController.init(allocator, &.{}, .{});
    defer controller.deinit();

    const selections = [_]Selection{
        Selection.init(1, 2, 1, 2),
        Selection.init(1, 6, 1, 6),
    };
    const expanded = (try controller.run(fixture.model(), &selections, true)).?;
    defer allocator.free(expanded);
    try std.testing.expectEqual(@as(usize, 2), expanded.len);
    try std.testing.expectEqualDeep(Selection.init(1, 1, 1, 4), expanded[0]);
    try std.testing.expectEqualDeep(Selection.init(1, 4, 1, 7), expanded[1]);
}
