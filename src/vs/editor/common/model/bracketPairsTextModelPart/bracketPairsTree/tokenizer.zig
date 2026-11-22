// Port of `src/vs/editor/common/model/bracketPairsTextModelPart/bracketPairsTree/tokenizer.ts`.
//
// `StringIdProvider` is the port's stable replacement for upstream's
// `DenseKeyProvider`; token lengths are UTF-8 byte lengths.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const Position = @import("../../../core/position.zig").Position;
const TextModel = @import("../../textModel.zig").TextModel;
const LanguageService = @import("../../../services/languageService.zig").LanguageService;
const length_mod = @import("./length.zig");
const Length = length_mod.Length;
const toLength = length_mod.toLength;
const lengthAdd = length_mod.lengthAdd;
const lengthDiff = length_mod.lengthDiff;
const lengthBetween = length_mod.lengthBetween;
const lengthIsZero = length_mod.lengthIsZero;
const lengthLessThan = length_mod.lengthLessThan;
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

    pub fn init(allocator: Allocator, model: *TextModel, languageService: *LanguageService, ids: *StringIdProvider, brackets: *std.StringHashMap(LanguageBrackets)) Tokenizer {
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

    pub fn deinit(self: *Tokenizer) void {
        self.tokens.deinit();
    }

    /// A tokenizer over an already tokenized stream, without a text model.
    /// Only `peek`/`read`/`skip` may be used afterwards: every field that refers
    /// to the model is left undefined on purpose.
    pub fn initFromTokens(allocator: Allocator, tokens: ArrayList(Token)) Tokenizer {
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
        self.skip(token.length);
        return token;
    }

    pub fn skip(self: *Tokenizer, length: Length) void {
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

    /// Upstream's `FastTokenizer`: an initial AST without token metadata.
    /// It scans the text with the language's bracket regexes and deliberately
    /// ignores string/comment token types. VS Code uses it for the first
    /// bracket colorization/guide pass and switches to the token-aware tree
    /// when background tokenization completes; the terminal has no
    /// whole-document background tokenizer, so this remains the guide tree.
    pub fn tokenizeFast(self: *Tokenizer) !void {
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
                if (matchAt(text, pos, text.len, defs, true)) |open| {
                    if (matchAt(text, pos, text.len, defs, false)) |close| {
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
                if (matchAt(text, pos, text.len, defs, false)) |close| {
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

    pub fn tokenize(self: *Tokenizer) !void {
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
                    // Upstream merges adjacent runs with identical metadata:
                    // identifiers are often split into several tokens, and a
                    // word bracket such as `begin` must match across them.
                    while (tokenIndex + 1 < lineTokens.getCount() and
                        lineTokens.getMetadata(tokenIndex) == lineTokens.getMetadata(tokenIndex + 1))
                    {
                        tokenIndex += 1;
                    }
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
                const token_end = if (hasTokens) @min(lineTokens.getEndOffset(tokenIndex), text.len) else text.len;

                if (matchAt(text, pos, token_end, defs, true)) |open| {
                    if (matchAt(text, pos, token_end, defs, false)) |close| {
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
                if (matchAt(text, pos, token_end, defs, false)) |close| {
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

    pub fn getBrackets(self: *Tokenizer, language: []const u8) !*LanguageBrackets {
        if (self.brackets.getPtr(language)) |b| return b;
        const config = self.languageService.getLanguageConfiguration(language) orelse self.languageService.getLanguageConfiguration(self.fallbackLanguage) orelse @import("../../../languages/languageConfiguration.zig").empty();
        try self.brackets.put(language, try buildLanguageBrackets(self.allocator, config));
        return self.brackets.getPtr(language).?;
    }

    pub fn emitBracket(self: *Tokenizer, lineNumber: usize, pos: usize, bracketText: []const u8, isOpening: bool, language: []const u8) !void {
        const start = Position.init(lineNumber, pos + 1);
        try self.emitText(start);
        const defs = try self.getBrackets(language);
        const token = (try tokenForText(self.allocator, self.ids, language, defs, bracketText, isOpening)) orelse return error.Unexpected;
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
