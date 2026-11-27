const std = @import("std");
const Io = std.Io;
const WindowIo = @import("ui").WindowIo;

test "WindowIo nested save RPC and timer keep the same window thread" {
    var runtime = try WindowIo.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const io = runtime.io();
    const Model = struct {
        thread: std.Thread.Id,
        phase: u8 = 0,
        edit_ready: Io.Event = .unset,

        fn participate(self: *@This(), serial: Io) !void {
            try std.testing.expectEqual(self.thread, std.Thread.getCurrentId());
            self.phase = 1;
            try self.edit_ready.wait(serial);
            try std.testing.expectEqual(self.thread, std.Thread.getCurrentId());
            try std.testing.expectEqual(@as(u8, 2), self.phase);
            self.phase = 3;
        }

        fn receiveEdit(self: *@This(), serial: Io) !void {
            try std.testing.expectEqual(self.thread, std.Thread.getCurrentId());
            try std.testing.expectEqual(@as(u8, 1), self.phase);
            try serial.sleep(.fromMilliseconds(1), .awake);
            try std.testing.expectEqual(self.thread, std.Thread.getCurrentId());
            self.phase = 2;
            self.edit_ready.set(serial);
        }
    };
    var model: Model = .{ .thread = std.Thread.getCurrentId() };
    var save = try io.concurrent(Model.participate, .{ &model, io });
    defer save.cancel(io) catch {};
    try std.testing.expect(runtime.dispatch());
    try std.testing.expectEqual(@as(u8, 1), model.phase);
    var edit = try io.concurrent(Model.receiveEdit, .{ &model, io });
    defer edit.cancel(io) catch {};
    try save.await(io);
    try edit.await(io);
    try std.testing.expectEqual(@as(u8, 3), model.phase);
}

test "WindowIo cancellation interrupts a suspended timer and groups join" {
    var runtime = try WindowIo.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const io = runtime.io();
    const Probe = struct {
        fn timer(serial: Io) Io.Cancelable!void {
            try serial.sleep(.fromSeconds(60), .awake);
        }
        fn increment(serial: Io, counter: *usize) Io.Cancelable!void {
            try serial.sleep(.fromMilliseconds(1), .awake);
            counter.* += 1;
        }
    };
    var future = try io.concurrent(Probe.timer, .{io});
    try std.testing.expect(runtime.dispatch());
    try std.testing.expectError(error.Canceled, future.cancel(io));
    var counter: usize = 0;
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Probe.increment, .{ io, &counter });
    try group.concurrent(io, Probe.increment, .{ io, &counter });
    try group.await(io);
    try std.testing.expectEqual(@as(usize, 2), counter);
}

test "WindowIo group cancellation after completion but before resumption is safe" {
    var runtime = try WindowIo.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const io = runtime.io();
    const Probe = struct {
        fn child() Io.Cancelable!void {}
        fn parent(serial: Io) !void {
            var group: Io.Group = .init;
            defer group.cancel(serial);
            try group.concurrent(serial, child, .{});
            try group.await(serial);
        }
    };
    var parent = try io.concurrent(Probe.parent, .{io});
    defer parent.cancel(io) catch {};
    // Parent suspends on the group, then the child completes and destroys
    // the group state. The parent is runnable but has not resumed yet.
    try std.testing.expect(runtime.dispatch());
    try std.testing.expect(runtime.dispatch());
    try std.testing.expectError(error.Canceled, parent.cancel(io));
}

test "WindowIo awaits a nested future and joins worker file I/O" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var runtime = try WindowIo.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const io = runtime.io();
    const Probe = struct {
        fn child(serial: Io, dir: Io.Dir, thread: std.Thread.Id) !void {
            try std.testing.expectEqual(thread, std.Thread.getCurrentId());
            try dir.writeFile(serial, .{ .sub_path = "edit.txt", .data = "modified" });
            try std.testing.expectEqual(thread, std.Thread.getCurrentId());
        }
        fn parent(serial: Io, dir: Io.Dir, thread: std.Thread.Id) !void {
            var future = serial.async(child, .{ serial, dir, thread });
            defer future.cancel(serial) catch {};
            try future.await(serial);
            try std.testing.expectEqual(thread, std.Thread.getCurrentId());
        }
    };
    var future = try io.concurrent(Probe.parent, .{ io, temp.dir, std.Thread.getCurrentId() });
    defer future.cancel(io) catch {};
    try future.await(io);
    const value = try temp.dir.readFileAlloc(std.testing.io, "edit.txt", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("modified", value);
}

test "WindowIo native wake remains ready when dispatching one task at a time" {
    var runtime = try WindowIo.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const io = runtime.io();
    const WakeProbe = struct {
        signals: std.atomic.Value(usize) = .init(0),
        fn notify(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            _ = self.signals.fetchAdd(1, .monotonic);
        }
        fn task(count: *usize) void {
            count.* += 1;
        }
    };
    var wake: WakeProbe = .{};
    runtime.setWake(.{ .context = &wake, .notify = WakeProbe.notify });
    defer runtime.setWake(null);
    var count: usize = 0;
    var first = try io.concurrent(WakeProbe.task, .{&count});
    defer first.cancel(io);
    var second = try io.concurrent(WakeProbe.task, .{&count});
    defer second.cancel(io);
    wake.signals.store(0, .monotonic);
    try std.testing.expect(runtime.dispatch());
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expect(wake.signals.load(.monotonic) != 0);
    try std.testing.expect(runtime.dispatch());
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expect(!runtime.dispatch());
    first.await(io);
    second.await(io);
}

test "WindowIo accepts a worker completion without moving editor execution" {
    var runtime = try WindowIo.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const io = runtime.io();
    const Probe = struct {
        editor_thread: std.Thread.Id,
        began: Io.Event = .unset,
        returned: Io.Event = .unset,
        worker_thread: ?std.Thread.Id = null,

        fn editor(self: *@This(), serial: Io) !void {
            try std.testing.expectEqual(self.editor_thread, std.Thread.getCurrentId());
            self.began.set(serial);
            try self.returned.wait(serial);
            try std.testing.expectEqual(self.editor_thread, std.Thread.getCurrentId());
            try std.testing.expect(self.worker_thread.? != self.editor_thread);
        }

        fn worker(self: *@This(), worker_io: Io) Io.Cancelable!void {
            try self.began.wait(worker_io);
            self.worker_thread = std.Thread.getCurrentId();
            self.returned.set(worker_io);
        }
    };
    var probe: Probe = .{ .editor_thread = std.Thread.getCurrentId() };
    var worker = try std.testing.io.concurrent(Probe.worker, .{ &probe, std.testing.io });
    defer worker.cancel(std.testing.io) catch {};
    var editor = try io.concurrent(Probe.editor, .{ &probe, io });
    defer editor.cancel(io) catch {};
    try editor.await(io);
    try worker.await(std.testing.io);
}

test "WindowIo root can select a result while sibling fibers are pending" {
    var runtime = try WindowIo.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const io = runtime.io();
    const Result = union(enum) { fast: Io.Cancelable!u32, slow: Io.Cancelable!u32 };
    var buffer: [2]Result = undefined;
    var selection = Io.Select(Result).init(io, &buffer);
    defer selection.cancelDiscard();
    const Probe = struct {
        fn result(serial: Io, duration: Io.Duration, value: u32) Io.Cancelable!u32 {
            try serial.sleep(duration, .awake);
            return value;
        }
    };
    try selection.concurrent(.slow, Probe.result, .{ io, Io.Duration.fromSeconds(60), @as(u32, 1) });
    try selection.concurrent(.fast, Probe.result, .{ io, Io.Duration.fromMilliseconds(1), @as(u32, 42) });
    switch (try selection.await()) {
        .fast => |value| try std.testing.expectEqual(@as(u32, 42), try value),
        .slow => return error.SlowTaskCompletedFirst,
    }
}

test "WindowIo detached jobs run on the worker and resume the owning window" {
    var first = try WindowIo.init(std.testing.allocator, std.testing.io);
    defer first.deinit();
    var second = try WindowIo.init(std.testing.allocator, std.testing.io);
    defer second.deinit();
    const Probe = struct {
        fn detached(worker: Io) !std.Thread.Id {
            try worker.sleep(.fromMilliseconds(1), .awake);
            return std.Thread.getCurrentId();
        }
        fn editor(serial: Io) !std.Thread.Id {
            const owner = std.Thread.getCurrentId();
            const worker = WindowIo.backingIo(serial);
            try std.testing.expect(worker.vtable != serial.vtable);
            const id = try WindowIo.workerCall(serial, detached, .{worker});
            try std.testing.expect(owner != id);
            try std.testing.expectEqual(owner, std.Thread.getCurrentId());
            return owner;
        }
    };
    const a = first.io();
    const b = second.io();
    var f = try a.concurrent(Probe.editor, .{a});
    defer _ = f.cancel(a) catch 0;
    var g = try b.concurrent(Probe.editor, .{b});
    defer _ = g.cancel(b) catch 0;
    try std.testing.expect(first.dispatch());
    try std.testing.expect(second.dispatch());
    try std.testing.expectEqual(std.Thread.getCurrentId(), try f.await(a));
    try std.testing.expectEqual(std.Thread.getCurrentId(), try g.await(b));
}
