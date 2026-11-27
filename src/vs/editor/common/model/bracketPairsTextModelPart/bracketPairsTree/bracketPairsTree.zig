// Port of `src/vs/editor/common/model/bracketPairsTextModelPart/bracketPairsTree/bracketPairsTree.ts`.
//
// Owns the two ASTs and their edit queues, as upstream does. The upstream
// modules `ast.ts`, `brackets.ts`, `length.ts`,
// `parser.ts`, `smallImmutableSet.ts` and `tokenizer.ts` live in their own
// files. Colors are UTF-8 byte lengths, not UTF-16 code units.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const TextModel = @import("../../textModel.zig").TextModel;
const LanguageConfigurationService = @import("../../../languages/languageConfigurationRegistry.zig").LanguageConfigurationService;
const CharacterPair = @import("../../../languages/languageConfiguration.zig").CharacterPair;
const Range = @import("../../../core/range.zig").Range;
const Position = @import("../../../core/position.zig").Position;
const CursorColumns = @import("../../../core/cursorColumns.zig").CursorColumns;
const BeforeEditPositionMapper = @import("./beforeEditPositionMapper.zig").BeforeEditPositionMapper;
const TextEditInfo = @import("./beforeEditPositionMapper.zig").TextEditInfo;
const NodeReader = @import("./nodeReader.zig").NodeReader;
const combineTextEditInfos = @import("./combineTextEditInfos.zig").combineTextEditInfos;
const ModelContentChangedEvent = @import("../../../textModelEvents.zig").ModelContentChangedEvent;
const ModelTokensChangedEvent = @import("../../../textModelEvents.zig").ModelTokensChangedEvent;
const Emitter = @import("../../../../../base/common/event.zig").Emitter;

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
    root: *AstNode,

    pub fn retain(self: ParsedDocument) ParsedDocument {
        self.root.refs += 1;
        return self;
    }

    pub fn deinit(self: *ParsedDocument) void {
        self.root.release();
    }
};

pub const BracketPairsTree = struct {
    allocator: Allocator,
    textModel: *TextModel,
    languageConfigurationService: *LanguageConfigurationService,
    initialAstWithoutTokens: ?ParsedDocument,
    astWithTokens: ParsedDocument,
    queuedTextEditsForInitialAstWithoutTokens: ArrayList(TextEditInfo),
    queuedTextEdits: ArrayList(TextEditInfo),
    ids: StringIdProvider,
    onDidChange: Emitter(void),

    pub fn init(allocator: Allocator, model: *TextModel, service: *LanguageConfigurationService) !BracketPairsTree {
        var ids = StringIdProvider.init(allocator);
        errdefer ids.deinit();
        const has_tokens = model.tokenization().getHasTokens();
        const initial = try parseDocumentFromTextBuffer(allocator, model, service, &.{}, null, &ids, !has_tokens);
        // Both trees initially own a reference to the same immutable root.
        // Subsequent parses share cached subtrees and copy changed paths.
        const needs_initial = !has_tokens or model.getBackgroundTokenizationState() != .Completed;
        return .{
            .allocator = allocator,
            .textModel = model,
            .languageConfigurationService = service,
            .initialAstWithoutTokens = if (needs_initial) initial.retain() else null,
            .astWithTokens = initial,
            .queuedTextEditsForInitialAstWithoutTokens = .init(allocator),
            .queuedTextEdits = .init(allocator),
            .ids = ids,
            .onDidChange = .init(allocator),
        };
    }

    pub fn deinit(self: *BracketPairsTree) void {
        if (self.initialAstWithoutTokens) |*initial| initial.deinit();
        self.astWithTokens.deinit();
        self.queuedTextEditsForInitialAstWithoutTokens.deinit();
        self.queuedTextEdits.deinit();
        self.ids.deinit();
        self.onDidChange.deinit();
    }

    pub fn handleDidChangeBackgroundTokenizationState(self: *BracketPairsTree) void {
        if (self.textModel.getBackgroundTokenizationState() != .Completed) return;
        if (self.initialAstWithoutTokens) |*initial| {
            initial.deinit();
            self.initialAstWithoutTokens = null;
            self.onDidChange.fire({}) catch {};
        }
    }

    pub fn handleDidChangeTokens(self: *BracketPairsTree, event: ModelTokensChangedEvent) !void {
        var edits = ArrayList(TextEditInfo).init(self.allocator);
        defer edits.deinit();
        for (event.ranges) |range| {
            if (range.fromLineNumber == 0 or range.toLineNumber < range.fromLineNumber) continue;
            try edits.append(.{
                .startOffset = toLength(range.fromLineNumber - 1, 0),
                .endOffset = toLength(range.toLineNumber, 0),
                .newLength = toLength(range.toLineNumber - range.fromLineNumber + 1, 0),
            });
        }
        try self.handleEdits(edits.items, true);
        if (self.initialAstWithoutTokens == null) self.onDidChange.fire({}) catch {};
    }

    pub fn handleContentChanged(self: *BracketPairsTree, change: ModelContentChangedEvent) !void {
        var edits = ArrayList(TextEditInfo).init(self.allocator);
        defer edits.deinit();
        for (change.changes.items) |c| {
            try edits.append(.{
                .startOffset = toLength(c.range.startLineNumber - 1, c.range.startColumn - 1),
                .endOffset = toLength(c.range.endLineNumber - 1, c.range.endColumn - 1),
                .newLength = lengthOfString(c.text.items()),
            });
        }
        std.mem.reverse(TextEditInfo, edits.items);
        try self.handleEdits(edits.items, false);
    }

    fn appendEdits(self: *BracketPairsTree, queue: *ArrayList(TextEditInfo), edits: []const TextEditInfo) !void {
        if (edits.len == 0) return;
        if (queue.items.len == 0) return queue.appendSlice(edits);
        const combined = try combineTextEditInfos(self.allocator, queue.items, edits);
        queue.deinit();
        queue.* = combined;
    }

    fn handleEdits(self: *BracketPairsTree, edits: []const TextEditInfo, tokenChange: bool) !void {
        try self.appendEdits(&self.queuedTextEdits, edits);
        if (self.initialAstWithoutTokens != null and !tokenChange) {
            try self.appendEdits(&self.queuedTextEditsForInitialAstWithoutTokens, edits);
        }
    }

    pub fn isDirty(self: *const BracketPairsTree) bool {
        return self.queuedTextEdits.items.len != 0 or self.queuedTextEditsForInitialAstWithoutTokens.items.len != 0;
    }

    pub fn flushQueue(self: *BracketPairsTree) !void {
        if (self.queuedTextEdits.items.len != 0) {
            const next = try parseDocumentFromTextBuffer(self.allocator, self.textModel, self.languageConfigurationService, self.queuedTextEdits.items, self.astWithTokens.root, &self.ids, false);
            self.astWithTokens.deinit();
            self.astWithTokens = next;
            self.queuedTextEdits.clearRetainingCapacity();
        }
        if (self.queuedTextEditsForInitialAstWithoutTokens.items.len != 0) {
            if (self.initialAstWithoutTokens) |*initial| {
                const next = try parseDocumentFromTextBuffer(self.allocator, self.textModel, self.languageConfigurationService, self.queuedTextEditsForInitialAstWithoutTokens.items, initial.root, &self.ids, false);
                initial.deinit();
                initial.* = next;
            }
            self.queuedTextEditsForInitialAstWithoutTokens.clearRetainingCapacity();
        }
    }

    pub fn visibleDocument(self: *const BracketPairsTree) ParsedDocument {
        return self.initialAstWithoutTokens orelse self.astWithTokens;
    }
};

/// Token state is contiguous, so the last line being accurate means every
/// earlier line is accurate too.
pub fn allLinesHaveAccurateTokens(model: *TextModel) bool {
    return model.getLineCount() == 0 or model.hasAccurateTokensForLine(model.getLineCount());
}

pub fn parseDocument(allocator: Allocator, model: *TextModel, languageConfigurationService: *LanguageConfigurationService, ids: *StringIdProvider) !ParsedDocument {
    return parseDocumentIncremental(allocator, model, languageConfigurationService, &.{}, null, ids);
}

/// Parses an already tokenized stream. Takes ownership of `tokens`.
pub fn parseTokens(allocator: Allocator, tokens: ArrayList(Token)) !ParsedDocument {
    var tokenizer = Tokenizer.initFromTokens(allocator, tokens);
    defer tokenizer.deinit();
    const region = try ast.NodeRegion.create(allocator);
    errdefer region.abort();
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    var parser = Parser{ .allocator = region.arena.allocator(), .scratch = scratch.allocator(), .region = region, .tokenizer = &tokenizer };
    const root = try parser.parseList(SmallImmutableSet.empty(), 0);
    region.commit();
    return .{ .root = root };
}

pub fn parseDocumentIncremental(allocator: Allocator, model: *TextModel, languageConfigurationService: *LanguageConfigurationService, edits: []const TextEditInfo, oldRoot: ?*AstNode, ids: *StringIdProvider) !ParsedDocument {
    return parseDocumentFromTextBuffer(allocator, model, languageConfigurationService, edits, oldRoot, ids, oldRoot == null and !model.tokenization().getHasTokens());
}

fn parseDocumentFromTextBuffer(allocator: Allocator, model: *TextModel, languageConfigurationService: *LanguageConfigurationService, edits: []const TextEditInfo, oldRoot: ?*AstNode, ids: *StringIdProvider, use_fast: bool) !ParsedDocument {
    const region = try ast.NodeRegion.create(allocator);
    errdefer region.abort();
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const a = region.arena.allocator();

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

    var tokenizer = Tokenizer.init(allocator, model, languageConfigurationService, ids, &brackets);
    defer tokenizer.deinit();
    // The initial tree can be built without syntax tokens. On an incremental
    // parse TextBufferTokenizer reads only the ranges the parser cannot reuse.
    tokenizer.enableLazy(use_fast);

    var parser = Parser{ .allocator = a, .scratch = scratch.allocator(), .region = region, .tokenizer = &tokenizer };
    if (oldRoot) |root_| {
        parser.oldRoot = root_;
        parser.oldReader = NodeReader.init(parser.scratch, root_);
        parser.positionMapper = try BeforeEditPositionMapper.init(parser.scratch, edits);
    }
    const root = try parser.parseList(SmallImmutableSet.empty(), 0);
    region.commit();
    return .{ .root = root };
}

test "bracketPairsTree: lengthOfString treats CRLF as one line break" {
    try std.testing.expectEqual(toLength(1, 1), lengthOfString("a\r\nb"));
    try std.testing.expectEqual(toLength(1, 1), lengthOfString("a\rb"));
    try std.testing.expectEqual(toLength(1, 1), lengthOfString("a\nb"));
    try std.testing.expectEqual(toLength(2, 0), lengthOfString("\r\n\r\n"));
    try std.testing.expectEqual(toLength(0, 3), lengthOfString("abc"));
}
