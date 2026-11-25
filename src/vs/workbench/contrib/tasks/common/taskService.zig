// Port of the provider registration contract from `src/vs/workbench/contrib/tasks/common/taskService.ts`.
// The terminal task picker consumes the extension host's task DTOs.
const std = @import("std");
const IDisposable = @import("../../../../base/common/lifecycle.zig").IDisposable;

pub const ITaskProvider = struct {
    context: *anyopaque,
    provide_tasks: *const fn (*anyopaque, std.mem.Allocator, std.json.Value) anyerror![]const std.json.Value,
};

pub const ITaskService = struct {
    context: *anyopaque,
    register_task_provider: *const fn (*anyopaque, ITaskProvider, []const u8) anyerror!IDisposable,

    pub fn registerTaskProvider(self: @This(), provider: ITaskProvider, kind: []const u8) !IDisposable {
        return self.register_task_provider(self.context, provider, kind);
    }
};
