// Product wiring for the native Vim built-in extension.
//
// The runtime is owned by the composition root. It registers Enable/Disable
// commands even while Vim is disabled. The commands persist `vim.enabled` in
// the user settings file, so the choice survives a restart. The workbench core
// still knows only the generic built-in extension and key-input contracts.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Workbench = @import("../../../browser/workbench.zig").Workbench;
const BuiltinExtensionHost = @import("../../../api/browser/builtinExtensionHost.zig").BuiltinExtensionHost;
const vim_extension = @import("./vimExtension.zig");

pub const EnableListener = struct {
    context: *anyopaque,
    on_enable: *const fn (context: *anyopaque) void,
};

pub const VimRuntime = struct {
    allocator: Allocator,
    workbench: *Workbench,
    host: ?*BuiltinExtensionHost = null,
    on_enable: ?EnableListener = null,

    pub fn init(allocator: Allocator, workbench: *Workbench) !*VimRuntime {
        const self = try allocator.create(VimRuntime);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .workbench = workbench };
        try self.registerCommands();
        return self;
    }

    pub fn deinit(self: *VimRuntime) void {
        self.disable();
        self.workbench.commands.unregister("vim.enable");
        self.workbench.commands.unregister("vim.disable");
        self.allocator.destroy(self);
    }

    pub fn setOnEnable(self: *VimRuntime, listener: ?EnableListener) void {
        self.on_enable = listener;
    }

    pub fn enable(self: *VimRuntime) !void {
        if (self.host != null) return;
        const host = try BuiltinExtensionHost.init(self.allocator, self.workbench);
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
        self.workbench.setUserConfigurationValue("vim.enabled", value) catch |err| {
            if (self.workbench.activeTab()) |tab| tab.editor.setMessage("Unable to persist vim.enabled: {s}", .{@errorName(err)});
        };
    }

    fn setMessage(self: *VimRuntime, text: []const u8) void {
        if (self.workbench.activeTab()) |tab| tab.editor.setMessage("{s}", .{text});
    }

    fn registerCommands(self: *VimRuntime) !void {
        try self.workbench.commands.register(.{
            .id = "vim.enable",
            .label = "Vim: Enable",
            .category = "Vim",
            .context = self,
            .run = enableCommand,
        });
        try self.workbench.commands.register(.{
            .id = "vim.disable",
            .label = "Vim: Disable",
            .category = "Vim",
            .context = self,
            .run = disableCommand,
        });
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
