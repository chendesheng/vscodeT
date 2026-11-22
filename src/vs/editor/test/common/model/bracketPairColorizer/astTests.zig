const std = @import("std");
const tree = @import("../../../../common/model/bracketPairsTextModelPart/bracketPairsTree/bracketPairsTree.zig");
const TestModel = @import("../../port/testSupport.zig").TestModel;
const TokenizationRegistry = @import("../../../../common/tokenizationRegistry.zig").TokenizationRegistry;
const ITokenizationSupport = @import("../../../../common/languages.zig").ITokenizationSupport;
const IState = @import("../../../../common/languages.zig").IState;
const EncodedTokenizationResult = @import("../../../../common/languages.zig").EncodedTokenizationResult;
const NullState = @import("../../../../common/languages/nullTokenize.zig").NullState;
const TokenPacked = @import("../../../../common/tokens/lineTokens.zig").TokenPacked;
const TokenMetadata = @import("../../../../common/encodedTokenAttributes.zig").TokenMetadata;
const LanguageConfiguration = @import("../../../../common/languages/languageConfiguration.zig").LanguageConfiguration;
const CharacterPair = @import("../../../../common/languages/languageConfiguration.zig").CharacterPair;

const Support = struct {
    fn getInitialState(_: *anyopaque, _: std.mem.Allocator) anyerror!IState {
        return NullState;
    }
    fn tokenizeEncoded(_: *anyopaque, allocator: std.mem.Allocator, line: []const u8, _: bool, state: IState) anyerror!EncodedTokenizationResult {
        const tokens = try allocator.alloc(TokenPacked, 1);
        var metadata = TokenMetadata.default;
        metadata.balancedBrackets = true;
        tokens[0] = .{ .endOffset = @intCast(line.len), .metadata = metadata };
        return .{ .tokens = tokens, .endState = state };
    }
    fn interface() ITokenizationSupport {
        return .{ .context = undefined, .vtable = &.{ .getInitialState = getInitialState, .tokenizeEncoded = tokenizeEncoded } };
    }
};

test "ast: length arithmetic" {
    const a = tree.toLength(1, 5);
    const b = tree.toLength(0, 3);
    try std.testing.expectEqual(1, tree.lengthLineCount(tree.lengthAdd(a, b)));
    try std.testing.expectEqual(8, tree.lengthColumnCount(tree.lengthAdd(a, b)));
    try std.testing.expectEqual(3, tree.lengthLineCount(tree.lengthAdd(a, tree.toLength(2, 0))));
    try std.testing.expectEqual(0, tree.lengthColumnCount(tree.lengthAdd(a, tree.toLength(2, 0))));
}

test "ast: small immutable sets" {
    const a = try (try tree.SmallImmutableSet.empty().add(1)).add(70);
    const b = try (try tree.SmallImmutableSet.empty().add(2)).add(70);
    try std.testing.expect(a.has(1));
    try std.testing.expect(a.has(70));
    try std.testing.expect(a.intersects(b));
    try std.testing.expect(a.merge(b).has(2));
    try std.testing.expect(!a.intersects(try tree.SmallImmutableSet.empty().add(3)));
}

test "ast: parser builds a 2-3 list tree" {
    const allocator = std.testing.allocator;
    try TokenizationRegistry.instance.register("astLang", Support.interface());
    defer TokenizationRegistry.instance.unregister("astLang");
    var ctx = try TestModel.init(allocator, "{ [ ( ) ] } 1 2 3 4 5 6 7", "astLang");
    defer ctx.deinit();
    var brackets = [_]CharacterPair{ .{ "{", "}" }, .{ "[", "]" }, .{ "(", ")" } };
    var config = @import("../../../../common/languages/languageConfiguration.zig").empty();
    config.brackets = &brackets;
    try ctx.languageService.registerLanguageConfiguration("astLang", config);
    ctx.model.forceTokenization(1);

    var ids = tree.StringIdProvider.init(allocator);
    defer ids.deinit();
    var doc = try tree.parseDocument(allocator, ctx.model, ctx.languageService, &ids);
    defer doc.deinit();
    try std.testing.expect(doc.root.kind == .list);
    try std.testing.expect(doc.root.list_height >= 1);
    try std.testing.expectEqual(tree.lengthOfString("{ [ ( ) ] } 1 2 3 4 5 6 7"), doc.root.length);
    try expect23Tree(doc.root);
}

test "ast: pair nodes preserve nesting" {
    const allocator = std.testing.allocator;
    try TokenizationRegistry.instance.register("astLang2", Support.interface());
    defer TokenizationRegistry.instance.unregister("astLang2");
    var ctx = try TestModel.init(allocator, "{[]}", "astLang2");
    defer ctx.deinit();
    var brackets = [_]CharacterPair{ .{ "{", "}" }, .{ "[", "]" } };
    var config = @import("../../../../common/languages/languageConfiguration.zig").empty();
    config.brackets = &brackets;
    try ctx.languageService.registerLanguageConfiguration("astLang2", config);
    ctx.model.forceTokenization(1);

    var ids = tree.StringIdProvider.init(allocator);
    defer ids.deinit();
    var doc = try tree.parseDocument(allocator, ctx.model, ctx.languageService, &ids);
    defer doc.deinit();
    try std.testing.expect(doc.root.kind == .pair);
    const outer = doc.root.data.pair;
    try std.testing.expect(outer.closing != null);
    try std.testing.expect(outer.child != null);
    try std.testing.expect(outer.child.?.kind == .pair);
    try std.testing.expectEqualStrings("{", outer.opening.data.bracket.info.bracket_text);
    try std.testing.expectEqualStrings("}", outer.closing.?.data.bracket.info.bracket_text);
}

fn expect23Tree(node: *tree.AstNode) !void {
    if (node.kind == .list) {
        const count = node.data.list.children.items.len;
        if (count == 0) return;
        try std.testing.expect(count == 2 or count == 3);
        for (node.data.list.children.items) |child| try expect23Tree(child);
    } else {
        var i: usize = 0;
        while (node.child(i)) |child| : (i += 1) try expect23Tree(child);
    }
}

test "ast: many pairs form a balanced 2-3 tree" {
    const allocator = std.testing.allocator;
    try TokenizationRegistry.instance.register("astLang3", Support.interface());
    defer TokenizationRegistry.instance.unregister("astLang3");
    var ctx = try TestModel.init(allocator, "{}{}{}{}{}{}{}{}{}{}", "astLang3");
    defer ctx.deinit();
    var brackets = [_]CharacterPair{.{ "{", "}" }};
    var config = @import("../../../../common/languages/languageConfiguration.zig").empty();
    config.brackets = &brackets;
    try ctx.languageService.registerLanguageConfiguration("astLang3", config);
    ctx.model.forceTokenization(1);

    var ids = tree.StringIdProvider.init(allocator);
    defer ids.deinit();
    var doc = try tree.parseDocument(allocator, ctx.model, ctx.languageService, &ids);
    defer doc.deinit();
    try expect23Tree(doc.root);
    try std.testing.expect(doc.root.list_height >= 2);

    var pairs = try ctx.model.getBracketPairsInRange(ctx.model.getFullModelRange());
    defer pairs.deinit();
    try std.testing.expectEqual(10, pairs.items.len);
}

test "ast: before-edit position mapper" {
    const allocator = std.testing.allocator;
    const Mapper = @import("../../../../common/model/bracketPairsTextModelPart/bracketPairsTree/beforeEditPositionMapper.zig").BeforeEditPositionMapper;
    const Edit = @import("../../../../common/model/bracketPairsTextModelPart/bracketPairsTree/beforeEditPositionMapper.zig").TextEditInfo;
    var edits = [_]Edit{Edit.init(tree.toLength(0, 4), tree.toLength(0, 7), tree.toLength(0, 2))};
    var mapper = try Mapper.init(allocator, &edits);
    defer mapper.deinit();

    const expectedOldColumns = [_]usize{ 0, 1, 2, 3, 4, 4, 7, 8, 9, 10 };
    for (expectedOldColumns, 0..) |column, i| {
        const old = mapper.getOffsetBeforeChange(tree.toLength(0, i));
        try std.testing.expectEqual(column, tree.lengthColumnCount(old));
    }
}

test "ast: node reader finds longest reusable node" {
    const allocator = std.testing.allocator;
    try TokenizationRegistry.instance.register("astLang4", Support.interface());
    defer TokenizationRegistry.instance.unregister("astLang4");
    var ctx = try TestModel.init(allocator, "{[]}", "astLang4");
    defer ctx.deinit();
    var brackets = [_]CharacterPair{ .{ "{", "}" }, .{ "[", "]" } };
    var config = @import("../../../../common/languages/languageConfiguration.zig").empty();
    config.brackets = &brackets;
    try ctx.languageService.registerLanguageConfiguration("astLang4", config);
    ctx.model.forceTokenization(1);

    var ids = tree.StringIdProvider.init(allocator);
    defer ids.deinit();
    var doc = try tree.parseDocument(allocator, ctx.model, ctx.languageService, &ids);
    defer doc.deinit();
    var reader = @import("../../../../common/model/bracketPairsTextModelPart/bracketPairsTree/nodeReader.zig").NodeReader.init(allocator, doc.root);
    defer reader.deinit();
    const cached = reader.readLongestNodeAt(0, tree.SmallImmutableSet.empty(), null);
    try std.testing.expect(cached != null);
    try std.testing.expect(cached.? == doc.root);
}

test "ast: incremental parse with an edit" {
    const allocator = std.testing.allocator;
    try TokenizationRegistry.instance.register("astLang5", Support.interface());
    defer TokenizationRegistry.instance.unregister("astLang5");
    var ctx = try TestModel.init(allocator, "{[]}", "astLang5");
    defer ctx.deinit();
    var brackets = [_]CharacterPair{ .{ "{", "}" }, .{ "[", "]" } };
    var config = @import("../../../../common/languages/languageConfiguration.zig").empty();
    config.brackets = &brackets;
    try ctx.languageService.registerLanguageConfiguration("astLang5", config);
    ctx.model.forceTokenization(1);

    var ids = tree.StringIdProvider.init(allocator);
    defer ids.deinit();
    var doc1 = try tree.parseDocument(allocator, ctx.model, ctx.languageService, &ids);
    try ctx.applyEdit(@import("../../../../common/core/range.zig").Range.init(1, 5, 1, 5), "x");
    ctx.model.forceTokenization(1);

    var edits = [_]@import("../../../../common/model/bracketPairsTextModelPart/bracketPairsTree/beforeEditPositionMapper.zig").TextEditInfo{
        @import("../../../../common/model/bracketPairsTextModelPart/bracketPairsTree/beforeEditPositionMapper.zig").TextEditInfo.init(tree.toLength(0, 4), tree.toLength(0, 4), tree.toLength(0, 1)),
    };
    var doc2 = try tree.parseDocumentIncremental(allocator, ctx.model, ctx.languageService, &edits, doc1.root, &ids);
    defer doc2.deinit();
    try std.testing.expectEqual(tree.lengthOfString("{[]}x"), doc2.root.length);
    doc1.deinit();
}

test "ast: combine sequential edits" {
    const allocator = std.testing.allocator;
    const combine = @import("../../../../common/model/bracketPairsTextModelPart/bracketPairsTree/combineTextEditInfos.zig").combineTextEditInfos;
    const Edit = @import("../../../../common/model/bracketPairsTextModelPart/bracketPairsTree/beforeEditPositionMapper.zig").TextEditInfo;

    var replace = [_]Edit{Edit.init(tree.toLength(0, 0), tree.toLength(0, 2), tree.toLength(0, 1))};
    var insert = [_]Edit{Edit.init(tree.toLength(0, 1), tree.toLength(0, 1), tree.toLength(0, 1))};
    var combined = try combine(allocator, &replace, &insert);
    defer combined.deinit();
    try std.testing.expectEqual(1, combined.items.len);
    try std.testing.expectEqual(2, tree.lengthColumnCount(combined.items[0].newLength));
    try std.testing.expectEqual(0, tree.lengthColumnCount(combined.items[0].startOffset));
}

test "ast: mapper handles edits after insert" {
    const allocator = std.testing.allocator;
    const Mapper = @import("../../../../common/model/bracketPairsTextModelPart/bracketPairsTree/beforeEditPositionMapper.zig").BeforeEditPositionMapper;
    const Edit = @import("../../../../common/model/bracketPairsTextModelPart/bracketPairsTree/beforeEditPositionMapper.zig").TextEditInfo;
    var edits = [_]Edit{Edit.init(tree.toLength(0, 2), tree.toLength(0, 2), tree.toLength(0, 2))};
    var mapper = try Mapper.init(allocator, &edits);
    defer mapper.deinit();
    try std.testing.expectEqual(0, tree.lengthColumnCount(mapper.getOffsetBeforeChange(tree.toLength(0, 0))));
    try std.testing.expectEqual(2, tree.lengthColumnCount(mapper.getOffsetBeforeChange(tree.toLength(0, 2))));
    try std.testing.expectEqual(2, tree.lengthColumnCount(mapper.getOffsetBeforeChange(tree.toLength(0, 4))));
}
