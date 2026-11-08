// Port of `src/vs/editor/common/languages/textToHtmlTokenizer.ts`.
//
// Divergences from the TypeScript module:
//
//  * `tokenizeToString` is synchronous: `TokenizationRegistry.getOrCreate` is
//    synchronous here, so the `Promise` of the upstream signature is dropped.
//  * The codec is passed as the concrete `LanguageIdCodec` because `LineTokens`
//    of this port is bound to the concrete codec. Upstream takes the whole
//    `ILanguageService` and reads `languageIdCodec` from it.
//  * `IReducedTokenizationSupport` is a wrapper around an optional
//    `ITokenizationSupport` that falls back to the null tokenizer, instead of
//    `Omit<ITokenizationSupport, 'tokenize'>`.
//  * Offsets are byte offsets (UTF-8) rather than UTF-16 code unit offsets.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const char_code = @import("../../../base/common/charCode.zig");
const CharCode = char_code.CharCode;

const strings = @import("../../../base/common/strings.zig");

const languages = @import("../languages.zig");
const EncodedTokenizationResult = languages.EncodedTokenizationResult;
const IState = languages.IState;
const ITokenizationSupport = languages.ITokenizationSupport;
const LanguageIdCodec = languages.LanguageIdCodec;
const TokenizationRegistry = @import("../tokenizationRegistry.zig").TokenizationRegistry;

const encoded_token_attributes = @import("../encodedTokenAttributes.zig");
const LanguageId = encoded_token_attributes.LanguageId;

const line_tokens = @import("../tokens/lineTokens.zig");
const LineTokens = line_tokens.LineTokens;
const TokenPacked = line_tokens.TokenPacked;

const null_tokenize = @import("./nullTokenize.zig");
const NullState = null_tokenize.NullState;
const nullTokenizeEncoded = null_tokenize.nullTokenizeEncoded;

/// The parts of `ITokenizationSupport` that produce HTML: everything but
/// `tokenize`, which is not needed because only encoded tokens are rendered.
pub const IReducedTokenizationSupport = struct {
    support: ?ITokenizationSupport = null,

    pub fn getInitialState(self: IReducedTokenizationSupport, allocator: Allocator) !IState {
        if (self.support) |support| {
            return support.getInitialState(allocator);
        }
        return NullState;
    }

    pub fn tokenizeEncoded(
        self: IReducedTokenizationSupport,
        allocator: Allocator,
        line: []const u8,
        has_eol: bool,
        state: IState,
    ) !EncodedTokenizationResult {
        if (self.support) |support| {
            return support.tokenizeEncoded(allocator, line, has_eol, state);
        }
        return nullTokenizeEncoded(allocator, .Null, state);
    }
};

/// The tokenizer used when a language has no tokenization support.
pub const fallback = IReducedTokenizationSupport{ .support = null };

/// Tokenizes `text` and returns the HTML rendering of the tokens.
pub fn tokenizeToStringSync(
    allocator: Allocator,
    codec: *LanguageIdCodec,
    text: []const u8,
    language_id: []const u8,
) ![]u8 {
    const support = TokenizationRegistry.instance.get(language_id);
    return _tokenizeToString(allocator, text, codec, .{ .support = support });
}

/// Tokenizes `text` and returns the HTML rendering of the tokens, falling back
/// to the null tokenizer when `language_id` is null or unknown.
pub fn tokenizeToString(
    allocator: Allocator,
    codec: *LanguageIdCodec,
    text: []const u8,
    language_id: ?[]const u8,
) ![]u8 {
    if (language_id == null) {
        return _tokenizeToString(allocator, text, codec, fallback);
    }
    const support = try TokenizationRegistry.instance.getOrCreate(language_id.?);
    return _tokenizeToString(allocator, text, codec, .{ .support = support });
}

/// Renders a single line of already tokenized text as HTML.
///
/// `color_map` holds the CSS colors indexed by `ColorId`; `view_line_tokens`
/// must be inflated (see `LineTokens.inflate`).
pub fn tokenizeLineToHTML(
    allocator: Allocator,
    text: []const u8,
    view_line_tokens: *const LineTokens,
    color_map: []const []const u8,
    start_offset: usize,
    end_offset: usize,
    tab_size: usize,
    use_nbsp: bool,
) ![]u8 {
    var result = ArrayList(u8).init(allocator);
    errdefer result.deinit();

    try result.appendSlice("<div>");
    var char_index: usize = 0;
    var width: usize = 0;
    var prev_is_space = true;

    var token_index: usize = 0;
    const token_count = view_line_tokens.getCount();
    while (token_index < token_count) : (token_index += 1) {
        const token_end_index = view_line_tokens.getEndOffset(token_index);

        var part_content = ArrayList(u8).init(allocator);
        defer part_content.deinit();

        while (char_index < token_end_index and char_index < end_offset) {
            const sequence_length = std.unicode.utf8ByteSequenceLength(text[char_index]) catch 1;
            const safe_sequence_length = @min(sequence_length, text.len - char_index);
            const code_point: u21 = if (safe_sequence_length == 1)
                text[char_index]
            else
                std.unicode.utf8Decode(text[char_index..][0..safe_sequence_length]) catch 0xFFFD;

            const is_tab = code_point == CharCode.Tab;
            width += if (strings.isFullWidthCharacter(code_point)) 2 else (if (is_tab) 0 else 1);

            if (char_index < start_offset) {
                if (is_tab) {
                    const remainder = width % tab_size;
                    width += if (remainder == 0) tab_size else tab_size - remainder;
                }
                char_index += safe_sequence_length;
                continue;
            }

            switch (code_point) {
                CharCode.Tab => {
                    const remainder = width % tab_size;
                    const insert_spaces_count = if (remainder == 0) tab_size else tab_size - remainder;
                    width += insert_spaces_count;
                    var spaces_remaining = insert_spaces_count;
                    while (spaces_remaining > 0) : (spaces_remaining -= 1) {
                        if (use_nbsp and prev_is_space) {
                            try part_content.appendSlice("&#160;");
                            prev_is_space = false;
                        } else {
                            try part_content.append(' ');
                            prev_is_space = true;
                        }
                    }
                },
                CharCode.LessThan => {
                    try part_content.appendSlice("&lt;");
                    prev_is_space = false;
                },
                CharCode.GreaterThan => {
                    try part_content.appendSlice("&gt;");
                    prev_is_space = false;
                },
                CharCode.Ampersand => {
                    try part_content.appendSlice("&amp;");
                    prev_is_space = false;
                },
                CharCode.Null => {
                    try part_content.appendSlice("&#00;");
                    prev_is_space = false;
                },
                CharCode.UTF8_BOM, CharCode.LINE_SEPARATOR, CharCode.PARAGRAPH_SEPARATOR, CharCode.NEXT_LINE => {
                    try part_content.appendSlice("\u{FFFD}");
                    prev_is_space = false;
                },
                CharCode.CarriageReturn => {
                    // zero width space, because carriage return would introduce a line break
                    try part_content.appendSlice("&#8203");
                    prev_is_space = false;
                },
                CharCode.Space => {
                    if (use_nbsp and prev_is_space) {
                        try part_content.appendSlice("&#160;");
                        prev_is_space = false;
                    } else {
                        try part_content.append(' ');
                        prev_is_space = true;
                    }
                },
                else => {
                    try part_content.appendSlice(text[char_index..][0..safe_sequence_length]);
                    prev_is_space = false;
                },
            }

            char_index += safe_sequence_length;
        }

        if (token_end_index <= start_offset) {
            continue;
        }

        var inline_style = try view_line_tokens.getInlineStyle(token_index, color_map);
        defer inline_style.deinit();
        try result.appendSlice("<span style=\"");
        try result.appendSlice(inline_style.items);
        try result.appendSlice("\">");
        try result.appendSlice(part_content.items);
        try result.appendSlice("</span>");

        if (token_end_index > end_offset or char_index >= end_offset or start_offset >= end_offset) {
            break;
        }
    }

    try result.appendSlice("</div>");
    return result.toOwnedSlice();
}

/// Tokenizes every line of `text` and renders the tokens as HTML.
pub fn _tokenizeToString(
    allocator: Allocator,
    text: []const u8,
    language_id_codec: *LanguageIdCodec,
    tokenization_support: IReducedTokenizationSupport,
) ![]u8 {
    var result = ArrayList(u8).init(allocator);
    errdefer result.deinit();

    try result.appendSlice("<div class=\"monaco-tokenized-source\">");

    var lines = try strings.splitLines(allocator, text);
    defer lines.deinit();

    var current_state = try tokenization_support.getInitialState(allocator);
    for (lines.items, 0..) |line, i| {
        if (i > 0) {
            try result.appendSlice("<br/>");
        }

        const tokenization_result = try tokenization_support.tokenizeEncoded(allocator, line, true, current_state);
        defer allocator.free(tokenization_result.tokens);

        LineTokens.convertToEndOffset(tokenization_result.tokens, line.len);

        var tokens = ArrayList(TokenPacked).init(allocator);
        errdefer tokens.deinit();
        try tokens.appendSlice(tokenization_result.tokens);

        var line_text = ArrayList(u8).init(allocator);
        errdefer line_text.deinit();
        try line_text.appendSlice(line);

        var tokens_of_line = LineTokens.init(tokens, line_text, language_id_codec);
        defer tokens_of_line.deinit();

        const view_line_tokens = tokens_of_line.inflate();

        var start_offset: usize = 0;
        var j: usize = 0;
        while (j < view_line_tokens.getCount()) : (j += 1) {
            var class_name = try view_line_tokens.getClassName(j);
            defer class_name.deinit();

            const end_index = view_line_tokens.getEndOffset(j);

            try result.appendSlice("<span class=\"");
            try result.appendSlice(class_name.items);
            try result.appendSlice("\">");

            const escaped = try strings.escape(allocator, line[start_offset..end_index]);
            defer allocator.free(escaped);
            try result.appendSlice(escaped);

            try result.appendSlice("</span>");
            start_offset = end_index;
        }

        current_state = tokenization_result.endState;
    }

    try result.appendSlice("</div>");
    return result.toOwnedSlice();
}

test "IReducedTokenizationSupport: falls back to the null tokenizer" {
    const allocator = std.testing.allocator;

    const initial_state = try fallback.getInitialState(allocator);
    try std.testing.expect(initial_state.equals(NullState));

    const encoded = try fallback.tokenizeEncoded(allocator, "line", true, initial_state);
    defer allocator.free(encoded.tokens);
    try std.testing.expectEqual(@as(usize, 1), encoded.tokens.len);
    try std.testing.expectEqual(@as(u32, 0), encoded.tokens[0].endOffset);
}

test "_tokenizeToString: renders one span per line" {
    const allocator = std.testing.allocator;

    var codec = try LanguageIdCodec.init(allocator);
    defer codec.deinit();

    const html = try _tokenizeToString(allocator, "hello\nworld", &codec, fallback);
    defer allocator.free(html);

    try std.testing.expect(std.mem.startsWith(u8, html, "<div class=\"monaco-tokenized-source\">"));
    try std.testing.expect(std.mem.endsWith(u8, html, "</div>"));
    try std.testing.expect(std.mem.indexOf(u8, html, "<br/>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "world") != null);
}

test "escape is applied to the rendered source" {
    const allocator = std.testing.allocator;

    var codec = try LanguageIdCodec.init(allocator);
    defer codec.deinit();

    const html = try _tokenizeToString(allocator, "a < b & c", &codec, fallback);
    defer allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "a &lt; b &amp; c") != null);
}
