// Port of the phase barriers in `src/vs/workbench/services/lifecycle/common/lifecycleService.ts`.
// A queued Zig continuation corresponds to a caller awaiting the phase barrier.
const std = @import("std");
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const lifecycle = @import("lifecycle.zig");
const Phase = lifecycle.LifecyclePhase;
const Continuation = lifecycle.Continuation;

pub const LifecycleService = struct {
    allocator: std.mem.Allocator,
    phase: Phase = .Starting,
    phase_when: std.EnumArray(Phase, std.ArrayList(Continuation)) = .initFill(.empty),
    on_will_shutdown: Emitter(lifecycle.WillShutdownEvent),
    on_did_shutdown: Emitter(void),
    will_shutdown: bool = false,

    pub fn init(allocator: std.mem.Allocator) LifecycleService {
        return .{ .allocator = allocator, .on_will_shutdown = .init(allocator), .on_did_shutdown = .init(allocator) };
    }

    pub fn deinit(self: *LifecycleService) void {
        for (&self.phase_when.values) |*queue| queue.deinit(self.allocator);
        self.on_will_shutdown.deinit();
        self.on_did_shutdown.deinit();
    }

    pub fn interface(self: *LifecycleService) lifecycle.ILifecycleService {
        return .{ .context = self, .phase_fn = phaseContext, .set_phase = setPhaseContext, .when_fn = whenContext, .on_will_shutdown = &self.on_will_shutdown, .on_did_shutdown = &self.on_did_shutdown };
    }

    pub fn setPhase(self: *LifecycleService, value: Phase) !void {
        if (!value.reached(self.phase)) return error.LifecycleCannotGoBackwards;
        if (self.phase == value) return;
        self.phase = value;
        const barrier = self.phase_when.getPtr(value);
        var callbacks = barrier.*;
        barrier.* = .empty;
        defer callbacks.deinit(self.allocator);
        var first_error: ?anyerror = null;
        for (callbacks.items) |callback| {
            callback.run(callback.context) catch |err| {
                if (first_error == null) first_error = err;
            };
        }
        if (first_error) |err| return err;
    }

    pub fn when(self: *LifecycleService, value: Phase, continuation: Continuation) !void {
        if (self.phase.reached(value)) return continuation.run(continuation.context);
        try self.phase_when.getPtr(value).append(self.allocator, continuation);
    }

    pub fn shutdown(self: *LifecycleService, reason: lifecycle.ShutdownReason) !void {
        if (self.will_shutdown) return;
        self.will_shutdown = true;
        const will = self.on_will_shutdown.fire(.{ .reason = reason });
        const did = self.on_did_shutdown.fire({});
        try will;
        try did;
    }

    fn phaseContext(context: *anyopaque) Phase {
        const self: *LifecycleService = @ptrCast(@alignCast(context));
        return self.phase;
    }
    fn setPhaseContext(context: *anyopaque, value: Phase) !void {
        const self: *LifecycleService = @ptrCast(@alignCast(context));
        try self.setPhase(value);
    }
    fn whenContext(context: *anyopaque, value: Phase, continuation: Continuation) !void {
        const self: *LifecycleService = @ptrCast(@alignCast(context));
        try self.when(value, continuation);
    }
};

test "phase barriers release all waiters once and reject a backwards transition" {
    const Trace = struct {
        count: usize = 0,
        fn run(context: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
        }
    };
    var lifecycle_service = LifecycleService.init(std.testing.allocator);
    defer lifecycle_service.deinit();
    const service = lifecycle_service.interface();
    var trace: Trace = .{};
    const callback = Continuation{ .context = &trace, .run = Trace.run };
    try service.when(.Starting, callback);
    try service.when(.Restored, callback);
    try service.when(.Restored, callback);
    try service.setPhase(.Ready);
    try std.testing.expectEqual(@as(usize, 1), trace.count);
    try service.setPhase(.Restored);
    try service.setPhase(.Restored);
    try service.when(.Ready, callback);
    try std.testing.expectEqual(@as(usize, 4), trace.count);
    try std.testing.expectError(error.LifecycleCannotGoBackwards, service.setPhase(.Ready));
    try std.testing.expectEqual(Phase.Restored, service.phase());
}
