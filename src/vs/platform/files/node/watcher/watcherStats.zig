// Port of `src/vs/platform/files/node/watcher/watcherStats.ts`.
//
// Formatting and counts follow upstream: request totals, suspended/polling
// counts, watcher totals and the per-request details. The terminal prints this
// through the watcher log when verbose logging is enabled.

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("../../common/watcher.zig");
const WatchRequest = common.WatchRequest;
const base_mod = @import("baseWatcher.zig");
const parcel_mod = @import("parcel/parcelWatcher.zig");
const ParcelWatcher = parcel_mod.ParcelWatcher;
const nodejs_mod = @import("nodejs/nodejsWatcherLib.zig");
const NodeJSWatcher = nodejs_mod.NodeJSWatcher;

pub fn computeStats(
    allocator: Allocator,
    requests: []const WatchRequest,
    failed_recursive_requests: usize,
    recursive: *const ParcelWatcher,
    non_recursive: *const NodeJSWatcher,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const writer = &output.writer;

    var recursive_total: usize = 0;
    var recursive_suspended: usize = 0;
    var non_recursive_total: usize = 0;
    var non_recursive_suspended: usize = 0;

    for (requests) |request| {
        if (request.recursive) {
            recursive_total += 1;
            if (recursive.isSuspended(&request) != .active) recursive_suspended += 1;
        } else {
            non_recursive_total += 1;
            if (non_recursive.isSuspended(&request) != .active) non_recursive_suspended += 1;
        }
    }

    var recursive_active: usize = 0;
    var recursive_failed: usize = 0;
    var recursive_stopped: usize = 0;
    for (recursive.instances.items) |instance| {
        if (!instance.failed and !instance.stopped) recursive_active += 1;
        if (instance.failed) recursive_failed += 1;
        if (instance.stopped) recursive_stopped += 1;
    }

    var non_recursive_active: usize = 0;
    var non_recursive_failed: usize = 0;
    for (non_recursive.instances.items) |instance| {
        if (!instance.failed) non_recursive_active += 1;
        if (instance.failed) non_recursive_failed += 1;
    }

    try writer.print(
        \\[File Watcher] request stats:
        \\
        \\[Summary]
        \\- Recursive Requests:     total: {d}, suspended: {d}, failed: {d}
        \\- Non-Recursive Requests: total: {d}, suspended: {d}
        \\- Recursive Watchers:     total: {d}, active: {d}, failed: {d}, stopped: {d}
        \\- Non-Recursive Watchers: total: {d}, active: {d}, failed: {d}
        \\
    , .{
        recursive_total,                   recursive_suspended,     failed_recursive_requests,
        non_recursive_total,               non_recursive_suspended, recursive.instances.items.len,
        recursive_active,                  recursive_failed,        recursive_stopped,
        non_recursive.instances.items.len, non_recursive_active,    non_recursive_failed,
    });

    try writer.writeAll("\n[Recursive Requests]\n");
    for (requests) |request| {
        if (!request.recursive) continue;
        try writeRequest(writer, &request, recursive.isSuspended(&request));
    }
    try writer.writeAll("\n[Non-Recursive Requests]\n");
    for (requests) |request| {
        if (request.recursive) continue;
        try writeRequest(writer, &request, non_recursive.isSuspended(&request));
    }
    try writer.writeAll("\n");
    return try output.toOwnedSlice();
}

fn writeRequest(
    writer: *std.Io.Writer,
    request: *const WatchRequest,
    state: base_mod.SuspensionState,
) !void {
    const decoration = switch (state) {
        .active => "",
        .suspended => " [SUSPENDED]",
        .suspended_polling => " [SUSPENDED <polling>]",
    };
    try writer.print(" {s}{s} (excludes: {d}, includes: {d}, filter: {s}, correlationId: {?d})\n", .{
        request.path,
        decoration,
        request.excludes.len,
        request.includes.len,
        common.requestFilterToString(request.filter),
        request.correlationId,
    });
}
