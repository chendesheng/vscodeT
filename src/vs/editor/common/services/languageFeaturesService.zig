// Port of the concrete registry collection from
// `src/vs/editor/common/services/languageFeaturesService.ts`.
//
// Only the twelve registries consumed by `MainThreadLanguageFeatures` and the
// TUI navigation contributions are ported; see `languageFeatures.zig` for the
// deferred set.

const std = @import("std");
const Allocator = std.mem.Allocator;
const registry = @import("../languageFeatureRegistry.zig");
const languages = @import("../languages.zig");
const completion = @import("../languages/completion.zig");
const features = @import("languageFeatures.zig");

pub const LanguageFeaturesService = struct {
    allocator: Allocator,
    hover_provider: registry.LanguageFeatureRegistry(languages.HoverProvider),
    completion_provider: registry.LanguageFeatureRegistry(completion.CompletionItemProvider),
    definition_provider: registry.LanguageFeatureRegistry(languages.DefinitionProvider),
    declaration_provider: registry.LanguageFeatureRegistry(languages.DeclarationProvider),
    implementation_provider: registry.LanguageFeatureRegistry(languages.ImplementationProvider),
    type_definition_provider: registry.LanguageFeatureRegistry(languages.TypeDefinitionProvider),
    reference_provider: registry.LanguageFeatureRegistry(languages.ReferenceProvider),
    document_symbol_provider: registry.LanguageFeatureRegistry(languages.DocumentSymbolProvider),
    code_lens_provider: registry.LanguageFeatureRegistry(languages.CodeLensProvider),
    code_action_provider: registry.LanguageFeatureRegistry(languages.CodeActionProvider),
    document_formatting_edit_provider: registry.LanguageFeatureRegistry(languages.DocumentFormattingEditProvider),
    document_range_formatting_edit_provider: registry.LanguageFeatureRegistry(languages.DocumentRangeFormattingEditProvider),
    on_type_formatting_edit_provider: registry.LanguageFeatureRegistry(languages.OnTypeFormattingEditProvider),

    pub fn init(allocator: Allocator) LanguageFeaturesService {
        return .{
            .allocator = allocator,
            .hover_provider = registry.LanguageFeatureRegistry(languages.HoverProvider).init(allocator),
            .completion_provider = registry.LanguageFeatureRegistry(completion.CompletionItemProvider).init(allocator),
            .definition_provider = registry.LanguageFeatureRegistry(languages.DefinitionProvider).init(allocator),
            .declaration_provider = registry.LanguageFeatureRegistry(languages.DeclarationProvider).init(allocator),
            .implementation_provider = registry.LanguageFeatureRegistry(languages.ImplementationProvider).init(allocator),
            .type_definition_provider = registry.LanguageFeatureRegistry(languages.TypeDefinitionProvider).init(allocator),
            .reference_provider = registry.LanguageFeatureRegistry(languages.ReferenceProvider).init(allocator),
            .document_symbol_provider = registry.LanguageFeatureRegistry(languages.DocumentSymbolProvider).init(allocator),
            .code_lens_provider = registry.LanguageFeatureRegistry(languages.CodeLensProvider).init(allocator),
            .code_action_provider = registry.LanguageFeatureRegistry(languages.CodeActionProvider).init(allocator),
            .document_formatting_edit_provider = registry.LanguageFeatureRegistry(languages.DocumentFormattingEditProvider).init(allocator),
            .document_range_formatting_edit_provider = registry.LanguageFeatureRegistry(languages.DocumentRangeFormattingEditProvider).init(allocator),
            .on_type_formatting_edit_provider = registry.LanguageFeatureRegistry(languages.OnTypeFormattingEditProvider).init(allocator),
        };
    }

    pub fn deinit(self: *LanguageFeaturesService) void {
        self.hover_provider.deinit();
        self.completion_provider.deinit();
        self.definition_provider.deinit();
        self.declaration_provider.deinit();
        self.implementation_provider.deinit();
        self.type_definition_provider.deinit();
        self.reference_provider.deinit();
        self.document_symbol_provider.deinit();
        self.code_lens_provider.deinit();
        self.code_action_provider.deinit();
        self.document_formatting_edit_provider.deinit();
        self.document_range_formatting_edit_provider.deinit();
        self.on_type_formatting_edit_provider.deinit();
    }

    pub fn interface(self: *LanguageFeaturesService) features.ILanguageFeaturesService {
        return .{
            .hover_provider = &self.hover_provider,
            .completion_provider = &self.completion_provider,
            .definition_provider = &self.definition_provider,
            .declaration_provider = &self.declaration_provider,
            .implementation_provider = &self.implementation_provider,
            .type_definition_provider = &self.type_definition_provider,
            .reference_provider = &self.reference_provider,
            .document_symbol_provider = &self.document_symbol_provider,
            .code_lens_provider = &self.code_lens_provider,
            .code_action_provider = &self.code_action_provider,
            .document_formatting_edit_provider = &self.document_formatting_edit_provider,
            .document_range_formatting_edit_provider = &self.document_range_formatting_edit_provider,
            .on_type_formatting_edit_provider = &self.on_type_formatting_edit_provider,
        };
    }
};
