// Port of the diff worker lifecycle in `src/vs/editor/browser/services/editorWorkerService.ts`.
// A native thread and two message queues replace the Web Worker and its message
// port. The terminal dispatches replies on its UI thread. Callers own the input
// until the reply callback runs, including when the originating editor closes.
const std = @import("std");

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

    pub fn init() EditorWorkerService {
        return .{ .io_state = std.Io.Threaded.init(std.heap.page_allocator, .{}) };
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
                return;
            };
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
        _ = self.dispatchReplies();
    }
};
