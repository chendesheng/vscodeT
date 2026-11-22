// Port of `src/vs/editor/common/model/bracketPairsTextModelPart/bracketPairsTree/bracketPairsTree.ts`.
//
// This file also contains the merged upstream modules `ast.ts`, `brackets.ts`,
// `parser.ts` and `tokenizer.ts`. The port merges them into one module (a
// deviation from the upstream file layout) and replaces `concat23Trees.ts`
// with a simpler `buildList`; nodes, the tokenizer/parser and the
// min-indentation cache keep the upstream behavior. `length.ts` and
// `smallImmutableSet.ts` are separate files. Colors are UTF-8 byte lengths,
// not UTF-16 code units.
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

pub const NodeKind = enum { text, bracket, pair, invalid_bracket, list };

pub const Data = union(enum) {
    text: void,
    bracket: BracketData,
    pair: PairData,
    invalid_bracket: InvalidData,
    list: ListData,
};

pub const BracketData = struct {
    info: BracketInfo,
    bracket_ids: SmallImmutableSet,
    colorized_bracket_ids: SmallImmutableSet = .{},
};

pub const PairData = struct {
    opening: *AstNode,
    child: ?*AstNode,
    closing: ?*AstNode,
};

pub const InvalidData = struct {
    info: BracketInfo,
    missing: SmallImmutableSet,
};

pub const ListData = struct {
    children: ArrayList(*AstNode),
    mutable: bool,
    cached_min_indentation: i64 = -1,
};

pub const AstNode = struct {
    kind: NodeKind,
    length: Length,
    list_height: u32,
    missing: SmallImmutableSet,
    data: Data,

    pub fn childrenLength(self: *const AstNode) usize {
        return switch (self.data) {
            .text, .bracket, .invalid_bracket => 0,
            .pair => blk: {
                const pair = self.data.pair;
                break :blk 1 + @as(usize, if (pair.child != null) 1 else 0) + @as(usize, if (pair.closing != null) 1 else 0);
            },
            .list => self.data.list.children.items.len,
        };
    }

    pub fn child(self: *const AstNode, index: usize) ?*AstNode {
        return switch (self.data) {
            .pair => |pair| switch (index) {
                0 => pair.opening,
                1 => pair.child,
                2 => pair.closing,
                else => null,
            },
            .list => |list| if (index < list.children.items.len) list.children.items[index] else null,
            else => null,
        };
    }

    pub fn clone(self: *const AstNode, allocator: Allocator) !*AstNode {
        const node = try allocator.create(AstNode);
        node.* = self.*;
        switch (self.data) {
            .text => {},
            .bracket => {},
            .invalid_bracket => {},
            .pair => |pair| {
                node.data.pair.opening = try pair.opening.clone(allocator);
                node.data.pair.child = if (pair.child) |c| try c.clone(allocator) else null;
                node.data.pair.closing = if (pair.closing) |closing| try closing.clone(allocator) else null;
            },
            .list => |list| {
                var children = ArrayList(*AstNode).init(allocator);
                for (list.children.items) |c| try children.append(try c.clone(allocator));
                node.data.list.children = children;
                node.data.list.mutable = true;
            },
        }
        return node;
    }

    pub fn canBeReused(self: *const AstNode, opened: SmallImmutableSet) bool {
        return switch (self.data) {
            .text => true,
            .invalid_bracket => false,
            .bracket => false,
            .pair => |pair| pair.closing != null and !opened.intersects(self.missing),
            .list => |list| list.children.items.len > 0 and !opened.intersects(self.missing),
        };
    }
};

/// Upstream uses `Number.MAX_SAFE_INTEGER` for "no indentation found".
pub const max_safe_integer: i64 = 9007199254740991;

/// Upstream `AstNode.computeMinIndentation`.
///
/// The minimum visible column of the first non-whitespace character in the
/// subtree's text. Text nodes that start mid-line contribute nothing for that
/// first line (the tokenizer guarantees they have no partial indentation).
/// Bracket leaf nodes contribute nothing.
pub fn computeMinIndentation(node: *AstNode, offset: Length, model: *TextModel) anyerror!i64 {
    switch (node.data) {
        .text => {
            const start_line_count = lengthLineCount(offset);
            const start_column_count = lengthColumnCount(offset);
            const start_line_number = (if (start_column_count == 0) start_line_count else start_line_count + 1) + 1;
            const end_line_number = lengthLineCount(lengthAdd(offset, node.length)) + 1;

            var result = max_safe_integer;
            var line_number = start_line_number;
            while (line_number <= end_line_number) : (line_number += 1) {
                const first_non_ws_column = try model.getLineFirstNonWhitespaceColumn(line_number);
                if (first_non_ws_column == 0) continue;

                var line_content = try model.getLineContent(line_number);
                defer line_content.deinit();
                const visible_column = CursorColumns.visibleColumnFromColumn(
                    line_content.items,
                    first_non_ws_column,
                    model.getOptions().tabSize,
                );
                result = @min(result, @as(i64, @intCast(visible_column)));
            }
            return result;
        },
        .bracket, .invalid_bracket => return max_safe_integer,
        .pair => |pair| {
            if (pair.child) |child| {
                return computeMinIndentation(child, lengthAdd(offset, pair.opening.length), model);
            }
            return max_safe_integer;
        },
        .list => |*list| {
            if (list.cached_min_indentation != -1) {
                return list.cached_min_indentation;
            }

            var min_indentation = max_safe_integer;
            var child_offset = offset;
            for (list.children.items) |child| {
                min_indentation = @min(min_indentation, try computeMinIndentation(child, child_offset, model));
                child_offset = lengthAdd(child_offset, child.length);
            }

            list.cached_min_indentation = min_indentation;
            return min_indentation;
        },
    }
}

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

const Parser = struct {
    allocator: Allocator,
    tokenizer: *Tokenizer,
    oldRoot: ?*AstNode = null,
    oldReader: ?NodeReader = null,
    positionMapper: ?BeforeEditPositionMapper = null,

    fn peek(self: *Parser) ?Token {
        return self.tokenizer.peek();
    }

    fn parseList(self: *Parser, opened: SmallImmutableSet, level: usize) !*AstNode {
        var items = ArrayList(*AstNode).init(self.allocator);
        while (true) {
            if (try self.tryReadChildFromCache(opened)) |cached| {
                try items.append(cached);
                continue;
            }
            const token = self.peek() orelse break;
            if (token.kind == .closing_bracket and token.bracket_ids.intersects(opened)) break;
            const child = try self.parseChild(opened, level + 1);
            if (child.kind == .list and child.data.list.children.items.len == 0) continue;
            try items.append(child);
        }
        if (items.items.len == 0) return try makeEmptyList(self.allocator);
        return try buildList(self.allocator, items.items);
    }

    fn tryReadChildFromCache(self: *Parser, opened: SmallImmutableSet) !?*AstNode {
        if (self.oldReader == null or self.positionMapper == null) return null;
        const maxCacheableLength = self.positionMapper.?.getDistanceToNextChange(self.tokenizer.offset);
        if (maxCacheableLength != null and lengthIsZero(maxCacheableLength.?)) return null;
        const oldOffset = self.positionMapper.?.getOffsetBeforeChange(self.tokenizer.offset);
        const cached = self.oldReader.?.readLongestNodeAt(oldOffset, opened, maxCacheableLength) orelse return null;
        self.tokenizer.skip(cached.length);
        return try cached.clone(self.allocator);
    }

    fn parseChild(self: *Parser, opened: SmallImmutableSet, level: usize) anyerror!*AstNode {
        const token = self.tokenizer.read().?;
        switch (token.kind) {
            .text => return try makeText(self.allocator, token.length),
            .closing_bracket => return try makeInvalid(self.allocator, token),
            .opening_bracket => {
                if (level > 300) return try makeText(self.allocator, token.length);
                const opening = try makeBracket(self.allocator, token);
                const child = try self.parseList(opened.merge(token.bracket_ids), level + 1);
                if (self.peek()) |next| {
                    if (next.kind == .closing_bracket and next.bracket_ids.intersects(token.bracket_ids)) {
                        _ = self.tokenizer.read();
                        const closing = try makeBracket(self.allocator, next);
                        return try makePair(self.allocator, opening, child, closing);
                    }
                }
                return try makePair(self.allocator, opening, child, null);
            },
        }
    }
};

fn buildList(allocator: Allocator, items: []*AstNode) !*AstNode {
    if (items.len == 0) return try makeEmptyList(allocator);
    if (items.len == 1) return items[0];
    if (items.len <= 3) return try makeList(allocator, items, items[0].list_height + 1);
    var groups = ArrayList(*AstNode).init(allocator);
    defer groups.deinit();
    var i: usize = 0;
    while (i < items.len) {
        const remaining = items.len - i;
        if (remaining <= 3) {
            try groups.append(try makeList(allocator, items[i..], items[i].list_height + 1));
            break;
        }
        const take: usize = if (remaining - 3 == 1) 2 else 3;
        try groups.append(try makeList(allocator, items[i .. i + take], items[i].list_height + 1));
        i += take;
    }
    return buildList(allocator, groups.items);
}

fn allocNode(allocator: Allocator) !*AstNode {
    return try allocator.create(AstNode);
}

fn makeText(allocator: Allocator, length: Length) !*AstNode {
    const node = try allocNode(allocator);
    node.* = .{ .kind = .text, .length = length, .list_height = 0, .missing = SmallImmutableSet.empty(), .data = .{ .text = {} } };
    return node;
}

fn makeBracket(allocator: Allocator, token: Token) !*AstNode {
    const node = try allocNode(allocator);
    node.* = .{
        .kind = .bracket,
        .length = token.length,
        .list_height = 0,
        .missing = SmallImmutableSet.empty(),
        .data = .{ .bracket = .{
            .info = token.bracket.?,
            .bracket_ids = token.bracket_ids,
            .colorized_bracket_ids = token.colorized_bracket_ids,
        } },
    };
    return node;
}

fn makeInvalid(allocator: Allocator, token: Token) !*AstNode {
    const node = try allocNode(allocator);
    node.* = .{
        .kind = .invalid_bracket,
        .length = token.length,
        .list_height = 0,
        .missing = token.bracket_ids,
        .data = .{ .invalid_bracket = .{ .info = token.bracket.?, .missing = token.bracket_ids } },
    };
    return node;
}

fn makePair(allocator: Allocator, opening: *AstNode, child: *AstNode, closing: ?*AstNode) !*AstNode {
    const node = try allocNode(allocator);
    var length = opening.length;
    length = lengthAdd(length, child.length);
    if (closing) |c| length = lengthAdd(length, c.length);
    node.* = .{
        .kind = .pair,
        .length = length,
        .list_height = 0,
        .missing = child.missing,
        .data = .{ .pair = .{ .opening = opening, .child = child, .closing = closing } },
    };
    return node;
}

fn makeList(allocator: Allocator, items: []*AstNode, height: u32) !*AstNode {
    var children = ArrayList(*AstNode).init(allocator);
    try children.appendSlice(items);
    var length: Length = 0;
    var missing = SmallImmutableSet.empty();
    for (items) |item| {
        length = lengthAdd(length, item.length);
        missing = missing.merge(item.missing);
    }
    const node = try allocNode(allocator);
    node.* = .{
        .kind = .list,
        .length = length,
        .list_height = height,
        .missing = missing,
        .data = .{ .list = .{ .children = children, .mutable = true } },
    };
    return node;
}

fn makeEmptyList(allocator: Allocator) !*AstNode {
    return try makeList(allocator, &[_]*AstNode{}, 0);
}

test "bracketPairsTree: lengthOfString treats CRLF as one line break" {
    try std.testing.expectEqual(toLength(1, 1), lengthOfString("a\r\nb"));
    try std.testing.expectEqual(toLength(1, 1), lengthOfString("a\rb"));
    try std.testing.expectEqual(toLength(1, 1), lengthOfString("a\nb"));
    try std.testing.expectEqual(toLength(2, 0), lengthOfString("\r\n\r\n"));
    try std.testing.expectEqual(toLength(0, 3), lengthOfString("abc"));
}
