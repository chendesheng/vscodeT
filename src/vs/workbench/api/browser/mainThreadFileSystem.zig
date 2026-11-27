// Port of the workspace.fs consumer side of
// `src/vs/workbench/api/browser/mainThreadFileSystem.ts`.
// Native resources go through IFileService. Remote extension-owned providers
// are not yet ported; unsupported registration fails explicitly.
const std = @import("std");
const files = @import("../../../platform/files/common/files.zig");
const std_uri = @import("../../../base/common/stdUri.zig");
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const Allocator = std.mem.Allocator;

pub const MainThreadFileSystem = struct {
    service: files.IFileService,

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
