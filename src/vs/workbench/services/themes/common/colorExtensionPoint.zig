// Port of ColorDataRenderer in `src/vs/workbench/services/themes/common/colorExtensionPoint.ts`.
// Features-table projection only; the contribution runtime is separate.
// Terminal table cells show literal color values instead of browser swatches.
const features = @import("../../extensionManagement/common/extensionFeatures.zig");

pub const colors_feature = features.manifestTable("colors", "Colors", &.{
    .{ .label = "ID", .key = "id" },
    .{ .label = "Description", .key = "description" },
    .{ .label = "Dark Default", .key = "defaults.dark" },
    .{ .label = "Light Default", .key = "defaults.light" },
    .{ .label = "High Contrast Default", .key = "defaults.highContrast" },
}, true);
