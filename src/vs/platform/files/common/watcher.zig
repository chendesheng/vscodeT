// Port of `src/vs/platform/files/common/watcher.ts`.
//
// Terminal adaptation: requests carry path strings instead of `URI`s, and the
// watcher runs in-process instead of behind the Electron IPC clients. Event and
// log subscriptions use explicit listener ids (the Zig analogue of upstream's
// `Event`/`IDisposable` pair).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const glob = @import("../../../base/common/glob.zig");
const files = @import("files.zig");
const FileChange = files.FileChange;
const FileChangeType = files.FileChangeType;
const FileChangeFilter = files.FileChangeFilter;
const isParent = files.isParent;

pub const PatternSource = glob.Source;

/// Mirrors upstream `IWatchRequest`.
pub const WatchRequest = struct {
    path: []const u8,
    recursive: bool,
    excludes: []const []const u8 = &.{},
    includes: []const PatternSource = &.{},
    correlationId: ?u32 = null,
    filter: ?u8 = null,
    pollingInterval: ?u32 = null,
};

pub fn isWatchRequestWithCorrelation(request: *const WatchRequest) bool {
    return request.correlationId != null;
}

pub fn isRecursiveWatchRequest(request: *const WatchRequest) bool {
    return request.recursive;
}

/// A copy of the requests and all of their strings. `watch()` callers may drop
/// their requests as soon as the call returns.
pub const OwnedRequests = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    requests: []WatchRequest,

    pub fn deinit(self: *OwnedRequests) void {
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};

pub fn copyRequests(allocator: Allocator, requests: []const WatchRequest) !*OwnedRequests {
    const self = try allocator.create(OwnedRequests);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .requests = &.{},
    };
    errdefer self.arena.deinit();

    const arena = self.arena.allocator();
    const copied = try arena.alloc(WatchRequest, requests.len);
    for (requests, 0..) |request, index| {
        const excludes = try arena.alloc([]const u8, request.excludes.len);
        for (request.excludes, 0..) |exclude, exclude_index| {
            excludes[exclude_index] = try arena.dupe(u8, exclude);
        }
        const includes = try arena.alloc(PatternSource, request.includes.len);
        for (request.includes, 0..) |source, source_index| {
            includes[source_index] = switch (source) {
                .string => |pattern| .{ .string = try arena.dupe(u8, pattern) },
                .relative => |relative| .{ .relative = .{
                    .base = try arena.dupe(u8, relative.base),
                    .pattern = try arena.dupe(u8, relative.pattern),
                } },
            };
        }
        copied[index] = .{
            .path = try arena.dupe(u8, request.path),
            .recursive = request.recursive,
            .excludes = excludes,
            .includes = includes,
            .correlationId = request.correlationId,
            .filter = request.filter,
            .pollingInterval = request.pollingInterval,
        };
    }
    self.requests = copied;
    return self;
}

pub const LogMessageType = enum { trace, warn, @"error", info, debug };

pub const ILogMessage = struct {
    type: LogMessageType,
    message: []const u8,
};

pub const IWatcherErrorEvent = struct {
    @"error": []const u8,
    request: ?*const WatchRequest = null,
};

pub const ChangeListener = struct {
    context: *anyopaque,
    callback: *const fn (context: *anyopaque, changes: []const FileChange) anyerror!void,
};

pub const LogListener = struct {
    context: *anyopaque,
    callback: *const fn (context: *anyopaque, message: ILogMessage) anyerror!void,
};

pub const ErrorListener = struct {
    context: *anyopaque,
    callback: *const fn (context: *anyopaque, event: IWatcherErrorEvent) anyerror!void,
};

pub const ListenerId = usize;

/// Mirrors upstream `IWatcher`. The explicit poll function is the terminal
/// replacement for the watcher process event loop.
pub const IWatcher = struct {
    context: *anyopaque,
    watch: *const fn (context: *anyopaque, requests: []const WatchRequest) anyerror!void,
    set_verbose_logging: *const fn (context: *anyopaque, enabled: bool) anyerror!void,
    stop: *const fn (context: *anyopaque) anyerror!void,
    subscribe_changes: *const fn (context: *anyopaque, listener: ChangeListener) anyerror!ListenerId,
    subscribe_logs: *const fn (context: *anyopaque, listener: LogListener) anyerror!ListenerId,
    subscribe_errors: *const fn (context: *anyopaque, listener: ErrorListener) anyerror!ListenerId,
    unsubscribe_changes: *const fn (context: *anyopaque, id: ListenerId) void,
    unsubscribe_logs: *const fn (context: *anyopaque, id: ListenerId) void,
    unsubscribe_errors: *const fn (context: *anyopaque, id: ListenerId) void,
};

pub const IRecursiveWatcher = struct {
    context: *anyopaque,
    watch: *const fn (context: *anyopaque, requests: []const WatchRequest) anyerror!void,
    set_verbose_logging: *const fn (context: *anyopaque, enabled: bool) anyerror!void,
    stop: *const fn (context: *anyopaque) anyerror!void,
    subscribe_changes: *const fn (context: *anyopaque, listener: ChangeListener) anyerror!ListenerId,
    subscribe_logs: *const fn (context: *anyopaque, listener: LogListener) anyerror!ListenerId,
    subscribe_errors: *const fn (context: *anyopaque, listener: ErrorListener) anyerror!ListenerId,
    unsubscribe_changes: *const fn (context: *anyopaque, id: ListenerId) void,
    unsubscribe_logs: *const fn (context: *anyopaque, id: ListenerId) void,
    unsubscribe_errors: *const fn (context: *anyopaque, id: ListenerId) void,
};

pub const SubscriptionCallback = struct {
    context: *anyopaque,
    callback: *const fn (context: *anyopaque, failed: bool, change: ?FileChange) anyerror!void,
};

pub const IRecursiveWatcherWithSubscribe = struct {
    watcher: IRecursiveWatcher,
    subscribe_path: *const fn (context: *anyopaque, path: []const u8, callback: SubscriptionCallback) anyerror!?ListenerId,
    unsubscribe_path: *const fn (context: *anyopaque, id: ListenerId) void,
};

pub const INonRecursiveWatcher = struct {
    context: *anyopaque,
    watch: *const fn (context: *anyopaque, requests: []const WatchRequest) anyerror!void,
    set_verbose_logging: *const fn (context: *anyopaque, enabled: bool) anyerror!void,
    stop: *const fn (context: *anyopaque) anyerror!void,
    subscribe_changes: *const fn (context: *anyopaque, listener: ChangeListener) anyerror!ListenerId,
    subscribe_logs: *const fn (context: *anyopaque, listener: LogListener) anyerror!ListenerId,
    unsubscribe_changes: *const fn (context: *anyopaque, id: ListenerId) void,
    unsubscribe_logs: *const fn (context: *anyopaque, id: ListenerId) void,
};

pub const IUniversalWatcher = IWatcher;

/// Resolves a plain relative pattern against the watch request path. Patterns
/// that start with `**` or are absolute stay global, like upstream.
pub fn normalizeWatcherPattern(path: []const u8, pattern: PatternSource) PatternSource {
    return switch (pattern) {
        .relative => pattern,
        .string => |value| blk: {
            if (std.mem.startsWith(u8, value, "**") or std.fs.path.isAbsolute(value)) break :blk pattern;
            break :blk .{ .relative = .{ .base = path, .pattern = value } };
        },
    };
}

pub fn parseWatcherPatterns(
    arena: Allocator,
    path: []const u8,
    patterns: []const PatternSource,
    ignore_case: bool,
) ![]const glob.Pattern {
    const sources = try arena.alloc(PatternSource, patterns.len);
    for (patterns, 0..) |pattern, index| {
        sources[index] = normalizeWatcherPattern(path, pattern);
    }
    const expression = try glob.Expression.initSources(arena, sources, .{ .ignore_case = ignore_case });
    return expression.patterns;
}

pub fn isFiltered(event: FileChange, filter: ?u8) bool {
    const value = filter orelse return false;
    return switch (event.type) {
        .ADDED => (value & FileChangeFilter.ADDED) == 0,
        .DELETED => (value & FileChangeFilter.DELETED) == 0,
        .UPDATED => (value & FileChangeFilter.UPDATED) == 0,
    };
}

pub fn requestFilterToString(filter: ?u8) []const u8 {
    const value = filter orelse return "<none>";
    if (value == 0) return "<all>";
    _ = FileChangeFilter.all;
    return switch (value & FileChangeFilter.all) {
        FileChangeFilter.ADDED => "[Added]",
        FileChangeFilter.DELETED => "[Deleted]",
        FileChangeFilter.UPDATED => "[Updated]",
        FileChangeFilter.ADDED | FileChangeFilter.DELETED => "[Added, Deleted]",
        FileChangeFilter.ADDED | FileChangeFilter.UPDATED => "[Added, Updated]",
        FileChangeFilter.DELETED | FileChangeFilter.UPDATED => "[Deleted, Updated]",
        else => "[Added, Deleted, Updated]",
    };
}

const CoalescedEntry = struct {
    change: FileChange,
    alive: bool,
};

/// Port of upstream `coalesceEvents`/`EventCoalescer`.
pub fn coalesceEvents(allocator: Allocator, changes: []const FileChange) ![]FileChange {
    return coalesceEventsWithCase(allocator, changes, builtin.os.tag != .linux);
}

pub fn coalesceEventsWithCase(
    allocator: Allocator,
    changes: []const FileChange,
    ignore_case: bool,
) ![]FileChange {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var entries = std.array_list.Managed(CoalescedEntry).init(allocator);
    defer entries.deinit();
    var index_by_key = std.StringHashMap(usize).init(allocator);
    defer index_by_key.deinit();

    for (changes) |change| {
        const key = try caseKey(arena_allocator, change.resource, ignore_case);
        if (index_by_key.get(key)) |index| {
            const existing = &entries.items[index];
            var keep_event = false;
            const existing_path = existing.change.resource;
            const new_path = change.resource;

            if (!std.mem.eql(u8, existing_path, new_path) and
                (change.type == .DELETED or change.type == .ADDED))
            {
                // Keep both sides of a case-only rename.
                keep_event = true;
            } else if (existing.change.type == .ADDED and change.type == .DELETED) {
                existing.alive = false;
                _ = index_by_key.remove(key);
            } else if (existing.change.type == .DELETED and change.type == .ADDED) {
                existing.change.type = .UPDATED;
            } else if (existing.change.type == .ADDED and change.type == .UPDATED) {
                // Keep the created event.
            } else {
                existing.change.type = change.type;
            }

            if (keep_event) {
                try appendCoalesced(allocator, &entries, &index_by_key, arena_allocator, change, ignore_case);
            }
        } else {
            try appendCoalesced(allocator, &entries, &index_by_key, arena_allocator, change, ignore_case);
        }
    }

    var add_or_change = std.array_list.Managed(FileChange).init(allocator);
    defer add_or_change.deinit();
    var deleted_paths = std.array_list.Managed([]const u8).init(allocator);
    defer deleted_paths.deinit();
    var deleted = std.array_list.Managed(FileChange).init(allocator);
    defer deleted.deinit();

    for (entries.items) |entry| {
        if (!entry.alive) continue;
        if (entry.change.type != .DELETED) {
            try add_or_change.append(entry.change);
        } else {
            try deleted.append(entry.change);
        }
    }

    std.mem.sort(FileChange, deleted.items, {}, struct {
        fn lessThan(_: void, a: FileChange, b: FileChange) bool {
            return a.resource.len < b.resource.len;
        }
    }.lessThan);

    for (deleted.items) |change| {
        var ignored = false;
        for (deleted_paths.items) |deleted_path| {
            if (isParent(change.resource, deleted_path, ignore_case)) {
                ignored = true;
                break;
            }
        }
        if (!ignored) {
            try deleted_paths.append(change.resource);
            try add_or_change.append(change);
        }
    }

    return try add_or_change.toOwnedSlice();
}

fn appendCoalesced(
    allocator: Allocator,
    entries: *std.array_list.Managed(CoalescedEntry),
    index_by_key: *std.StringHashMap(usize),
    key_allocator: Allocator,
    change: FileChange,
    ignore_case: bool,
) !void {
    const key = try caseKey(key_allocator, change.resource, ignore_case);
    try entries.append(.{ .change = change, .alive = true });
    try index_by_key.put(key, entries.items.len - 1);
    _ = allocator;
}

fn caseKey(allocator: Allocator, value: []const u8, ignore_case: bool) ![]const u8 {
    if (!ignore_case) return value;
    const copy = try allocator.dupe(u8, value);
    for (copy) |*ch| ch.* = std.ascii.toLower(ch.*);
    return copy;
}

/// Hash used by `BaseWatcher` for uncorrelated requests.
pub fn hashRequest(request: *const WatchRequest) u32 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(request.path);
    hasher.update(if (request.recursive) "1" else "0");
    for (request.excludes) |exclude| {
        hasher.update("\x00");
        hasher.update(exclude);
    }
    for (request.includes) |include| {
        switch (include) {
            .string => |value| {
                hasher.update("\x01");
                hasher.update(value);
            },
            .relative => |relative| {
                hasher.update("\x02");
                hasher.update(relative.base);
                hasher.update("\x03");
                hasher.update(relative.pattern);
            },
        }
    }
    if (request.correlationId) |id| {
        var buffer: [4]u8 = undefined;
        std.mem.writeInt(u32, &buffer, id, .big);
        hasher.update(&buffer);
    }
    if (request.filter) |filter| hasher.update(&[_]u8{filter});
    if (request.pollingInterval) |interval| {
        var buffer: [4]u8 = undefined;
        std.mem.writeInt(u32, &buffer, interval, .big);
        hasher.update(&buffer);
    }
    return @truncate(hasher.final());
}

test "coalesceEvents: create/delete/update matrix" {
    const allocator = std.testing.allocator;
    const changes = [_]FileChange{
        .{ .type = .ADDED, .resource = "/a" },
        .{ .type = .DELETED, .resource = "/a" },
        .{ .type = .UPDATED, .resource = "/b" },
    };
    const result = try coalesceEventsWithCase(allocator, &changes, false);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("/b", result[0].resource);
}

test "coalesceEvents: folder delete hides children" {
    const allocator = std.testing.allocator;
    const changes = [_]FileChange{
        .{ .type = .DELETED, .resource = "/root/folder" },
        .{ .type = .DELETED, .resource = "/root/folder/child" },
        .{ .type = .ADDED, .resource = "/root/added" },
    };
    const result = try coalesceEventsWithCase(allocator, &changes, false);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 2), result.len);
}

test "parseWatcherPatterns: relative and globstar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const patterns = [_]PatternSource{
        .{ .string = "*.js" },
        .{ .string = "**/*.ts" },
    };
    const parsed = try parseWatcherPatterns(arena.allocator(), "/users/data/src", &patterns, false);
    try std.testing.expectEqual(@as(usize, 2), parsed.len);
    try std.testing.expect(parsed[0].matches("/users/data/src/foo.js"));
    try std.testing.expect(!parsed[0].matches("/users/data/src/bar/foo.js"));
    try std.testing.expect(parsed[1].matches("/users/data/src/bar/foo.ts"));
}
