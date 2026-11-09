// Shared helpers for the comment contributions.
const language_configuration_registry = @import("../../../common/languages/languageConfigurationRegistry.zig");
const ICommentsConfiguration = language_configuration_registry.ICommentsConfiguration;
const LanguageService = @import("../../../common/services/languageService.zig").LanguageService;

/// Resolves the comment configuration for `languageId` from the model language
/// service. The full upstream `ILanguageConfigurationService` is not ported;
/// this is the portable subset the comment commands need.
pub fn commentsFor(language_service: *LanguageService, language_id: []const u8) ?ICommentsConfiguration {
    const config = language_service.getLanguageConfiguration(language_id) orelse return null;
    return language_configuration_registry.ResolvedLanguageConfiguration._handleComments(config);
}
