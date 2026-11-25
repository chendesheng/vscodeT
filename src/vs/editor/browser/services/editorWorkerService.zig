// Port of the diff worker lifecycle in `src/vs/editor/browser/services/editorWorkerService.ts`.
// A native thread and two message queues replace the Web Worker and its message
// port. The terminal dispatches replies on its UI thread. Callers own the input
// until the reply callback runs, including when the originating editor closes.
const std = @import("std");

const dispatch = @import("../../../base/common/windowDispatch.zig");

pub const Request = struct {
    node: std.DoublyLinkedList.Node = .{},
    compute: *const fn (*Request) void,
    reply: *const fn (*Request) bool,
};

pub const EditorWorkerService = struct {
    const idle_timeout_ms = 5 * 60 * 1000;
    io_state: std.Io.Threaded,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    thread: ?std.Thread = null,
    requests: std.DoublyLinkedList = .{},
    replies: std.DoublyLinkedList = .{},
    stopping: bool = false,
    last_used: i64 = 0,
    next_idle_check: i64 = 0,
    replies_ready: dispatch.Task = .{},
    idle_check: dispatch.Task = .{},

    pub fn init() EditorWorkerService {
        return .{ .io_state = std.Io.Threaded.init(std.heap.page_allocator, .{}) };
    }

    pub fn attachWindow(self: *EditorWorkerService, window: *dispatch.Queue) void {
        self.replies_ready = .{ .queue = window, .context = self, .run = onReplies, .progress = true };
        self.idle_check = .{ .queue = window, .context = self, .run = onIdleCheck };
    }

    fn onReplies(context: *anyopaque, _: i64, _: bool) bool {
        const self: *EditorWorkerService = @ptrCast(@alignCast(context));
        return self.dispatchReplies();
    }

    fn onIdleCheck(context: *anyopaque, now: i64, _: bool) bool {
        const self: *EditorWorkerService = @ptrCast(@alignCast(context));
        self.checkStopIdleWorker(now);
        if (self.thread != null) self.idle_check.schedule(self.next_idle_check);
        return false;
    }

    pub fn deinit(self: *EditorWorkerService) void {
        self.stopWorker();
        self.io_state.deinit();
    }

    pub fn computeDiff(self: *EditorWorkerService, request: *Request, now_ms: i64) void {
        self.last_used = now_ms;
        const io = self.io_state.io();
        if (self.thread == null) {
            self.next_idle_check = now_ms + idle_timeout_ms / 2;
            self.thread = std.Thread.spawn(.{}, run, .{self}) catch {
                // EditorWorkerClient falls back to a local worker when creation fails.
                request.compute(request);
                self.replies.append(&request.node);
                self.replies_ready.post();
                return;
            };
            self.idle_check.schedule(self.next_idle_check);
        }
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.requests.append(&request.node);
        self.condition.signal(io);
    }

    fn run(self: *EditorWorkerService) void {
        const io = self.io_state.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (true) {
            while (self.requests.first == null) {
                if (self.stopping) return;
                self.condition.waitUncancelable(io, &self.mutex);
            }
            const node = self.requests.popFirst().?;
            const request: *Request = @fieldParentPtr("node", node);
            self.mutex.unlock(io);
            request.compute(request);
            self.mutex.lockUncancelable(io);
            self.replies.append(node);
            self.replies_ready.post();
            self.condition.broadcast(io);
        }
    }

    pub fn dispatchReplies(self: *EditorWorkerService) bool {
        const io = self.io_state.io();
        self.mutex.lockUncancelable(io);
        var replies = self.replies;
        self.replies = .{};
        self.mutex.unlock(io);
        var changed = false;
        while (replies.popFirst()) |node| {
            const request: *Request = @fieldParentPtr("node", node);
            if (request.reply(request)) changed = true;
        }
        return changed;
    }

    pub fn waitForReply(self: *EditorWorkerService) void {
        const io = self.io_state.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (self.replies.first == null) self.condition.waitUncancelable(io, &self.mutex);
    }

    pub fn checkStopIdleWorker(self: *EditorWorkerService, now_ms: i64) void {
        if (self.thread == null or now_ms < self.next_idle_check) return;
        self.next_idle_check = now_ms + idle_timeout_ms / 2;
        if (now_ms - self.last_used > idle_timeout_ms) self.stopWorker();
    }

    pub fn stopWorker(self: *EditorWorkerService) void {
        if (self.thread) |thread| {
            const io = self.io_state.io();
            self.mutex.lockUncancelable(io);
            self.stopping = true;
            self.condition.signal(io);
            self.mutex.unlock(io);
            thread.join();
            self.thread = null;
            self.stopping = false;
        }
        self.idle_check.schedule(null);
        self.replies_ready.schedule(null);
        _ = self.dispatchReplies();
    }
};
