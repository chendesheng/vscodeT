const std = @import("std");

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

test "language detection by path" {
    try std.testing.expectEqualStrings("zig", languageIdForPath("src/main.zig"));
    try std.testing.expectEqualStrings("c", languageIdForPath("foo.h"));
    try std.testing.expectEqualStrings("typescript", languageIdForPath("app.ts"));
    try std.testing.expectEqualStrings("typescript", languageIdForPath("APP.TS"));
    try std.testing.expectEqualStrings("plaintext", languageIdForPath("Makefile"));
}
