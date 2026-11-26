// Port of the enablement portion of
// `src/vs/workbench/services/extensionManagement/common/extensionManagement.ts`.
//
// Terminal adaptation: only the global (user) enablement states are produced
// by the ported service. Workspace enablement, workspace trust, extension
// kind, virtual workspaces, malicious-extension, allow-list and dependency
// disablement are member values kept for upstream ordering/fidelity; nothing
// in the TUI assigns them.
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
