// Port of JSONValidationDataRenderer in `src/vs/workbench/api/common/jsonValidationExtensionPoint.ts`.
// Features-table projection only; the contribution runtime is separate.
const features = @import("../../services/extensionManagement/common/extensionFeatures.zig");

pub const json_validation_feature = features.manifestTable("jsonValidation", "JSON Validation", &.{
    .{ .label = "File Match", .key = "fileMatch" },
    .{ .label = "Schema", .key = "url" },
}, false);
