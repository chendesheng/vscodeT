// Native local-process lifecycle adapter. The portable Extensions workbench
// service decides when a host restart suffices and owns the accepted registry.
const std = @import("std");
const Extensions = @import("../vs/workbench/api/browser/extensionHostAdapter.zig").Extensions;
const abstract = @import("../vs/workbench/services/extensions/common/abstractExtensionService.zig");
const Service = @import("../vs/workbench/contrib/extensions/browser/extensionsWorkbenchService.zig").ExtensionsWorkbenchService;
const dispatch = @import("../vs/base/common/windowDispatch.zig");
const SignalSubscription = @import("../vs/base/common/event.zig").SignalSubscription;
const Workbench = @import("workbenchWindow.zig").TerminalWorkbench;

pub const ExtensionHostRuntime = struct {
    workbench: *Workbench,
    service: *Service,
    host: *?*Extensions,
    user_data_dir: []const u8,
    runtime_dir: []const u8,
    description_listener: ?SignalSubscription = null,
    reconcile_task: dispatch.Task = .{},
    pending_snapshot: ?abstract.RuntimeInventory = null,
    queued: bool = false,

    pub fn attach(self: *ExtensionHostRuntime) !void {
        try self.service.recordRuntime();
        try self.service.setRuntimeStatusService(if (self.host.*) |host| host.interface() else null);
        self.service.restart_host = .{ .context = self, .restart = restart };
        self.reconcile_task = .{ .queue = &self.workbench.window_events, .context = self, .run = reconcile };
        self.description_listener = try self.service.on_did_change_enabled_descriptions.listenSignal(self, descriptionsChanged);
    }

    pub fn detach(self: *ExtensionHostRuntime) void {
        self.service.restart_host = null;
        self.service.setRuntimeStatusService(null) catch {};
        if (self.description_listener) |listener| listener.dispose();
        self.description_listener = null;
        self.reconcile_task.schedule(null);
        if (self.host.*) |host| host.cancelDescriptionDelta(false);
        if (self.pending_snapshot) |*snapshot| snapshot.deinit();
        self.pending_snapshot = null;
    }

    fn descriptionsChanged(self: *ExtensionHostRuntime) !void {
        self.reconcile_task.post();
    }

    fn reconcile(context: *anyopaque, _: i64, _: bool) bool {
        const self: *ExtensionHostRuntime = @ptrCast(@alignCast(context));
        if (self.pending_snapshot != null) {
            self.queued = true;
            return false;
        }
        const host = self.host.* orelse return false;
        const runtime = self.service.runtime orelse return false;
        if (!runtime.hasChanges(self.service.enabledDescriptions()) or runtime.requiresReload(self.service.enabledDescriptions())) return false;
        const allocator = self.workbench.allocator;
        const paths = abstract.resolveEnabledPaths(allocator, self.workbench.io, self.service.enabledDescriptions(), self.runtime_dir) catch return false;
        defer abstract.freePaths(allocator, paths);
        var snapshot = abstract.RuntimeInventory.init(allocator, self.service.enabledDescriptions()) catch return false;
        const result = host.applyDescriptionDelta(paths, .{ .context = self, .complete = deltaComplete }) catch {
            snapshot.deinit();
            return false;
        };
        switch (result) {
            .unchanged => self.service.acceptRuntime(snapshot) catch {},
            .pending => self.pending_snapshot = snapshot,
            .restart_required => snapshot.deinit(),
        }
        return result != .restart_required;
    }

    fn deltaComplete(context: *anyopaque, accepted: bool) void {
        const self: *ExtensionHostRuntime = @ptrCast(@alignCast(context));
        var snapshot = self.pending_snapshot orelse return;
        self.pending_snapshot = null;
        if (accepted) self.service.acceptRuntime(snapshot) catch {} else snapshot.deinit();
        if (self.queued) {
            self.queued = false;
            self.reconcile_task.post();
        }
    }

    fn restart(context: *anyopaque) !void {
        const self: *ExtensionHostRuntime = @ptrCast(@alignCast(context));
        if (self.pending_snapshot != null) return error.ExtensionOperationInProgress;
        self.reconcile_task.schedule(null);
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
        try self.service.setRuntimeStatusService(null);
        if (self.host.*) |host| host.deinit();
        self.host.* = null;
        if (paths.len > 0) self.host.* = try Extensions.init(allocator, io, self.workbench.extensionHostServices(), paths, self.user_data_dir, self.runtime_dir);
        try self.service.setRuntimeStatusService(if (self.host.*) |host| host.interface() else null);
        self.workbench.requestFrame();
    }
};
