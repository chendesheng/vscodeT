// Port of the diff editor configuration schema fields in
// `src/vs/editor/common/config/editorConfigurationSchema.ts`.
const registry = @import("../../../platform/configuration/common/configurationRegistry.zig");

pub const diff_editor_properties = [_]registry.PropertySchema{
    .{
        .key = "diffEditor.hideOriginalLineNumbers",
        .value_type = "boolean",
        .value_types = &.{ "boolean", "null" },
        .default = .null,
        .scope = .LANGUAGE_OVERRIDABLE,
    },
};
