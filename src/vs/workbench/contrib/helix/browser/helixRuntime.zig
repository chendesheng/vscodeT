// Product wiring for the native Helix built-in extension.
//
// The runtime is owned by the composition root. It registers Enable/Disable
// commands even while Helix is disabled. The commands persist `helix.enabled`
// in the user settings file, so the choice survives a restart. The workbench
// core still knows only the generic built-in extension and key-input contracts.
const std = @import("std");
const Allocator = std.mem.Allocator;
const IDisposable = @import("../../../api/common/extensionApi.zig").IDisposable;
const BuiltinExtensionHost = @import("../../../api/browser/builtinExtensionHost.zig").BuiltinExtensionHost;
const helix_extension = @import("./helixExtension.zig");

pub const EnableListener = struct {
    context: *anyopaque,
    on_enable: *const fn (context: *anyopaque) void,
};

pub const HelixRuntime = struct {
    allocator: Allocator,
    parent: *BuiltinExtensionHost,
    enable_command: IDisposable = .none,
    disable_command: IDisposable = .none,
    host: ?*BuiltinExtensionHost = null,
    on_enable: ?EnableListener = null,

    pub fn init(allocator: Allocator, parent: *BuiltinExtensionHost) !*HelixRuntime {
        const self = try allocator.create(HelixRuntime);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .parent = parent };
        try self.registerCommands();
        return self;
    }

    pub fn deinit(self: *HelixRuntime) void {
        self.disable();
        self.disable_command.dispose();
        self.enable_command.dispose();
        self.allocator.destroy(self);
    }

    pub fn setOnEnable(self: *HelixRuntime, listener: ?EnableListener) void {
        self.on_enable = listener;
    }

    pub fn enable(self: *HelixRuntime) !void {
        if (self.host != null) return;
        const host = try self.parent.createChild();
        errdefer host.deinit();
        try host.registerBuiltin(try helix_extension.create(self.allocator));
        host.activate();
        self.host = host;
        if (self.on_enable) |listener| listener.on_enable(listener.context);
        self.setMessage("Helix enabled");
    }

    pub fn disable(self: *HelixRuntime) void {
        if (self.host) |host| {
            host.deinit();
            self.host = null;
            self.setMessage("Helix disabled");
        }
    }

    pub fn isEnabled(self: *const HelixRuntime) bool {
        return self.host != null;
    }

    /// Enables or disables Helix for this session and writes the choice to the
    /// terminal's user settings file.
    pub fn setEnabledPersistent(self: *HelixRuntime, enabled: bool) !void {
        if (enabled) try self.enable() else self.disable();
        const value = std.json.Value{ .bool = enabled };
        self.parent.context.workspace.updateUserConfiguration("helix.enabled", value) catch |err| {
            var buffer: [256]u8 = undefined;
            self.setMessage(std.fmt.bufPrint(&buffer, "Unable to persist helix.enabled: {s}", .{@errorName(err)}) catch "Unable to persist helix.enabled");
        };
    }

    fn setMessage(self: *HelixRuntime, text: []const u8) void {
        if (self.parent.context.editors.activeTextEditor()) |editor| editor.setMessage(text);
    }

    fn registerCommands(self: *HelixRuntime) !void {
        const commands = self.parent.context.commands;
        self.enable_command = try commands.register("helix.enable", "Helix: Enable", .{ .category = "Helix", .context = self, .run = enableCommand });
        errdefer self.enable_command.dispose();
        self.disable_command = try commands.register("helix.disable", "Helix: Disable", .{ .category = "Helix", .context = self, .run = disableCommand });
    }

    fn enableCommand(context: *anyopaque) anyerror!void {
        const self: *HelixRuntime = @ptrCast(@alignCast(context));
        try self.setEnabledPersistent(true);
    }

    fn disableCommand(context: *anyopaque) anyerror!void {
        const self: *HelixRuntime = @ptrCast(@alignCast(context));
        try self.setEnabledPersistent(false);
    }
};
