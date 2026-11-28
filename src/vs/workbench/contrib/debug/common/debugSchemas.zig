// Port of DebuggersDataRenderer in `src/vs/workbench/contrib/debug/common/debugSchemas.ts`.
// Features-table projection only; the contribution runtime is separate.
const features = @import("../../../services/extensionManagement/common/extensionFeatures.zig");

pub const debuggers_feature = features.manifestTable("debuggers", "Debuggers", &.{
    .{ .label = "Name", .key = "label" },
    .{ .label = "Type", .key = "type" },
}, false);
