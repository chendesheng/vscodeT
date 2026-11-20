// Port of the registry subset of
// `src/vs/editor/common/services/languageFeatures.ts`.
//
// The terminal workbench has no DI container. `LanguageFeaturesService` owns
// the registries and returns this pointer bag through `interface()`.
//
// Deferred registries from upstream (rename, semantic tokens, inlay hints,
// code lens, links, colors, folding, selection ranges, signature help,
// call/type hierarchy, inline completions, paste/drop edits and the remaining
// language-feature registries) are not present.

const registry = @import("../languageFeatureRegistry.zig");
const languages = @import("../languages.zig");
const completion = @import("../languages/completion.zig");

pub const ILanguageFeaturesService = struct {
    hover_provider: *registry.LanguageFeatureRegistry(languages.HoverProvider),
    completion_provider: *registry.LanguageFeatureRegistry(completion.CompletionItemProvider),
    definition_provider: *registry.LanguageFeatureRegistry(languages.DefinitionProvider),
    declaration_provider: *registry.LanguageFeatureRegistry(languages.DeclarationProvider),
    implementation_provider: *registry.LanguageFeatureRegistry(languages.ImplementationProvider),
    type_definition_provider: *registry.LanguageFeatureRegistry(languages.TypeDefinitionProvider),
    reference_provider: *registry.LanguageFeatureRegistry(languages.ReferenceProvider),
    document_symbol_provider: *registry.LanguageFeatureRegistry(languages.DocumentSymbolProvider),
    code_action_provider: *registry.LanguageFeatureRegistry(languages.CodeActionProvider),
    document_formatting_edit_provider: *registry.LanguageFeatureRegistry(languages.DocumentFormattingEditProvider),
    document_range_formatting_edit_provider: *registry.LanguageFeatureRegistry(languages.DocumentRangeFormattingEditProvider),
    on_type_formatting_edit_provider: *registry.LanguageFeatureRegistry(languages.OnTypeFormattingEditProvider),
};
