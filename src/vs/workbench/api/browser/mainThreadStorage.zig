// Port of `src/vs/workbench/api/browser/mainThreadStorage.ts`.
//
// Terminal adaptation: the in-memory storage service is session-only, there is
// no profile storage migration, no storage sync and no cross-window watcher.
// Raw extension state is stored as JSON text under the extension id, exactly
// like `IExtensionStorageService.getExtensionStateRaw`/`setExtensionState`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const protocol = @import("../common/extHost.protocol.zig");
const storage_mod = @import("../../../platform/storage/common/storage.zig");
const InMemoryStorageService = storage_mod.InMemoryStorageService;
const StorageScope = storage_mod.StorageScope;
const StorageTarget = storage_mod.StorageTarget;
const StorageValue = storage_mod.StorageValue;

pub const MainThreadStorage = struct {
    allocator: Allocator,
    storage: InMemoryStorageService,

    pub fn init(allocator: Allocator) !MainThreadStorage {
        return .{
            .allocator = allocator,
            .storage = InMemoryStorageService.init(allocator),
        };
    }

    pub fn deinit(self: *MainThreadStorage) void {
        self.storage.deinit();
    }

    pub fn invoke(
        self: *MainThreadStorage,
        method: []const u8,
        args: []const rpc.Arg,
        arena: Allocator,
    ) !rpc.HandlerReply {
        if (std.mem.eql(u8, method, "$initializeExtensionStorage")) {
            const shared = boolArg(args, 0) orelse return error.InvalidArguments;
            const extension_id = stringArg(args, 1) orelse return error.InvalidArguments;
            const raw = self.storage.get(extension_id, scopeFor(shared), null);
            if (raw) |value| {
                return .{ .json = .{ .string = try arena.dupe(u8, value) } };
            }
            return .empty;
        }
        if (std.mem.eql(u8, method, "$setValue")) {
            const shared = boolArg(args, 0) orelse return error.InvalidArguments;
            const extension_id = stringArg(args, 1) orelse return error.InvalidArguments;
            const value = valueArg(args, 2) orelse return error.InvalidArguments;
            var output: std.Io.Writer.Allocating = .init(arena);
            try std.json.Stringify.value(value, .{}, &output.writer);
            try self.storage.store(extension_id, .{ .string = output.written() }, scopeFor(shared), .machine);
            return .empty;
        }
        if (std.mem.eql(u8, method, "$registerExtensionStorageKeysToSync")) {
            // No settings sync in the terminal workbench.
            return .empty;
        }
        if (methodKind(method) == .request) {
            return .{ .err = .{ .name = "Unsupported", .message = method } };
        }
        return .empty;
    }
};

fn scopeFor(shared: bool) StorageScope {
    return if (shared) .application_shared else .profile;
}

fn methodKind(method: []const u8) protocol.MethodKind {
    for (protocol.MainThreadStorage.methods) |candidate| {
        if (std.mem.eql(u8, candidate.name, method)) return candidate.kind;
    }
    return .notification;
}

fn boolArg(args: []const rpc.Arg, index: usize) ?bool {
    if (index >= args.len or args[index] != .json or args[index].json != .bool) return null;
    return args[index].json.bool;
}

fn stringArg(args: []const rpc.Arg, index: usize) ?[]const u8 {
    if (index >= args.len or args[index] != .json or args[index].json != .string) return null;
    return args[index].json.string;
}

fn valueArg(args: []const rpc.Arg, index: usize) ?std.json.Value {
    if (index >= args.len or args[index] != .json) return null;
    return args[index].json;
}

test "MainThreadStorage: mementos are stored per scope" {
    const allocator = std.testing.allocator;
    var actor = try MainThreadStorage.init(allocator);
    defer actor.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var initialize_args = [_]rpc.Arg{
        .{ .json = .{ .bool = false } },
        .{ .json = .{ .string = "vscode.typescript-language-features" } },
    };
    try std.testing.expectEqual(rpc.HandlerReply.empty, try actor.invoke("$initializeExtensionStorage", &initialize_args, scratch));

    var value: std.json.ObjectMap = .empty;
    try value.put(scratch, "suggestTS7NoPlugins.dismissed", .{ .bool = true });
    var set_args = [_]rpc.Arg{
        .{ .json = .{ .bool = false } },
        .{ .json = .{ .string = "vscode.typescript-language-features" } },
        .{ .json = .{ .object = value } },
    };
    try std.testing.expectEqual(rpc.HandlerReply.empty, try actor.invoke("$setValue", &set_args, scratch));

    const reply = try actor.invoke("$initializeExtensionStorage", &initialize_args, scratch);
    try std.testing.expect(reply == .json);
    try std.testing.expect(std.mem.indexOf(u8, reply.json.string, "suggestTS7NoPlugins") != null);

    var shared_args = [_]rpc.Arg{
        .{ .json = .{ .bool = true } },
        .{ .json = .{ .string = "vscode.typescript-language-features" } },
    };
    try std.testing.expectEqual(rpc.HandlerReply.empty, try actor.invoke("$initializeExtensionStorage", &shared_args, scratch));
}
