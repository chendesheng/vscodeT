// Terminal adaptation of the browser event loop: std.Io tasks run as fibers
// confined to the window thread. Blocking system I/O uses a separate Threaded
// Io. The host may dispatch one runnable fiber per event-loop turn, or await
// from the root when running a standalone structured scope.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const native = @import("window_fiber.zig");

pub const WindowIo = struct {
    const Self = @This();
    allocator: Allocator,
    worker: Io,
    owner: std.Thread.Id,
    root: native.Context,
    current: ?*Task = null,
    live: usize = 0,
    mutex: Io.Mutex = .init,
    ready: Io.Condition = .init,
    head: ?*Task = null,
    tail: ?*Task = null,
    wake: ?Wake = null,

    pub const Wake = struct {
        context: *anyopaque,
        notify: *const fn (*anyopaque) void,
    };

    /// The owner must keep this object at a stable address until all futures
    /// and groups are joined. The editor Io is only used from this thread;
    /// background jobs use the separately supplied worker Io, which must
    /// support concurrency (e.g. Io.Threaded).
    pub fn init(allocator: Allocator, worker: Io) !Self {
        return .{ .allocator = allocator, .worker = worker, .owner = std.Thread.getCurrentId(), .root = try native.initRoot() };
    }

    pub fn deinit(self: *Self) void {
        self.assertOwner();
        std.debug.assert(self.current == null and self.live == 0 and self.head == null);
        native.deinitRoot(&self.root);
    }

    pub fn io(self: *Self) Io {
        return .{ .userdata = self, .vtable = &vtable };
    }

    /// Whether an event-loop turn can run a fiber without blocking.
    pub fn hasReady(self: *Self) bool {
        self.mutex.lockUncancelable(self.worker);
        defer self.mutex.unlock(self.worker);
        return self.head != null;
    }

    /// The callback may be invoked on a worker thread and must only signal
    /// readiness; it must not dispatch work or call back into WindowIo.
    pub fn setWake(self: *Self, wake: ?Wake) void {
        self.assertOwner();
        self.mutex.lockUncancelable(self.worker);
        defer self.mutex.unlock(self.worker);
        self.wake = wake;
        if (self.head != null) if (wake) |w| w.notify(w.context);
    }

    fn assertOwner(self: *Self) void {
        if (self.owner != std.Thread.getCurrentId()) @panic("WindowIo task scheduling requires the window thread");
    }

    fn fromOpaque(context: ?*anyopaque) *Self {
        const self: *Self = @ptrCast(@alignCast(context.?));
        return self;
    }

    fn enqueueLocked(self: *Self, task: *Task) void {
        if (task.queued) return;
        task.queued = true;
        if (self.tail) |tail| tail.next = task else self.head = task;
        self.tail = task;
        self.ready.signal(self.worker);
        if (self.wake) |wake| wake.notify(wake.context);
    }

    fn enqueue(self: *Self, task: *Task) void {
        self.mutex.lockUncancelable(self.worker);
        defer self.mutex.unlock(self.worker);
        self.enqueueLocked(task);
    }

    fn next(self: *Self, wait: bool) ?*Task {
        self.mutex.lockUncancelable(self.worker);
        defer self.mutex.unlock(self.worker);
        while (self.head == null) {
            if (!wait) return null;
            self.ready.waitUncancelable(self.worker, &self.mutex);
        }
        const task = self.head.?;
        self.head = task.next;
        if (self.head == null) self.tail = null;
        task.next = null;
        task.queued = false;
        // A native wake can be coalesced; preserve readiness for the next
        // event-loop turn if this dispatch only consumed one runnable task.
        if (self.head != null) if (self.wake) |wake| wake.notify(wake.context);
        return task;
    }

    /// Run one ready fiber until completion or its next blocking Io operation.
    /// This never blocks when the ready queue is empty.
    pub fn dispatch(self: *Self) bool {
        self.assertOwner();
        std.debug.assert(self.current == null);
        const task = self.next(false) orelse return false;
        self.resumeTask(task);
        return true;
    }

    fn resumeTask(self: *Self, task: *Task) void {
        std.debug.assert(self.current == null and !task.done);
        self.current = task;
        const owns_root = native.enterRoot(&self.root);
        defer native.leaveRoot(owns_root);
        native.switchTo(&self.root, &task.fiber.context);
        self.current = null;
        if (task.done and task.group != null) self.finishGroupTask(task);
    }

    fn suspendFiber(self: *Self) void {
        const current = self.current.?;
        native.switchTo(&current.fiber.context, &self.root);
        std.debug.assert(self.current == current);
    }

    const Bytes = struct {
        allocation: []u8,
        length: usize,
        alignment: Alignment,

        fn init(allocator: Allocator, length: usize, alignment: Alignment) !Bytes {
            const size = @max(length, 1);
            const ptr = allocator.rawAlloc(size, alignment, @returnAddress()) orelse return error.OutOfMemory;
            return .{ .allocation = ptr[0..size], .length = length, .alignment = alignment };
        }

        fn slice(self: Bytes) []u8 {
            return self.allocation[0..self.length];
        }

        fn deinit(self: Bytes, allocator: Allocator) void {
            allocator.rawFree(self.allocation, self.alignment, @returnAddress());
        }
    };

    const WorkerWait = struct {
        context: *anyopaque,
        cancel: *const fn (*anyopaque) void,
    };

    const Task = struct {
        scheduler: *Self,
        fiber: native.Fiber = undefined,
        args: Bytes,
        result: Bytes,
        start: union(enum) {
            future: *const fn (*const anyopaque, *anyopaque) void,
            group: *const fn (*const anyopaque) void,
        },
        next: ?*Task = null,
        queued: bool = false,
        done: bool = false,
        canceled: bool = false,
        cancel_protection: Io.CancelProtection = .unblocked,
        waiter: ?*Task = null,
        waiting: union(enum) { none, future: *Task, group: *GroupState, worker: WorkerWait } = .none,
        group: ?*GroupState = null,
        group_next: ?*Task = null,

        fn entry(context: *anyopaque) noreturn {
            const self: *Task = @ptrCast(@alignCast(context));
            switch (self.start) {
                .future => |start| start(self.args.slice().ptr, self.result.slice().ptr),
                .group => |start| start(self.args.slice().ptr),
            }
            self.done = true;
            if (self.waiter) |waiter| self.scheduler.enqueue(waiter);
            self.scheduler.suspendFiber();
            unreachable;
        }

        fn requestCancel(self: *Task) void {
            if (self.done) return;
            self.canceled = true;
            if (self.cancel_protection == .blocked) return;
            switch (self.waiting) {
                .none => {},
                .future => |task| task.requestCancel(),
                .group => |group| group.requestCancel(),
                .worker => |worker| worker.cancel(worker.context),
            }
        }
    };

    fn createTask(self: *Self, result_len: usize, result_alignment: Alignment, context: []const u8, context_alignment: Alignment, start: @FieldType(Task, "start")) !*Task {
        self.assertOwner();
        const task = try self.allocator.create(Task);
        errdefer self.allocator.destroy(task);
        const args = try Bytes.init(self.allocator, context.len, context_alignment);
        errdefer args.deinit(self.allocator);
        @memcpy(args.slice(), context);
        const result = try Bytes.init(self.allocator, result_len, result_alignment);
        errdefer result.deinit(self.allocator);
        task.* = .{ .scheduler = self, .args = args, .result = result, .start = start };
        try task.fiber.init(Task.entry, task);
        self.live += 1;
        return task;
    }

    fn destroyTask(self: *Self, task: *Task) void {
        std.debug.assert(task.done and !task.queued);
        task.fiber.deinit();
        task.args.deinit(self.allocator);
        task.result.deinit(self.allocator);
        self.live -= 1;
        self.allocator.destroy(task);
    }

    fn asyncTask(context: ?*anyopaque, result: []u8, result_alignment: Alignment, args: []const u8, args_alignment: Alignment, start: *const fn (*const anyopaque, *anyopaque) void) ?*Io.AnyFuture {
        const self = fromOpaque(context);
        const task = self.createTask(result.len, result_alignment, args, args_alignment, .{ .future = start }) catch {
            start(args.ptr, result.ptr);
            return null;
        };
        self.enqueue(task);
        return @ptrCast(task);
    }

    fn concurrentTask(context: ?*anyopaque, result_len: usize, result_alignment: Alignment, args: []const u8, args_alignment: Alignment, start: *const fn (*const anyopaque, *anyopaque) void) Io.ConcurrentError!*Io.AnyFuture {
        const self = fromOpaque(context);
        const task = self.createTask(result_len, result_alignment, args, args_alignment, .{ .future = start }) catch return error.ConcurrencyUnavailable;
        self.enqueue(task);
        return @ptrCast(task);
    }

    fn awaitTask(context: ?*anyopaque, future: *Io.AnyFuture, result: []u8, _: Alignment) void {
        const self = fromOpaque(context);
        self.assertOwner();
        const task: *Task = @ptrCast(@alignCast(future));
        if (!task.done) {
            if (self.current) |current| {
                std.debug.assert(task != current and task.waiter == null);
                task.waiter = current;
                current.waiting = .{ .future = task };
                if (current.canceled and current.cancel_protection == .unblocked) task.requestCancel();
                self.suspendFiber();
                current.waiting = .none;
            } else while (!task.done) self.resumeTask(self.next(true).?);
        }
        std.debug.assert(task.done);
        @memcpy(result, task.result.slice());
        self.destroyTask(task);
    }

    fn cancelTask(context: ?*anyopaque, future: *Io.AnyFuture, result: []u8, result_alignment: Alignment) void {
        const self = fromOpaque(context);
        self.assertOwner();
        const task: *Task = @ptrCast(@alignCast(future));
        task.requestCancel();
        awaitTask(context, future, result, result_alignment);
    }

    const GroupState = struct {
        group: *Io.Group,
        head: ?*Task = null,
        waiter: ?*Task = null,
        canceled: bool = false,

        fn requestCancel(self: *GroupState) void {
            self.canceled = true;
            var task = self.head;
            while (task) |item| : (task = item.group_next) item.requestCancel();
        }
    };

    fn groupState(self: *Self, group: *Io.Group) !*GroupState {
        if (group.token.load(.acquire)) |token| return @ptrCast(@alignCast(token));
        const state = try self.allocator.create(GroupState);
        state.* = .{ .group = group };
        group.token.store(state, .release);
        return state;
    }

    fn groupConcurrent(context: ?*anyopaque, group: *Io.Group, args: []const u8, args_alignment: Alignment, start: *const fn (*const anyopaque) void) Io.ConcurrentError!void {
        const self = fromOpaque(context);
        self.assertOwner();
        const state = self.groupState(group) catch return error.ConcurrencyUnavailable;
        const task = self.createTask(0, .of(u8), args, args_alignment, .{ .group = start }) catch {
            if (state.head == null) {
                group.token.store(null, .release);
                self.allocator.destroy(state);
            }
            return error.ConcurrencyUnavailable;
        };
        task.group = state;
        task.group_next = state.head;
        state.head = task;
        task.canceled = state.canceled;
        self.enqueue(task);
    }

    fn groupAsync(context: ?*anyopaque, group: *Io.Group, args: []const u8, args_alignment: Alignment, start: *const fn (*const anyopaque) void) void {
        groupConcurrent(context, group, args, args_alignment, start) catch start(args.ptr);
    }

    fn finishGroupTask(self: *Self, task: *Task) void {
        const state = task.group.?;
        var link = &state.head;
        while (link.* != task) link = &link.*.?.group_next;
        link.* = task.group_next;
        self.destroyTask(task);
        if (state.head != null) return;
        state.group.token.store(null, .release);
        if (state.waiter) |waiter| {
            // The group state is freed before its waiter resumes; cancellation
            // in the intervening turn must not follow a stale group pointer.
            waiter.waiting = .none;
            self.enqueue(waiter);
        }
        self.allocator.destroy(state);
    }

    fn groupAwait(context: ?*anyopaque, group: *Io.Group, token: *anyopaque) Io.Cancelable!void {
        const self = fromOpaque(context);
        self.assertOwner();
        const state: *GroupState = @ptrCast(@alignCast(token));
        if (self.current) |current| {
            std.debug.assert(state.waiter == null);
            state.waiter = current;
            current.waiting = .{ .group = state };
            if (current.canceled and current.cancel_protection == .unblocked) state.requestCancel();
            self.suspendFiber();
            current.waiting = .none;
            return checkCancel(context);
        }
        while (group.token.load(.acquire) != null) self.resumeTask(self.next(true).?);
    }

    fn groupCancel(context: ?*anyopaque, group: *Io.Group, token: *anyopaque) void {
        fromOpaque(context).assertOwner();
        const state: *GroupState = @ptrCast(@alignCast(token));
        state.requestCancel();
        groupAwait(context, group, token) catch {};
    }

    fn checkCancel(context: ?*anyopaque) Io.Cancelable!void {
        const self = fromOpaque(context);
        self.assertOwner();
        if (self.current) |current| {
            if (current.canceled and current.cancel_protection == .unblocked) {
                current.canceled = false;
                return error.Canceled;
            }
        }
    }

    fn recancel(context: ?*anyopaque) void {
        const self = fromOpaque(context);
        self.assertOwner();
        if (self.current) |current| current.canceled = true;
    }

    fn swapCancelProtection(context: ?*anyopaque, new: Io.CancelProtection) Io.CancelProtection {
        const self = fromOpaque(context);
        self.assertOwner();
        const current = self.current orelse return .unblocked;
        const old = current.cancel_protection;
        current.cancel_protection = new;
        return old;
    }

    /// A window RPC can suspend only from a dispatched fiber: a root-level
    /// await does not dispatch the native window's event queue.
    pub fn inFiber(serial: Io) bool {
        if (serial.vtable != &vtable) return false;
        const self = fromOpaque(serial.userdata);
        self.assertOwner();
        return self.current != null;
    }

    /// Returns the detached I/O backend for work that must run off-window.
    /// Non-WindowIo callers (standalone services/tests) retain their supplied Io.
    pub fn backingIo(serial: Io) Io {
        if (serial.vtable == &vtable) return fromOpaque(serial.userdata).worker;
        return serial;
    }

    /// Run a detached operation while suspending the calling window fiber.
    /// The function must only touch its owned/captured data and the backing Io;
    /// callers install results on the window after this returns. On ordinary
    /// Io this runs inline (the caller may already be a background job).
    pub fn workerCall(serial: Io, comptime function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) @typeInfo(@TypeOf(function)).@"fn".return_type.? {
        if (serial.vtable != &vtable) return @call(.auto, function, args);
        return fromOpaque(serial.userdata).executeWorker(@TypeOf(function), function, args);
    }

    /// Use the worker backend for blocking operations. A fiber retains its
    /// arguments/results until the worker has fully joined.
    fn forward(self: *Self, comptime name: []const u8, args: std.meta.ArgsTuple(@typeInfo(@FieldType(Io.VTable, name)).pointer.child)) @typeInfo(@typeInfo(@FieldType(Io.VTable, name)).pointer.child).@"fn".return_type.? {
        const Fn = @typeInfo(@FieldType(Io.VTable, name)).pointer.child;
        var worker_args = args;
        worker_args[0] = self.worker.userdata;
        const function = @field(self.worker.vtable.*, name);
        // Some operations are immediate, or rely on the calling thread.
        if (comptime immediate(name)) return @call(.auto, function, worker_args);
        return self.executeWorker(Fn, function, worker_args);
    }

    fn executeWorker(self: *Self, comptime Fn: type, function: *const Fn, args: std.meta.ArgsTuple(Fn)) @typeInfo(Fn).@"fn".return_type.? {
        const Result = @typeInfo(Fn).@"fn".return_type.?;
        // Forwarding from an existing worker stays on it. Root-level waits
        // enter a structured scope rather than block the scheduler.
        if (self.owner != std.Thread.getCurrentId()) return @call(.auto, function, args);
        const current = self.current orelse {
            const RootCall = struct {
                fn run(runtime: *Self, run_function: *const Fn, original_args: std.meta.ArgsTuple(Fn)) Result {
                    return runtime.executeWorker(Fn, run_function, original_args);
                }
            };
            const serial = self.io();
            var future = serial.concurrent(RootCall.run, .{ self, function, args }) catch return @call(.auto, function, args);
            return future.await(serial);
        };
        if (comptime canCancel(Result)) {
            try checkCancel(self);
        }
        const Work = struct {
            scheduler: *Self,
            task: *Task,
            function: *const Fn,
            args: std.meta.ArgsTuple(Fn),
            result: Result = undefined,
            future: Io.Future(void) = undefined,
            cancellation: ?Io.Future(void) = null,
            done: bool = false,
            canceling: bool = false,

            fn run(work: *@This()) void {
                work.result = @call(.auto, work.function, work.args);
                const scheduler = work.scheduler;
                scheduler.mutex.lockUncancelable(scheduler.worker);
                work.done = true;
                if (!work.canceling) scheduler.enqueueLocked(work.task);
                scheduler.mutex.unlock(scheduler.worker);
            }

            fn cancelRun(work: *@This()) void {
                const scheduler = work.scheduler;
                work.future.cancel(scheduler.worker);
                scheduler.enqueue(work.task);
            }

            fn cancel(opaque_context: *anyopaque) void {
                const work: *@This() = @ptrCast(@alignCast(opaque_context));
                const scheduler = work.scheduler;
                scheduler.mutex.lockUncancelable(scheduler.worker);
                if (work.done or work.canceling) {
                    scheduler.mutex.unlock(scheduler.worker);
                    return;
                }
                work.canceling = true;
                scheduler.mutex.unlock(scheduler.worker);
                work.cancellation = scheduler.worker.concurrent(cancelRun, .{work}) catch {
                    cancelRun(work);
                    return;
                };
            }
        };
        var work: Work = .{ .scheduler = self, .task = current, .function = function, .args = args };
        work.future = self.worker.concurrent(Work.run, .{&work}) catch return @call(.auto, function, args);
        current.waiting = .{ .worker = .{ .context = &work, .cancel = Work.cancel } };
        if (current.canceled and current.cancel_protection == .unblocked) Work.cancel(&work);
        self.suspendFiber();
        current.waiting = .none;
        if (work.cancellation) |*cancellation| {
            cancellation.await(self.worker);
        } else {
            work.future.await(self.worker);
        }
        if (comptime canCancel(Result)) {
            if (work.result) |_| {} else |err| {
                if (err == error.Canceled) current.canceled = false;
            }
        }
        return work.result;
    }

    fn canCancel(comptime Result: type) bool {
        return switch (@typeInfo(Result)) {
            .error_union => |info| blk: {
                const errors = @typeInfo(info.error_set).error_set.error_names orelse break :blk true;
                for (errors) |err| if (std.mem.eql(u8, err, "Canceled")) break :blk true;
                break :blk false;
            },
            else => false,
        };
    }

    fn immediate(comptime name: []const u8) bool {
        const names = .{ "crashHandler", "now", "clockResolution", "futexWake", "lockStderr", "tryLockStderr", "unlockStderr", "processReplace", "processSetCurrentDir", "processSetCurrentPath" };
        inline for (names) |item| if (std.mem.eql(u8, name, item)) return true;
        return false;
    }

    fn Forward(comptime name: []const u8) type {
        const Fn = @typeInfo(@FieldType(Io.VTable, name)).pointer.child;
        const info = @typeInfo(Fn).@"fn";
        const R = info.return_type.?;
        const n = info.param_types.len;
        const A = if (n > 1) info.param_types[1].? else void;
        const B = if (n > 2) info.param_types[2].? else void;
        const C = if (n > 3) info.param_types[3].? else void;
        const D = if (n > 4) info.param_types[4].? else void;
        const E = if (n > 5) info.param_types[5].? else void;
        return struct {
            const call = switch (n) {
                1 => f1,
                2 => f2,
                3 => f3,
                4 => f4,
                5 => f5,
                6 => f6,
                else => @compileError("Unexpected Io vtable arity"),
            };
            fn f1(p: ?*anyopaque) R {
                return fromOpaque(p).forward(name, .{p});
            }
            fn f2(p: ?*anyopaque, a: A) R {
                return fromOpaque(p).forward(name, .{ p, a });
            }
            fn f3(p: ?*anyopaque, a: A, b: B) R {
                return fromOpaque(p).forward(name, .{ p, a, b });
            }
            fn f4(p: ?*anyopaque, a: A, b: B, c: C) R {
                return fromOpaque(p).forward(name, .{ p, a, b, c });
            }
            fn f5(p: ?*anyopaque, a: A, b: B, c: C, d: D) R {
                return fromOpaque(p).forward(name, .{ p, a, b, c, d });
            }
            fn f6(p: ?*anyopaque, a: A, b: B, c: C, d: D, e: E) R {
                return fromOpaque(p).forward(name, .{ p, a, b, c, d, e });
            }
        };
    }

    const vtable: Io.VTable = makeVtable();
    fn makeVtable() Io.VTable {
        const overrides = .{ .async = asyncTask, .concurrent = concurrentTask, .await = awaitTask, .cancel = cancelTask, .groupAsync = groupAsync, .groupConcurrent = groupConcurrent, .groupAwait = groupAwait, .groupCancel = groupCancel, .checkCancel = checkCancel, .recancel = recancel, .swapCancelProtection = swapCancelProtection };
        var result: Io.VTable = undefined;
        inline for (@typeInfo(Io.VTable).@"struct".field_names) |name| {
            @field(result, name) = if (@hasField(@TypeOf(overrides), name)) @field(overrides, name) else Forward(name).call;
        }
        return result;
    }
};
