// Port of `src/vs/workbench/contrib/search/browser/searchActionsSymbol.ts`.
const actions = @import("../../../../platform/actions/common/actions.zig");
const keys = @import("../../../../base/common/keyCodes.zig");
const quick_input = @import("../../../../platform/quickinput/common/quickInput.zig");
const weight = @backingInt(@import("../../../../platform/keybinding/common/keybindingsRegistry.zig").KeybindingWeight.WorkbenchContrib);

pub const show_all_symbols: actions.Action2 = .{
    .command = .{ .id = "workbench.action.showAllSymbols", .title = "Go to Symbol in Workspace..." },
    .f1 = true,
    .keybindings = &.{.{ .id = "workbench.action.showAllSymbols", .weight = weight, .bindings = .{ .primary = keys.KeyMod.CtrlCmd | @backingInt(keys.KeyCode.KeyT) } }},
    .menus = &.{.{ .id = actions.menu_ids.MenubarGoMenu, .group = "3_global_nav", .order = 2 }},
    .context = @constCast(&{}),
    .run_fn = run,
};

fn run(_: *anyopaque, accessor: @import("../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor) !void {
    const service = try accessor.get(quick_input.quick_input_service_id);
    try service.quick_access.show(@import("symbolsQuickAccess.zig").SymbolsQuickAccessProvider.PREFIX);
}
