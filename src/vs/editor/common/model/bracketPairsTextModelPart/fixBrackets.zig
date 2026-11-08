// Port of `src/vs/editor/common/model/bracketPairsTextModelPart/fixBrackets.ts`.
//
// Upstream builds a `TextBufferTokenizer` over a `StaticTokenizerSource` that
// exposes a single line, parses it and then re-serializes the AST, inserting the
// expected closing bracket text wherever the parser found an unclosed opening
// bracket. This port scans the line tokens directly (the same way
// `bracketPairsTree.zig` does for a whole model) and then reuses the parser from
// the tree module, so no tokenizer source indirection is needed.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const tree = @import("./bracketPairsTree/bracketPairsTree.zig");
const AstNode = tree.AstNode;
const Length = tree.Length;
const LanguageBrackets = tree.LanguageBrackets;
const SmallImmutableSet = tree.SmallImmutableSet;
const Token = tree.Token;
const buildLanguageBrackets = tree.buildLanguageBrackets;
const lengthAdd = tree.lengthAdd;
const lengthDiff = tree.lengthDiff;
const lengthGetColumnCountIfZeroLineCount = tree.lengthGetColumnCountIfZeroLineCount;
const lengthZero = tree.lengthZero;
const matchAt = tree.matchAt;
const parseTokens = tree.parseTokens;
const toLength = tree.toLength;

const LanguageService = @import("../../services/languageService.zig").LanguageService;
const LineTokens = @import("../../tokens/lineTokens.zig").LineTokens;
const languageConfiguration = @import("../../languages/languageConfiguration.zig");
const CharacterPair = languageConfiguration.CharacterPair;

/// Re-serializes `line_content` so that every unclosed bracket gets its closing
/// bracket, and every unexpected closing bracket is dropped.
///
/// `line_tokens` are the tokens of that same line. The returned text is owned by
/// the caller.
pub fn fixBracketsInLine(
    allocator: Allocator,
    line_content: []const u8,
    line_tokens: *const LineTokens,
    language_service: *LanguageService,
    fallback_language: []const u8,
) ![]u8 {
    var scanner = try Scanner.init(allocator, line_content, fallback_language, language_service);
    defer scanner.deinit();
    try scanner.scan(line_tokens);

    for (scanner.tokens.items) |t| {
        std.debug.print("TOKEN kind={s} len={d} text={?s}\n", .{ @tagName(t.kind), t.length, if (t.bracket) |b| b.bracket_text else null });
    }
    var document = try parseTokens(allocator, scanner.takeTokens());
    defer document.deinit();

    var result = ArrayList(u8).init(allocator);
    errdefer result.deinit();
    _ = try processNode(&scanner, document.root, lengthZero(), line_content, &result);
    return result.toOwnedSlice();
}

/// The parts of the whole-document bracket tokenizer that a single line needs.
const Scanner = struct {
    allocator: Allocator,
    line_content: []const u8,
    fallbackLanguage: []const u8,
    languageService: *LanguageService,
    ids: tree.StringIdProvider,
    brackets: std.StringHashMap(LanguageBrackets),
    tokens: ArrayList(Token),

    fn init(allocator: Allocator, line_content: []const u8, fallback_language: []const u8, language_service: *LanguageService) !Scanner {
        return .{
            .allocator = allocator,
            .line_content = line_content,
            .fallbackLanguage = fallback_language,
            .languageService = language_service,
            .ids = tree.StringIdProvider.init(allocator),
            .brackets = std.StringHashMap(LanguageBrackets).init(allocator),
            .tokens = ArrayList(Token).init(allocator),
        };
    }

    fn deinit(self: *Scanner) void {
        self.ids.deinit();
        var it = self.brackets.valueIterator();
        while (it.next()) |language_brackets| {
            language_brackets.defs.deinit();
            language_brackets.all.deinit();
        }
        self.brackets.deinit();
        self.tokens.deinit();
    }

    /// Hands the token list over to the caller, which becomes responsible for it.
    fn takeTokens(self: *Scanner) ArrayList(Token) {
        const tokens = self.tokens;
        self.tokens = ArrayList(Token).init(self.allocator);
        return tokens;
    }

    fn scan(self: *Scanner, line_tokens: *const LineTokens) !void {
        const text = self.line_content;
        if (text.len == 0) return;

        var token_index: usize = 0;
        var pos: usize = 0;
        var last_pos: usize = 0;
        while (pos < text.len) {
            const has_tokens = line_tokens.getCount() > 0;
            if (has_tokens) {
                while (token_index + 1 < line_tokens.getCount() and line_tokens.getEndOffset(token_index) <= pos) token_index += 1;
            }
            const token_language = if (has_tokens) line_tokens.getLanguageId(token_index) else self.fallbackLanguage;
            const language = if (self.languageService.getLanguageConfiguration(token_language) != null) token_language else self.fallbackLanguage;
            const token_type = if (has_tokens) line_tokens.getStandardTokenType(token_index) else .Other;
            const balanced = if (has_tokens) line_tokens.getMetadata(token_index).balancedBrackets else false;
            const defs = try self.getBrackets(language);
            if (token_type != .Other or !balanced or defs.defs.items.len == 0) {
                pos += utf8Len(text[pos..]);
                continue;
            }

            if (matchAt(text, pos, defs, true)) |open| {
                if (matchAt(text, pos, defs, false)) |close| {
                    if (close.len >= open.len) {
                        try self.emitText(last_pos, pos);
                        try self.emitBracket(pos, close, false, language);
                        pos += close.len;
                        last_pos = pos;
                        continue;
                    }
                }
                try self.emitText(last_pos, pos);
                try self.emitBracket(pos, open, true, language);
                pos += open.len;
                last_pos = pos;
                continue;
            }
            if (matchAt(text, pos, defs, false)) |close| {
                try self.emitText(last_pos, pos);
                try self.emitBracket(pos, close, false, language);
                pos += close.len;
                last_pos = pos;
                continue;
            }
            pos += utf8Len(text[pos..]);
        }
        try self.emitText(last_pos, text.len);
    }

    fn emitText(self: *Scanner, from: usize, to: usize) !void {
        if (to <= from) return;
        try self.tokens.append(.{ .kind = .text, .length = toLength(0, to - from) });
    }

    fn emitBracket(self: *Scanner, pos: usize, bracket_text: []const u8, is_opening: bool, language: []const u8) !void {
        const info = tree.BracketInfo{
            .bracket_text = bracket_text,
            .language_id = language,
            .is_opening = is_opening,
            .colorized = self.isColorized(language, bracket_text, is_opening),
            .range = @import("../../core/range.zig").Range.init(1, pos + 1, 1, pos + 1 + bracket_text.len),
        };
        var bracket_id: usize = 0;
        var bracket_ids = SmallImmutableSet.empty();
        if (is_opening) {
            const key = try std.fmt.allocPrint(self.allocator, "{s}:::{s}", .{ language, bracket_text });
            defer self.allocator.free(key);
            bracket_id = try self.ids.get(key);
            bracket_ids = bracket_ids.add(bracket_id);
        } else {
            const defs = try self.getBrackets(language);
            for (defs.defs.items) |def| {
                if (!std.mem.eql(u8, def.close, bracket_text)) continue;
                const key = try std.fmt.allocPrint(self.allocator, "{s}:::{s}", .{ language, def.open });
                defer self.allocator.free(key);
                const id = try self.ids.get(key);
                if (bracket_id == 0) bracket_id = id;
                bracket_ids = bracket_ids.add(id);
            }
        }
        try self.tokens.append(.{
            .kind = if (is_opening) .opening_bracket else .closing_bracket,
            .length = toLength(0, bracket_text.len),
            .bracket_id = bracket_id,
            .bracket_ids = bracket_ids,
            .bracket = info,
        });
    }

    fn getBrackets(self: *Scanner, language: []const u8) !*LanguageBrackets {
        if (self.brackets.getPtr(language)) |b| return b;
        const config = self.languageService.getLanguageConfiguration(language) orelse
            self.languageService.getLanguageConfiguration(self.fallbackLanguage) orelse
            @import("../../languages/languageConfiguration.zig").empty();
        try self.brackets.put(language, try buildLanguageBrackets(self.allocator, config));
        return self.brackets.getPtr(language).?;
    }

    fn isColorized(self: *Scanner, language: []const u8, bracket_text: []const u8, is_opening: bool) bool {
        const defs = self.brackets.getPtr(language) orelse return false;
        for (defs.defs.items) |def| {
            if (is_opening and std.mem.eql(u8, def.open, bracket_text)) return def.colorized;
            if (!is_opening and std.mem.eql(u8, def.close, bracket_text)) return def.colorized;
        }
        return false;
    }

    /// The closing token text that matches `opening_text` in `language`, if the
    /// language declares such a bracket pair.
    fn findClosingTokenText(self: *Scanner, language: []const u8, opening_text: []const u8) !?[]const u8 {
        const defs = try self.getBrackets(language);
        for (defs.defs.items) |def| {
            if (std.mem.eql(u8, def.open, opening_text)) return def.close;
        }
        return null;
    }
};

/// Appends the repaired text of `node` to `result` and returns the offset right
/// after the node. Mirrors `processNode` in the upstream module: every branch
/// advances by the length of the node it processed.
fn processNode(
    scanner: *Scanner,
    node: *AstNode,
    offset: Length,
    line_content: []const u8,
    result: *ArrayList(u8),
) !Length {
    switch (node.data) {
        .pair => |pair| {
            var current = try processNode(scanner, pair.opening, offset, line_content, result);
            if (pair.child) |child| {
                current = try processNode(scanner, child, current, line_content, result);
            }
            if (pair.closing) |closing| {
                current = try processNode(scanner, closing, current, line_content, result);
            } else {
                const opening_info = pair.opening.data.bracket.info;
                if (try scanner.findClosingTokenText(opening_info.language_id, opening_info.bracket_text)) |closing_token_text| {
                    try result.appendSlice(closing_token_text);
                }
            }
            return current;
        },
        .invalid_bracket => {
            // remove the bracket, but keep advancing so that later siblings stay
            // aligned with the line columns
            return lengthAdd(offset, node.length);
        },
        .text, .bracket => {
            const start = lengthGetColumnCountIfZeroLineCount(offset);
            const end = lengthGetColumnCountIfZeroLineCount(lengthAdd(offset, node.length));
            if (start < end and end <= line_content.len) {
                try result.appendSlice(line_content[start..end]);
            }
            return lengthAdd(offset, node.length);
        },
        .list => |list| {
            var current = offset;
            for (list.children.items) |child| {
                current = try processNode(scanner, child, current, line_content, result);
            }
            return current;
        },
    }
}

fn utf8Len(text: []const u8) usize {
    if (text.len == 0) return 1;
    return std.unicode.utf8ByteSequenceLength(text[0]) catch 1;
}

const TokenizationRegistry = @import("../../tokenizationRegistry.zig").TokenizationRegistry;
const ITokenizationSupport = @import("../../languages.zig").ITokenizationSupport;
const IState = @import("../../languages.zig").IState;
const EncodedTokenizationResult = @import("../../languages.zig").EncodedTokenizationResult;
const NullState = @import("../../languages/nullTokenize.zig").NullState;
const TokenPacked = @import("../../tokens/lineTokens.zig").TokenPacked;
const TokenMetadata = @import("../../encodedTokenAttributes.zig").TokenMetadata;

const Support = struct {
    fn getInitialState(_: *anyopaque, _: Allocator) anyerror!IState {
        return NullState;
    }
    fn tokenizeEncoded(_: *anyopaque, allocator: Allocator, line: []const u8, _: bool, state: IState) anyerror!EncodedTokenizationResult {
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

fn fixedLine(allocator: Allocator, ctx: anytype, language_id: []const u8, line: []const u8) ![]u8 {
    var line_tokens = try ctx.model.tokenization().getLineTokens(1);
    defer line_tokens.deinit();
    return fixBracketsInLine(allocator, line, &line_tokens, ctx.languageService, language_id);
}

test "fixBracketsInLine: appends missing closing brackets" {
    const allocator = std.testing.allocator;
    const TestModel = @import("../../../test/common/port/testSupport.zig").TestModel;
    try TokenizationRegistry.instance.register("fixLang", Support.interface());
    defer TokenizationRegistry.instance.unregister("fixLang");

    var ctx = try TestModel.init(allocator, "hello (world", "fixLang");
    defer ctx.deinit();
    var brackets = [_]CharacterPair{.{ "(", ")" }};
    var config = @import("../../languages/languageConfiguration.zig").empty();
    config.brackets = &brackets;
    try ctx.languageService.registerLanguageConfiguration("fixLang", config);
    ctx.model.forceTokenization(1);

    const fixed = try fixedLine(allocator, &ctx, "fixLang", "hello (world");
    defer allocator.free(fixed);
    try std.testing.expectEqualStrings("hello (world)", fixed);
}

test "fixBracketsInLine: drops unexpected closing brackets" {
    const allocator = std.testing.allocator;
    const TestModel = @import("../../../test/common/port/testSupport.zig").TestModel;
    try TokenizationRegistry.instance.register("fixLang2", Support.interface());
    defer TokenizationRegistry.instance.unregister("fixLang2");

    var ctx = try TestModel.init(allocator, "a) b", "fixLang2");
    defer ctx.deinit();
    var brackets = [_]CharacterPair{.{ "(", ")" }};
    var config = @import("../../languages/languageConfiguration.zig").empty();
    config.brackets = &brackets;
    try ctx.languageService.registerLanguageConfiguration("fixLang2", config);
    ctx.model.forceTokenization(1);

    const fixed = try fixedLine(allocator, &ctx, "fixLang2", "a) b");
    defer allocator.free(fixed);
    try std.testing.expectEqualStrings("a b", fixed);
}

test "fixBracketsInLine: keeps the text of a balanced line" {
    const allocator = std.testing.allocator;
    const TestModel = @import("../../../test/common/port/testSupport.zig").TestModel;
    try TokenizationRegistry.instance.register("fixLang3", Support.interface());
    defer TokenizationRegistry.instance.unregister("fixLang3");

    var ctx = try TestModel.init(allocator, "(a (b) c)", "fixLang3");
    defer ctx.deinit();
    var brackets = [_]CharacterPair{.{ "(", ")" }};
    var config = @import("../../languages/languageConfiguration.zig").empty();
    config.brackets = &brackets;
    try ctx.languageService.registerLanguageConfiguration("fixLang3", config);
    ctx.model.forceTokenization(1);

    const fixed = try fixedLine(allocator, &ctx, "fixLang3", "(a (b) c)");
    defer allocator.free(fixed);
    try std.testing.expectEqualStrings("(a (b) c)", fixed);
}

test "fixBracketsInLine: closes nested opening brackets in order" {
    const allocator = std.testing.allocator;
    const TestModel = @import("../../../test/common/port/testSupport.zig").TestModel;
    try TokenizationRegistry.instance.register("fixLang4", Support.interface());
    defer TokenizationRegistry.instance.unregister("fixLang4");

    var ctx = try TestModel.init(allocator, "([1, 2", "fixLang4");
    defer ctx.deinit();
    var brackets = [_]CharacterPair{ .{ "(", ")" }, .{ "[", "]" } };
    var config = @import("../../languages/languageConfiguration.zig").empty();
    config.brackets = &brackets;
    try ctx.languageService.registerLanguageConfiguration("fixLang4", config);
    ctx.model.forceTokenization(1);

    const fixed = try fixedLine(allocator, &ctx, "fixLang4", "([1, 2");
    defer allocator.free(fixed);
    try std.testing.expectEqualStrings("([1, 2])", fixed);
}
