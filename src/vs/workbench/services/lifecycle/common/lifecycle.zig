// Port of the startup phases and terminal shutdown events from
// `src/vs/workbench/services/lifecycle/common/lifecycle.ts`.
// The terminal's event loop runs phase continuations and joins synchronous
// shutdown listeners before releasing services and the terminal.
const Emitter = @import("../../../../base/common/event.zig").Emitter;

pub const LifecyclePhase = enum(u8) {
    Starting = 1,
    Ready = 2,
    Restored = 3,
    Eventually = 4,

    pub fn reached(self: LifecyclePhase, phase: LifecyclePhase) bool {
        return @backingInt(self) >= @backingInt(phase);
    }
};

pub const ShutdownReason = enum(u8) { close = 1, quit, reload, load };
pub const WillShutdownEvent = struct { reason: ShutdownReason };
pub const Continuation = struct {
    context: *anyopaque,
    run: *const fn (*anyopaque) anyerror!void,
};

pub const ILifecycleService = struct {
    context: *anyopaque,
    phase_fn: *const fn (*anyopaque) LifecyclePhase,
    set_phase: *const fn (*anyopaque, LifecyclePhase) anyerror!void,
    when_fn: *const fn (*anyopaque, LifecyclePhase, Continuation) anyerror!void,
    on_will_shutdown: *Emitter(WillShutdownEvent),
    on_did_shutdown: *Emitter(void),

    pub fn phase(self: ILifecycleService) LifecyclePhase {
        return self.phase_fn(self.context);
    }
    pub fn setPhase(self: ILifecycleService, value: LifecyclePhase) !void {
        try self.set_phase(self.context, value);
    }
    pub fn when(self: ILifecycleService, phase_value: LifecyclePhase, continuation: Continuation) !void {
        try self.when_fn(self.context, phase_value, continuation);
    }
};
