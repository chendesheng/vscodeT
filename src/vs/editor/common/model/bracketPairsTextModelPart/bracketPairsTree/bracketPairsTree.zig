const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const TextModel = @import("../../textModel.zig").TextModel;
const LanguageService = @import("../../../services/languageService.zig").LanguageService;
const LanguageConfiguration = @import("../../../languages/languageConfiguration.zig").LanguageConfiguration;
const CharacterPair = @import("../../../languages/languageConfiguration.zig").CharacterPair;
const Range = @import("../../../core/range.zig").Range;
const Position = @import("../../../core/position.zig").Position;
const BeforeEditPositionMapper = @import("./beforeEditPositionMapper.zig").BeforeEditPositionMapper;
const TextEditInfo = @import("./beforeEditPositionMapper.zig").TextEditInfo;
const NodeReader = @import("./nodeReader.zig").NodeReader;

pub const factor: u64 = 1 << 32;

/// A compact line/column length. Upper 32 bits are lines, lower 32 columns.
pub const Length = u64;

pub fn toLength(lineCount: usize, columnCount: usize) Length {
    return (@as(u64, @intCast(lineCount)) << 32) | @as(u64, @intCast(columnCount));
}

pub fn lengthZero() Length {
    return 0;
}

pub fn lengthLineCount(length: Length) usize {
    return @intCast(length >> 32);
}

/// Returns the amount of columns of the given length, assuming that it does not
/// span any line.
pub fn lengthGetColumnCountIfZeroLineCount(length: Length) usize {
    return @intCast(length);
}

pub fn lengthColumnCount(length: Length) usize {
    return @intCast(length & 0xFFFF_FFFF);
}

pub fn lengthAdd(a: Length, b: Length) Length {
    if (b >> 32 != 0) return toLength(lengthLineCount(a) + lengthLineCount(b), lengthColumnCount(b));
    return toLength(lengthLineCount(a), lengthColumnCount(a) + lengthColumnCount(b));
}

pub fn lengthOfString(text: []const u8) Length {
    var lines: usize = 0;
    var lastStart: usize = 0;
    for (text, 0..) |c, i| {
        if (c == '\n' or c == '\r') {
            lines += 1;
            lastStart = i + 1;
        }
    }
    return toLength(lines, text.len - lastStart);
}

pub fn positionToLength(position: Position) Length {
    return toLength(position.lineNumber - 1, position.column - 1);
}

pub fn lengthToPosition(length: Length) Position {
    return Position.init(lengthLineCount(length) + 1, lengthColumnCount(length) + 1);
}

pub fn lengthDiff(start: Length, end: Length) Length {
    if (lengthLineCount(start) != lengthLineCount(end)) {
        return toLength(lengthLineCount(end) - lengthLineCount(start), lengthColumnCount(end));
    }
    return toLength(0, lengthColumnCount(end) - lengthColumnCount(start));
}

pub fn lengthDiffNonNegative(start: Length, end: Length) Length {
    if (!lengthLessThan(start, end)) return 0;
    return lengthDiff(start, end);
}

pub fn lengthEquals(a: Length, b: Length) bool {
    return a == b;
}

pub fn lengthBetween(start: Position, end: Position) Length {
    if (start.lineNumber == end.lineNumber) {
        return toLength(0, end.column - start.column);
    }
    return toLength(end.lineNumber - start.lineNumber, end.column - 1);
}

pub fn lengthIsZero(length: Length) bool {
    return length == 0;
}

pub fn lengthLessThanEqual(a: Length, b: Length) bool {
    return a == b or lengthLessThan(a, b);
}

pub fn lengthLessThan(a: Length, b: Length) bool {
    if (lengthLineCount(a) != lengthLineCount(b)) return lengthLineCount(a) < lengthLineCount(b);
    return lengthColumnCount(a) < lengthColumnCount(b);
}

/// A small immutable set used for dense opening-bracket ids.
pub const SmallImmutableSet = struct {
    words: [4]u64 = .{ 0, 0, 0, 0 },

    pub fn empty() SmallImmutableSet {
        return .{};
    }

    pub fn add(self: SmallImmutableSet, id: usize) SmallImmutableSet {
        var result = self;
        const word = id / 64;
        if (word >= result.words.len) return result;
        result.words[word] |= @as(u64, 1) << @intCast(id % 64);
        return result;
    }

    pub fn addAll(self: SmallImmutableSet, other: SmallImmutableSet) SmallImmutableSet {
        var result = self;
        for (&result.words, other.words) |*a, b| a.* |= b;
        return result;
    }

    pub fn has(self: SmallImmutableSet, id: usize) bool {
        const word = id / 64;
        if (word >= self.words.len) return false;
        return (self.words[word] & (@as(u64, 1) << @intCast(id % 64))) != 0;
    }

    pub fn intersects(self: SmallImmutableSet, other: SmallImmutableSet) bool {
        for (self.words, other.words) |a, b| if ((a & b) != 0) return true;
        return false;
    }

    pub fn merge(self: SmallImmutableSet, other: SmallImmutableSet) SmallImmutableSet {
        return self.addAll(other);
    }

    pub fn isEmpty(self: SmallImmutableSet) bool {
        for (self.words) |word| if (word != 0) return false;
        return true;
    }

    pub fn eql(self: SmallImmutableSet, other: SmallImmutableSet) bool {
        return std.mem.eql(u64, &self.words, &other.words);
    }

    pub fn first(self: SmallImmutableSet) ?usize {
        for (self.words, 0..) |word, i| {
            if (word != 0) return i * 64 + @ctz(word);
        }
        return null;
    }
};

pub const TokenKind = enum { text, opening_bracket, closing_bracket };

pub const BracketInfo = struct {
    bracket_text: []const u8,
    language_id: []const u8,
    is_opening: bool,
    colorized: bool,
    range: Range,
};

pub const Token = struct {
    kind: TokenKind,
    length: Length,
    bracket_id: usize = 0,
    bracket_ids: SmallImmutableSet = .{},
    bracket: ?BracketInfo = null,
};

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

pub const ParsedDocument = struct {
    arena: std.heap.ArenaAllocator,
    root: *AstNode,

    pub fn deinit(self: *ParsedDocument) void {
        self.arena.deinit();
    }
};

pub const StringIdProvider = struct {
    allocator: Allocator,
    ids: std.StringHashMap(usize),
    next_id: usize = 0,

    pub fn init(allocator: Allocator) StringIdProvider {
        return .{ .allocator = allocator, .ids = std.StringHashMap(usize).init(allocator) };
    }

    pub fn deinit(self: *StringIdProvider) void {
        var it = self.ids.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.ids.deinit();
    }

    pub fn get(self: *StringIdProvider, value: []const u8) !usize {
        if (self.ids.get(value)) |id| return id;
        const key = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(key);
        const id = self.next_id;
        self.next_id += 1;
        try self.ids.put(key, id);
        return id;
    }
};

const BracketDef = struct {
    open: []const u8,
    close: []const u8,
    colorized: bool,
};

pub const LanguageBrackets = struct {
    defs: ArrayList(BracketDef),
    all: ArrayList([]const u8),
};

pub fn buildLanguageBrackets(allocator: Allocator, config: LanguageConfiguration) !LanguageBrackets {
    var defs = ArrayList(BracketDef).init(allocator);
    errdefer defs.deinit();
    var all = ArrayList([]const u8).init(allocator);
    errdefer all.deinit();
    if (config.brackets) |brackets| {
        for (brackets) |pair| {
            if (pair[0].len == 0 or pair[1].len == 0) continue;
            try defs.append(.{
                .open = pair[0],
                .close = pair[1],
                .colorized = isColorizedPair(config, pair[0], pair[1]),
            });
            try all.append(pair[0]);
            try all.append(pair[1]);
        }
    }
    return .{ .defs = defs, .all = all };
}

fn isColorizedPair(config: LanguageConfiguration, open: []const u8, close: []const u8) bool {
    if (config.colorizedBracketPairs) |pairs| {
        for (pairs) |pair| {
            if (std.mem.eql(u8, pair[0], open) and std.mem.eql(u8, pair[1], close)) return true;
        }
        return false;
    }
    return open.len > 0 and close.len > 0 and open[0] != '<' and close[0] != '>';
}

const Tokenizer = struct {
    allocator: Allocator,
    model: *TextModel,
    languageService: *LanguageService,
    fallbackLanguage: []const u8,
    ids: *StringIdProvider,
    brackets: *std.StringHashMap(LanguageBrackets),
    tokens: ArrayList(Token),
    cursor: Position,
    tokenIndex: usize = 0,
    tokenOffset: Length = 0,
    offset: Length = 0,

    fn init(allocator: Allocator, model: *TextModel, languageService: *LanguageService, ids: *StringIdProvider, brackets: *std.StringHashMap(LanguageBrackets)) Tokenizer {
        return .{
            .allocator = allocator,
            .model = model,
            .languageService = languageService,
            .fallbackLanguage = model.getLanguageId(),
            .ids = ids,
            .brackets = brackets,
            .tokens = ArrayList(Token).init(allocator),
            .cursor = Position.init(1, 1),
        };
    }

    fn deinit(self: *Tokenizer) void {
        self.tokens.deinit();
    }

    /// A tokenizer over an already tokenized stream, without a text model.
    /// Only `peek`/`read`/`skip` may be used afterwards: every field that refers
    /// to the model is left undefined on purpose.
    fn initFromTokens(allocator: Allocator, tokens: ArrayList(Token)) Tokenizer {
        return .{
            .allocator = allocator,
            .model = undefined,
            .languageService = undefined,
            .fallbackLanguage = "",
            .ids = undefined,
            .brackets = undefined,
            .tokens = tokens,
            .cursor = Position.init(1, 1),
        };
    }

    fn remaining(self: *Tokenizer) ?Token {
        while (self.tokenIndex < self.tokens.items.len and self.tokenOffset >= self.tokens.items[self.tokenIndex].length) {
            self.tokenOffset = 0;
            self.tokenIndex += 1;
        }
        if (self.tokenIndex >= self.tokens.items.len) return null;
        var token = self.tokens.items[self.tokenIndex];
        token.length = lengthDiff(self.tokenOffset, token.length);
        return token;
    }

    fn peek(self: *Tokenizer) ?Token {
        return self.remaining();
    }

    fn read(self: *Tokenizer) ?Token {
        const token = self.remaining() orelse return null;
        self.skip(token.length);
        return token;
    }

    fn skip(self: *Tokenizer, length: Length) void {
        var remainingLength = length;
        while (remainingLength != 0) {
            if (self.tokenIndex >= self.tokens.items.len) return;
            const tokenLength = self.tokens.items[self.tokenIndex].length;
            const available = lengthDiff(self.tokenOffset, tokenLength);
            if (lengthLessThan(available, remainingLength)) {
                remainingLength = lengthDiff(available, remainingLength);
                self.offset = lengthAdd(self.offset, available);
                self.tokenIndex += 1;
                self.tokenOffset = 0;
            } else {
                self.tokenOffset = lengthAdd(self.tokenOffset, remainingLength);
                self.offset = lengthAdd(self.offset, remainingLength);
                remainingLength = 0;
            }
        }
    }

    fn textLengthUntil(self: *Tokenizer, position: Position) Length {
        return lengthBetween(self.cursor, position);
    }

    fn emitText(self: *Tokenizer, position: Position) !void {
        const len = self.textLengthUntil(position);
        if (!lengthIsZero(len)) {
            try self.tokens.append(.{ .kind = .text, .length = len });
            self.cursor = position;
        }
    }

    /// Upstream's `FastTokenizer`: an initial AST without token metadata.
    /// It scans the text with the language's bracket regexes and deliberately
    /// ignores string/comment token types. VS Code uses it for the first
    /// bracket colorization/guide pass and switches to the token-aware tree
    /// when background tokenization completes; the terminal has no
    /// whole-document background tokenizer, so this remains the guide tree.
    fn tokenizeFast(self: *Tokenizer) !void {
        const line_count = self.model.getLineCount();
        var line_number: usize = 1;
        while (line_number <= line_count) : (line_number += 1) {
            var line_content = try self.model.getLineContent(line_number);
            defer line_content.deinit();
            const text = line_content.items;
            if (text.len == 0) continue;

            const language = self.fallbackLanguage;
            const defs = try self.getBrackets(language);
            if (defs.defs.items.len == 0) continue;

            var pos: usize = 0;
            while (pos < text.len) {
                if (matchAt(text, pos, defs, true)) |open| {
                    if (matchAt(text, pos, defs, false)) |close| {
                        if (close.len >= open.len) {
                            try self.emitBracket(line_number, pos, close, false, language);
                            pos += close.len;
                            continue;
                        }
                    }
                    try self.emitBracket(line_number, pos, open, true, language);
                    pos += open.len;
                    continue;
                }
                if (matchAt(text, pos, defs, false)) |close| {
                    try self.emitBracket(line_number, pos, close, false, language);
                    pos += close.len;
                    continue;
                }
                pos += utf8Len(text[pos..]);
            }
        }

        const end = Position.init(line_count, self.model.getLineMaxColumn(line_count));
        try self.emitText(end);
    }

    fn tokenize(self: *Tokenizer) !void {
        var lineNumber: usize = 1;
        while (lineNumber <= self.model.getLineCount()) : (lineNumber += 1) {
            var lineContent = try self.model.getLineContent(lineNumber);
            defer lineContent.deinit();
            var lineTokens = try self.model.tokenization().getLineTokens(lineNumber);
            defer lineTokens.deinit();
            const text = lineContent.items;
            if (text.len == 0) continue;

            var tokenIndex: usize = 0;
            var pos: usize = 0;
            while (pos < text.len) {
                const hasTokens = lineTokens.getCount() > 0;
                if (hasTokens) {
                    while (tokenIndex + 1 < lineTokens.getCount() and lineTokens.getEndOffset(tokenIndex) <= pos) tokenIndex += 1;
                }
                const tokenLanguage = if (hasTokens) lineTokens.getLanguageId(tokenIndex) else self.fallbackLanguage;
                const language = if (self.languageService.getLanguageConfiguration(tokenLanguage) != null) tokenLanguage else self.fallbackLanguage;
                const tokenType = if (hasTokens) lineTokens.getStandardTokenType(tokenIndex) else .Other;
                const balanced = if (hasTokens) lineTokens.getMetadata(tokenIndex).balancedBrackets else false;
                const defs = try self.getBrackets(language);
                if (tokenType != .Other or !balanced or defs.defs.items.len == 0) {
                    pos += utf8Len(text[pos..]);
                    continue;
                }

                if (matchAt(text, pos, defs, true)) |open| {
                    if (matchAt(text, pos, defs, false)) |close| {
                        if (close.len >= open.len and close.len >= open.len) {
                            try self.emitBracket(lineNumber, pos, close, false, language);
                            pos += close.len;
                            continue;
                        }
                    }
                    try self.emitBracket(lineNumber, pos, open, true, language);
                    pos += open.len;
                    continue;
                }
                if (matchAt(text, pos, defs, false)) |close| {
                    try self.emitBracket(lineNumber, pos, close, false, language);
                    pos += close.len;
                    continue;
                }
                pos += utf8Len(text[pos..]);
            }
        }

        const end = Position.init(self.model.getLineCount(), self.model.getLineMaxColumn(self.model.getLineCount()));
        try self.emitText(end);
    }

    fn getBrackets(self: *Tokenizer, language: []const u8) !*LanguageBrackets {
        if (self.brackets.getPtr(language)) |b| return b;
        const config = self.languageService.getLanguageConfiguration(language) orelse self.languageService.getLanguageConfiguration(self.fallbackLanguage) orelse @import("../../../languages/languageConfiguration.zig").empty();
        try self.brackets.put(language, try buildLanguageBrackets(self.allocator, config));
        return self.brackets.getPtr(language).?;
    }

    fn emitBracket(self: *Tokenizer, lineNumber: usize, pos: usize, bracketText: []const u8, isOpening: bool, language: []const u8) !void {
        const start = Position.init(lineNumber, pos + 1);
        try self.emitText(start);
        const range = Range.init(lineNumber, pos + 1, lineNumber, pos + 1 + bracketText.len);
        const info = BracketInfo{
            .bracket_text = bracketText,
            .language_id = language,
            .is_opening = isOpening,
            .colorized = self.colorized(language, bracketText, isOpening),
            .range = range,
        };
        var bracket_id: usize = 0;
        var bracket_ids = SmallImmutableSet.empty();
        if (isOpening) {
            const key = try std.fmt.allocPrint(self.allocator, "{s}:::{s}", .{ language, bracketText });
            defer self.allocator.free(key);
            bracket_id = try self.ids.get(key);
            bracket_ids = bracket_ids.add(bracket_id);
        } else {
            const defs = try self.getBrackets(language);
            for (defs.defs.items) |def| {
                if (!std.mem.eql(u8, def.close, bracketText)) continue;
                const key = try std.fmt.allocPrint(self.allocator, "{s}:::{s}", .{ language, def.open });
                defer self.allocator.free(key);
                const id = try self.ids.get(key);
                if (bracket_id == 0) bracket_id = id;
                bracket_ids = bracket_ids.add(id);
            }
        }
        try self.tokens.append(.{
            .kind = if (isOpening) .opening_bracket else .closing_bracket,
            .length = toLength(0, bracketText.len),
            .bracket_id = bracket_id,
            .bracket_ids = bracket_ids,
            .bracket = info,
        });
        self.cursor = Position.init(lineNumber, pos + 1 + bracketText.len);
    }

    fn colorized(self: *Tokenizer, language: []const u8, bracketText: []const u8, isOpening: bool) bool {
        const defs = self.brackets.getPtr(language) orelse return false;
        for (defs.defs.items) |def| {
            if (isOpening and std.mem.eql(u8, def.open, bracketText)) return def.colorized;
            if (!isOpening and std.mem.eql(u8, def.close, bracketText)) return def.colorized;
        }
        return false;
    }
};

pub fn matchAt(text: []const u8, pos: usize, brackets: *LanguageBrackets, opening: bool) ?[]const u8 {
    var best: ?[]const u8 = null;
    for (brackets.defs.items) |def| {
        const candidate = if (opening) def.open else def.close;
        if (candidate.len == 0 or pos + candidate.len > text.len) continue;
        if (!std.mem.eql(u8, text[pos .. pos + candidate.len], candidate)) continue;
        if (best == null or candidate.len > best.?.len) best = candidate;
    }
    return best;
}

fn utf8Len(text: []const u8) usize {
    if (text.len == 0) return 1;
    return std.unicode.utf8ByteSequenceLength(text[0]) catch 1;
}

pub fn parseDocument(allocator: Allocator, model: *TextModel, languageService: *LanguageService) !ParsedDocument {
    return parseDocumentIncremental(allocator, model, languageService, &.{}, null);
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

pub fn parseDocumentIncremental(allocator: Allocator, model: *TextModel, languageService: *LanguageService, edits: []const TextEditInfo, oldRoot: ?*AstNode) !ParsedDocument {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var ids = StringIdProvider.init(allocator);
    defer ids.deinit();
    var brackets = std.StringHashMap(LanguageBrackets).init(allocator);
    defer {
        var it = brackets.valueIterator();
        while (it.next()) |b| {
            b.defs.deinit();
            b.all.deinit();
        }
        brackets.deinit();
    }

    var tokenizer = Tokenizer.init(allocator, model, languageService, &ids, &brackets);
    defer tokenizer.deinit();
    // Terminal adaptation: with bracket-pair colorization disabled there is
    // no completed background tokenization to wait for, so use upstream's
    // fast initial tree for guides instead of the token-aware parser.
    if (!model.getOptions().bracketPairColorizationOptions.enabled) {
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
        .data = .{ .bracket = .{ .info = token.bracket.?, .bracket_ids = token.bracket_ids } },
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
