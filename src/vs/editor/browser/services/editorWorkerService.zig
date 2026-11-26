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
    computing: bool = false,
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
            self.computing = true;
            self.mutex.unlock(io);
            request.compute(request);
            self.mutex.lockUncancelable(io);
            self.computing = false;
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
        if (now_ms - self.last_used <= idle_timeout_ms) return;
        // Browser worker termination is nonblocking. Native worker shutdown
        // joins the thread, so an idle check must not stop a worker that is
        // still computing (including an unlimited-duration diff).
        const io = self.io_state.io();
        self.mutex.lockUncancelable(io);
        const busy = self.computing or self.requests.first != null;
        self.mutex.unlock(io);
        if (!busy) self.stopWorker();
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

test "editorWorkerService: idle check does not join an in-flight computation" {
    const Probe = struct {
        request: Request = .{ .compute = runProbe, .reply = replyProbe },
        service: *EditorWorkerService,
        started: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),

        fn runProbe(message: *Request) void {
            const self: *@This() = @fieldParentPtr("request", message);
            self.started.store(true, .release);
            // Bound the wait so a regression that joins would fail rather
            // than hang the test runner.
            for (0..1000) |_| {
                if (self.done.load(.acquire)) return;
                self.service.io_state.io().sleep(.fromMilliseconds(1), .awake) catch return;
            }
        }

        fn replyProbe(_: *Request) bool {
            return false;
        }
    };
    var service = EditorWorkerService.init();
    defer service.deinit();
    var probe = Probe{ .service = &service };
    service.computeDiff(&probe.request, 0);
    defer {
        probe.done.store(true, .release);
        service.stopWorker();
    }
    for (0..1000) |_| {
        if (probe.started.load(.acquire)) break;
        service.io_state.io().sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(probe.started.load(.acquire));
    service.checkStopIdleWorker(5 * 60 * 1000 + 1);
    try std.testing.expect(service.thread != null);
}
