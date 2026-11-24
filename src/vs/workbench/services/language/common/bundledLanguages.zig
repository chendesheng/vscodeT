//! Terminal bundled language subset.
//!
//! Upstream ships each built-in language as a built-in extension contribution
//! (`languages` extension point + `language-configuration.json`). The terminal
//! has no extension host for built-ins, so this module declares the bundled
//! grammars and the portable comment/bracket/folding data they need. It is a
//! Zig adaptation, not a port of one upstream file; the registration path goes
//! through the ported `WorkbenchLanguageService`/`LanguageService`.
const std = @import("std");
const vscode_syntax = @import("vscode-syntax");
const LanguageIdCodec = @import("../../../../editor/common/languages.zig").LanguageIdCodec;
const LanguageService = @import("../../../../editor/common/services/languageService.zig").LanguageService;
const language_configuration = @import("../../../../editor/common/languages/languageConfiguration.zig");
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
    /// Display aliases. Upstream language contributions carry these; the
    /// terminal bundled set declares them next to the grammar id so the
    /// language picker and status bar use the same names.
    names: []const []const u8,
    extensions: []const []const u8,
};

/// Languages whose grammars are bundled with textmate.zig, grouped by language
/// id so the editor can register them on the ported `LanguageService`.
pub const bundled_languages = [_]BundledLanguage{
    .{ .id = "zig", .names = &.{"Zig"}, .extensions = &.{".zig"} },
    .{ .id = "json", .names = &.{"JSON"}, .extensions = &.{".json"} },
    .{ .id = "jsonc", .names = &.{"JSON with Comments"}, .extensions = &.{".jsonc"} },
    .{ .id = "javascript", .names = &.{"JavaScript"}, .extensions = &.{ ".js", ".mjs", ".cjs" } },
    .{ .id = "javascriptreact", .names = &.{"JavaScript React"}, .extensions = &.{".jsx"} },
    .{ .id = "typescript", .names = &.{"TypeScript"}, .extensions = &.{ ".ts", ".mts", ".cts" } },
    .{ .id = "typescriptreact", .names = &.{"TypeScript React"}, .extensions = &.{".tsx"} },
    .{ .id = "python", .names = &.{"Python"}, .extensions = &.{".py"} },
    .{ .id = "rust", .names = &.{"Rust"}, .extensions = &.{".rs"} },
    .{ .id = "go", .names = &.{"Go"}, .extensions = &.{".go"} },
    .{ .id = "c", .names = &.{"C"}, .extensions = &.{ ".c", ".h" } },
    .{ .id = "cpp", .names = &.{"C++"}, .extensions = &.{ ".cpp", ".cc", ".cxx", ".hpp" } },
    .{ .id = "java", .names = &.{"Java"}, .extensions = &.{".java"} },
    .{ .id = "html", .names = &.{"HTML"}, .extensions = &.{ ".html", ".htm" } },
    .{ .id = "css", .names = &.{"CSS"}, .extensions = &.{".css"} },
    .{ .id = "scss", .names = &.{"SCSS"}, .extensions = &.{".scss"} },
    .{ .id = "markdown", .names = &.{"Markdown"}, .extensions = &.{ ".md", ".markdown" } },
    .{ .id = "search-result", .names = &.{"Search Result"}, .extensions = &.{".code-search"} },
    .{ .id = "yaml", .names = &.{"YAML"}, .extensions = &.{ ".yaml", ".yml" } },
    .{ .id = "toml", .names = &.{"TOML"}, .extensions = &.{".toml"} },
    .{ .id = "shellscript", .names = &.{"Shell Script"}, .extensions = &.{ ".sh", ".bash" } },
    .{ .id = "plaintext", .names = &.{"Plain Text"}, .extensions = &.{".txt"} },
};

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

/// The upstream `language-configuration.json` contributed by the VS Code
/// extension that owns this language, embedded by the build from the pinned
/// checkout (or a vendored copy when the checkout is absent). `language.zig`
/// only holds the terminal's built-in language table; the language-specific
/// comments, brackets, pairs, folding flag and indentation rules live in the
/// ported extension assets.
pub fn bundledLanguageConfiguration(language_id: []const u8) ?[]const u8 {
    return vscode_syntax.languageConfigurationData(language_id);
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

test "bundled language configurations are ported assets" {
    const json = bundledLanguageConfiguration("json") orelse return error.MissingLanguageConfiguration;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"indentationRules\"") != null);
    try std.testing.expect(bundledLanguageConfiguration("jsonc") != null);
    // Zig has no upstream extension configuration; it keeps the TUI fallback.
    try std.testing.expect(bundledLanguageConfiguration("zig") == null);
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
