// Port of the portable behavior in
// `src/vs/platform/files/node/watcher/baseWatcher.ts`.
//
// Terminal adaptation: failed requests are retried from the explicit `poll`
// loop instead of `fs.watchFile`. The retry interval, request correlation and
// suspend/resume event shape follow upstream: a request that starts failing is
// suspended, and when the path exists again an ADDED event is emitted and the
// request is restarted.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const common = @import("../../common/watcher.zig");
const WatchRequest = common.WatchRequest;
const FileChange = @import("../../common/files.zig").FileChange;
const FileChangeType = @import("../../common/files.zig").FileChangeType;

pub const SuspensionState = enum { active, suspended, suspended_polling };

pub const StartRequestFn = *const fn (context: *anyopaque, request: *const WatchRequest) anyerror!void;
pub const StopRequestFn = *const fn (context: *anyopaque, request: *const WatchRequest) void;
pub const EmitChangesFn = *const fn (context: *anyopaque, changes: []const FileChange) void;

pub const BaseWatcher = struct {
    allocator: Allocator,
    io: Io,
    context: *anyopaque,
    start_request: StartRequestFn,
    stop_request: StopRequestFn,
    emit_changes: EmitChangesFn,

    requests: ?*common.OwnedRequests = null,
    active: std.array_list.Managed(*const WatchRequest),
    suspended: std.array_list.Managed(Suspended),

    suspended_polling_interval_ms: i64 = 5007,
    verbose_logging: bool = false,
    needs_reconcile: bool = false,

    const Suspended = struct {
        request: *const WatchRequest,
        next_retry_ms: i64,
    };

    pub fn init(
        allocator: Allocator,
        io: Io,
        context: *anyopaque,
        start_request: StartRequestFn,
        stop_request: StopRequestFn,
        emit_changes: EmitChangesFn,
    ) BaseWatcher {
        return .{
            .allocator = allocator,
            .io = io,
            .context = context,
            .start_request = start_request,
            .stop_request = stop_request,
            .emit_changes = emit_changes,
            .active = std.array_list.Managed(*const WatchRequest).init(allocator),
            .suspended = std.array_list.Managed(Suspended).init(allocator),
        };
    }

    pub fn deinit(self: *BaseWatcher) void {
        self.stop();
        if (self.requests) |owned| {
            owned.deinit();
            self.requests = null;
        }
        self.active.deinit();
        self.suspended.deinit();
    }

    pub fn watch(self: *BaseWatcher, requests: []const WatchRequest, now_ms: i64) !void {
        self.stopAll();
        for (self.suspended.items) |suspended| self.stop_request(self.context, suspended.request);
        self.suspended.clearRetainingCapacity();
        if (self.requests) |owned| {
            owned.deinit();
            self.requests = null;
        }

        const owned = try common.copyRequests(self.allocator, requests);
        self.requests = owned;
        for (owned.requests) |*request| {
            self.startOrSuspend(request, now_ms);
        }
    }

    fn startOrSuspend(self: *BaseWatcher, request: *const WatchRequest, now_ms: i64) void {
        self.start_request(self.context, request) catch {
            self.suspended.append(.{
                .request = request,
                .next_retry_ms = now_ms + self.suspended_polling_interval_ms,
            }) catch {};
            return;
        };
        self.active.append(@constCast(request)) catch {};
    }

    /// Called by a concrete watcher when an active request fails.
    pub fn requestFailed(self: *BaseWatcher, request: *const WatchRequest, now_ms: i64) void {
        var index: usize = 0;
        while (index < self.active.items.len) : (index += 1) {
            if (sameRequest(self.active.items[index], request)) {
                const active = self.active.orderedRemove(index);
                self.stop_request(self.context, active);
                break;
            }
        }
        self.suspended.append(.{
            .request = request,
            .next_retry_ms = now_ms + self.suspended_polling_interval_ms,
        }) catch {};
    }

    pub fn poll(self: *BaseWatcher, now_ms: i64) !bool {
        var changed = false;
        var index: usize = 0;
        while (index < self.suspended.items.len) {
            const suspended = self.suspended.items[index];
            if (now_ms < suspended.next_retry_ms) {
                index += 1;
                continue;
            }
            self.start_request(self.context, suspended.request) catch {
                self.suspended.items[index].next_retry_ms = now_ms + self.suspended_polling_interval_ms;
                index += 1;
                continue;
            };
            self.active.append(@constCast(suspended.request)) catch {};
            const change = [_]FileChange{.{
                .type = .ADDED,
                .resource = suspended.request.path,
                .cId = suspended.request.correlationId,
            }};
            self.emit_changes(self.context, &change);
            _ = self.suspended.orderedRemove(index);
            changed = true;
        }
        return changed;
    }

    pub fn isSuspended(self: *const BaseWatcher, request: *const WatchRequest) SuspensionState {
        for (self.suspended.items) |suspended| {
            if (sameRequest(suspended.request, request)) return .suspended;
        }
        for (self.active.items) |active| {
            if (sameRequest(active, request)) return .active;
        }
        return .active;
    }

    pub fn stop(self: *BaseWatcher) void {
        self.stopAll();
        for (self.suspended.items) |suspended| self.stop_request(self.context, suspended.request);
        self.suspended.clearRetainingCapacity();
    }

    fn stopAll(self: *BaseWatcher) void {
        for (self.active.items) |request| self.stop_request(self.context, request);
        self.active.clearRetainingCapacity();
    }

    pub fn requestToString(self: *const BaseWatcher, request: *const WatchRequest, allocator: Allocator) ![]u8 {
        _ = self;
        return std.fmt.allocPrint(allocator, "{s} (excludes: {d}, includes: {d}, filter: {s}, correlationId: {?d})", .{
            request.path,
            request.excludes.len,
            request.includes.len,
            common.requestFilterToString(request.filter),
            request.correlationId,
        });
    }
};

fn sameRequest(a: *const WatchRequest, b: *const WatchRequest) bool {
    return std.mem.eql(u8, a.path, b.path) and a.correlationId == b.correlationId and a.recursive == b.recursive;
}
