// Port of `AbstractWatcherClient`/`AbstractUniversalWatcherClient` from
// `src/vs/platform/files/common/watcher.ts` and the watcher-process split in
// `src/vs/platform/files/node/watcher/watcherClient.ts` /
// `watcherMain.ts`.
//
// Terminal adaptation: there is no Electron utility process, so the watcher
// side runs on a dedicated worker thread. The client contract is the upstream
// one: `watch` copies the request list and returns without waiting for the
// recursive scan. Worker events wake the window, which delivers each batch
// to the registered listeners. Restart-on-error keeps upstream's five-attempt limit and
// its `No space left on device` / `EMFILE` exceptions.
//
// The watcher implementation itself (the in-process `UniversalWatcher`) is
// unchanged; only its thread changes. On stop, the client cooperatively
// cancels an in-progress recursive scan so quitting does not wait for a large
// tree walk to finish.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const common = @import("../../common/watcher.zig");
const files = @import("../../common/files.zig");
const event = @import("../../../../base/common/event.zig");
const Emitter = event.Emitter;
const UniversalWatcher = @import("./watcher.zig").UniversalWatcher;

const FileChange = files.FileChange;
const ILogMessage = common.ILogMessage;
const LogMessageType = common.LogMessageType;
const IWatcherErrorEvent = common.IWatcherErrorEvent;
const WatchRequest = common.WatchRequest;

pub const MAX_RESTARTS: usize = 5;
const worker_wait_ms: i64 = 10;

/// Mirrors the error delivered by upstream `onDidError`.
pub const WatcherError = struct {
    message: []const u8,
    failed_request: bool,
};

const ChangeBatch = struct {
    items: []FileChange,
};

const LogItem = struct {
    type: LogMessageType,
    message: []u8,
};

const ErrorItem = struct {
    message: []u8,
    failed_request: bool,
};

pub const UniversalWatcherClient = struct {
    allocator: Allocator,
    io_state: std.Io.Threaded,
    io: Io,

    mutex: Io.Mutex = .init,
    condition: Io.Condition = .init,
    thread: ?std.Thread = null,

    stop_requested: bool = false,
    pending_requests: ?*common.OwnedRequests = null,
    restart_requested: bool = false,
    restart_count: usize = 0,
    verbose_logging: bool = false,
    verbose_dirty: bool = false,
    watch_ready: bool = false,
    delivery: @import("../../../../base/common/windowDispatch.zig").Task = .{},
    scan_cancel: std.atomic.Value(bool) = .init(false),

    changes: std.array_list.Managed(ChangeBatch),
    logs: std.array_list.Managed(LogItem),
    errors: std.array_list.Managed(ErrorItem),

    on_change: Emitter([]const FileChange),
    on_log: Emitter(ILogMessage),
    on_error: Emitter(WatcherError),

    pub fn init(allocator: Allocator) !*UniversalWatcherClient {
        const self = try allocator.create(UniversalWatcherClient);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .io_state = undefined,
            .io = undefined,
            .changes = std.array_list.Managed(ChangeBatch).init(allocator),
            .logs = std.array_list.Managed(LogItem).init(allocator),
            .errors = std.array_list.Managed(ErrorItem).init(allocator),
            .on_change = Emitter([]const FileChange).init(allocator),
            .on_log = Emitter(ILogMessage).init(allocator),
            .on_error = Emitter(WatcherError).init(allocator),
        };
        errdefer {
            self.changes.deinit();
            self.logs.deinit();
            self.errors.deinit();
            self.on_change.deinit();
            self.on_log.deinit();
            self.on_error.deinit();
        }

        self.io_state = std.Io.Threaded.init(std.heap.page_allocator, .{});
        self.io = self.io_state.io();
        errdefer self.io_state.deinit();

        self.thread = try std.Thread.spawn(.{}, workerMain, .{self});
        return self;
    }

    pub fn deinit(self: *UniversalWatcherClient) void {
        self.stop();
        self.delivery.schedule(null);
        self.freeQueued();
        self.changes.deinit();
        self.logs.deinit();
        self.errors.deinit();
        self.on_change.deinit();
        self.on_log.deinit();
        self.on_error.deinit();
        self.io_state.deinit();
        self.allocator.destroy(self);
    }

    /// Asks the worker to stop and joins it. Idempotent.
    pub fn stop(self: *UniversalWatcherClient) void {
        self.mutex.lockUncancelable(self.io);
        self.stop_requested = true;
        self.scan_cancel.store(true, .release);
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }

        if (self.pending_requests) |requests| {
            requests.deinit();
            self.pending_requests = null;
        }
    }

    /// Upstream `AbstractWatcherClient.watch`: the request list is sent to the
    /// watcher and this call does not wait for the recursive scan.
    pub fn watch(self: *UniversalWatcherClient, requests: []const WatchRequest) !void {
        const owned = try common.copyRequests(self.allocator, requests);
        errdefer owned.deinit();

        self.mutex.lockUncancelable(self.io);
        if (self.pending_requests) |old| old.deinit();
        self.pending_requests = owned;
        self.watch_ready = false;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
    }

    pub fn setVerboseLogging(self: *UniversalWatcherClient, enabled: bool) void {
        self.mutex.lockUncancelable(self.io);
        self.verbose_logging = enabled;
        self.verbose_dirty = true;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
    }

    /// True after the worker has applied the current request list.
    pub fn isReady(self: *UniversalWatcherClient) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.watch_ready;
    }

    pub fn attachWindow(self: *UniversalWatcherClient, window: *@import("../../../../base/common/windowDispatch.zig").Queue) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.delivery = .{ .queue = window, .context = self, .run = deliver, .progress = true };
        if (self.changes.items.len != 0 or self.logs.items.len != 0 or self.errors.items.len != 0) self.delivery.post();
    }

    fn deliver(ctx: *anyopaque, _: i64, _: bool) bool {
        const self: *UniversalWatcherClient = @ptrCast(@alignCast(ctx));
        return self.poll();
    }

    pub fn hasQueuedEvents(self: *UniversalWatcherClient) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.changes.items.len > 0 or self.logs.items.len > 0 or self.errors.items.len > 0;
    }

    /// Drains the worker queues on the main thread and fires the upstream
    /// callbacks. Returns true when anything was delivered.
    pub fn poll(self: *UniversalWatcherClient) bool {
        var change_batches = std.array_list.Managed(ChangeBatch).init(self.allocator);
        defer change_batches.deinit();
        var logs = std.array_list.Managed(LogItem).init(self.allocator);
        defer logs.deinit();
        var errors = std.array_list.Managed(ErrorItem).init(self.allocator);
        defer errors.deinit();

        self.mutex.lockUncancelable(self.io);
        std.mem.swap(@TypeOf(change_batches), &change_batches, &self.changes);
        std.mem.swap(@TypeOf(logs), &logs, &self.logs);
        std.mem.swap(@TypeOf(errors), &errors, &self.errors);
        self.mutex.unlock(self.io);

        var delivered = false;
        for (change_batches.items) |*batch| {
            defer {
                for (batch.items) |change| self.allocator.free(@constCast(change.resource));
                self.allocator.free(batch.items);
            }
            if (batch.items.len == 0) continue;
            delivered = true;
            self.on_change.fire(batch.items) catch {};
        }
        for (logs.items) |*item| {
            defer self.allocator.free(item.message);
            delivered = true;
            self.on_log.fire(.{ .type = item.type, .message = item.message }) catch {};
        }
        for (errors.items) |*item| {
            defer self.allocator.free(item.message);
            delivered = true;
            self.on_error.fire(.{ .message = item.message, .failed_request = item.failed_request }) catch {};
            self.handleError(item.message, item.failed_request);
        }
        return delivered;
    }

    fn handleError(self: *UniversalWatcherClient, message: []const u8, failed_request: bool) void {
        if (canRestart(message, failed_request)) {
            if (self.restart_count < MAX_RESTARTS) {
                self.restart_count += 1;
                std.log.scoped(.file_watcher).warn(
                    "restarting watcher after unexpected error: {s}",
                    .{message},
                );
                self.mutex.lockUncancelable(self.io);
                self.restart_requested = true;
                self.condition.broadcast(self.io);
                self.mutex.unlock(self.io);
            } else {
                std.log.scoped(.file_watcher).err(
                    "gave up attempting to restart watcher after unexpected error: {s}",
                    .{message},
                );
            }
            return;
        }
        std.log.scoped(.file_watcher).err("{s}", .{message});
    }

    fn canRestart(message: []const u8, failed_request: bool) bool {
        // A failing request must not restart the whole watcher: from a large
        // number of requests some can fail, and restarting would only retry
        // them all. This mirrors upstream `AbstractWatcherClient.canRestart`.
        if (failed_request) return false;
        if (std.mem.indexOf(u8, message, "No space left on device") != null) return false;
        if (std.mem.indexOf(u8, message, "EMFILE") != null) return false;
        return true;
    }

    fn freeQueued(self: *UniversalWatcherClient) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.changes.items) |*batch| {
            for (batch.items) |change| self.allocator.free(@constCast(change.resource));
            self.allocator.free(batch.items);
        }
        self.changes.clearRetainingCapacity();
        for (self.logs.items) |item| self.allocator.free(item.message);
        self.logs.clearRetainingCapacity();
        for (self.errors.items) |item| self.allocator.free(item.message);
        self.errors.clearRetainingCapacity();
    }

    fn pushChanges(self: *UniversalWatcherClient, changes: []const FileChange) void {
        if (changes.len == 0) return;
        const items = self.allocator.alloc(FileChange, changes.len) catch return;
        var copied: usize = 0;
        while (copied < changes.len) : (copied += 1) {
            const resource = self.allocator.dupe(u8, changes[copied].resource) catch {
                for (items[0..copied]) |item| self.allocator.free(@constCast(item.resource));
                self.allocator.free(items);
                return;
            };
            items[copied] = .{
                .type = changes[copied].type,
                .resource = resource,
                .cId = changes[copied].cId,
            };
        }

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.changes.append(.{ .items = items }) catch {
            for (items) |item| self.allocator.free(@constCast(item.resource));
            self.allocator.free(items);
            return;
        };
        self.delivery.post();
    }

    fn pushLog(self: *UniversalWatcherClient, message: ILogMessage) void {
        const copy = self.allocator.dupe(u8, message.message) catch return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.logs.append(.{ .type = message.type, .message = copy }) catch {
            self.allocator.free(copy);
            return;
        };
        self.delivery.post();
    }

    fn pushError(self: *UniversalWatcherClient, comptime fmt: []const u8, args: anytype, failed_request: bool) void {
        var buffer: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, fmt, args) catch return;
        const copy = self.allocator.dupe(u8, text) catch return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.errors.append(.{ .message = copy, .failed_request = failed_request }) catch {
            self.allocator.free(copy);
            return;
        };
        self.delivery.post();
    }

    fn onWorkerChanges(changes: []const FileChange, self: *UniversalWatcherClient) !void {
        self.pushChanges(changes);
    }

    fn onWorkerLog(message: ILogMessage, self: *UniversalWatcherClient) !void {
        self.pushLog(message);
    }

    fn onWorkerError(watcher_error: IWatcherErrorEvent, self: *UniversalWatcherClient) !void {
        self.pushError("{s}", .{watcher_error.@"error"}, watcher_error.request != null);
    }
};

fn workerMain(self: *UniversalWatcherClient) void {
    var watcher: ?*UniversalWatcher = null;
    defer if (watcher) |value| value.deinit();

    var current: ?*common.OwnedRequests = null;
    defer if (current) |value| value.deinit();
    var applied = false;

    while (true) {
        self.mutex.lockUncancelable(self.io);
        if (self.stop_requested) {
            self.mutex.unlock(self.io);
            return;
        }
        const pending = self.pending_requests;
        self.pending_requests = null;
        const restart = self.restart_requested;
        self.restart_requested = false;
        const verbose = self.verbose_logging;
        const verbose_dirty = self.verbose_dirty;
        self.verbose_dirty = false;
        self.mutex.unlock(self.io);

        if (pending) |requests| {
            if (current) |old| old.deinit();
            current = requests;
            applied = false;
        }
        if (restart) {
            if (watcher) |value| {
                value.deinit();
                watcher = null;
            }
            applied = false;
        }

        if (watcher == null) {
            // The watcher worker owns its tree and event batches. Give it a
            // dedicated allocator, like the upstream watcher process has its
            // own heap: the Debug allocator's stack-trace capture and lock
            // would otherwise dominate a large recursive scan and contend
            // with the UI thread. Client queues still use `self.allocator`.
            watcher = UniversalWatcher.init(std.heap.smp_allocator, self.io) catch |err| {
                self.pushError("failed to create file watcher: {s}", .{@errorName(err)}, false);
                self.mutex.lockUncancelable(self.io);
                self.condition.waitTimeout(self.io, &self.mutex, .{
                    .duration = .{ .raw = std.Io.Duration.fromMilliseconds(100), .clock = .awake },
                }) catch {};
                self.mutex.unlock(self.io);
                continue;
            };
            watcher.?.setCancelFlag(&self.scan_cancel);
            _ = watcher.?.on_change.listen(self, UniversalWatcherClient.onWorkerChanges) catch {};
            _ = watcher.?.on_log.listen(self, UniversalWatcherClient.onWorkerLog) catch {};
            _ = watcher.?.on_error.listen(self, UniversalWatcherClient.onWorkerError) catch {};
            self.pushLog(.{ .type = .info, .message = "[File Watcher (universal)] started" });
            applied = false;
        }

        if (verbose_dirty) watcher.?.setVerboseLogging(verbose);

        if (!applied and current != null) {
            // Clear the shutdown cancellation only when the worker is not
            // already stopping. A stop that races with this store sets the
            // flag again and aborts the scan.
            self.mutex.lockUncancelable(self.io);
            if (self.stop_requested) {
                self.mutex.unlock(self.io);
                continue;
            }
            self.scan_cancel.store(false, .release);
            self.mutex.unlock(self.io);

            var applied_ok = true;
            watcher.?.watch(current.?.requests) catch |err| {
                applied_ok = false;
                self.pushError("file watcher failed to watch: {s}", .{@errorName(err)}, false);
            };
            applied = true;
            self.mutex.lockUncancelable(self.io);
            self.watch_ready = applied_ok and self.pending_requests == null;
            self.mutex.unlock(self.io);
        }

        _ = watcher.?.poll(nowMs(self.io)) catch |err| {
            self.pushError("file watcher poll failed: {s}", .{@errorName(err)}, false);
        };

        self.mutex.lockUncancelable(self.io);
        if (!self.stop_requested and self.pending_requests == null and
            !self.restart_requested and !self.verbose_dirty)
        {
            self.condition.waitTimeout(self.io, &self.mutex, .{
                .duration = .{ .raw = std.Io.Duration.fromMilliseconds(worker_wait_ms), .clock = .awake },
            }) catch |err| switch (err) {
                error.Timeout => {},
                else => {},
            };
        }
        self.mutex.unlock(self.io);
    }
}

fn nowMs(io: Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}
