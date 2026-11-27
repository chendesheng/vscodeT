// Port of `src/vs/editor/contrib/codeAction/browser/codeActionContributions.ts`.
const registry = @import("../../../../platform/configuration/common/configurationRegistry.zig");
pub const editor_actions = @import("codeActionCommands.zig").editor_actions;

pub const properties = [_]registry.PropertySchema{
    .{ .key = "editor.codeActionWidget.showHeaders", .value_type = "boolean", .default = .{ .bool = true }, .scope = .LANGUAGE_OVERRIDABLE },
    .{ .key = "editor.codeActionWidget.includeNearbyQuickFixes", .value_type = "boolean", .default = .{ .bool = true }, .scope = .LANGUAGE_OVERRIDABLE },
};
