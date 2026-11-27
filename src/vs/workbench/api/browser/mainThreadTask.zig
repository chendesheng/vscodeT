// Port of the contributed task provider bridge from `src/vs/workbench/api/browser/mainThreadTask.ts`.
const std = @import("std");
const tasks = @import("../../contrib/tasks/common/taskService.zig");
const manager = @import("../../services/extensions/common/extensionHostManager.zig");
const protocol = @import("../common/extHost.protocol.zig");
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const proxy = @import("../../services/extensions/common/proxyIdentifier.zig").identifierFromEnum;
const IDisposable = @import("../../../base/common/lifecycle.zig").IDisposable;

pub const MainThreadTask = struct {
    allocator: std.mem.Allocator,
    host: *manager.HostManager,
    window: *@import("../../../base/common/windowDispatch.zig").Queue,
    service: tasks.ITaskService,
    providers: std.AutoArrayHashMapUnmanaged(u32, *Provider) = .empty,

    const Provider = struct {
        handle: u32,
        host: *manager.HostManager,
        window: *@import("../../../base/common/windowDispatch.zig").Queue,
        registration: IDisposable,

        fn interface(self: *@This()) tasks.ITaskProvider {
            return .{ .context = self, .provide_tasks = provideTasks };
        }

        fn provideTasks(context: *anyopaque, arena: std.mem.Allocator, valid_types: std.json.Value) ![]const std.json.Value {
            const self: *@This() = @ptrCast(@alignCast(context));
            const args = [_]rpc.Arg{ .{ .json = .{ .integer = self.handle } }, .{ .json = valid_types } };
            const result = try self.host.requestAwait(self.window, arena, proxy(protocol.ExtHostContext.ExtHostTask), "$provideTasks", &args, .None, 10000);
            if (result != .object) return &.{};
            const list = result.object.get("tasks") orelse return &.{};
            return if (list == .array) list.array.items else &.{};
        }
    };

    pub fn deinit(self: *@This()) void {
        while (self.providers.count() > 0) self.unregisterTaskProvider(self.providers.keys()[self.providers.count() - 1]);
        self.providers.deinit(self.allocator);
    }

    fn registerTaskProvider(self: *@This(), handle: u32, kind: []const u8) !void {
        const provider = try self.allocator.create(Provider);
        errdefer self.allocator.destroy(provider);
        provider.* = .{ .handle = handle, .host = self.host, .window = self.window, .registration = undefined };
        provider.registration = try self.service.registerTaskProvider(provider.interface(), kind);
        errdefer provider.registration.dispose();
        if (try self.providers.fetchPut(self.allocator, handle, provider)) |old| {
            old.value.registration.dispose();
            self.allocator.destroy(old.value);
        }
    }

    fn unregisterTaskProvider(self: *@This(), handle: u32) void {
        const entry = self.providers.fetchOrderedRemove(handle) orelse return;
        entry.value.registration.dispose();
        self.allocator.destroy(entry.value);
    }

    pub fn invoke(self: *@This(), method: []const u8, args: []const rpc.Arg) !rpc.HandlerReply {
        const register = std.mem.eql(u8, method, "$registerTaskProvider");
        if (register or std.mem.eql(u8, method, "$unregisterTaskProvider")) {
            if (args.len < 1 or args[0] != .json or args[0].json != .integer) return error.InvalidArguments;
            const handle = std.math.cast(u32, args[0].json.integer) orelse return error.InvalidArguments;
            if (register) {
                if (args.len < 2 or args[1] != .json or args[1].json != .string) return error.InvalidArguments;
                try self.registerTaskProvider(handle, args[1].json.string);
            } else self.unregisterTaskProvider(handle);
        } else if (!std.mem.eql(u8, method, "$registerTaskSystem") and !std.mem.eql(u8, method, "$registerSupportedExecutions")) {
            return .{ .err = .{ .name = "Unsupported", .message = method } };
        }
        return .empty;
    }
};
