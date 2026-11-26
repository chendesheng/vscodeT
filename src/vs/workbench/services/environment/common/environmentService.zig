// Port of the window-kind property in
// `src/vs/workbench/services/environment/common/environmentService.ts`.
// The native terminal always constructs the normal workbench. The portable
// Agents-window action branch is retained for consumers of this contract.
const instantiation = @import("../../../../platform/instantiation/common/instantiation.zig");

pub const IWorkbenchEnvironmentService = struct {
    isSessionsWindow: bool = false,
};

pub const workbench_environment_service_id = instantiation.ServiceIdentifier(IWorkbenchEnvironmentService, "environmentService");
