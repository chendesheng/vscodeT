// Port of the portable state machine from
// `src/vs/editor/contrib/hover/browser/hoverOperation.ts`.
//
// Browser timing and async iterables are not available here. Timers are
// injected through `Timer`, and async computation is represented by a callback
// that yields its results synchronously; the state machine still models the
// first wait, second wait, cancellation, and final result notification.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const CancellationToken = @import("../../../../base/common/cancellation.zig").CancellationToken;
const HoverStartSource = @import("./hoverTypes.zig").HoverStartSource;

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

pub fn HoverComputer(comptime Args: type, comptime Result: type) type {
    return struct {
        context: *anyopaque,
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
        on_result: *const fn (context: *anyopaque, result: ResultEvent) void,
        on_result_context: *anyopaque,

        state: State = .idle,
        options: ?Args = null,
        results: ArrayList(Result),
        pending_phase: Phase = .none,
        hover_time_ms: u64 = 300,

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
            self.timer.cancel(self.timer.context);
            self.results.deinit();
        }

        fn resetResults(self: *Self) void {
            self.results.clearRetainingCapacity();
            self.options = null;
            self.state = .idle;
            self.pending_phase = .none;
        }

        fn schedule(self: *Self, phase: Phase, delay_ms: u64) void {
            self.pending_phase = phase;
            self.timer.schedule(self.timer.context, delay_ms, onTimer, self);
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

        fn appendAsyncResults(self: *Self) void {
            if (self.computer.compute_async) |compute| {
                const args = self.options.?;
                const values = compute(self.computer.context, &args, .None) catch &[_]Result{};
                self.results.appendSlice(values) catch {};
                self.state = .waiting_for_async;
            } else {
                self.state = .waiting_for_async;
            }
        }

        fn triggerAsyncComputation(self: *Self) void {
            const options = self.options orelse return;
            self.state = .second_wait;
            self.schedule(.second_wait, self.hover_time_ms / 2);
            self.appendAsyncResults();
            _ = options;
        }

        fn triggerSyncComputation(self: *Self) void {
            if (self.computer.compute_sync) |compute| {
                const options = self.options orelse return;
                const values = compute(self.computer.context, &options) catch &[_]Result{};
                self.results.appendSlice(values) catch {};
            }
            self.state = .idle;
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
                self.options = options;
                self.state = .first_wait;
                self.schedule(.first_wait, self.hover_time_ms / 2);
                return;
            }

            self.options = options;
            self.results.clearRetainingCapacity();
            self.appendAsyncResults();
            self.triggerSyncComputation();
        }

        pub fn cancel(self: *Self) void {
            self.timer.cancel(self.timer.context);
            self.resetResults();
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
