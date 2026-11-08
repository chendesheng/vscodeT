const std = @import("std");
const ArrayList = std.array_list.Managed;
const RegExp = @import("../basics/RegExp.zig").RegExp;
const LanguageIdCodec = @import("../languages.zig").LanguageIdCodec;
const LineTokens = @import("../tokens/lineTokens.zig").LineTokens;
const TokenTextMetadata = @import("../tokens/lineTokens.zig").TokenTextMetadata;
const TokenMetadata = @import("../encodedTokenAttributes.zig").TokenMetadata;
const StandardTokenType = @import("../encodedTokenAttributes.zig").StandardTokenType;
const EditorAutoIndentStrategy = @import("../editorOptions.zig").EditorAutoIndentStrategy;
const CharacterPair = @import("languageConfiguration.zig").CharacterPair;
const IndentAction = @import("languageConfiguration.zig").IndentAction;
const OnEnterRule = @import("languageConfiguration.zig").OnEnterRule;
const RichEditBrackets = @import("supports/richEditBrackets.zig").RichEditBrackets;
const BracketsUtils = @import("supports/richEditBrackets.zig").BracketsUtils;
const createScopedLineTokens = @import("supports.zig").createScopedLineTokens;
const ignoreBracketsInToken = @import("supports.zig").ignoreBracketsInToken;
const BracketElectricCharacterSupport = @import("supports/electricCharacter.zig").BracketElectricCharacterSupport;
const OnEnterSupport = @import("supports/onEnter.zig").OnEnterSupport;

fn makeLineTokens(
    allocator: std.mem.Allocator,
    codec: *LanguageIdCodec,
    texts: []const []const u8,
    languages: []const []const u8,
    token_types: []const StandardTokenType,
) !LineTokens {
    const metadata = try allocator.alloc(TokenTextMetadata, texts.len);
    defer allocator.free(metadata);
    for (texts, 0..) |text, i| {
        var token_metadata = TokenMetadata.default;
        token_metadata.languageId = try codec.encodeLanguageId(languages[i]);
        token_metadata.tokenType = token_types[i];
        metadata[i] = .{ .text = text, .metadata = token_metadata };
    }
    return LineTokens.createFromTextAndMetadata(allocator, metadata, codec);
}

test "scoped line tokens: selects embedded language run" {
    const allocator = std.testing.allocator;
    var codec = try LanguageIdCodec.init(allocator);
    defer codec.deinit();
    try codec.register("html");
    try codec.register("js");

    const texts = [_][]const u8{ "a", "bc", "d" };
    const languages = [_][]const u8{ "html", "js", "html" };
    const token_types = [_]StandardTokenType{ .Other, .String, .Other };
    var line = try makeLineTokens(allocator, &codec, &texts, &languages, &token_types);
    defer line.deinit();

    const scoped = createScopedLineTokens(&line, 1);
    try std.testing.expectEqualStrings("bc", scoped.getLineContent());
    try std.testing.expectEqualStrings("js", scoped.languageId);
    try std.testing.expectEqual(@as(usize, 1), scoped.getTokenCount());
    try std.testing.expectEqual(@as(usize, 1), scoped.firstCharOffset);
    try std.testing.expectEqualStrings("a", scoped.getActualLineContentBefore(0));
    try std.testing.expectEqualStrings("abc", scoped.getActualLineContentBefore(2));
    try std.testing.expectEqual(@as(usize, 0), scoped.findTokenIndexAtOffset(0));
    try std.testing.expectEqual(StandardTokenType.String, scoped.getStandardTokenType(0));
    try std.testing.expect(ignoreBracketsInToken(.String));
    try std.testing.expect(!ignoreBracketsInToken(.Other));
}

test "rich edit brackets: grouping, matching, and word boundaries" {
    const allocator = std.testing.allocator;
    const pairs = [_]CharacterPair{ .{ "{", "}" }, .{ "(", ")" } };
    var brackets = try RichEditBrackets.init(allocator, "test", &pairs);
    defer brackets.deinit();

    try std.testing.expectEqual(@as(usize, 2), brackets.brackets.len);
    try std.testing.expect(brackets.textIsOpenBracket.get("{").?);
    try std.testing.expect(!brackets.textIsOpenBracket.get("}").?);
    try std.testing.expectEqualStrings("{", brackets.textIsBracket.get("{").?.open[0]);

    const next = BracketsUtils.findNextBracketInRange(&brackets.forwardRegex, 1, "x{y}", 0, 4).?;
    try std.testing.expectEqual(@as(usize, 2), next.startColumn);
    try std.testing.expectEqual(@as(usize, 3), next.endColumn);

    const prev = (try BracketsUtils.findPrevBracketInRange(allocator, &brackets.reversedRegex, 1, "x{y}", 0, 4)).?;
    try std.testing.expectEqual(@as(usize, 4), prev.startColumn);
    try std.testing.expectEqual(@as(usize, 5), prev.endColumn);

    const word_pairs = [_]CharacterPair{.{ "begin", "end" }};
    var word_brackets = try RichEditBrackets.init(allocator, "test", &word_pairs);
    defer word_brackets.deinit();
    try std.testing.expect(BracketsUtils.findNextBracketInRange(&word_brackets.forwardRegex, 1, "abegin", 0, 6) == null);
    try std.testing.expect(BracketsUtils.findNextBracketInRange(&word_brackets.forwardRegex, 1, "begin", 0, 5) != null);

    const word_prev = (try BracketsUtils.findPrevBracketInRange(allocator, &word_brackets.reversedRegex, 1, "begin end", 0, 9)).?;
    try std.testing.expectEqual(@as(usize, 7), word_prev.startColumn);
    try std.testing.expectEqual(@as(usize, 10), word_prev.endColumn);

    const fuzzy = [_]CharacterPair{ .{ "if", "end" }, .{ "for", "end" }, .{ "{", "}" } };
    var fuzzy_brackets = try RichEditBrackets.init(allocator, "test", &fuzzy);
    defer fuzzy_brackets.deinit();
    try std.testing.expectEqual(@as(usize, 2), fuzzy_brackets.brackets.len);
    try std.testing.expect(fuzzy_brackets.textIsBracket.get("end") != null);
}

test "electric characters: dedup and match open bracket" {
    const allocator = std.testing.allocator;
    var codec = try LanguageIdCodec.init(allocator);
    defer codec.deinit();
    try codec.register("test");

    const pairs = [_]CharacterPair{ .{ "{", "}" }, .{ "(", ")" } };
    var brackets = try RichEditBrackets.init(allocator, "test", &pairs);
    defer brackets.deinit();

    const support = BracketElectricCharacterSupport.init(&brackets);
    var electric_characters = ArrayList([]const u8).init(allocator);
    defer electric_characters.deinit();
    try support.getElectricCharacters(&electric_characters);
    try std.testing.expectEqual(@as(usize, 2), electric_characters.items.len);
    try std.testing.expectEqualStrings("}", electric_characters.items[0]);
    try std.testing.expectEqualStrings(")", electric_characters.items[1]);

    const texts = [_][]const u8{"\t\t"};
    const languages = [_][]const u8{"test"};
    const token_types = [_]StandardTokenType{.Other};
    var line = try makeLineTokens(allocator, &codec, &texts, &languages, &token_types);
    defer line.deinit();
    const scoped = createScopedLineTokens(&line, 2);

    const action = try support.onElectricCharacter(allocator, "}", scoped, 3);
    try std.testing.expect(action != null);
    try std.testing.expectEqualStrings("}", action.?.matchOpenBracket);

    const string_token_types = [_]StandardTokenType{.String};
    var string_line = try makeLineTokens(allocator, &codec, &texts, &languages, &string_token_types);
    defer string_line.deinit();
    const string_scoped = createScopedLineTokens(&string_line, 2);
    try std.testing.expect(try support.onElectricCharacter(allocator, "}", string_scoped, 3) == null);
}

fn expectIndentAction(support: *const OnEnterSupport, before: []const u8, after: []const u8, expected: ?IndentAction) !void {
    const result = support.onEnter(EditorAutoIndentStrategy.Advanced, "", before, after);
    if (expected) |indent_action| {
        try std.testing.expect(result != null);
        try std.testing.expectEqual(indent_action, result.?.indentAction);
    } else {
        try std.testing.expect(result == null);
    }
}

test "on enter: bracket cases" {
    const allocator = std.testing.allocator;
    const pairs = [_]CharacterPair{ .{ "(", ")" }, .{ "begin", "end" } };
    var support = try OnEnterSupport.init(allocator, .{ .brackets = &pairs });
    defer support.deinit();

    try expectIndentAction(&support, "a", "", null);
    try expectIndentAction(&support, "", "b", null);
    try expectIndentAction(&support, "(", "b", .Indent);
    try expectIndentAction(&support, "a", ")", null);
    try expectIndentAction(&support, "begin", "ending", .Indent);
    try expectIndentAction(&support, "abegin", "end", null);
    try expectIndentAction(&support, "begin", ")", .Indent);
    try expectIndentAction(&support, "begin", "end", .IndentOutdent);
    try expectIndentAction(&support, "begin ", " end", .IndentOutdent);
    try expectIndentAction(&support, " begin", "end//as", .IndentOutdent);
    try expectIndentAction(&support, "(", ")", .IndentOutdent);
    try expectIndentAction(&support, "( ", ")", .IndentOutdent);
    try expectIndentAction(&support, "a(", ")b", .IndentOutdent);
    try expectIndentAction(&support, "(", "", .Indent);
    try expectIndentAction(&support, "(", "foo", .Indent);
    try expectIndentAction(&support, "begin", "foo", .Indent);
    try expectIndentAction(&support, "begin", "", .Indent);
}

test "on enter: regexp rules" {
    const allocator = std.testing.allocator;

    var before = try RegExp.init("^\\s*/\\*\\*", .{});
    defer before.deinit();
    var after = try RegExp.init("^\\s*\\*/$", .{});
    defer after.deinit();
    const rules = [_]OnEnterRule{.{
        .beforeText = before,
        .afterText = after,
        .previousLineText = null,
        .action = .{ .indentAction = .IndentOutdent, .appendText = " * ", .removeText = null },
    }};
    var support = try OnEnterSupport.init(allocator, .{ .onEnterRules = &rules });
    defer support.deinit();

    const result = support.onEnter(EditorAutoIndentStrategy.Advanced, "", "/**", " */").?;
    try std.testing.expectEqual(IndentAction.IndentOutdent, result.indentAction);
    try std.testing.expectEqualStrings(" * ", result.appendText.?);

    var remove_before = try RegExp.init("^\\s*\\*/$", .{});
    defer remove_before.deinit();
    const remove_rules = [_]OnEnterRule{.{
        .beforeText = remove_before,
        .afterText = null,
        .previousLineText = null,
        .action = .{ .indentAction = .None, .appendText = null, .removeText = 1 },
    }};
    var remove_support = try OnEnterSupport.init(allocator, .{ .onEnterRules = &remove_rules });
    defer remove_support.deinit();
    const remove_result = remove_support.onEnter(EditorAutoIndentStrategy.Advanced, "", " */", "").?;
    try std.testing.expectEqual(IndentAction.None, remove_result.indentAction);
    try std.testing.expectEqual(@as(?usize, 1), remove_result.removeText);
}

test "rich edit brackets: utility edge cases" {
    const allocator = std.testing.allocator;
    const pairs = [_]CharacterPair{.{ "{", "}" }};
    var brackets = try RichEditBrackets.init(allocator, "test", &pairs);
    defer brackets.deinit();

    const prev = (try BracketsUtils.findPrevBracketInRange(allocator, &brackets.reversedRegex, 1, "{", 0, 1)).?;
    try std.testing.expectEqual(@as(usize, 1), prev.startColumn);
    try std.testing.expectEqual(@as(usize, 2), prev.endColumn);

    try std.testing.expect(BracketsUtils.findNextBracketInRange(&brackets.forwardRegex, 1, "", 0, 0) == null);
    try std.testing.expect(BracketsUtils.findNextBracketInRange(&brackets.forwardRegex, 1, "abc", 0, 3) == null);

    const empty = [_][]const u8{};
    try std.testing.expectError(error.EmptyBrackets, @import("supports/richEditBrackets.zig").createBracketOrRegExp(allocator, &empty, .{}));
}

test "electric characters: no-op cases" {
    const allocator = std.testing.allocator;
    var codec = try LanguageIdCodec.init(allocator);
    defer codec.deinit();
    try codec.register("test");

    const pairs = [_]CharacterPair{ .{ "{", "}" }, .{ "(", ")" } };
    var brackets = try RichEditBrackets.init(allocator, "test", &pairs);
    defer brackets.deinit();
    const support = BracketElectricCharacterSupport.init(&brackets);
    const languages = [_][]const u8{"test"};
    const token_types = [_]StandardTokenType{.Other};

    const open_texts = [_][]const u8{"\t{"};
    var open_line = try makeLineTokens(allocator, &codec, &open_texts, &languages, &token_types);
    defer open_line.deinit();
    const open_scoped = createScopedLineTokens(&open_line, 1);
    try std.testing.expect(try support.onElectricCharacter(allocator, "{", open_scoped, 2) == null);

    const text_before_texts = [_][]const u8{"x\t"};
    var text_before_line = try makeLineTokens(allocator, &codec, &text_before_texts, &languages, &token_types);
    defer text_before_line.deinit();
    const text_before_scoped = createScopedLineTokens(&text_before_line, 1);
    try std.testing.expect(try support.onElectricCharacter(allocator, "}", text_before_scoped, 3) == null);
}

test "on enter: javascript jsdoc rules" {
    const allocator = std.testing.allocator;

    var jsdoc_start = try RegExp.init("^\\s*/\\*\\*(?!/)([^*]|\\*(?!/))*$", .{});
    defer jsdoc_start.deinit();
    var jsdoc_end = try RegExp.init("^\\s*\\*/$", .{});
    defer jsdoc_end.deinit();
    var star_line = try RegExp.init("^(\\t|[ ])*[ ]\\*([ ]([^*]|\\*(?!/))*)?$", .{});
    defer star_line.deinit();
    var star_previous = try RegExp.init("(?=^(\\s*(/\\*\\*|\\*)).*)(?=(?!(\\s*\\*/)))", .{});
    defer star_previous.deinit();
    var close_line = try RegExp.init("^(\\t|[ ])*[ ]\\*/\\s*$", .{});
    defer close_line.deinit();
    var decorated_close = try RegExp.init("^(\\t|[ ])*[ ]\\*[^/]*\\*/\\s*$", .{});
    defer decorated_close.deinit();

    const rules = [_]OnEnterRule{
        .{
            .beforeText = jsdoc_start,
            .afterText = jsdoc_end,
            .previousLineText = null,
            .action = .{ .indentAction = .IndentOutdent, .appendText = " * ", .removeText = null },
        },
        .{
            .beforeText = jsdoc_start,
            .afterText = null,
            .previousLineText = null,
            .action = .{ .indentAction = .None, .appendText = " * ", .removeText = null },
        },
        .{
            .beforeText = star_line,
            .afterText = null,
            .previousLineText = star_previous,
            .action = .{ .indentAction = .None, .appendText = "* ", .removeText = null },
        },
        .{
            .beforeText = close_line,
            .afterText = null,
            .previousLineText = null,
            .action = .{ .indentAction = .None, .appendText = null, .removeText = 1 },
        },
        .{
            .beforeText = decorated_close,
            .afterText = null,
            .previousLineText = null,
            .action = .{ .indentAction = .None, .appendText = null, .removeText = 1 },
        },
    };
    var support = try OnEnterSupport.init(allocator, .{ .onEnterRules = &rules });
    defer support.deinit();

    const Function = struct {
        fn check(sup: *const OnEnterSupport, previous: []const u8, before: []const u8, after: []const u8, expected: ?IndentAction, append: ?[]const u8, remove: ?usize) !void {
            const result = sup.onEnter(EditorAutoIndentStrategy.Advanced, previous, before, after);
            if (expected) |action| {
                try std.testing.expect(result != null);
                try std.testing.expectEqual(action, result.?.indentAction);
                if (append) |text| try std.testing.expectEqualStrings(text, result.?.appendText.?);
                if (remove) |count| try std.testing.expectEqual(@as(?usize, count), result.?.removeText);
            } else {
                try std.testing.expect(result == null);
            }
        }
    };
    const check = Function.check;

    try check(&support, "", "\t/**", " */", .IndentOutdent, " * ", null);
    try check(&support, "", "\t/**", "", .None, " * ", null);
    try check(&support, "", "\t/**/", "", null, null, null);
    try check(&support, "", "\t/** */", "", null, null, null);
    try check(&support, "\t/**", "\t *", "", .None, "* ", null);
    try check(&support, "", "\t */", "", .None, null, 1);
    try check(&support, "", "\t * */", "", .None, null, 1);
}
