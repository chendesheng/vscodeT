// Port of the startup-phase subset of
// `src/vs/workbench/common/contributions.ts`.
//
// Upstream registers workbench contributions with a `WorkbenchPhase` and the
// contribution registry instantiates them when the lifecycle reaches that
// phase. The terminal workbench only needs the ordering for its startup
// contributions, so this file keeps the phase values and a small run registry;
// lazy/on-editor instantiations are not ported.
//
// `WorkspaceWatcher` is registered as `AfterRestored`, matching
// `src/vs/workbench/contrib/files/browser/files.contribution.ts`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const lifecycle_mod = @import("../services/lifecycle/common/lifecycle.zig");

pub const WorkbenchPhase = enum {
    block_startup,
    block_restore,
    after_restored,
    eventually,

    pub fn toLifecyclePhase(self: WorkbenchPhase) lifecycle_mod.LifecyclePhase {
        return switch (self) {
            .block_startup => .Starting,
            .block_restore => .Ready,
            .after_restored => .Restored,
            .eventually => .Eventually,
        };
    }
};

pub const WorkbenchContributions = struct {
    allocator: Allocator,
    entries: std.array_list.Managed(Entry),
    lifecycle: ?lifecycle_mod.ILifecycleService = null,

    const Entry = struct {
        phase: WorkbenchPhase,
        context: *anyopaque,
        run_fn: *const fn (context: *anyopaque) anyerror!void,
    };

    pub fn init(allocator: Allocator) WorkbenchContributions {
        return .{
            .allocator = allocator,
            .entries = std.array_list.Managed(Entry).init(allocator),
        };
    }

    pub fn deinit(self: *WorkbenchContributions) void {
        self.entries.deinit();
    }

    pub fn register(
        self: *WorkbenchContributions,
        phase: WorkbenchPhase,
        context: *anyopaque,
        run_fn: *const fn (context: *anyopaque) anyerror!void,
    ) !void {
        if (self.lifecycle) |service| return service.when(phase.toLifecyclePhase(), .{ .context = context, .run = run_fn });
        try self.entries.append(.{
            .phase = phase,
            .context = context,
            .run_fn = run_fn,
        });
    }

    pub fn start(self: *WorkbenchContributions, accessor: @import("../../platform/instantiation/common/instantiation.zig").ServicesAccessor) !void {
        const service = (try accessor.get(lifecycle_mod.lifecycle_service_id)).*;
        self.lifecycle = service;
        while (self.entries.items.len > 0) {
            const entry = self.entries.orderedRemove(0);
            try service.when(entry.phase.toLifecyclePhase(), .{ .context = entry.context, .run = entry.run_fn });
        }
    }
};
