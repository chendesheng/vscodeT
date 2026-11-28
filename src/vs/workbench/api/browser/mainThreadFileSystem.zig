// Port of the workspace.fs consumer side of
// `src/vs/workbench/api/browser/mainThreadFileSystem.ts`.
// Native resources go through IFileService. Remote extension-owned providers
// are not yet ported; unsupported registration fails explicitly.
const std = @import("std");
const files = @import("../../../platform/files/common/files.zig");
const std_uri = @import("../../../base/common/stdUri.zig");
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const Allocator = std.mem.Allocator;
const window_dispatch = @import("../../../base/common/windowDispatch.zig");

pub const MainThreadFileSystem = struct {
    service: files.IFileService,
    window: ?*window_dispatch.Queue = null,
    allocator: Allocator = std.heap.page_allocator,
    requests: std.Io.Group = .init,

    pub fn deinit(self: *MainThreadFileSystem) void {
        if (self.window) |window| self.requests.cancel(window.io);
    }

    /// The RPC decoder's arena and frame are borrowed until invoke returns.
    /// Keep a separate owned request for the window fiber, and settle the
    /// protocol reply only when its filesystem operation has completed.
    pub fn invokeAsync(self: *MainThreadFileSystem, method: []const u8, args: []const rpc.Arg, arena: Allocator) !rpc.HandlerReply {
        if (self.window == null or self.window.?.scheduler == null)
            return self.invoke(method, args, arena);

        const request = try self.allocator.create(Request);
        errdefer self.allocator.destroy(request);
        request.* = .{ .owner = self, .arena = .init(self.allocator), .method = undefined, .args = undefined };
        errdefer request.arena.deinit();
        const a = request.arena.allocator();
        request.method = try a.dupe(u8, method);
        const owned = try a.alloc(rpc.Arg, args.len);
        for (args, owned) |arg, *target| target.* = switch (arg) {
            .json => |value| .{ .json = try rpc.cloneJsonValue(a, value) },
            .buffer => |bytes| .{ .buffer = try a.dupe(u8, bytes) },
            .undefined => .undefined,
        };
        request.args = owned;
        return .{ .deferred = .{ .context = request, .start = Request.start } };
    }

    const Request = struct {
        owner: *MainThreadFileSystem,
        arena: std.heap.ArenaAllocator,
        method: []const u8,
        args: []const rpc.Arg,

        fn start(context: *anyopaque, channel: *rpc.RpcProtocol, id: u32) void {
            const self: *Request = @ptrCast(@alignCast(context));
            const owner = self.owner;
            owner.requests.concurrent(owner.window.?.io, run, .{ self, channel, id }) catch {
                channel.sendReply(id, .{ .err = .{ .name = "Unavailable", .message = "File operation could not be scheduled" } });
                self.destroy();
            };
        }

        fn run(self: *Request, channel: *rpc.RpcProtocol, id: u32) void {
            defer self.destroy();
            self.owner.window.?.io.checkCancel() catch {
                channel.sendReply(id, .{ .err = .{ .name = "Canceled", .message = "File operation canceled" } });
                return;
            };
            const io = self.owner.window.?.io;
            const previous = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(previous);
            const reply = self.owner.invoke(self.method, self.args, self.arena.allocator()) catch |err| rpc.HandlerReply{ .err = .{ .name = @errorName(err), .message = @errorName(err) } };
            channel.sendReply(id, reply);
        }

        fn destroy(self: *Request) void {
            const allocator = self.owner.allocator;
            self.arena.deinit();
            allocator.destroy(self);
        }
    };

    pub fn invoke(self: *const MainThreadFileSystem, method: []const u8, args: []const rpc.Arg, arena: Allocator) !rpc.HandlerReply {
        return self.dispatch(method, args, arena) catch |err| .{ .err = .{
            .name = switch (err) {
                error.FileNotFound => "EntryNotFound",
                error.FileExists => "EntryExists",
                error.FileNotADirectory => "EntryNotADirectory",
                error.FileIsADirectory => "EntryIsADirectory",
                error.NoPermissions, error.FileReadonly, error.AccessDenied => "NoPermissions",
                error.ProviderUnavailable, error.TrashUnavailable, error.Unavailable, error.UnsupportedFileSystemProvider => "Unavailable",
                else => "Unknown",
            },
            .message = @errorName(err),
        } };
    }

    fn dispatch(self: *const MainThreadFileSystem, method: []const u8, args: []const rpc.Arg, arena: Allocator) !rpc.HandlerReply {
        if (std.mem.eql(u8, method, "$ensureActivation")) {
            const scheme = try jsonArg(args, 0);
            if (scheme != .string) return error.InvalidArguments;
            if (!self.service.hasProvider(.{ .scheme = scheme.string, .path = .{ .raw = "/" } })) return error.ProviderUnavailable;
            return .empty;
        }
        if (std.mem.eql(u8, method, "$registerFileSystemProvider") or std.mem.eql(u8, method, "$unregisterProvider") or std.mem.eql(u8, method, "$onFileSystemChange")) return error.UnsupportedFileSystemProvider;
        const resource = try uriArg(args, 0, arena);
        if (std.mem.eql(u8, method, "$stat")) {
            const stat = try self.service.stat(resource);
            var result: std.json.ObjectMap = .empty;
            try result.put(arena, "type", .{ .integer = stat.type });
            // The native stat service records nanoseconds; VS Code FileStat
            // exposes Unix milliseconds to extension code.
            try result.put(arena, "ctime", .{ .integer = @divTrunc(stat.ctime, std.time.ns_per_ms) });
            try result.put(arena, "mtime", .{ .integer = @divTrunc(stat.mtime, std.time.ns_per_ms) });
            try result.put(arena, "size", .{ .integer = @intCast(stat.size) });
            if (stat.permissions) |permissions| try result.put(arena, "permissions", .{ .integer = permissions });
            return .{ .json = .{ .object = result } };
        }
        if (std.mem.eql(u8, method, "$readdir")) {
            const entries = try self.service.readDirectory(arena, resource);
            var result = std.json.Array.init(arena);
            for (entries) |entry| {
                var pair = std.json.Array.init(arena);
                try pair.append(.{ .string = entry.name });
                try pair.append(.{ .integer = entry.type });
                try result.append(.{ .array = pair });
            }
            return .{ .json = .{ .array = result } };
        }
        if (std.mem.eql(u8, method, "$readFile")) return .{ .buffer = try self.service.readFile(arena, resource) };
        if (std.mem.eql(u8, method, "$writeFile")) {
            if (args.len < 2 or args[1] != .buffer) return error.InvalidArguments;
            try self.service.writeFile(resource, args[1].buffer, .{ .create = true, .overwrite = true });
        } else if (std.mem.eql(u8, method, "$mkdir")) {
            try self.service.createFolder(resource);
        } else if (std.mem.eql(u8, method, "$delete")) {
            const opts = try jsonArg(args, 1);
            try self.service.del(resource, .{ .recursive = boolField(opts, "recursive"), .useTrash = boolField(opts, "useTrash"), .atomic = boolField(opts, "atomic") });
        } else if (std.mem.eql(u8, method, "$rename") or std.mem.eql(u8, method, "$copy")) {
            const target = try uriArg(args, 1, arena);
            const opts = try jsonArg(args, 2);
            if (std.mem.eql(u8, method, "$rename")) try self.service.move(resource, target, boolField(opts, "overwrite")) else try self.service.copy(resource, target, boolField(opts, "overwrite"));
        } else return error.UnsupportedFileSystemProvider;
        return .empty;
    }
};

fn jsonArg(args: []const rpc.Arg, index: usize) !std.json.Value {
    if (index >= args.len or args[index] != .json) return error.InvalidArguments;
    return args[index].json;
}

fn uriArg(args: []const rpc.Arg, index: usize, arena: Allocator) !std.Uri {
    const uri = try std.Uri.parse(try std_uri.encodedResourceFromJson(arena, try jsonArg(args, index)));
    if (!std.mem.eql(u8, uri.scheme, "file")) return error.UnsupportedFileSystemProvider;
    return uri;
}

fn boolField(value: std.json.Value, field: []const u8) bool {
    if (value != .object) return false;
    const prop = value.object.get(field) orelse return false;
    return prop == .bool and prop.bool;
}
