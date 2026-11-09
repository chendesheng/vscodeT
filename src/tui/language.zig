const std = @import("std");
const language_configuration = @import("../vs/editor/common/languages/languageConfiguration.zig");
const CommentRule = language_configuration.CommentRule;
const LineCommentConfig = language_configuration.LineCommentConfig;
const CharacterPair = language_configuration.CharacterPair;

var standard_brackets = [_]CharacterPair{
    .{ "{", "}" },
    .{ "[", "]" },
    .{ "(", ")" },
};

/// TUI-local stand-in for vscode's language association registry. Only the
/// grammars bundled with textmate.zig are recognized.
pub fn languageIdForPath(path: []const u8) []const u8 {
    const basename = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, basename, '.') orelse return "plaintext";
    const ext = basename[dot + 1 ..];
    const map = .{
        .{ "zig", "zig" },             .{ "json", "json" },
        .{ "jsonc", "jsonc" },         .{ "js", "javascript" },
        .{ "mjs", "javascript" },      .{ "cjs", "javascript" },
        .{ "jsx", "javascriptreact" }, .{ "ts", "typescript" },
        .{ "mts", "typescript" },      .{ "cts", "typescript" },
        .{ "tsx", "typescriptreact" }, .{ "py", "python" },
        .{ "rs", "rust" },             .{ "go", "go" },
        .{ "c", "c" },                 .{ "h", "c" },
        .{ "cpp", "cpp" },             .{ "cc", "cpp" },
        .{ "cxx", "cpp" },             .{ "hpp", "cpp" },
        .{ "java", "java" },           .{ "html", "html" },
        .{ "htm", "html" },            .{ "css", "css" },
        .{ "scss", "scss" },           .{ "md", "markdown" },
        .{ "markdown", "markdown" },   .{ "yaml", "yaml" },
        .{ "yml", "yaml" },            .{ "toml", "toml" },
        .{ "sh", "shellscript" },      .{ "bash", "shellscript" },
    };
    inline for (map) |entry| {
        if (std.ascii.eqlIgnoreCase(entry[0], ext)) return entry[1];
    }
    return "plaintext";
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

test "comment rules for supported languages" {
    try std.testing.expect(commentRuleFor("zig") != null);
    try std.testing.expect(commentRuleFor("python") != null);
    try std.testing.expect(commentRuleFor("html") != null);
    try std.testing.expect(commentRuleFor("plaintext") == null);
    try std.testing.expect(commentRuleFor("json") == null);
}

test "language detection by path" {
    try std.testing.expectEqualStrings("zig", languageIdForPath("src/main.zig"));
    try std.testing.expectEqualStrings("c", languageIdForPath("foo.h"));
    try std.testing.expectEqualStrings("typescript", languageIdForPath("app.ts"));
    try std.testing.expectEqualStrings("typescript", languageIdForPath("APP.TS"));
    try std.testing.expectEqualStrings("plaintext", languageIdForPath("Makefile"));
}
