// Port of LocalizationsDataRenderer in `src/vs/workbench/contrib/localization/common/localization.contribution.ts`.
// Features-table projection only; the contribution runtime is separate.
const features = @import("../../../services/extensionManagement/common/extensionFeatures.zig");

pub const localizations_feature = features.manifestTable("localizations", "Language Packs", &.{
    .{ .label = "Language ID", .key = "languageId" },
    .{ .label = "Language Name", .key = "languageName" },
    .{ .label = "Language Name (Localized)", .key = "localizedLanguageName" },
}, true);
