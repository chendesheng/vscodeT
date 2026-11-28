// Port of AuthenticationDataRenderer in `src/vs/workbench/contrib/authentication/browser/authentication.contribution.ts`.
// Features-table projection only; the contribution runtime is separate.
const features = @import("../../../services/extensionManagement/common/extensionFeatures.zig");

pub const authentication_feature = features.manifestTable("authentication", "Authentication", &.{
    .{ .label = "Label", .key = "label" },
    .{ .label = "ID", .key = "id" },
    .{ .label = "MCP Authorization Servers", .key = "authorizationServerGlobs" },
}, true);
