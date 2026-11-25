// Port of the portable shape of
// `src/vs/workbench/contrib/quickaccess/browser/commandsQuickAccess.ts`.
//
// Upstream this provider extends `AbstractEditorCommandsQuickAccessProvider`
// to merge editor action picks with global menu actions. The TUI command
// registry already contains both editor and workbench commands, so this
// provider simply wraps the shared command picker with the `>` prefix.
// ShowAllCommandsAction requests the command provider via IQuickInputService.

const std = @import("std");
const platform = @import("../../../../platform/quickinput/browser/commandsQuickAccess.zig");
const quick_access = @import("../../../../platform/quickinput/common/quickAccess.zig");

const actions = @import("../../../../platform/actions/common/actions.zig");
const bindings = @import("../../../../platform/keybinding/common/keybindingsRegistry.zig");
const key_codes = @import("../../../../base/common/keyCodes.zig");
const quick_input = @import("../../../../platform/quickinput/common/quickInput.zig");
const ServicesAccessor = @import("../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;

pub const ShowAllCommandsAction = struct {
    pub const ID = "workbench.action.showCommands";
    pub const label = "Show All Commands";
    pub const descriptor = actions.Action2{
        .command = .{ .id = ID, .title = label },
        .f1 = true,
        .keybindings = &.{.{
            .id = ID,
            .weight = @backingInt(bindings.KeybindingWeight.WorkbenchContrib),
            .bindings = .{
                .primary = key_codes.KeyMod.CtrlCmd | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.KeyP),
                .secondary = &.{@backingInt(key_codes.KeyCode.F1)},
            },
        }},
        .context = @constCast(&{}),
        .run_fn = run,
    };

    fn run(_: *anyopaque, accessor: ServicesAccessor) anyerror!void {
        const service = try accessor.get(quick_input.quick_input_service_id);
        try service.quick_access.show(CommandsQuickAccessProvider.PREFIX);
    }
};

pub const CommandsQuickAccessProvider = struct {
    pub const PREFIX = ">";
    pub const PLACEHOLDER = "Type the name of a command to run.";

    allocator: std.mem.Allocator,
    base: *platform.CommandsQuickAccessProvider,

    pub fn init(
        allocator: std.mem.Allocator,
        source: platform.CommandPickSource,
        executor: platform.CommandExecutor,
    ) !*CommandsQuickAccessProvider {
        const self = try allocator.create(CommandsQuickAccessProvider);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .base = try platform.CommandsQuickAccessProvider.init(
                allocator,
                PREFIX,
                source,
                executor,
            ),
        };
        return self;
    }

    pub fn interface(self: *CommandsQuickAccessProvider) quick_access.Provider {
        return .{
            .context = self,
            .prefix = PREFIX,
            .placeholder = PLACEHOLDER,
            .provide = provideFn,
            .refresh = refreshFn,
            .accept = acceptFn,
            .dispose = disposeFn,
        };
    }

    fn provideFn(
        context: *anyopaque,
        picker: *@import("../../../../platform/quickinput/browser/quickInput.zig").QuickPick,
        token: @import("../../../../base/common/cancellation.zig").CancellationToken,
    ) anyerror!void {
        const self: *CommandsQuickAccessProvider = @ptrCast(@alignCast(context));
        const base = self.base.interface();
        return base.provide(base.context, picker, token);
    }

    fn refreshFn(
        context: *anyopaque,
        picker: *@import("../../../../platform/quickinput/browser/quickInput.zig").QuickPick,
    ) anyerror!void {
        const self: *CommandsQuickAccessProvider = @ptrCast(@alignCast(context));
        const base = self.base.interface();
        return base.refresh(base.context, picker);
    }

    fn acceptFn(
        context: *anyopaque,
        picker: *@import("../../../../platform/quickinput/browser/quickInput.zig").QuickPick,
    ) anyerror!void {
        const self: *CommandsQuickAccessProvider = @ptrCast(@alignCast(context));
        const base = self.base.interface();
        return base.accept(base.context, picker);
    }

    fn disposeFn(context: *anyopaque) void {
        const self: *CommandsQuickAccessProvider = @ptrCast(@alignCast(context));
        const base = self.base;
        if (base.interface().dispose) |dispose| dispose(base);
        self.allocator.destroy(self);
    }
};
