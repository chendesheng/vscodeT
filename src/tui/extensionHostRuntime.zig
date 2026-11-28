// Native local-process lifecycle adapter. The portable Extensions workbench
// service decides when a host restart suffices and owns the accepted registry.
const std = @import("std");
const Extensions = @import("../vs/workbench/api/browser/extensionHostAdapter.zig").Extensions;
const abstract = @import("../vs/workbench/services/extensions/common/abstractExtensionService.zig");
const Service = @import("../vs/workbench/contrib/extensions/browser/extensionsWorkbenchService.zig").ExtensionsWorkbenchService;
const Workbench = @import("workbenchWindow.zig").TerminalWorkbench;

pub const ExtensionHostRuntime = struct {
    workbench: *Workbench,
    service: *Service,
    host: *?*Extensions,
    user_data_dir: []const u8,
    runtime_dir: []const u8,

    pub fn attach(self: *ExtensionHostRuntime) !void {
        try self.service.recordRuntime();
        self.service.restart_host = .{ .context = self, .restart = restart };
    }

    pub fn detach(self: *ExtensionHostRuntime) void {
        self.service.restart_host = null;
    }

    fn restart(context: *anyopaque) !void {
        const self: *ExtensionHostRuntime = @ptrCast(@alignCast(context));
        const allocator = self.workbench.allocator;
        const io = self.workbench.io;
        const paths = try abstract.resolveEnabledPaths(allocator, io, self.service.enabledDescriptions(), self.runtime_dir);
        defer abstract.freePaths(allocator, paths);
        // Stop the old host only after resolving all desired paths. Its actor
        // teardown unregisters providers and listeners before the new host
        // reuses the same workbench services and open editor models.
        if (paths.len > 0) {
            const script = try std.fs.path.join(allocator, &.{ self.runtime_dir, "extensionHost.mjs" });
            defer allocator.free(script);
            try std.Io.Dir.cwd().access(io, script, .{});
        }
        if (self.host.*) |host| host.deinit();
        self.host.* = null;
        if (paths.len > 0) self.host.* = try Extensions.init(allocator, io, self.workbench.extensionHostServices(), paths, self.user_data_dir, self.runtime_dir);
        self.workbench.requestFrame();
    }
};
