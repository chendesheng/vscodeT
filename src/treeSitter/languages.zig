const ts = @import("tree-sitter");
const tree_sitter_zig = @import("tree-sitter-zig");

pub const LanguageId = enum {
    zig,
};

pub fn createLanguage(lang: LanguageId) *const ts.Language {
    switch (lang) {
        .zig => return @ptrCast(tree_sitter_zig.language()),
    }
}
