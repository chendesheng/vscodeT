// Worker completion and timer delivery for the terminal window. This adapts
// the browser event loop used by promises and RunOnceScheduler.
const std = @import("std");

pub const Wake = struct {
    context: *anyopaque,
    signal: *const fn (*anyopaque) void,
};

pub const Queue = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    scheduled: std.DoublyLinkedList = .{},
    wake: ?Wake = null,

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
