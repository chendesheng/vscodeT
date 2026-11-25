// Product wiring for the native Vim built-in extension.
//
// The runtime is owned by the composition root. It registers Enable/Disable
// commands even while Vim is disabled. The commands persist `vim.enabled` in
// the user settings file, so the choice survives a restart. The workbench core
// still knows only the generic built-in extension and key-input contracts.
const std = @import("std");
const Allocator = std.mem.Allocator;
const IDisposable = @import("../../../api/common/extensionApi.zig").IDisposable;
const BuiltinExtensionHost = @import("../../../api/browser/builtinExtensionHost.zig").BuiltinExtensionHost;
const vim_extension = @import("./vimExtension.zig");

pub const EnableListener = struct {
    context: *anyopaque,
    on_enable: *const fn (context: *anyopaque) void,
};

pub const VimRuntime = struct {
    allocator: Allocator,
    parent: *BuiltinExtensionHost,
    enable_command: IDisposable = .none,
    disable_command: IDisposable = .none,
    host: ?*BuiltinExtensionHost = null,
    on_enable: ?EnableListener = null,

    pub fn init(allocator: Allocator, parent: *BuiltinExtensionHost) !*VimRuntime {
        const self = try allocator.create(VimRuntime);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .parent = parent };
        try self.registerCommands();
        return self;
    }

    pub fn deinit(self: *VimRuntime) void {
        self.disable();
        self.disable_command.dispose();
        self.enable_command.dispose();
        self.allocator.destroy(self);
    }

    pub fn setOnEnable(self: *VimRuntime, listener: ?EnableListener) void {
        self.on_enable = listener;
    }

    pub fn enable(self: *VimRuntime) !void {
        if (self.host != null) return;
        const host = try self.parent.createChild();
        errdefer host.deinit();
        try host.registerBuiltin(try vim_extension.create(self.allocator));
        host.activate();
        self.host = host;
        if (self.on_enable) |listener| listener.on_enable(listener.context);
        self.setMessage("Vim enabled");
    }

    pub fn disable(self: *VimRuntime) void {
        if (self.host) |host| {
            host.deinit();
            self.host = null;
            self.setMessage("Vim disabled");
        }
    }

    pub fn isEnabled(self: *const VimRuntime) bool {
        return self.host != null;
    }

    /// Enables or disables Vim for this session and writes the choice to the
    /// terminal's user settings file.
    pub fn setEnabledPersistent(self: *VimRuntime, enabled: bool) !void {
        if (enabled) try self.enable() else self.disable();
        const value = std.json.Value{ .bool = enabled };
        self.parent.context.workspace.updateUserConfiguration("vim.enabled", value) catch |err| {
            var buffer: [256]u8 = undefined;
            self.setMessage(std.fmt.bufPrint(&buffer, "Unable to persist vim.enabled: {s}", .{@errorName(err)}) catch "Unable to persist vim.enabled");
        };
    }

    fn setMessage(self: *VimRuntime, text: []const u8) void {
        if (self.parent.context.editors.activeTextEditor()) |editor| editor.setMessage(text);
    }

    fn registerCommands(self: *VimRuntime) !void {
        const commands = self.parent.context.commands;
        self.enable_command = try commands.register("vim.enable", "Vim: Enable", .{ .category = "Vim", .context = self, .run = enableCommand });
        errdefer self.enable_command.dispose();
        self.disable_command = try commands.register("vim.disable", "Vim: Disable", .{ .category = "Vim", .context = self, .run = disableCommand });
    }

    fn enableCommand(context: *anyopaque) anyerror!void {
        const self: *VimRuntime = @ptrCast(@alignCast(context));
        try self.setEnabledPersistent(true);
    }

    fn disableCommand(context: *anyopaque) anyerror!void {
        const self: *VimRuntime = @ptrCast(@alignCast(context));
        try self.setEnabledPersistent(false);
    }
};
