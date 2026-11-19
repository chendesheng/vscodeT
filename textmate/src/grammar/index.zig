// Port of `vscode-textmate/src/grammar/index.ts`
// (microsoft/vscode-textmate v9.3.2).
pub const grammar = @import("grammar.zig");
pub const grammar_dependencies = @import("grammarDependencies.zig");
pub const basic_scopes_attribute_provider = @import("basicScopesAttributeProvider.zig");
pub const tokenize_string = @import("tokenizeString.zig");
