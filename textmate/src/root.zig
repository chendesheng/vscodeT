//! Zig port of `microsoft/vscode-textmate` 9.3.2.
//!
//! The reference checkout lives at `../vscode-textmate`. Each module keeps the
//! upstream file name and the behavioral contract of its TypeScript source;
//! deliberate Zig adaptations are documented in the module header.
//!
//! This package is standalone: it must not import from `src/`.
pub const matcher = @import("matcher.zig");
pub const rawGrammar = @import("rawGrammar.zig");
pub const onigLib = @import("onigLib.zig");
pub const utils = @import("utils.zig");
pub const json = @import("json.zig");
pub const plist = @import("plist.zig");
pub const parseRawGrammar = @import("parseRawGrammar.zig");
pub const encodedTokenAttributes = @import("encodedTokenAttributes.zig");
pub const rule = @import("rule.zig");
pub const grammarDependencies = @import("grammar/grammarDependencies.zig");
pub const theme = @import("theme.zig");
pub const grammar = @import("grammar/grammar.zig");
pub const basicScopesAttributeProvider = @import("grammar/basicScopesAttributeProvider.zig");
pub const tokenizeString = @import("grammar/tokenizeString.zig");
pub const diffStateStacks = @import("diffStateStacks.zig");
pub const registry = @import("registry.zig");
pub const main = @import("main.zig");
pub const debug = @import("debug.zig");
pub const grammar_index = @import("grammar/index.zig");

test {
    _ = matcher;
    _ = @import("matcher.test.zig");
    _ = rawGrammar;
    _ = onigLib;
    _ = utils;
    _ = json;
    _ = plist;
    _ = parseRawGrammar;
    _ = encodedTokenAttributes;
    _ = rule;
    _ = grammarDependencies;
    _ = theme;
    _ = grammar;
    _ = basicScopesAttributeProvider;
    _ = tokenizeString;
    _ = diffStateStacks;
    _ = registry;
    _ = main;
    _ = debug;
    _ = grammar_index;
    _ = @import("tests/grammar.test.zig");
    _ = @import("tests/theme.test.zig");
    _ = @import("tests/tokenization.test.zig");
    _ = @import("tests/themes.test.zig");
    _ = @import("tests/json.test.zig");
}
