const ts = @import("tree-sitter");
const tree_sitter_zig = @import("tree-sitter-zig");
const tree_sitter_typescript = @import("tree-sitter-typescript");

pub const LanguageId = enum {
    zig,
    typescript,
    tsx,
};

pub fn createLanguage(lang: LanguageId) *const ts.Language {
    switch (lang) {
        .zig => return @ptrCast(tree_sitter_zig.language()),
        .typescript => return @ptrCast(tree_sitter_typescript.languageTs()),
        .tsx => return @ptrCast(tree_sitter_typescript.languageTsx()),
    }
}
