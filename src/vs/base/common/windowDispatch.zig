// Worker completion and timer delivery for the terminal window. This adapts
// the browser event loop used by promises and RunOnceScheduler.
const std = @import("std");
const WindowIo = @import("ui").WindowIo;

/// Window tasks may await detached work without moving their continuation or
/// editor state to the worker thread. Standalone owners keep their supplied Io.
pub fn workerCall(io: std.Io, comptime function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) @typeInfo(@TypeOf(function)).@"fn".return_type.? {
    return WindowIo.workerCall(io, function, args);
}

pub fn backingIo(io: std.Io) std.Io {
    return WindowIo.backingIo(io);
}

pub const Wake = struct {
    context: *anyopaque,
    signal: *const fn (*anyopaque) void,
};

/// Global window events corresponding to the browser resize and capturing
/// pointer events. The terminal host delivers them before layout or input.
pub const WindowEvent = enum { resize, pointer_down, pointer_up };
pub const WindowEventEmitter = @import("event.zig").Emitter(WindowEvent);

/// Window/client coordinates stay independent of the hit-tested editor's
/// local surface. Capture mirrors window mousemove/mouseup listeners.
pub const PointerInput = struct {
    kind: enum { down, move, up, click, wheel },
    x: usize,
    y: usize,
};
pub const PointerCapture = struct {
    context: *anyopaque,
    dispatch: *const fn (*anyopaque, PointerInput) bool,
    cancel: *const fn (*anyopaque) void,
};

pub const Queue = struct {
    io: std.Io,
    /// The native window supplies its serial executor. Standalone callers
    /// retain their original Io and callback-only dispatch.
    scheduler: ?*WindowIo = null,
    mutex: std.Io.Mutex = .init,
    scheduled: std.DoublyLinkedList = .{},
    idle: std.DoublyLinkedList = .{},
    wake: ?Wake = null,
    window_events: ?WindowEventEmitter = null,
    current_pointer_input: ?PointerInput = null,
    pointer_capture: ?PointerCapture = null,

    pub fn fireWindowEvent(self: *Queue, event: WindowEvent) void {
        if (self.window_events) |*emitter| emitter.fire(event) catch {};
    }

    /// Called once per native input before hit testing. A captured move or
    /// release belongs to the owner even outside its original editor pane.
    pub fn beginPointerInput(self: *Queue, input: PointerInput) bool {
        self.current_pointer_input = input;
        const capture = self.pointer_capture orelse return false;
        switch (input.kind) {
            .down => {
                self.pointer_capture = null;
                capture.cancel(capture.context);
                return false;
            },
            .up, .click => self.pointer_capture = null,
            .wheel => return false,
            .move => {},
        }
        return capture.dispatch(capture.context, input);
    }

    pub fn endPointerInput(self: *Queue) void {
        self.current_pointer_input = null;
    }

    pub fn capturePointer(self: *Queue, capture: PointerCapture) void {
        if (self.pointer_capture) |previous| {
            if (previous.context != capture.context) {
                self.pointer_capture = null;
                previous.cancel(previous.context);
            }
        }
        self.pointer_capture = capture;
    }

    pub fn releasePointer(self: *Queue, context: *anyopaque) void {
        if (self.pointer_capture) |capture| {
            if (capture.context == context) self.pointer_capture = null;
        }
    }

    pub fn deinitWindowEvents(self: *Queue) void {
        self.setWake(null);
        if (self.pointer_capture) |capture| {
            self.pointer_capture = null;
            capture.cancel(capture.context);
        }
        self.current_pointer_input = null;
        if (self.window_events) |*emitter| emitter.deinit();
        self.window_events = null;
    }

    /// Queue synchronization is also called from true background workers;
    /// it must never suspend a window fiber while holding the queue lock.
    pub fn workerIo(self: *const Queue) std.Io {
        return if (self.scheduler) |scheduler| scheduler.worker else self.io;
    }

    pub fn setWake(self: *Queue, wake: ?Wake) void {
        const worker = self.workerIo();
        self.mutex.lockUncancelable(worker);
        self.wake = wake;
        self.mutex.unlock(worker);
        if (self.scheduler) |scheduler| scheduler.setWake(if (wake) |w| .{ .context = w.context, .notify = w.signal } else null);
    }

    pub fn nextTimeout(self: *Queue, now: i64, maximum: i32) i32 {
        if (self.scheduler) |scheduler| if (scheduler.hasReady()) return 0;
        const worker = self.workerIo();
        self.mutex.lockUncancelable(worker);
        defer self.mutex.unlock(worker);
        if (self.idle.first != null) return 0;
        const node = self.scheduled.first orelse return maximum;
        const task: *Task = @alignCast(@fieldParentPtr("node", node));
        return @intCast(std.math.clamp(task.at.? -| now, 0, maximum));
    }

    /// One batch per turn lets input and paint run between result batches.
    /// Due work (including an idle callback's timeout) precedes idle work;
    /// otherwise the next idle callback runs in registration order.
    pub fn dispatch(self: *Queue, now: i64) bool {
        // One runnable fiber per turn; its owner posts a completed result or
        // requests a frame through the existing events. Merely starting an
        // I/O wait is not a redraw.
        if (self.scheduler) |scheduler| _ = scheduler.dispatch();
        const worker = self.workerIo();
        self.mutex.lockUncancelable(worker);
        const due: ?*Task = if (self.scheduled.first) |node| blk: {
            const task: *Task = @alignCast(@fieldParentPtr("node", node));
            break :blk if (task.at.? <= now) task else null;
        } else null;
        const task = due orelse if (self.idle.first) |node| @as(*Task, @alignCast(@fieldParentPtr("idle_node", node))) else {
            self.mutex.unlock(worker);
            return false;
        };
        self.scheduled.remove(&task.node);
        if (task.idle) self.idle.remove(&task.idle_node);
        task.at = null;
        self.mutex.unlock(worker);
        return task.run(task.context, now, task.progress);
    }
};

pub const Callback = *const fn (*anyopaque, i64, bool) bool;
pub const Task = struct {
    queue: ?*Queue = null,
    context: *anyopaque = undefined,
    run: Callback = undefined,
    progress: bool = false,
    /// Native adaptation of runWhenWindowIdle: this task can be dispatched
    /// ahead of its deadline when there is no due window work. A deadline of
    /// maxInt(i64) means there is no timeout.
    idle: bool = false,
    node: std.DoublyLinkedList.Node = .{},
    idle_node: std.DoublyLinkedList.Node = .{},
    at: ?i64 = null,

    pub fn post(self: *Task) void {
        self.schedule(@import("timeCompat.zig").milliTimestamp());
    }

    pub fn schedule(self: *Task, at: ?i64) void {
        const queue = self.queue orelse return;
        const worker = queue.workerIo();
        queue.mutex.lockUncancelable(worker);
        defer queue.mutex.unlock(worker);
        if (self.at == at or (self.progress and self.at != null and at != null)) return;
        const was_scheduled = self.at != null;
        if (was_scheduled) {
            queue.scheduled.remove(&self.node);
            if (self.idle and at == null) queue.idle.remove(&self.idle_node);
        }
        self.at = at;
        const deadline = at orelse return;
        var cursor = queue.scheduled.last;
        while (cursor) |node| : (cursor = node.prev) {
            const other: *Task = @alignCast(@fieldParentPtr("node", node));
            if (other.at.? <= deadline) break;
        }
        if (cursor) |node| queue.scheduled.insertAfter(node, &self.node) else queue.scheduled.prepend(&self.node);
        if (self.idle and !was_scheduled) queue.idle.append(&self.idle_node);
        if (self.progress) {
            if (queue.wake) |wake| wake.signal(wake.context);
        }
    }
};

test "Window dispatch prioritizes due work and runs idle callbacks in registration order" {
    const Probe = struct {
        order: *std.ArrayList(u8),
        id: u8,
        fn run(context: *anyopaque, _: i64, _: bool) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.order.append(std.testing.allocator, self.id) catch unreachable;
            return true;
        }
    };
    var queue: Queue = .{ .io = std.testing.io };
    var order: std.ArrayList(u8) = .empty;
    defer order.deinit(std.testing.allocator);
    var first: Probe = .{ .order = &order, .id = 1 };
    var second: Probe = .{ .order = &order, .id = 2 };
    var due: Probe = .{ .order = &order, .id = 3 };
    var idle_first: Task = .{ .queue = &queue, .context = &first, .run = Probe.run, .idle = true };
    var idle_second: Task = .{ .queue = &queue, .context = &second, .run = Probe.run, .idle = true };
    var timed: Task = .{ .queue = &queue, .context = &due, .run = Probe.run };
    idle_first.schedule(std.math.maxInt(i64));
    idle_second.schedule(50);
    timed.schedule(10);
    try std.testing.expectEqual(@as(i32, 0), queue.nextTimeout(0, 250));
    try std.testing.expect(queue.dispatch(10));
    try std.testing.expect(queue.dispatch(10));
    try std.testing.expectEqualSlices(u8, &.{ 3, 1 }, order.items);
    idle_second.schedule(null);
    try std.testing.expect(!queue.dispatch(10));
    try std.testing.expectEqual(@as(i32, 250), queue.nextTimeout(10, 250));

    // An idle deadline that has expired joins the timed work ordering.
    idle_first.schedule(std.math.maxInt(i64));
    idle_second.schedule(50);
    timed.schedule(60);
    try std.testing.expect(queue.dispatch(60));
    try std.testing.expect(queue.dispatch(60));
    try std.testing.expect(queue.dispatch(60));
    try std.testing.expectEqualSlices(u8, &.{ 3, 1, 2, 3, 1 }, order.items);
}
