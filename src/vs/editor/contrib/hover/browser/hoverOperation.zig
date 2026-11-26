// Port of the portable state machine from
// `src/vs/editor/contrib/hover/browser/hoverOperation.ts`.
//
// Native deadline timers and detachable result continuations replace the
// browser schedulers and AsyncIterableProducer. Async results stream in
// resolution order, sync results start at the full delay, and the independent
// three-delay loading state and cancellation follow the upstream operation.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const cancellation = @import("../../../../base/common/cancellation.zig");
const CancellationToken = cancellation.CancellationToken;
const IDisposable = @import("../../../../base/common/lifecycle.zig").IDisposable;

pub const HoverStartMode = enum {
    delayed,
    immediate,
};

pub const Timer = struct {
    context: *anyopaque,
    schedule: *const fn (
        context: *anyopaque,
        delay_ms: u64,
        callback: *const fn (callback_context: *anyopaque) void,
        callback_context: *anyopaque,
    ) void,
    cancel: *const fn (context: *anyopaque) void,
};

/// Native continuation of the upstream asynchronous iterable. The result
/// values are borrowed for the emit call; complete invalidates the request's
/// disposable, and cancel must detach both callbacks.
pub fn AsyncResultSink(comptime Result: type) type {
    return struct {
        context: *anyopaque,
        emit: *const fn (*anyopaque, []const Result) void,
        complete: *const fn (*anyopaque) void,
    };
}

pub fn HoverComputer(comptime Args: type, comptime Result: type) type {
    return struct {
        context: *anyopaque,
        request_async: ?*const fn (*anyopaque, *const Args, CancellationToken, AsyncResultSink(Result)) anyerror!?IDisposable = null,
        compute_async: ?*const fn (context: *anyopaque, args: *const Args, token: CancellationToken) anyerror![]const Result = null,
        compute_sync: ?*const fn (context: *anyopaque, args: *const Args) anyerror![]const Result = null,
    };
}

pub fn HoverResult(comptime Args: type, comptime Result: type) type {
    return struct {
        value: []const Result,
        is_complete: bool,
        has_loading_message: bool,
        options: Args,
    };
}

pub fn HoverOperation(comptime Args: type, comptime Result: type) type {
    return struct {
        const Self = @This();
        const Computer = HoverComputer(Args, Result);
        const ResultEvent = HoverResult(Args, Result);
        const State = enum {
            idle,
            first_wait,
            second_wait,
            waiting_for_async,
            waiting_for_async_showing_loading,
        };
        const Phase = enum { none, first_wait, second_wait };

        allocator: Allocator,
        computer: Computer,
        timer: Timer,
        loading_timer: ?Timer = null,
        on_result: *const fn (context: *anyopaque, result: ResultEvent) void,
        on_result_context: *anyopaque,

        state: State = .idle,
        options: ?Args = null,
        results: ArrayList(Result),
        pending_phase: Phase = .none,
        hover_time_ms: u64 = 300,
        async_source: ?cancellation.CancellationTokenSource = null,
        async_request: ?IDisposable = null,
        async_done: bool = true,
        starting_async: bool = false,

        pub fn init(
            allocator: Allocator,
            computer: Computer,
            timer: Timer,
            on_result: *const fn (context: *anyopaque, result: ResultEvent) void,
            on_result_context: *anyopaque,
        ) Self {
            return .{
                .allocator = allocator,
                .computer = computer,
                .timer = timer,
                .on_result = on_result,
                .on_result_context = on_result_context,
                .results = ArrayList(Result).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.cancel();
            self.results.deinit();
        }

        pub fn setLoadingTimer(self: *Self, timer: Timer) void {
            if (self.loading_timer) |old| old.cancel(old.context);
            self.loading_timer = timer;
        }

        fn schedule(self: *Self, phase: Phase, delay_ms: u64) void {
            self.pending_phase = phase;
            self.timer.schedule(self.timer.context, delay_ms, onTimer, self);
        }

        fn cancelTimer(self: *Self) void {
            self.pending_phase = .none;
            self.timer.cancel(self.timer.context);
        }

        fn cancelLoadingTimer(self: *Self) void {
            if (self.loading_timer) |timer| timer.cancel(timer.context);
        }

        fn onTimer(context: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context));
            const phase = self.pending_phase;
            self.pending_phase = .none;
            switch (phase) {
                .first_wait => self.triggerAsyncComputation(),
                .second_wait => self.triggerSyncComputation(),
                .none => {},
            }
        }

        fn onLoadingTimer(context: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context));
            if (self.state != .waiting_for_async) return;
            self.state = .waiting_for_async_showing_loading;
            self.fireResult();
        }

        fn releaseSource(self: *Self) void {
            if (self.async_source) |*source| source.deinit();
            self.async_source = null;
        }

        fn onAsyncResults(context: *anyopaque, values: []const Result) void {
            const self: *Self = @ptrCast(@alignCast(context));
            if (self.async_done or self.options == null or values.len == 0) return;
            self.results.appendSlice(values) catch return;
            self.fireResult();
        }

        fn onAsyncComplete(context: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context));
            if (self.async_done) return;
            self.async_done = true;
            self.async_request = null;
            if (!self.starting_async) self.releaseSource();
            if (self.state == .waiting_for_async or self.state == .waiting_for_async_showing_loading) {
                self.state = .idle;
                self.cancelLoadingTimer();
                self.fireResult();
            }
        }

        fn startAsync(self: *Self, options: *const Args) void {
            self.async_done = false;
            if (self.computer.request_async) |request| {
                self.async_source = cancellation.CancellationTokenSource.init(self.allocator) catch {
                    self.async_done = true;
                    return;
                };
                const token = self.async_source.?.token() catch {
                    self.releaseSource();
                    self.async_done = true;
                    return;
                };
                self.starting_async = true;
                const pending = request(self.computer.context, options, token, .{ .context = self, .emit = onAsyncResults, .complete = onAsyncComplete }) catch null;
                self.starting_async = false;
                if (self.async_done) {
                    self.releaseSource();
                } else if (pending) |handle| {
                    self.async_request = handle;
                } else onAsyncComplete(self);
            } else {
                if (self.computer.compute_async) |compute| {
                    const values = compute(self.computer.context, options, .None) catch &.{};
                    self.results.appendSlice(values) catch {};
                }
                self.async_done = true;
            }
        }

        fn triggerAsyncComputation(self: *Self) void {
            const options = self.options orelse return;
            self.state = .second_wait;
            self.schedule(.second_wait, self.hover_time_ms - self.hover_time_ms / 2);
            self.startAsync(&options);
        }

        fn triggerSyncComputation(self: *Self) void {
            if (self.computer.compute_sync) |compute| {
                const options = self.options orelse return;
                const values = compute(self.computer.context, &options) catch &.{};
                self.results.appendSlice(values) catch {};
            }
            self.state = if (self.async_done) .idle else .waiting_for_async;
            if (self.async_done) self.cancelLoadingTimer();
            self.fireResult();
        }

        fn fireResult(self: *Self) void {
            if (self.state == .first_wait or self.state == .second_wait) return;
            self.on_result(self.on_result_context, .{
                .value = self.results.items,
                .is_complete = self.state == .idle,
                .has_loading_message = self.state == .waiting_for_async_showing_loading,
                .options = self.options orelse return,
            });
        }

        pub fn start(self: *Self, mode: HoverStartMode, options: Args) void {
            if (mode == .delayed) {
                if (self.state != .idle) return;
                self.results.clearRetainingCapacity();
                self.options = options;
                self.state = .first_wait;
                self.schedule(.first_wait, self.hover_time_ms / 2);
                if (self.loading_timer) |timer| timer.schedule(timer.context, 3 * self.hover_time_ms, onLoadingTimer, self);
                return;
            }
            switch (self.state) {
                .idle => {
                    self.results.clearRetainingCapacity();
                    self.options = options;
                    self.triggerAsyncComputation();
                    self.cancelTimer();
                    self.triggerSyncComputation();
                },
                .second_wait => {
                    self.cancelTimer();
                    self.triggerSyncComputation();
                },
                else => {},
            }
        }

        pub fn cancel(self: *Self) void {
            self.cancelTimer();
            self.cancelLoadingTimer();
            self.async_done = true; // callbacks during token cancellation are stale
            if (self.async_source) |*source| source.cancel();
            if (self.async_request) |request| request.dispose();
            self.async_request = null;
            self.releaseSource();
            self.results.clearRetainingCapacity();
            self.options = null;
            self.state = .idle;
        }

        pub fn isIdle(self: *const Self) bool {
            return self.state == .idle and self.pending_phase == .none;
        }
    };
}

test "hoverOperation: delayed operation fires after both waits" {
    const testing = std.testing;

    const FakeTimer = struct {
        callback: ?*const fn (*anyopaque) void = null,
        context: *anyopaque = undefined,
        delay: u64 = 0,

        fn schedule(context: *anyopaque, delay: u64, callback: *const fn (*anyopaque) void, callback_context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.callback = callback;
            self.context = callback_context;
            self.delay = delay;
        }

        fn cancel(_: *anyopaque) void {}
    };

    const State = struct {
        events: ArrayList(u32),

        fn result(context: *anyopaque, event: @import("./hoverOperation.zig").HoverResult(u32, u32)) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.events.append(@intCast(event.value.len)) catch {};
        }
    };

    const allocator = testing.allocator;
    var fake_timer = FakeTimer{};
    var state = State{ .events = ArrayList(u32).init(allocator) };
    defer state.events.deinit();

    const computer = @import("./hoverOperation.zig").HoverComputer(u32, u32){
        .context = &state,
        .compute_sync = struct {
            fn compute(_: *anyopaque, _: *const u32) anyerror![]const u32 {
                return &.{ 7, 8 };
            }
        }.compute,
    };
    var operation = @import("./hoverOperation.zig").HoverOperation(u32, u32).init(
        allocator,
        computer,
        .{ .context = &fake_timer, .schedule = FakeTimer.schedule, .cancel = FakeTimer.cancel },
        State.result,
        &state,
    );
    defer operation.deinit();

    operation.start(.delayed, 0);
    try testing.expectEqual(@as(usize, 0), state.events.items.len);
    try testing.expectEqual(@as(u64, 150), fake_timer.delay);

    fake_timer.callback.?(fake_timer.context);
    try testing.expectEqual(@as(usize, 0), state.events.items.len);
    try testing.expectEqual(@as(u64, 150), fake_timer.delay);

    fake_timer.callback.?(fake_timer.context);
    try testing.expectEqual(@as(usize, 1), state.events.items.len);
    try testing.expectEqual(@as(u32, 2), state.events.items[0]);
}

test "hoverOperation: streams semantic results after full delay, shows loading at triple delay, and detaches canceled requests" {
    const a = std.testing.allocator;
    const FakeTimer = struct {
        delay: u64 = 0,
        callback: ?*const fn (*anyopaque) void = null,
        context: ?*anyopaque = null,
        fn interface(self: *@This()) Timer {
            return .{ .context = self, .schedule = schedule, .cancel = cancel };
        }
        fn schedule(context: *anyopaque, delay: u64, callback: *const fn (*anyopaque) void, target: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.delay = delay;
            self.callback = callback;
            self.context = target;
        }
        fn cancel(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.callback = null;
        }
        fn fire(self: *@This()) void {
            const callback = self.callback.?;
            self.callback = null;
            callback(self.context.?);
        }
    };
    const State = struct {
        sink: ?AsyncResultSink(u32) = null,
        token: CancellationToken = .None,
        canceled: bool = false,
        events: std.ArrayList(struct { count: usize, complete: bool, loading: bool }) = .empty,
        fn request(context: *anyopaque, _: *const u32, token: CancellationToken, sink: AsyncResultSink(u32)) !?IDisposable {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.sink = sink;
            self.token = token;
            return IDisposable.from(@This(), self, cancelRequest);
        }
        fn cancelRequest(self: *@This()) void {
            self.canceled = self.token.isCancellationRequested();
            self.sink = null;
        }
        fn sync(_: *anyopaque, _: *const u32) ![]const u32 {
            return &.{9};
        }
        fn result(context: *anyopaque, event: HoverResult(u32, u32)) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.events.append(std.testing.allocator, .{ .count = event.value.len, .complete = event.is_complete, .loading = event.has_loading_message }) catch unreachable;
        }
        fn emit(self: *@This(), values: []const u32) void {
            const sink = self.sink orelse return;
            sink.emit(sink.context, values);
        }
        fn complete(self: *@This()) void {
            const sink = self.sink.?;
            self.sink = null;
            sink.complete(sink.context);
        }
    };
    var state: State = .{};
    defer state.events.deinit(a);
    var timer: FakeTimer = .{};
    var loading: FakeTimer = .{};
    var operation = HoverOperation(u32, u32).init(a, .{ .context = &state, .request_async = State.request, .compute_sync = State.sync }, timer.interface(), State.result, &state);
    defer operation.deinit();
    operation.setLoadingTimer(loading.interface());
    operation.start(.delayed, 1);
    try std.testing.expectEqual(150, timer.delay);
    try std.testing.expectEqual(900, loading.delay);
    timer.fire();
    state.emit(&.{1});
    try std.testing.expectEqual(0, state.events.items.len);
    timer.fire();
    try std.testing.expectEqual(2, state.events.items[0].count);
    try std.testing.expect(!state.events.items[0].complete and !state.events.items[0].loading);
    loading.fire();
    try std.testing.expect(state.events.items[1].loading);
    state.emit(&.{2});
    try std.testing.expectEqual(3, state.events.items[2].count);
    try std.testing.expect(state.events.items[2].loading);
    state.complete();
    try std.testing.expect(state.events.items[3].complete and !state.events.items[3].loading);
    operation.cancel();
    operation.start(.delayed, 2);
    timer.fire();
    operation.cancel();
    try std.testing.expect(state.canceled and state.sink == null);
    try std.testing.expect(timer.callback == null and loading.callback == null);
    state.emit(&.{3});
    try std.testing.expectEqual(4, state.events.items.len);
}
