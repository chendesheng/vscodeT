// Worker completion and timer delivery for the terminal window. This adapts
// the browser event loop used by promises and RunOnceScheduler.
const std = @import("std");

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
    mutex: std.Io.Mutex = .init,
    scheduled: std.DoublyLinkedList = .{},
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
        if (self.pointer_capture) |capture| {
            self.pointer_capture = null;
            capture.cancel(capture.context);
        }
        self.current_pointer_input = null;
        if (self.window_events) |*emitter| emitter.deinit();
        self.window_events = null;
    }

    pub fn setWake(self: *Queue, wake: ?Wake) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.wake = wake;
    }

    pub fn nextTimeout(self: *Queue, now: i64, maximum: i32) i32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const node = self.scheduled.first orelse return maximum;
        const task: *Task = @alignCast(@fieldParentPtr("node", node));
        return @intCast(std.math.clamp(task.at.? -| now, 0, maximum));
    }

    /// One batch per turn lets input and paint run between result batches.
    pub fn dispatch(self: *Queue, now: i64) bool {
        self.mutex.lockUncancelable(self.io);
        const task: *Task = if (self.scheduled.first) |node| @alignCast(@fieldParentPtr("node", node)) else {
            self.mutex.unlock(self.io);
            return false;
        };
        if (task.at.? > now) {
            self.mutex.unlock(self.io);
            return false;
        }
        self.scheduled.remove(&task.node);
        task.at = null;
        self.mutex.unlock(self.io);
        return task.run(task.context, now, task.progress);
    }
};

pub const Callback = *const fn (*anyopaque, i64, bool) bool;
pub const Task = struct {
    queue: ?*Queue = null,
    context: *anyopaque = undefined,
    run: Callback = undefined,
    progress: bool = false,
    node: std.DoublyLinkedList.Node = .{},
    at: ?i64 = null,

    pub fn post(self: *Task) void {
        self.schedule(@import("timeCompat.zig").milliTimestamp());
    }

    pub fn schedule(self: *Task, at: ?i64) void {
        const queue = self.queue orelse return;
        queue.mutex.lockUncancelable(queue.io);
        defer queue.mutex.unlock(queue.io);
        if (self.at == at or (self.progress and self.at != null and at != null)) return;
        if (self.at != null) queue.scheduled.remove(&self.node);
        self.at = at;
        const deadline = at orelse return;
        var cursor = queue.scheduled.last;
        while (cursor) |node| : (cursor = node.prev) {
            const other: *Task = @alignCast(@fieldParentPtr("node", node));
            if (other.at.? <= deadline) break;
        }
        if (cursor) |node| queue.scheduled.insertAfter(node, &self.node) else queue.scheduled.prepend(&self.node);
        if (self.progress) {
            if (queue.wake) |wake| wake.signal(wake.context);
        }
    }
};
