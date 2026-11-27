// Port of `src/vs/editor/common/services/semanticTokensStylingService.ts`.
// Each request owns its styling cache; replacing the theme invalidates that
// cache by canceling requests and restyling their stored semantic data.
const std = @import("std");
const theme_service = @import("../../../platform/theme/common/themeService.zig");
const languages = @import("../languages.zig");
const styling = @import("semanticTokensProviderStyling.zig");
const contract = @import("semanticTokensStyling.zig");
pub const SemanticTokensStylingService = struct {
    theme: ?theme_service.IColorTheme = null,
    pub fn interface(self: *SemanticTokensStylingService) contract.ISemanticTokensStylingService {
        return .{ .context = self, .get_styling = getStyling };
    }
    fn getStyling(context: *anyopaque, a: std.mem.Allocator, legend: languages.SemanticTokensLegend, language: []const u8) ?styling.SemanticTokensProviderStyling {
        const self: *SemanticTokensStylingService = @ptrCast(@alignCast(context));
        return .init(a, legend, self.theme orelse return null, language);
    }
};
