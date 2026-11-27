// Port of `src/vs/editor/common/services/semanticTokensStyling.ts`.
const std = @import("std");
const languages = @import("../languages.zig");
const styling = @import("semanticTokensProviderStyling.zig");
const instantiation = @import("../../../platform/instantiation/common/instantiation.zig");
pub const ISemanticTokensStylingService = struct {
    context: *anyopaque,
    get_styling: *const fn (*anyopaque, std.mem.Allocator, languages.SemanticTokensLegend, []const u8) ?styling.SemanticTokensProviderStyling,
    pub fn getStyling(self: ISemanticTokensStylingService, a: std.mem.Allocator, legend: languages.SemanticTokensLegend, language: []const u8) ?styling.SemanticTokensProviderStyling {
        return self.get_styling(self.context, a, legend, language);
    }
};
pub const semantic_tokens_styling_service_id = instantiation.ServiceIdentifier(ISemanticTokensStylingService, "semanticTokensStylingService");
