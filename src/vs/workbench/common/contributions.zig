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

pub const WorkbenchPhase = enum {
    block_startup,
    block_restore,
    after_restored,
    eventually,
};

pub const WorkbenchContributions = struct {
    allocator: Allocator,
    entries: std.array_list.Managed(Entry),

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
        try self.entries.append(.{
            .phase = phase,
            .context = context,
            .run_fn = run_fn,
        });
    }

    pub fn run(self: *WorkbenchContributions, phase: WorkbenchPhase) !void {
        for (self.entries.items) |entry| {
            if (entry.phase != phase) continue;
            try entry.run_fn(entry.context);
        }
    }
};
