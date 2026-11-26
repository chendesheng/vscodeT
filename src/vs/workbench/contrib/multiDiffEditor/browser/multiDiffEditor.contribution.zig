// Port of the Action2 registration in
// `src/vs/workbench/contrib/multiDiffEditor/browser/multiDiffEditor.contribution.ts`.
const CommandRegistry = @import("../../../browser/commands.zig").CommandRegistry;
const InstantiationService = @import("../../../../platform/instantiation/common/instantiationService.zig").InstantiationService;

pub fn registerActions(commands: *CommandRegistry, instantiation: *InstantiationService) !void {
    for (@import("actions.zig").editor_actions) |action| try commands.registerAction(instantiation, action);
}
