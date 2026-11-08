const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const PieceTreeTextBuffer = @import("../pieceTreeTextBuffer/pieceTreeTextBuffer.zig").PieceTreeTextBuffer;
const textMate = @import("../tokenize/textMateTokenizer.zig");
const TokenPacked = @import("../tokens/lineTokens.zig").TokenPacked;
const ITokenizationSupport = @import("../languages.zig").ITokenizationSupport;

/// TUI-local stand-in for vscode's language association registry. Upstream
/// resolves this through `ILanguageService.guessLanguageIdByFilepathOrFirstLine`
/// (`src/vs/editor/common/services/languageService.ts`), which consults the
/// platform/configured associations in
/// `src/vs/editor/common/services/languagesAssociations.ts`. The TUI has no
/// workbench extension registry, so this covers only the grammars bundled with
/// textmate.zig.
fn languageIdForPath(path: []const u8) ?[]const u8 {
    const basename = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, basename, '.') orelse return null;
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
    return null;
}

pub const Highlighter = struct {
    allocator: Allocator,
    support: ?ITokenizationSupport,
    arena: std.heap.ArenaAllocator,
    lines: ArrayList([]const TokenPacked),

    pub fn init(allocator: Allocator, path: []const u8) !Highlighter {
        const languageId = languageIdForPath(path);
        var support: ?ITokenizationSupport = null;
        if (languageId) |lang| {
            support = try textMate.create(std.heap.page_allocator, lang);
        }
        return .{
            .allocator = allocator,
            .support = support,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .lines = ArrayList([]const TokenPacked).init(allocator),
        };
    }

    pub fn deinit(self: *Highlighter) void {
        if (self.support) |support| support.dispose();
        self.lines.deinit();
        self.arena.deinit();
    }

    pub fn rehighlight(self: *Highlighter, tree: *PieceTreeTextBuffer) !void {
        const support = self.support orelse return;
        _ = self.arena.reset(.retain_capacity);
        self.lines.clearRetainingCapacity();

        const allocator = self.arena.allocator();
        var state = try support.getInitialState(allocator);
        var lineNumber: usize = 1;
        while (lineNumber <= tree.getLineCount()) : (lineNumber += 1) {
            var line = try tree.getLineContent(lineNumber);
            defer line.deinit();
            const result = try support.tokenizeEncoded(allocator, line.items, true, state);
            try self.lines.append(result.tokens);
            state = result.endState;
        }
    }

    pub fn tokensForLine(self: *const Highlighter, lineNumber: usize) []const TokenPacked {
        if (lineNumber == 0 or lineNumber > self.lines.items.len) return &.{};
        return self.lines.items[lineNumber - 1];
    }
};

test "highlighter: language detection by path" {
    try std.testing.expectEqualStrings("zig", languageIdForPath("src/main.zig").?);
    try std.testing.expectEqualStrings("c", languageIdForPath("foo.h").?);
    try std.testing.expectEqualStrings("typescript", languageIdForPath("app.ts").?);
    try std.testing.expectEqualStrings("typescript", languageIdForPath("APP.TS").?);
    try std.testing.expect(languageIdForPath("Makefile") == null);
}
