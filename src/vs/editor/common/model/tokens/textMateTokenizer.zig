// TextMate tokenization backed by the faithful `vscode_textmate` port.
//
// The port works in UTF-16 code units; this adapter converts token starts to
// UTF-8 byte offsets for the editor and keeps the editor's existing Dark+
// `TokenTheme`/TokenMetadata pipeline.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const tm = @import("vscode_textmate");
const tm_main = tm.main;
const tm_raw = tm.rawGrammar;
const languages = @import("../../languages.zig");
const IState = languages.IState;
const ITokenizationSupport = languages.ITokenizationSupport;
const EncodedTokenizationResult = languages.EncodedTokenizationResult;
const TokenPacked = @import("../../tokens/lineTokens.zig").TokenPacked;
const TokenMetadata = @import("../../encodedTokenAttributes.zig").TokenMetadata;
const StandardTokenType = @import("../../encodedTokenAttributes.zig").StandardTokenType;
const tokenization = @import("../../languages/supports/tokenization.zig");
const toStandardTokenType = tokenization.toStandardTokenType;
const vscode_syntax = @import("vscode-syntax");

var initialized = false;
var onig_lib: tm_main.OnigLib = undefined;
var registry: ?*tm_main.Registry = null;
var fence_grammar: ?*tm_raw.RawGrammar = null;
var loader_context: u8 = 0;

const DynamicGrammar = struct {
    language: []const u8,
    scope: []const u8,
    data: []const u8,
};
var dynamic_grammars: ?std.array_list.Managed(DynamicGrammar) = null;

fn ensureInitialized() !void {
    if (initialized) return;
    onig_lib = tm_main.OnigLib.init(std.heap.page_allocator);
    registry = try tm_main.Registry.init(std.heap.page_allocator, .{
        .onig_lib = onig_lib.interface(),
        .context = &loader_context,
        .load_grammar = loadGrammar,
    });
    initialized = true;
}

/// Registers a grammar contributed by a declarative extension. The language
/// and scope mappings take precedence over the bundled grammar table.
pub fn registerGrammar(language: []const u8, scope: []const u8, data: []const u8) void {
    if (dynamic_grammars == null) dynamic_grammars = std.array_list.Managed(DynamicGrammar).init(std.heap.page_allocator);
    const list = &dynamic_grammars.?;
    for (list.items) |*entry| {
        if (!std.mem.eql(u8, entry.language, language)) continue;
        std.heap.page_allocator.free(entry.scope);
        std.heap.page_allocator.free(entry.data);
        entry.scope = std.heap.page_allocator.dupe(u8, scope) catch return;
        entry.data = std.heap.page_allocator.dupe(u8, data) catch return;
        return;
    }
    const scope_copy = std.heap.page_allocator.dupe(u8, scope) catch return;
    const data_copy = std.heap.page_allocator.dupe(u8, data) catch return;
    const language_copy = std.heap.page_allocator.dupe(u8, language) catch return;
    list.append(.{ .language = language_copy, .scope = scope_copy, .data = data_copy }) catch {};
}

fn dynamicGrammarForLanguage(language: []const u8) ?DynamicGrammar {
    if (dynamic_grammars) |list| {
        for (list.items) |entry| {
            if (std.mem.eql(u8, entry.language, language)) return entry;
        }
    }
    return null;
}

fn dynamicGrammarForScope(scope: []const u8) ?DynamicGrammar {
    if (dynamic_grammars) |list| {
        for (list.items) |entry| {
            if (std.mem.eql(u8, entry.scope, scope)) return entry;
        }
    }
    return null;
}

fn loadGrammar(_: *anyopaque, scope: []const u8) anyerror!?*tm_raw.RawGrammar {
    const dynamic_data = if (dynamicGrammarForScope(scope)) |entry| entry.data else null;
    const data = dynamic_data orelse (vscode_syntax.dataForScope(scope) orelse return null);
    const raw = try std.heap.page_allocator.create(tm_raw.RawGrammar);
    errdefer std.heap.page_allocator.destroy(raw);
    raw.* = try tm.parseRawGrammar.parseRawGrammar(std.heap.page_allocator, data, "embedded.json");
    if (std.mem.eql(u8, scope, "text.html.markdown")) try installMarkdownCodeFences(raw);
    return raw;
}

/// Prepend the supported-language fence patterns to VS Code's markdown
/// grammar. The fence grammar is kept alive for the lifetime of the process
/// because its rule objects are linked into the markdown grammar.
fn installMarkdownCodeFences(markdown: *tm_raw.RawGrammar) !void {
    if (fence_grammar == null) {
        const fence_data = vscode_syntax.dataForScope("markdown.code.fences") orelse return;
        const raw = try std.heap.page_allocator.create(tm_raw.RawGrammar);
        raw.* = try tm.parseRawGrammar.parseRawGrammar(std.heap.page_allocator, fence_data, "embedded.json");
        fence_grammar = raw;
    }

    const fence_patterns = fence_grammar.?.root.getArray("patterns") orelse return;
    const markdown_patterns = markdown.root.getArray("patterns") orelse &.{};
    const allocator = markdown.arena.allocator();
    const combined = try allocator.alloc(tm_raw.Value, fence_patterns.len + markdown_patterns.len);
    @memcpy(combined[0..fence_patterns.len], fence_patterns);
    @memcpy(combined[fence_patterns.len..], markdown_patterns);
    try markdown.root.put(allocator, "patterns", .{ .array = combined });
}

fn grammarScope(languageId: []const u8) ?[]const u8 {
    if (dynamicGrammarForLanguage(languageId)) |entry| return entry.scope;
    if (vscode_syntax.scopeForLanguage(languageId)) |scope| return scope;
    const map = .{
        .{ "zig", "source.zig" },
        .{ "json", "source.json" },
        .{ "jsonc", "source.json.comments" },
        .{ "javascript", "source.js" },
        .{ "javascriptreact", "source.js.jsx" },
        .{ "typescript", "source.ts" },
        .{ "typescriptreact", "source.tsx" },
        .{ "python", "source.python" },
        .{ "rust", "source.rust" },
        .{ "go", "source.go" },
        .{ "c", "source.c" },
        .{ "cpp", "source.cpp" },
        .{ "java", "source.java" },
        .{ "html", "text.html.basic" },
        .{ "css", "source.css" },
        .{ "scss", "source.css.scss" },
        .{ "markdown", "text.html.markdown" },
        .{ "yaml", "source.yaml" },
        .{ "toml", "source.toml" },
        .{ "shellscript", "source.shell" },
        .{ "bash", "source.shell" },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, entry[0], languageId)) return entry[1];
    }
    return null;
}

const TextMateState = struct {
    stack: ?*tm_main.StateStack = null,
    first_line: bool,
    pub const vtable = IState.VTable{ .clone = clone, .equals = equals };

    fn clone(ctx: *anyopaque, allocator: Allocator) anyerror!IState {
        const self: *TextMateState = @ptrCast(@alignCast(ctx));
        const result = try allocator.create(TextMateState);
        result.* = .{ .stack = self.stack, .first_line = self.first_line };
        return .{ .context = result, .vtable = &vtable };
    }

    fn equals(ctx: *anyopaque, other: IState) bool {
        const self: *TextMateState = @ptrCast(@alignCast(ctx));
        if (other.vtable != &vtable) return false;
        const b: *TextMateState = @ptrCast(@alignCast(other.context));
        if (self.first_line != b.first_line) return false;
        if (self.stack == null or b.stack == null) return self.stack == null and b.stack == null;
        return self.stack.?.equals(b.stack.?);
    }
};

const TextMateSupport = struct {
    allocator: Allocator,
    grammar: *tm_main.IGrammar,
    language_id: []u8,

    pub fn deinit(self: *TextMateSupport) void {
        self.allocator.free(self.language_id);
        self.allocator.destroy(self);
    }

    fn getInitialState(ctx: *anyopaque, allocator: Allocator) anyerror!IState {
        _ = ctx;
        const state = try allocator.create(TextMateState);
        state.* = .{ .stack = null, .first_line = true };
        return .{ .context = state, .vtable = &TextMateState.vtable };
    }

    fn tokenizeEncoded(ctx: *anyopaque, allocator: Allocator, line: []const u8, hasEOL: bool, state: IState) anyerror!EncodedTokenizationResult {
        _ = hasEOL;
        const self: *TextMateSupport = @ptrCast(@alignCast(ctx));
        const input: *TextMateState = @ptrCast(@alignCast(state.context));
        const previous = if (input.first_line) null else input.stack;
        const result = try self.grammar.tokenizeLine(line, previous, 0);

        const next = try allocator.create(TextMateState);
        next.* = .{ .stack = result.rule_stack, .first_line = false };
        return .{
            .tokens = try tokensFromScopes(
                allocator,
                line,
                result.tokens,
                tokenization.getActiveTokenTheme(),
            ),
            .endState = .{ .context = next, .vtable = &TextMateState.vtable },
        };
    }

    fn dispose(ctx: *anyopaque) void {
        const self: *TextMateSupport = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    pub const vtable = ITokenizationSupport.VTable{
        .getInitialState = getInitialState,
        .tokenizeEncoded = tokenizeEncoded,
        .dispose = dispose,
    };
};

fn defaultMetadata() TokenMetadata {
    var metadata = TokenMetadata.default;
    metadata.languageId = 0;
    metadata.balancedBrackets = true;
    return metadata;
}

pub fn create(allocator: Allocator, languageId: []const u8) !?ITokenizationSupport {
    const scope = grammarScope(languageId) orelse return null;
    try ensureInitialized();
    const grammar = (try registry.?.loadGrammarWithEmbeddedLanguages(scope, 0, &.{})) orelse return null;

    const context = try allocator.create(TextMateSupport);
    context.* = .{
        .allocator = allocator,
        .grammar = grammar,
        .language_id = try allocator.dupe(u8, languageId),
    };
    return .{ .context = context, .vtable = &TextMateSupport.vtable };
}

test "textmate tokenizer: VS Code grammars and fallbacks are available" {
    if (vscode_syntax.scopeForLanguage("jsonc") == null) return error.SkipZigTest;
    try std.testing.expectEqualStrings("source.json.comments", grammarScope("jsonc").?);
    try std.testing.expectEqualStrings("source.js.jsx", grammarScope("javascriptreact").?);
    try std.testing.expect(vscode_syntax.dataForScope("source.json.comments") != null);
    try std.testing.expect(vscode_syntax.dataForScope("source.zig") != null);
    try ensureInitialized();
}

test "textmate tokenizer: zig grammar produces scopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const support = (try create(allocator, "zig")) orelse return error.NoSupport;
    defer support.dispose();
    const state = try support.getInitialState(allocator);
    const result = try support.tokenizeEncoded(allocator, "const x = 1; // hi", true, state);
    try std.testing.expect(result.tokens.len >= 2);
    try std.testing.expectEqual(StandardTokenType.Comment, result.tokens[result.tokens.len - 1].metadata.tokenType);
}

pub fn ensureTokenizer(languageId: []const u8) void {
    const registry_instance = &@import("../../tokenizationRegistry.zig").TokenizationRegistry.instance;
    if (registry_instance.get(languageId) != null) return;
    const support = create(std.heap.page_allocator, languageId) catch return orelse return;
    registry_instance.register(languageId, support) catch support.dispose();
}

test "textmate tokenizer: integrated through TextModel" {
    const TestModel = @import("../../../test/common/port/testSupport.zig").TestModel;
    var ctx = try TestModel.init(std.testing.allocator, "const x = 1; // hi", "zig");
    defer ctx.deinit();
    ctx.model.forceTokenization(1);
    var lineTokens = try ctx.model.tokenization().getLineTokens(1);
    defer lineTokens.deinit();
    var found_comment = false;
    for (0..lineTokens.getCount()) |i| {
        if (lineTokens.getStandardTokenType(i) == .Comment) found_comment = true;
    }
    try std.testing.expect(found_comment);
}

const Utf16Cursor = struct {
    text: []const u8,
    byte_index: usize = 0,
    utf16_index: usize = 0,

    fn advanceTo(self: *Utf16Cursor, target: usize) usize {
        if (target <= self.utf16_index) return self.byte_index;
        while (self.byte_index < self.text.len) {
            const byte = self.text[self.byte_index];
            const length = std.unicode.utf8ByteSequenceLength(byte) catch 1;
            const end = @min(self.byte_index + length, self.text.len);
            const codepoint = std.unicode.utf8Decode(self.text[self.byte_index..end]) catch 0xFFFD;
            const width: usize = if (codepoint > 0xFFFF) 2 else 1;
            if (self.utf16_index + width > target) break;
            self.utf16_index += width;
            self.byte_index = end;
        }
        return self.byte_index;
    }
};

fn tokensFromScopes(
    allocator: Allocator,
    line: []const u8,
    tokens: []const tm_main.IToken,
    theme: ?*tokenization.TokenTheme,
) ![]TokenPacked {
    var result = ArrayList(TokenPacked).init(allocator);
    errdefer result.deinit();
    const root_rule = if (theme) |active| active._match("") else null;
    var cursor = Utf16Cursor{ .text = line };

    for (tokens) |token| {
        if (token.end_index <= token.start_index) continue;
        const start = cursor.advanceTo(token.start_index);
        var metadata = defaultMetadata();
        for (token.scopes) |scope| {
            const token_type = toStandardTokenType(scope);
            if (token_type != .Other) metadata.tokenType = token_type;
            if (theme) |active| {
                applyThemeRule(&metadata, active, scope, root_rule.?);
            } else {
                metadata = metadataForScope(metadata, scope);
            }
        }
        if (result.items.len > 0 and result.items[result.items.len - 1].metadata == metadata) {
            // Keep the previous token's start offset; conversion extends it.
        } else {
            try result.append(.{ .endOffset = @intCast(start), .metadata = metadata });
        }
    }
    if (result.items.len == 0) try result.append(.{ .endOffset = 0, .metadata = defaultMetadata() });
    return result.toOwnedSlice();
}

fn applyThemeRule(
    metadata: *TokenMetadata,
    theme: *tokenization.TokenTheme,
    scope: []const u8,
    root_rule: *const tokenization.ThemeTrieElementRule,
) void {
    const rule = theme._match(scope);
    if (rule == root_rule) return;

    // Rules inherit their parent's colors, so only apply a color when it
    // differs from the theme default. That keeps an outer scope's color when
    // an inner scope only contributes a font style (or has no rule of its own).
    if (rule.getForeground() != root_rule.getForeground()) metadata.foreground = rule.getForeground();
    const background: u8 = @intCast(rule.getBackground());
    if (background != @as(u8, @intCast(root_rule.getBackground()))) metadata.background = background;

    const font_style = rule.getFontStyle();
    if (font_style.bold or font_style.italic or font_style.underline or font_style.strikethrough) {
        metadata.fontStyle = font_style;
    }
}

fn metadataForScope(metadata_: TokenMetadata, scope: []const u8) TokenMetadata {
    var metadata = metadata_;
    if (std.mem.startsWith(u8, scope, "comment")) {
        metadata.tokenType = .Comment;
        metadata.foreground = 5;
    } else if (std.mem.startsWith(u8, scope, "string")) {
        metadata.tokenType = .String;
        metadata.foreground = 6;
    } else if (std.mem.indexOf(u8, scope, "regexp") != null) {
        metadata.tokenType = .RegEx;
        metadata.foreground = 7;
    } else if (std.mem.startsWith(u8, scope, "invalid")) {
        metadata.foreground = 7;
    } else if (std.mem.startsWith(u8, scope, "markup.inline.raw") or
        std.mem.startsWith(u8, scope, "punctuation.definition.raw"))
    {
        // Dark+ colors inline code with the string color. Backticks have a
        // separate punctuation scope in the grammar, so map both.
        metadata.foreground = 6;
    } else if (std.mem.startsWith(u8, scope, "keyword") or std.mem.startsWith(u8, scope, "storage")) {
        metadata.foreground = 8;
    } else if (std.mem.startsWith(u8, scope, "constant")) {
        metadata.foreground = 9;
    } else if (std.mem.startsWith(u8, scope, "support.function") or
        std.mem.startsWith(u8, scope, "entity.name.function") or
        std.mem.startsWith(u8, scope, "entity.name.section"))
    {
        metadata.foreground = 10;
    } else if (std.mem.startsWith(u8, scope, "support.type") or
        std.mem.startsWith(u8, scope, "support.class") or
        std.mem.startsWith(u8, scope, "entity.name.type") or
        std.mem.startsWith(u8, scope, "entity.name.tag"))
    {
        metadata.foreground = 11;
    } else if (std.mem.startsWith(u8, scope, "variable")) {
        metadata.foreground = 12;
    }
    return metadata;
}

test "textmate tokenizer: state survives lines" {
    const TestModel = @import("../../../test/common/port/testSupport.zig").TestModel;
    var ctx = try TestModel.init(std.testing.allocator, "/* comment\nstill */ int x = 1;", "c");
    defer ctx.deinit();
    ctx.model.forceTokenization(2);

    var line1 = try ctx.model.tokenization().getLineTokens(1);
    defer line1.deinit();
    try std.testing.expectEqual(StandardTokenType.Comment, line1.getStandardTokenType(0));

    var line2 = try ctx.model.tokenization().getLineTokens(2);
    defer line2.deinit();
    try std.testing.expectEqual(StandardTokenType.Comment, line2.getStandardTokenType(0));
    try std.testing.expect(line2.getCount() > 1);
}

test "textmate tokenizer: token text and foreground stay aligned" {
    const TestModel = @import("../../../test/common/port/testSupport.zig").TestModel;
    var ctx = try TestModel.init(std.testing.allocator, "const std = @import(\"std\");", "zig");
    defer ctx.deinit();
    ctx.model.forceTokenization(1);

    var tokens = try ctx.model.tokenization().getLineTokens(1);
    defer tokens.deinit();

    var saw_const = false;
    var saw_std_variable = false;
    var saw_string = false;
    var saw_import = false;
    for (0..tokens.getCount()) |i| {
        const text = tokens.getTokenText(i);
        const fg = tokens.getForeground(i);
        if (std.mem.eql(u8, text, "const")) {
            saw_const = true;
            try std.testing.expectEqual(@as(u9, 8), fg);
        } else if (std.mem.eql(u8, text, "std")) {
            saw_std_variable = true;
            try std.testing.expectEqual(@as(u9, 12), fg);
        } else if (std.mem.eql(u8, text, "\"std\"")) {
            saw_string = true;
            try std.testing.expectEqual(@as(u9, 6), fg);
        } else if (std.mem.eql(u8, text, "@import")) {
            saw_import = true;
            try std.testing.expectEqual(@as(u9, 10), fg);
        }
    }
    try std.testing.expect(saw_const and saw_std_variable and saw_string and saw_import);
}

test "textmate tokenizer: markdown inline raw scopes use the string color" {
    const line = "a `code` span";
    const root_scopes = [_][]const u8{ "text.html.markdown", "meta.paragraph.markdown" };
    const raw_scopes = [_][]const u8{
        "text.html.markdown",
        "meta.paragraph.markdown",
        "markup.inline.raw.string.markdown",
        "punctuation.definition.raw.markdown",
    };
    const segments = [_]tm_main.IToken{
        .{ .start_index = 0, .end_index = 2, .scopes = &root_scopes },
        .{ .start_index = 2, .end_index = 8, .scopes = &raw_scopes },
        .{ .start_index = 8, .end_index = 13, .scopes = &root_scopes },
    };
    const tokens = try tokensFromScopes(std.testing.allocator, line, &segments, null);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 3), tokens.len);
    try std.testing.expectEqual(@as(u32, 0), tokens[0].endOffset);
    try std.testing.expectEqual(TokenMetadata.default.foreground, tokens[0].metadata.foreground);
    try std.testing.expectEqual(@as(u32, 2), tokens[1].endOffset);
    try std.testing.expectEqual(@as(u9, 6), tokens[1].metadata.foreground);
    try std.testing.expectEqual(@as(u32, 8), tokens[2].endOffset);
    try std.testing.expectEqual(TokenMetadata.default.foreground, tokens[2].metadata.foreground);
}

test "textmate tokenizer: markdown does not break later tokenization" {
    const TestModel = @import("../../../test/common/port/testSupport.zig").TestModel;

    var html = try TestModel.init(std.testing.allocator, "<div>hi</div>", "html");
    defer html.deinit();
    html.model.forceTokenization(1);
    var html_tokens = try html.model.tokenization().getLineTokens(1);
    defer html_tokens.deinit();
    try std.testing.expect(html_tokens.getCount() > 0);

    var markdown = try TestModel.init(std.testing.allocator, "a `code` span", "markdown");
    defer markdown.deinit();
    markdown.model.forceTokenization(1);
    var markdown_tokens = try markdown.model.tokenization().getLineTokens(1);
    defer markdown_tokens.deinit();

    var zig = try TestModel.init(std.testing.allocator, "const x = 1;", "zig");
    defer zig.deinit();
    zig.model.forceTokenization(1);
    var tokens = try zig.model.tokenization().getLineTokens(1);
    defer tokens.deinit();

    var saw_const = false;
    for (0..tokens.getCount()) |i| {
        if (std.mem.eql(u8, tokens.getTokenText(i), "const")) {
            saw_const = true;
            try std.testing.expectEqual(@as(u9, 8), tokens.getForeground(i));
        }
    }
    try std.testing.expect(saw_const);
}

test "textmate tokenizer: token cache shifts after inserting a line above" {
    const TestModel = @import("../../../test/common/port/testSupport.zig").TestModel;
    const Range = @import("../../core/range.zig").Range;

    var ctx = try TestModel.init(std.testing.allocator, "const a = 1;\n/// comment\npub fn f() void {}\n", "zig");
    defer ctx.deinit();
    ctx.model.forceTokenization(3);

    try ctx.applyEdit(Range.init(1, 1, 1, 1), "\n\n");

    var tokens = try ctx.model.tokenization().getLineTokens(4);
    defer tokens.deinit();
    var found_comment = false;
    for (0..tokens.getCount()) |i| {
        if (tokens.getStandardTokenType(i) == .Comment) found_comment = true;
    }
    try std.testing.expect(found_comment);
}
