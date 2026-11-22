// Port of `src/vs/editor/common/model/bracketPairsTextModelPart/bracketPairsTree/bracketPairsTree.ts`.
//
// The port keeps the bracket-pair tree, document parsing and query logic in
// this file; the upstream modules `ast.ts`, `brackets.ts`, `length.ts`,
// `parser.ts`, `smallImmutableSet.ts` and `tokenizer.ts` live in their own
// files. `concat23Trees.ts` is replaced by the parser's `buildList`. Colors
// are UTF-8 byte lengths, not UTF-16 code units.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const TextModel = @import("../../textModel.zig").TextModel;
const LanguageService = @import("../../../services/languageService.zig").LanguageService;
const LanguageConfiguration = @import("../../../languages/languageConfiguration.zig").LanguageConfiguration;
const CharacterPair = @import("../../../languages/languageConfiguration.zig").CharacterPair;
const Range = @import("../../../core/range.zig").Range;
const Position = @import("../../../core/position.zig").Position;
const CursorColumns = @import("../../../core/cursorColumns.zig").CursorColumns;
const BeforeEditPositionMapper = @import("./beforeEditPositionMapper.zig").BeforeEditPositionMapper;
const TextEditInfo = @import("./beforeEditPositionMapper.zig").TextEditInfo;
const NodeReader = @import("./nodeReader.zig").NodeReader;

const length_mod = @import("./length.zig");
pub const factor = length_mod.factor;
pub const Length = length_mod.Length;
pub const toLength = length_mod.toLength;
pub const lengthZero = length_mod.lengthZero;
pub const lengthLineCount = length_mod.lengthLineCount;
pub const lengthGetColumnCountIfZeroLineCount = length_mod.lengthGetColumnCountIfZeroLineCount;
pub const lengthColumnCount = length_mod.lengthColumnCount;
pub const lengthAdd = length_mod.lengthAdd;
pub const lengthOfString = length_mod.lengthOfString;
pub const positionToLength = length_mod.positionToLength;
pub const LengthObj = length_mod.LengthObj;
pub const lengthToObj = length_mod.lengthToObj;
pub const lengthToPosition = length_mod.lengthToPosition;
pub const lengthsToRange = length_mod.lengthsToRange;
pub const lengthDiff = length_mod.lengthDiff;
pub const lengthDiffNonNegative = length_mod.lengthDiffNonNegative;
pub const lengthEquals = length_mod.lengthEquals;
pub const lengthBetween = length_mod.lengthBetween;
pub const lengthIsZero = length_mod.lengthIsZero;
pub const lengthLessThanEqual = length_mod.lengthLessThanEqual;
pub const lengthLessThan = length_mod.lengthLessThan;

const set_mod = @import("./smallImmutableSet.zig");
pub const SmallImmutableSet = set_mod.SmallImmutableSet;

const brackets_mod = @import("./brackets.zig");
pub const LanguageBrackets = brackets_mod.LanguageBrackets;
pub const buildLanguageBrackets = brackets_mod.buildLanguageBrackets;
pub const matchAt = brackets_mod.matchAt;

const tokenizer_mod = @import("./tokenizer.zig");
const Tokenizer = tokenizer_mod.Tokenizer;
pub const StringIdProvider = tokenizer_mod.StringIdProvider;
pub const TokenKind = tokenizer_mod.TokenKind;
pub const BracketInfo = tokenizer_mod.BracketInfo;
pub const Token = tokenizer_mod.Token;

const ast = @import("./ast.zig");
pub const NodeKind = ast.NodeKind;
pub const Data = ast.Data;
pub const BracketData = ast.BracketData;
pub const PairData = ast.PairData;
pub const InvalidData = ast.InvalidData;
pub const ListData = ast.ListData;
pub const AstNode = ast.AstNode;
pub const max_safe_integer = ast.max_safe_integer;
pub const computeMinIndentation = ast.computeMinIndentation;
pub const makeText = ast.makeText;
pub const makeBracket = ast.makeBracket;
pub const makeInvalid = ast.makeInvalid;
pub const makePair = ast.makePair;
pub const makeList = ast.makeList;
pub const makeEmptyList = ast.makeEmptyList;

const Parser = @import("./parser.zig").Parser;

pub const ParsedDocument = struct {
    arena: std.heap.ArenaAllocator,
    root: *AstNode,

    pub fn deinit(self: *ParsedDocument) void {
        self.arena.deinit();
    }
};

/// Terminal adaptation: at or below this many lines the bracket AST may
/// tokenize the whole document so its first pass already respects
/// string/comment tokens. Above it the view defers the initial build and the
/// parser starts from upstream's fast, token-agnostic tree until the
/// background tokenizer completes.
pub const eager_build_line_count: usize = 500;

/// Token state is contiguous, so the last line being accurate means every
/// earlier line is accurate too.
pub fn allLinesHaveAccurateTokens(model: *TextModel) bool {
    return model.getLineCount() == 0 or model.hasAccurateTokensForLine(model.getLineCount());
}

pub fn parseDocument(allocator: Allocator, model: *TextModel, languageService: *LanguageService, ids: *StringIdProvider) !ParsedDocument {
    return parseDocumentIncremental(allocator, model, languageService, &.{}, null, ids);
}

/// Parses an already tokenized stream. Takes ownership of `tokens`.
pub fn parseTokens(allocator: Allocator, tokens: ArrayList(Token)) !ParsedDocument {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var tokenizer = Tokenizer.initFromTokens(allocator, tokens);
    defer tokenizer.deinit();
    var parser = Parser{ .allocator = arena.allocator(), .tokenizer = &tokenizer };
    const root = try parser.parseList(SmallImmutableSet.empty(), 0);
    return .{ .arena = arena, .root = root };
}

pub fn parseDocumentIncremental(allocator: Allocator, model: *TextModel, languageService: *LanguageService, edits: []const TextEditInfo, oldRoot: ?*AstNode, ids: *StringIdProvider) !ParsedDocument {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    // Bracket ids must stay stable for the lifetime of the tree: cached nodes
    // carry ids and `canBeReused` compares them against freshly tokenized text.
    var brackets = std.StringHashMap(LanguageBrackets).init(allocator);
    defer {
        var it = brackets.valueIterator();
        while (it.next()) |b| {
            b.defs.deinit();
            b.all.deinit();
        }
        brackets.deinit();
    }

    var tokenizer = Tokenizer.init(allocator, model, languageService, ids, &brackets);
    defer tokenizer.deinit();
    // Terminal adaptation: colorization consumes token types. The fast tree is
    // only used for the *initial* build while tokens are incomplete; once an
    // AST exists, incremental parses stay token-aware (missing tokens for the
    // edited lines simply act as "balanced" until their token update is
    // queued). Small documents are tokenized eagerly by the model, so their
    // first tree already sees accurate tokens. With colorization off there is
    // no token consumer beyond guides, so keep the fast tree.
    const use_fast = !model.getOptions().bracketPairColorizationOptions.enabled or
        (oldRoot == null and
            !allLinesHaveAccurateTokens(model) and
            model.getBackgroundTokenizationState() != .Completed);
    if (use_fast) {
        try tokenizer.tokenizeFast();
    } else {
        try tokenizer.tokenize();
    }

    var parser = Parser{ .allocator = a, .tokenizer = &tokenizer };
    if (oldRoot) |root_| {
        parser.oldRoot = root_;
        parser.oldReader = NodeReader.init(a, root_);
        parser.positionMapper = try BeforeEditPositionMapper.init(a, edits);
    }
    const root = try parser.parseList(SmallImmutableSet.empty(), 0);
    return .{ .arena = arena, .root = root };
}

test "bracketPairsTree: lengthOfString treats CRLF as one line break" {
    try std.testing.expectEqual(toLength(1, 1), lengthOfString("a\r\nb"));
    try std.testing.expectEqual(toLength(1, 1), lengthOfString("a\rb"));
    try std.testing.expectEqual(toLength(1, 1), lengthOfString("a\nb"));
    try std.testing.expectEqual(toLength(2, 0), lengthOfString("\r\n\r\n"));
    try std.testing.expectEqual(toLength(0, 3), lengthOfString("abc"));
}
