// Port of `src/vs/platform/files/node/watcher/watcher.ts` and the manager
// shape of `nodejsWatcher.ts`.
//
// The terminal uses one in-process `UniversalWatcher`: recursive requests go
// to `ParcelWatcher`, non-recursive requests to `NodeJSWatcher`. Both share one
// parcel-watcher backend so the TUI polls a single inotify/kqueue handle.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const common = @import("../../common/watcher.zig");
const files = @import("../../common/files.zig");
const WatchRequest = common.WatchRequest;
const FileChange = files.FileChange;
const event = @import("../../../../base/common/event.zig");
const Emitter = event.Emitter;
const plib = @import("parcel/watcherLib/root.zig");
const parcel_mod = @import("parcel/parcelWatcher.zig");
const ParcelWatcher = parcel_mod.ParcelWatcher;
const nodejs_mod = @import("nodejs/nodejsWatcherLib.zig");
const NodeJSWatcher = nodejs_mod.NodeJSWatcher;

pub const UniversalWatcher = struct {
    allocator: Allocator,
    io: Io,
    lib: *plib.Lib,
    recursive: *ParcelWatcher,
    non_recursive: *NodeJSWatcher,

    on_change: Emitter([]const FileChange),
    on_log: Emitter(common.ILogMessage),
    on_error: Emitter(common.IWatcherErrorEvent),

    pub fn init(allocator: Allocator, io: Io) !*UniversalWatcher {
        const self = try allocator.create(UniversalWatcher);
        errdefer allocator.destroy(self);

        const lib = try plib.Lib.init(allocator, io);
        errdefer lib.deinit();
        const recursive = try ParcelWatcher.initWithLib(allocator, io, lib, .{}, false);
        errdefer recursive.deinit();
        const non_recursive = try NodeJSWatcher.initWithLib(allocator, io, lib, .{}, false);
        errdefer non_recursive.deinit();

        self.* = .{
            .allocator = allocator,
            .io = io,
            .lib = lib,
            .recursive = recursive,
            .non_recursive = non_recursive,
            .on_change = Emitter([]const FileChange).init(allocator),
            .on_log = Emitter(common.ILogMessage).init(allocator),
            .on_error = Emitter(common.IWatcherErrorEvent).init(allocator),
        };

        _ = try recursive.on_change.listen(self, forwardChange);
        _ = try recursive.on_log.listen(self, forwardLog);
        _ = try recursive.on_error.listen(self, forwardError);
        _ = try non_recursive.on_change.listen(self, forwardChange);
        _ = try non_recursive.on_log.listen(self, forwardLog);
        return self;
    }

    pub fn deinit(self: *UniversalWatcher) void {
        self.non_recursive.deinit();
        self.recursive.deinit();
        self.on_change.deinit();
        self.on_log.deinit();
        self.on_error.deinit();
        self.lib.deinit();
        self.allocator.destroy(self);
    }

    pub fn watch(self: *UniversalWatcher, requests: []const WatchRequest) !void {
        var recursive = std.array_list.Managed(WatchRequest).init(self.allocator);
        defer recursive.deinit();
        var non_recursive = std.array_list.Managed(WatchRequest).init(self.allocator);
        defer non_recursive.deinit();

        for (requests) |request| {
            if (request.recursive) {
                try recursive.append(request);
            } else {
                try non_recursive.append(request);
            }
        }

        try self.recursive.watch(recursive.items);
        try self.non_recursive.watch(non_recursive.items);
    }

    pub fn stop(self: *UniversalWatcher) void {
        self.non_recursive.stop();
        self.recursive.stop();
    }

    pub fn setVerboseLogging(self: *UniversalWatcher, enabled: bool) void {
        self.recursive.setVerboseLogging(enabled);
        self.non_recursive.setVerboseLogging(enabled);
    }

    pub fn poll(self: *UniversalWatcher, now_ms: i64) !bool {
        var changed = false;
        if (try self.non_recursive.poll(now_ms)) changed = true;
        if (try self.recursive.poll(now_ms)) changed = true;
        return changed;
    }

    pub fn nextTimeout(self: *const UniversalWatcher, now_ms: i64) ?u32 {
        return self.lib.nextTimeout(now_ms);
    }

    pub fn waitHandle(self: *const UniversalWatcher) plib.WaitHandle {
        return self.lib.waitHandle();
    }

    pub fn isSuspended(self: *const UniversalWatcher, request: *const WatchRequest) @import("baseWatcher.zig").SuspensionState {
        return if (request.recursive)
            self.recursive.isSuspended(request)
        else
            self.non_recursive.isSuspended(request);
    }

    pub fn log(self: *UniversalWatcher, message: common.ILogMessage) void {
        self.on_log.fire(message) catch {};
    }
};

fn forwardChange(changes: []const FileChange, self: *UniversalWatcher) !void {
    try self.on_change.fire(changes);
}

fn forwardLog(message: common.ILogMessage, self: *UniversalWatcher) !void {
    try self.on_log.fire(message);
}

fn forwardError(error_event: common.IWatcherErrorEvent, self: *UniversalWatcher) !void {
    try self.on_error.fire(error_event);
}
