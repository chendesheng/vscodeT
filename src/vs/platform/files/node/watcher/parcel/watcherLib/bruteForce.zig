// Port of `src/shared/BruteForceBackend.cc` from `@parcel/watcher` v2.5.6
// (external package).
//
// The terminal implements snapshot and polling operations in `root.zig`; this
// backend only exists so a request can be subscribed on platforms without a
// native event source. It never produces events itself.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const watcher_mod = @import("watcher.zig");
const Watcher = watcher_mod.Watcher;
const root_mod = @import("root.zig");
const WaitHandle = root_mod.WaitHandle;

pub const Backend = struct {
    allocator: Allocator,
    io: Io,

    pub fn init(allocator: Allocator, io: Io) !Backend {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(_: *Backend) void {}

    pub fn waitHandle(_: *const Backend) WaitHandle {
        return .none;
    }

    pub fn subscribe(_: *Backend, _: *Watcher) !void {}

    pub fn unsubscribe(_: *Backend, _: *Watcher) void {}

    pub fn poll(_: *Backend, _: i64) !bool {
        return false;
    }
};
