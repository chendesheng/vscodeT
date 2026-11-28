// Port of the enablement portion of
// `src/vs/workbench/services/extensionManagement/common/extensionManagement.ts`.
//
// The terminal service supports global/workspace states and computed
// disabled-dependency state. Other upstream restrictions are retained in
// the enum for protocol fidelity but not yet computed.
const std = @import("std");

/// Upstream `EnablementState`; the numeric values match so persisted or
/// serialized state keeps the same meaning.
pub const EnablementState = enum(u8) {
    DisabledByTrustRequirement = 0,
    DisabledByExtensionKind = 1,
    DisabledByEnvironment = 2,
    EnabledByEnvironment = 3,
    DisabledByMalicious = 4,
    DisabledByVirtualWorkspace = 5,
    DisabledByInvalidExtension = 6,
    DisabledByAllowlist = 7,
    DisabledByExtensionDependency = 8,
    DisabledByUnification = 9,
    DisabledGlobally = 10,
    DisabledWorkspace = 11,
    EnabledGlobally = 12,
    EnabledWorkspace = 13,

    /// Upstream `isEnabledEnablementState`.
    pub fn isEnabled(self: EnablementState) bool {
        return switch (self) {
            .EnabledByEnvironment, .EnabledGlobally, .EnabledWorkspace => true,
            else => false,
        };
    }
};
