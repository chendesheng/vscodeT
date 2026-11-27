// Port of `src/vs/editor/common/model/bracketPairsTextModelPart/bracketPairsTree/tokenizer.ts`.
//
// `StringIdProvider` is the port's stable replacement for upstream's
// `DenseKeyProvider`; token lengths are UTF-8 byte lengths.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const Position = @import("../../../core/position.zig").Position;
const TextModel = @import("../../textModel.zig").TextModel;
const LanguageConfigurationService = @import("../../../languages/languageConfigurationRegistry.zig").LanguageConfigurationService;
const NULL_LANGUAGE_ID = @import("../../../languages.zig").NULL_LANGUAGE_ID;
const length_mod = @import("./length.zig");
const Length = length_mod.Length;
const toLength = length_mod.toLength;
const lengthAdd = length_mod.lengthAdd;
const lengthDiff = length_mod.lengthDiff;
const lengthBetween = length_mod.lengthBetween;
const lengthIsZero = length_mod.lengthIsZero;
const lengthLessThan = length_mod.lengthLessThan;
const lengthToPosition = length_mod.lengthToPosition;
const set_mod = @import("./smallImmutableSet.zig");
const SmallImmutableSet = set_mod.SmallImmutableSet;
const brackets_mod = @import("./brackets.zig");
const LanguageBrackets = brackets_mod.LanguageBrackets;
const buildLanguageBrackets = brackets_mod.buildLanguageBrackets;
const matchAt = brackets_mod.matchAt;

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

pub const TokenKind = enum { text, opening_bracket, closing_bracket };

pub const BracketInfo = struct {
    bracket_text: []const u8,
    language_id: []const u8,
    is_opening: bool,
    colorized: bool,
};

pub const Token = struct {
    kind: TokenKind,
    length: Length,
    bracket_id: usize = 0,
    bracket_ids: SmallImmutableSet = .{},
    /// Openings this closing bracket closes *and* colorizes (upstream
    /// `ClosingBracketKind.openingColorized`).
    colorized_bracket_ids: SmallImmutableSet = .{},
    bracket: ?BracketInfo = null,
};

pub const Tokenizer = struct {
    const CachedToken = struct {
        language: []const u8,
        text: []const u8,
        opening: bool,
        token: Token,
    };

    allocator: Allocator,
    model: *TextModel,
    languageConfigurationService: *LanguageConfigurationService,
    ids: *StringIdProvider,
    brackets: *std.StringHashMap(LanguageBrackets),
    tokens: ArrayList(Token),
    cursor: Position,
    tokenIndex: usize = 0,
    tokenOffset: Length = 0,
    offset: Length = 0,
    lazy: bool = false,
    lazy_fast: bool = false,
    cached_tokens: std.ArrayList(CachedToken) = .empty,

    pub fn init(allocator: Allocator, model: *TextModel, languageConfigurationService: *LanguageConfigurationService, ids: *StringIdProvider, brackets: *std.StringHashMap(LanguageBrackets)) Tokenizer {
        return .{
            .allocator = allocator,
            .model = model,
            .languageConfigurationService = languageConfigurationService,
            .ids = ids,
            .brackets = brackets,
            .tokens = ArrayList(Token).init(allocator),
            .cursor = Position.init(1, 1),
        };
    }

    pub fn deinit(self: *Tokenizer) void {
        self.tokens.deinit();
        self.cached_tokens.deinit(self.allocator);
    }

    /// A tokenizer over an already tokenized stream, without a text model.
    /// Only `peek`/`read`/`skip` may be used afterwards: every field that refers
    /// to the model is left undefined on purpose.
    pub fn initFromTokens(allocator: Allocator, tokens: ArrayList(Token)) Tokenizer {
        return .{
            .allocator = allocator,
            .model = undefined,
            .languageConfigurationService = undefined,
            .ids = undefined,
            .brackets = undefined,
            .tokens = tokens,
            .cursor = Position.init(1, 1),
        };
    }

    pub fn remaining(self: *Tokenizer) ?Token {
        while (self.tokenIndex < self.tokens.items.len and self.tokenOffset >= self.tokens.items[self.tokenIndex].length) {
            self.tokenOffset = 0;
            self.tokenIndex += 1;
        }
        if (self.tokenIndex >= self.tokens.items.len) return null;
        var token = self.tokens.items[self.tokenIndex];
        token.length = lengthDiff(self.tokenOffset, token.length);
        return token;
    }

    pub fn peek(self: *Tokenizer) ?Token {
        return self.remaining();
    }

    pub fn read(self: *Tokenizer) ?Token {
        const token = self.remaining() orelse return null;
        self.advanceBuffered(token.length);
        return token;
    }

    pub fn skip(self: *Tokenizer, length: Length) void {
        if (self.lazy) {
            // Upstream TextBufferTokenizer.skip seeks directly to the new
            // line/column; cached AST subtrees are never tokenized.
            self.offset = lengthAdd(self.offset, length);
            self.tokens.clearRetainingCapacity();
            self.tokenIndex = 0;
            self.tokenOffset = 0;
            return;
        }
        self.advanceBuffered(length);
    }

    fn advanceBuffered(self: *Tokenizer, length: Length) void {
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

    /// The parser asks for tokens only when no old AST node can be reused.
    /// Keep a small line-local buffer, not a whole-document token array.
    pub fn enableLazy(self: *Tokenizer, fast: bool) void {
        self.lazy = true;
        self.lazy_fast = fast;
    }

    pub fn prepare(self: *Tokenizer) !void {
        if (!self.lazy or self.remaining() != null) return;
        self.tokens.clearRetainingCapacity();
        self.tokenIndex = 0;
        self.tokenOffset = 0;
        self.cursor = lengthToPosition(self.offset);
        const line_count = self.model.getLineCount();
        var line = self.cursor.lineNumber;
        var start = self.cursor.column - 1;
        while (line <= line_count) : (line += 1) {
            try self.scanLine(line, start, self.lazy_fast);
            if (self.tokens.items.len != 0) return;
            start = 0;
        }
        try self.emitText(Position.init(line_count, self.model.getLineMaxColumn(line_count)));
    }

    pub fn textLengthUntil(self: *Tokenizer, position: Position) Length {
        return lengthBetween(self.cursor, position);
    }

    pub fn emitText(self: *Tokenizer, position: Position) !void {
        const len = self.textLengthUntil(position);
        if (!lengthIsZero(len)) {
            try self.tokens.append(.{ .kind = .text, .length = len });
            self.cursor = position;
        }
    }

    /// Upstream's FastTokenizer and TextBufferTokenizer share bracket lookup
    /// and matching. The eager methods remain available for tokenizer tests.
    pub fn tokenizeFast(self: *Tokenizer) !void {
        try self.tokenizeAll(true);
    }

    pub fn tokenize(self: *Tokenizer) !void {
        try self.tokenizeAll(false);
    }

    fn tokenizeAll(self: *Tokenizer, fast: bool) !void {
        const line_count = self.model.getLineCount();
        for (1..line_count + 1) |line| try self.scanLine(line, 0, fast);
        try self.emitText(Position.init(line_count, self.model.getLineMaxColumn(line_count)));
    }

    fn scanLine(self: *Tokenizer, line_number: usize, start: usize, fast: bool) !void {
        // TextBufferTokenizer's default token covers the entire line with
        // balanced-bracket metadata. Scan its borrowed content directly
        // rather than allocating the identical synthetic token and line copy.
        if (fast or self.model.tokenization().hasDefaultTokens(line_number)) {
            const text = try self.model.borrowLineContent(line_number);
            try self.scanRange(line_number, text, @min(start, text.len), text.len, self.model.getLanguageId());
            return;
        }

        var line_tokens = try self.model.tokenization().getLineTokens(line_number);
        defer line_tokens.deinit();
        const text = line_tokens.getLineContent();
        var pos = @min(start, text.len);
        var token_index: usize = 0;
        while (pos < text.len) {
            const has_tokens = line_tokens.getCount() > 0;
            if (has_tokens) {
                while (token_index + 1 < line_tokens.getCount() and line_tokens.getEndOffset(token_index) <= pos) token_index += 1;
                // Merge adjacent metadata-identical runs like upstream.
                while (token_index + 1 < line_tokens.getCount() and
                    line_tokens.getMetadata(token_index) == line_tokens.getMetadata(token_index + 1))
                {
                    token_index += 1;
                }
            }
            const token_end = if (has_tokens) @min(line_tokens.getEndOffset(token_index), text.len) else text.len;
            if (token_end <= pos) break;
            if (has_tokens and line_tokens.getStandardTokenType(token_index) == .Other and line_tokens.getMetadata(token_index).balancedBrackets) {
                const token_language = line_tokens.getLanguageId(token_index);
                const language = if (std.mem.eql(u8, token_language, NULL_LANGUAGE_ID)) self.model.getLanguageId() else token_language;
                try self.scanRange(line_number, text, pos, token_end, language);
            }
            pos = token_end;
        }
    }

    fn scanRange(self: *Tokenizer, line_number: usize, text: []const u8, start: usize, end: usize, language: []const u8) !void {
        const defs = try self.getBrackets(language);
        if (defs.defs.items.len == 0) return;
        var pos = start;
        while (pos < end) {
            if (defs.start_bytes.isSet(std.ascii.toLower(text[pos]))) {
                const open = matchAt(text, pos, end, defs, true);
                const close = matchAt(text, pos, end, defs, false);
                if (close != null and (open == null or close.?.len >= open.?.len)) {
                    try self.emitBracket(line_number, pos, close.?, false, language);
                    pos += close.?.len;
                    continue;
                }
                if (open) |bracket| {
                    try self.emitBracket(line_number, pos, bracket, true, language);
                    pos += bracket.len;
                    continue;
                }
            }
            pos += utf8Len(text[pos..]);
        }
    }

    pub fn getBrackets(self: *Tokenizer, language: []const u8) !*LanguageBrackets {
        if (self.brackets.getPtr(language)) |b| return b;
        const resolved = self.languageConfigurationService.resolved(language);
        const config = if (resolved) |value| value.underlyingConfig else @import("../../../languages/languageConfiguration.zig").empty();
        try self.brackets.put(language, try buildLanguageBrackets(self.allocator, config));
        return self.brackets.getPtr(language).?;
    }

    /// Like upstream BracketTokens, construct metadata once per distinct
    /// language/delimiter rather than formatting and allocating its dense key
    /// for each bracket in the document.
    fn cachedToken(self: *Tokenizer, language: []const u8, defs: *LanguageBrackets, text: []const u8, opening: bool) !Token {
        for (self.cached_tokens.items) |entry| {
            if (entry.opening == opening and std.mem.eql(u8, entry.text, text) and std.mem.eql(u8, entry.language, language)) return entry.token;
        }
        const token = (try tokenForText(self.allocator, self.ids, language, defs, text, opening)) orelse return error.Unexpected;
        try self.cached_tokens.append(self.allocator, .{ .language = language, .text = text, .opening = opening, .token = token });
        return token;
    }

    pub fn emitBracket(self: *Tokenizer, lineNumber: usize, pos: usize, bracketText: []const u8, isOpening: bool, language: []const u8) !void {
        const start = Position.init(lineNumber, pos + 1);
        try self.emitText(start);
        const defs = try self.getBrackets(language);
        const token = try self.cachedToken(language, defs, bracketText, isOpening);
        try self.tokens.append(token);
        self.cursor = Position.init(lineNumber, pos + 1 + bracketText.len);
    }
};

/// Upstream `BracketTokens.getToken`: builds an opening or closing token for
/// canonical bracket text. `prefer_opening` disambiguates text configured both
/// ways; without it closing wins (upstream's map overwrites openings).
pub fn tokenForText(
    allocator: Allocator,
    ids: *StringIdProvider,
    language: []const u8,
    brackets: *LanguageBrackets,
    text: []const u8,
    prefer_opening: ?bool,
) !?Token {
    if (prefer_opening == null or prefer_opening.? == false) {
        var bracket_id: usize = 0;
        var bracket_ids = SmallImmutableSet.empty();
        var colorized_ids = SmallImmutableSet.empty();
        var colorized = false;
        var found = false;
        for (brackets.defs.items) |def| {
            if (!std.mem.eql(u8, def.close, text)) continue;
            const key = try std.fmt.allocPrint(allocator, "{s}:::{s}", .{ language, def.open });
            defer allocator.free(key);
            const id = try ids.get(key);
            if (!found) bracket_id = id;
            found = true;
            bracket_ids = try bracket_ids.add(id);
            colorized = colorized or def.colorized;
            if (def.colorized) colorized_ids = try colorized_ids.add(id);
        }
        if (found) {
            return Token{
                .kind = .closing_bracket,
                .length = toLength(0, text.len),
                .bracket_id = bracket_id,
                .bracket_ids = bracket_ids,
                .colorized_bracket_ids = colorized_ids,
                .bracket = .{
                    .bracket_text = text,
                    .language_id = language,
                    .is_opening = false,
                    .colorized = colorized,
                },
            };
        }
    }

    if (prefer_opening == null or prefer_opening.? == true) {
        for (brackets.defs.items) |def| {
            if (!std.mem.eql(u8, def.open, text)) continue;
            const key = try std.fmt.allocPrint(allocator, "{s}:::{s}", .{ language, text });
            defer allocator.free(key);
            const id = try ids.get(key);
            return Token{
                .kind = .opening_bracket,
                .length = toLength(0, text.len),
                .bracket_id = id,
                .bracket_ids = try SmallImmutableSet.empty().add(id),
                .colorized_bracket_ids = if (def.colorized) try SmallImmutableSet.empty().add(id) else SmallImmutableSet.empty(),
                .bracket = .{
                    .bracket_text = text,
                    .language_id = language,
                    .is_opening = true,
                    .colorized = def.colorized,
                },
            };
        }
    }
    return null;
}

fn utf8Len(text: []const u8) usize {
    if (text.len == 0) return 1;
    return std.unicode.utf8ByteSequenceLength(text[0]) catch 1;
}
