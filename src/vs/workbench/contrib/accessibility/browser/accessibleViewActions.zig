// Port of the accessibility help/accessible view command registrations in
// `src/vs/workbench/contrib/accessibility/browser/accessibleViewActions.ts`.
const api = @import("../../../../platform/accessibility/browser/accessibleView.zig");
const actions = @import("../../../../platform/actions/common/actions.zig");
const ServicesAccessor = @import("../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const Expr = @import("../../../../platform/contextkey/common/contextkey.zig").Expr;
const keys = @import("../../../../base/common/keyCodes.zig");
const weight = @backingInt(@import("../../../../platform/keybinding/common/keybindingsRegistry.zig").KeybindingWeight.WorkbenchContrib);
const help_not_shown = Expr{ .Not = "accessibilityHelpIsShown" };
const help_shown = Expr{ .Defined = "accessibilityHelpIsShown" };
const view_shown = Expr{ .Defined = "accessibleViewIsShown" };
const view_or_help = Expr{ .Or = @constCast(&[_]*const Expr{ &help_shown, &view_shown }) };
const verbosity_enabled = Expr{ .Defined = "accessibleViewVerbosityEnabled" };
const can_disable = Expr{ .And = @constCast(&[_]*const Expr{ &view_or_help, &verbosity_enabled }) };

pub const accessible_view_actions = [_]actions.Action2{
    openAction("editor.action.accessibilityHelp", "Open Accessibility Help", .Help, .F1, &help_not_shown),
    openAction("editor.action.accessibleView", "Open Accessible View", .View, .F2, null),
    .{
        .command = .{ .id = "editor.action.accessibleViewDisableHint", .title = "Disable Accessible View Hint", .icon = "bellSlash", .precondition = &can_disable },
        .f1 = true,
        .menus = &.{.{ .id = actions.menu_ids.AccessibleView, .group = "navigation", .when = &can_disable }},
        .keybindings = &.{.{ .id = "editor.action.accessibleViewDisableHint", .weight = weight, .bindings = .{ .primary = keys.KeyMod.Alt | @backingInt(keys.KeyCode.F6) } }},
        .context = @constCast(&{}),
        .run_fn = struct {
            fn run(_: *anyopaque, accessor: ServicesAccessor) !void {
                try (try accessor.get(api.accessible_view_service_id)).disableHint();
            }
        }.run,
    },
};

fn openAction(comptime id: []const u8, title: []const u8, comptime kind: api.AccessibleViewType, comptime key: keys.KeyCode, when: ?*const Expr) actions.Action2 {
    return .{
        .command = .{ .id = id, .title = title },
        .f1 = true,
        .context = @constCast(&{}),
        .keybindings = &.{.{ .id = id, .weight = weight, .when = when, .bindings = .{ .primary = keys.KeyMod.Alt | @backingInt(key), .linux = .{ .primary = keys.KeyMod.Alt | keys.KeyMod.Shift | @backingInt(key), .secondary = &.{keys.KeyMod.Alt | @backingInt(key)} } } }},
        .run_fn = struct {
            fn run(_: *anyopaque, accessor: ServicesAccessor) !void {
                try (try accessor.get(api.accessible_view_service_id)).open(accessor, kind);
            }
        }.run,
    };
}
