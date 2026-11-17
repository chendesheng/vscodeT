// Port of the data/runner subset of
// `src/vs/platform/progress/common/progress.ts`.
//
// Terminal adaptations: `IProgressService`, `UnmanagedProgress` and
// `LongRunningOperation` (cancellation tokens, disposables, workbench
// reporting) are not ported; the progress location/options/steps, runner and
// the generic `Progress` reporter are.
const std = @import("std");
const NotificationText = @import("../../notification/common/notificationMessage.zig").NotificationText;

pub const ProgressLocation = enum(u8) {
    Explorer = 1,
    Scm = 3,
    Extensions = 5,
    Window = 10,
    Notification = 15,
    Dialog = 20,
};

/// A localized string or rich notification text.
pub const Message = union(enum) {
    text: []const u8,
    content: *const NotificationText,
};

pub const IProgressOptions = struct {
    location: ProgressLocation,
    title: ?Message = null,
    source: ?[]const u8 = null,
    total: ?i64 = null,
    cancellable: bool = false,
    buttons: []const []const u8 = &.{},
};

pub const IProgressNotificationOptions = struct {
    base: IProgressOptions,
    delay: ?i64 = null,
    kind: ?enum { loading, syncing } = null,
};

pub const IProgressStep = struct {
    message: ?Message = null,
    increment: ?i64 = null,
    total: ?i64 = null,
};

pub const IProgressRunner = struct {
    context: *anyopaque,
    total_fn: *const fn (context: *anyopaque, value: i64) void,
    worked_fn: *const fn (context: *anyopaque, value: i64) void,
    done_fn: *const fn (context: *anyopaque) void,

    pub fn total(self: IProgressRunner, value: i64) void {
        self.total_fn(self.context, value);
    }

    pub fn worked(self: IProgressRunner, value: i64) void {
        self.worked_fn(self.context, value);
    }

    pub fn done(self: IProgressRunner) void {
        self.done_fn(self.context);
    }
};

const EmptyRunner = struct {
    fn total(_: *anyopaque, _: i64) void {}
    fn worked(_: *anyopaque, _: i64) void {}
    fn done(_: *anyopaque) void {}
};

pub const emptyProgressRunner = IProgressRunner{
    .context = @ptrFromInt(1),
    .total_fn = EmptyRunner.total,
    .worked_fn = EmptyRunner.worked,
    .done_fn = EmptyRunner.done,
};

/// `IProgress<T>`; `None` is available as `Progress(T).none`.
pub fn Progress(comptime T: type) type {
    return struct {
        const Self = @This();
        context: *anyopaque,
        callback: *const fn (context: *anyopaque, item: T) void,
        value: ?T = null,

        pub fn init(context: *anyopaque, callback: *const fn (context: *anyopaque, item: T) void) Self {
            return .{ .context = context, .callback = callback };
        }

        pub fn report(self: *Self, item: T) void {
            self.value = item;
            self.callback(self.context, item);
        }

        pub fn None() Self {
            return .{ .context = @ptrFromInt(1), .callback = noneCallback };
        }

        fn noneCallback(_: *anyopaque, _: T) void {}
    };
}

test "progress reporter stores and forwards values" {
    const State = struct {
        total: i64 = 0,
        fn report(context: *anyopaque, item: i64) void {
            const state: *@This() = @ptrCast(@alignCast(context));
            state.total += item;
        }
    };
    var state = State{};
    var progress = Progress(i64).init(&state, State.report);
    progress.report(3);
    progress.report(4);
    try std.testing.expectEqual(@as(i64, 7), state.total);
    try std.testing.expectEqual(@as(?i64, 4), progress.value);
}

test "progress runner delegates and the empty runner is a no-op" {
    const State = struct {
        total_value: i64 = 0,
        worked_value: i64 = 0,
        done_called: bool = false,
        fn total(context: *anyopaque, value: i64) void {
            const state: *@This() = @ptrCast(@alignCast(context));
            state.total_value = value;
        }
        fn worked(context: *anyopaque, value: i64) void {
            const state: *@This() = @ptrCast(@alignCast(context));
            state.worked_value = value;
        }
        fn done(context: *anyopaque) void {
            const state: *@This() = @ptrCast(@alignCast(context));
            state.done_called = true;
        }
    };
    var state = State{};
    const runner = IProgressRunner{
        .context = &state,
        .total_fn = State.total,
        .worked_fn = State.worked,
        .done_fn = State.done,
    };
    runner.total(10);
    runner.worked(2);
    runner.done();
    try std.testing.expectEqual(@as(i64, 10), state.total_value);
    try std.testing.expectEqual(@as(i64, 2), state.worked_value);
    try std.testing.expect(state.done_called);

    emptyProgressRunner.total(5);
    emptyProgressRunner.worked(5);
    emptyProgressRunner.done();
    try std.testing.expectEqual(@as(u8, 15), @backingInt(ProgressLocation.Notification));
}
