// Port of the portable shape of
// `src/vs/workbench/contrib/quickaccess/browser/commandsQuickAccess.ts`.
//
// Upstream this provider extends `AbstractEditorCommandsQuickAccessProvider`
// to merge editor action picks with global menu actions. The TUI command
// registry already contains both editor and workbench commands, so this
// provider simply wraps the shared command picker with the `>` prefix.
// Menus, actions, keybinding labels and AI/TF-IDF suggestions are not ported.

const std = @import("std");
const platform = @import("../../../../platform/quickinput/browser/commandsQuickAccess.zig");
const quick_access = @import("../../../../platform/quickinput/common/quickAccess.zig");

pub const ShowAllCommandsAction = struct {
    pub const ID = "workbench.action.showCommands";
    pub const label = "Show All Commands";
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
