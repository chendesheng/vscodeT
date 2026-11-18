const std = @import("std");
const LanguageIdCodec = @import("../vs/editor/common/languages.zig").LanguageIdCodec;
const LanguageService = @import("../vs/editor/common/services/languageService.zig").LanguageService;
const language_configuration = @import("../vs/editor/common/languages/languageConfiguration.zig");
const CommentRule = language_configuration.CommentRule;
const LineCommentConfig = language_configuration.LineCommentConfig;
const CharacterPair = language_configuration.CharacterPair;
const FoldingRules = language_configuration.FoldingRules;

var standard_brackets = [_]CharacterPair{
    .{ "{", "}" },
    .{ "[", "]" },
    .{ "(", ")" },
};

pub const BundledLanguage = struct {
    id: []const u8,
    extensions: []const []const u8,
};

/// Languages whose grammars are bundled with textmate.zig, grouped by language
/// id so the editor can register them on the ported `LanguageService`.
pub const bundled_languages = [_]BundledLanguage{
    .{ .id = "zig", .extensions = &.{".zig"} },
    .{ .id = "json", .extensions = &.{".json"} },
    .{ .id = "jsonc", .extensions = &.{".jsonc"} },
    .{ .id = "javascript", .extensions = &.{ ".js", ".mjs", ".cjs" } },
    .{ .id = "javascriptreact", .extensions = &.{".jsx"} },
    .{ .id = "typescript", .extensions = &.{ ".ts", ".mts", ".cts" } },
    .{ .id = "typescriptreact", .extensions = &.{".tsx"} },
    .{ .id = "python", .extensions = &.{".py"} },
    .{ .id = "rust", .extensions = &.{".rs"} },
    .{ .id = "go", .extensions = &.{".go"} },
    .{ .id = "c", .extensions = &.{ ".c", ".h" } },
    .{ .id = "cpp", .extensions = &.{ ".cpp", ".cc", ".cxx", ".hpp" } },
    .{ .id = "java", .extensions = &.{".java"} },
    .{ .id = "html", .extensions = &.{ ".html", ".htm" } },
    .{ .id = "css", .extensions = &.{".css"} },
    .{ .id = "scss", .extensions = &.{".scss"} },
    .{ .id = "markdown", .extensions = &.{ ".md", ".markdown" } },
    .{ .id = "yaml", .extensions = &.{ ".yaml", ".yml" } },
    .{ .id = "toml", .extensions = &.{".toml"} },
    .{ .id = "shellscript", .extensions = &.{ ".sh", ".bash" } },
    .{ .id = "plaintext", .extensions = &.{".txt"} },
};

/// Display name for a language id. Upstream language contributions carry
/// aliases; the bundled terminal set registers only ids and extensions, so the
/// status bar and language picker use this small table for the same labels.
pub fn displayName(language_id: []const u8) []const u8 {
    const names = .{
        .{ "zig", "Zig" },
        .{ "json", "JSON" },
        .{ "jsonc", "JSON with Comments" },
        .{ "javascript", "JavaScript" },
        .{ "javascriptreact", "JavaScript React" },
        .{ "typescript", "TypeScript" },
        .{ "typescriptreact", "TypeScript React" },
        .{ "python", "Python" },
        .{ "rust", "Rust" },
        .{ "go", "Go" },
        .{ "c", "C" },
        .{ "cpp", "C++" },
        .{ "java", "Java" },
        .{ "html", "HTML" },
        .{ "css", "CSS" },
        .{ "scss", "SCSS" },
        .{ "markdown", "Markdown" },
        .{ "yaml", "YAML" },
        .{ "toml", "TOML" },
        .{ "shellscript", "Shell Script" },
        .{ "plaintext", "Plain Text" },
    };
    inline for (names) |entry| {
        if (std.mem.eql(u8, language_id, entry[0])) return entry[1];
    }
    return language_id;
}

/// Comment rules for the languages recognized by the TUI. VS Code ships these
/// in per-language `language-configuration.json` files; this is the portable
/// subset needed by the comment contributions.
pub fn commentRuleFor(language_id: []const u8) ?CommentRule {
    const slash = CommentRule{
        .lineComment = LineCommentConfig{ .comment = "//", .noIndent = null },
        .blockComment = .{ "/*", "*/" },
    };
    const hash = CommentRule{
        .lineComment = LineCommentConfig{ .comment = "#", .noIndent = null },
        .blockComment = null,
    };
    const html = CommentRule{
        .lineComment = null,
        .blockComment = .{ "<!--", "-->" },
    };

    const table = .{
        .{ "zig", CommentRule{ .lineComment = LineCommentConfig{ .comment = "//", .noIndent = null }, .blockComment = null } },
        .{ "jsonc", slash },
        .{ "javascript", slash },
        .{ "javascriptreact", slash },
        .{ "typescript", slash },
        .{ "typescriptreact", slash },
        .{ "c", slash },
        .{ "cpp", slash },
        .{ "java", slash },
        .{ "rust", slash },
        .{ "go", slash },
        .{ "scss", slash },
        .{ "css", CommentRule{ .lineComment = null, .blockComment = .{ "/*", "*/" } } },
        .{ "python", hash },
        .{ "shellscript", hash },
        .{ "yaml", hash },
        .{ "toml", hash },
        .{ "html", html },
    };

    inline for (table) |entry| {
        if (std.mem.eql(u8, entry[0], language_id)) return entry[1];
    }
    return null;
}

/// Bracket pairs shared by the languages the TUI recognizes. Language-specific
/// extra pairs (for example angle brackets) are intentionally not modeled yet.
pub fn bracketsFor(language_id: []const u8) ?[]CharacterPair {
    if (std.mem.eql(u8, language_id, "plaintext") or std.mem.eql(u8, language_id, "json")) return null;
    return &standard_brackets;
}

/// Folding rules from the upstream language configurations. Region markers
/// are regular expressions that upstream compiles per language; the TUI uses
/// indentation folding, so only the off-side flag is carried here. Python and
/// YAML use the off-side rule; the other bundled languages keep empty lines
/// with the preceding block.
pub fn foldingRulesFor(language_id: []const u8) ?FoldingRules {
    const off_side = std.mem.eql(u8, language_id, "python") or
        std.mem.eql(u8, language_id, "yaml");
    return .{ .offSide = off_side, .markers = null };
}

test "comment rules for supported languages" {
    try std.testing.expect(commentRuleFor("zig") != null);
    try std.testing.expect(commentRuleFor("python") != null);
    try std.testing.expect(commentRuleFor("html") != null);
    try std.testing.expect(commentRuleFor("plaintext") == null);
    try std.testing.expect(commentRuleFor("json") == null);
}

test "language detection by path" {
    const allocator = std.testing.allocator;
    var codec = try LanguageIdCodec.init(allocator);
    defer codec.deinit();
    var service = LanguageService.init(allocator, &codec);
    defer service.deinit();
    for (bundled_languages) |bundled| {
        try service.registerLanguage(.{ .id = bundled.id, .extensions = bundled.extensions });
    }

    try std.testing.expectEqualStrings("zig", service.guessLanguageIdByFilepathOrFirstLine("src/main.zig", null).?);
    try std.testing.expectEqualStrings("c", service.guessLanguageIdByFilepathOrFirstLine("foo.h", null).?);
    try std.testing.expectEqualStrings("typescript", service.guessLanguageIdByFilepathOrFirstLine("app.ts", null).?);
    try std.testing.expectEqualStrings("typescript", service.guessLanguageIdByFilepathOrFirstLine("APP.TS", null).?);
    // The editor falls back to plaintext when no association matches.
    try std.testing.expect(service.guessLanguageIdByFilepathOrFirstLine("Makefile", null) == null);
}
