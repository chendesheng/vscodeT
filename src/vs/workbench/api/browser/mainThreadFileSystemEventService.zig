// Port of `src/vs/workbench/api/browser/mainThreadFileSystemEventService.ts`.
// Native watch requests use the shared FileWatcherService. Working-copy file
// operation participants are a separate, not yet ported contract.
const std = @import("std");
const files = @import("../../../platform/files/common/files.zig");
const watcher = @import("../../../platform/files/node/watcher/fileWatcherService.zig");
const common = @import("../../../platform/files/common/watcher.zig");
const std_uri = @import("../../../base/common/stdUri.zig");
const manager = @import("../../services/extensions/common/extensionHostManager.zig");
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const Allocator = std.mem.Allocator;

pub const MainThreadFileSystemEventService = struct {
    allocator: Allocator,
    service: *watcher.FileWatcherService,
    files_service: files.IFileService,
    host: Host,
    watches: std.AutoHashMap(u64, Watch),
    listener: ?usize = null,
    next_correlation: u32 = 0,

    const Watch = struct {
        handle: *watcher.WatchHandle,
        correlation: ?u32,
    };
    pub const Host = struct {
        context: *anyopaque,
        notify: *const fn (*anyopaque, std.json.Value) anyerror!void,
    };

    pub fn init(allocator: Allocator, service: *watcher.FileWatcherService, files_service: files.IFileService, host: Host) MainThreadFileSystemEventService {
        return .{ .allocator = allocator, .service = service, .files_service = files_service, .host = host, .watches = .init(allocator) };
    }

    pub fn attach(self: *MainThreadFileSystemEventService) !void {
        self.listener = try self.service.on_did_change.listen(self, onFileChanges);
    }

    pub fn deinit(self: *MainThreadFileSystemEventService) void {
        if (self.listener) |id| self.service.on_did_change.unlisten(id);
        var it = self.watches.valueIterator();
        while (it.next()) |watch| watch.handle.dispose();
        self.watches.deinit();
    }

    pub fn invoke(self: *MainThreadFileSystemEventService, method: []const u8, args: []const rpc.Arg, arena: Allocator) !rpc.HandlerReply {
        if (std.mem.eql(u8, method, "$unwatch")) {
            const key = try sessionKey(args, 0);
            if (self.watches.fetchRemove(key)) |old| old.value.handle.dispose();
        } else if (std.mem.eql(u8, method, "$watch")) {
            const key = try sessionKey(args, 1);
            if (args.len < 5 or args[2] != .json or args[3] != .json or args[3].json != .object or args[4] != .json or args[4].json != .bool) return error.InvalidArguments;
            const resource = try std.Uri.parse(try std_uri.encodedResourceFromJson(arena, args[2].json));
            if (!std.mem.eql(u8, resource.scheme, "file")) return error.UnsupportedFileSystemProvider;
            const path = try std_uri.fsPath(resource, arena);
            const opts = args[3].json.object;
            const recursive = opts.get("recursive") orelse return error.InvalidArguments;
            if (recursive != .bool) return error.InvalidArguments;
            var options: watcher.WatchOptions = .{ .recursive = recursive.bool };
            if (options.recursive) {
                if (self.files_service.stat(resource)) |stat| {
                    if (!files.FileType.isDirectory(stat.type)) options.recursive = false;
                } else |_| {}
            }
            if (opts.get("excludes")) |excludes| {
                if (excludes == .array) {
                    const result = try arena.alloc([]const u8, excludes.array.items.len);
                    for (excludes.array.items, result) |item, *dest| {
                        if (item != .string) return error.InvalidArguments;
                        dest.* = item.string;
                    }
                    options.excludes = result;
                }
            }
            if (opts.get("includes")) |includes| {
                if (includes == .array) {
                    const result = try arena.alloc(common.PatternSource, includes.array.items.len);
                    for (includes.array.items, result) |item, *dest| {
                        if (item == .string) {
                            dest.* = .{ .string = item.string };
                        } else if (item == .object) {
                            const base = item.object.get("base") orelse return error.InvalidArguments;
                            const pattern = item.object.get("pattern") orelse return error.InvalidArguments;
                            if (base != .string or pattern != .string) return error.InvalidArguments;
                            dest.* = .{ .relative = .{ .base = base.string, .pattern = pattern.string } };
                        } else return error.InvalidArguments;
                    }
                    options.includes = result;
                }
            }
            if (opts.get("filter")) |filter| if (filter == .integer) {
                options.filter = std.math.cast(u8, filter.integer);
            };
            // Upstream currently passes false for extensions, but retains the
            // non-recursive correlated request path.
            if (args[4].json.bool and !options.recursive) {
                self.next_correlation += 1;
                options.correlation_id = self.next_correlation;
            }
            const handle = try self.service.watch(path, options);
            errdefer handle.dispose();
            const entry = try self.watches.getOrPut(key);
            if (entry.found_existing) entry.value_ptr.handle.dispose();
            entry.value_ptr.* = .{ .handle = handle, .correlation = options.correlation_id };
        } else return error.UnsupportedMethod;
        return .empty;
    }

    fn onFileChanges(changes: []const files.FileChange, self: *MainThreadFileSystemEventService) !void {
        try self.sendChanges(changes, null, null);
        var it = self.watches.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.correlation) |id| try self.sendChanges(changes, id, @bitCast(entry.key_ptr.*));
        }
    }

    fn sendChanges(self: *MainThreadFileSystemEventService, changes: []const files.FileChange, correlation: ?u32, session: ?f64) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var created = std.json.Array.init(a);
        var changed = std.json.Array.init(a);
        var deleted = std.json.Array.init(a);
        for (changes) |change| {
            if (change.cId != correlation) continue;
            const uri = try manager.fileUri(a, change.resource);
            switch (change.type) {
                .ADDED => try created.append(uri),
                .UPDATED => try changed.append(uri),
                .DELETED => try deleted.append(uri),
            }
        }
        if (created.items.len + changed.items.len + deleted.items.len == 0) return;
        var event: std.json.ObjectMap = .empty;
        try event.put(a, "created", .{ .array = created });
        try event.put(a, "changed", .{ .array = changed });
        try event.put(a, "deleted", .{ .array = deleted });
        if (session) |id| try event.put(a, "session", .{ .float = id });
        try self.host.notify(self.host.context, .{ .object = event });
    }
};

fn sessionKey(args: []const rpc.Arg, index: usize) !u64 {
    if (index >= args.len or args[index] != .json) return error.InvalidArguments;
    // ExtHostFileSystemWatcher uses Math.random(), not an integer handle.
    const session: f64 = switch (args[index].json) {
        .float => |number| number,
        .integer => |number| @floatFromInt(number),
        else => return error.InvalidArguments,
    };
    return @bitCast(session);
}
