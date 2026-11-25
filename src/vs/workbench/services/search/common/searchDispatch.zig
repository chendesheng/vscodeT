// Search progress and debounce callbacks on the owning window thread.
const dispatch = @import("../../../../base/common/windowDispatch.zig");
const Task = dispatch.Task;
const Callback = dispatch.Callback;
const Queue = dispatch.Queue;

pub const Delivery = struct {
    timer: Task = .{},
    progress: Task = .{},

    pub fn attach(self: *Delivery, queue: *Queue, context: *anyopaque, run: Callback) void {
        self.timer = .{ .queue = queue, .context = context, .run = run };
        self.progress = .{ .queue = queue, .context = context, .run = run, .progress = true };
    }

    pub fn notify(context: *anyopaque) void {
        const self: *Delivery = @ptrCast(@alignCast(context));
        self.progress.post();
    }
};
