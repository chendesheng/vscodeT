// Port of
// `src/vs/workbench/services/textMate/browser/backgroundTokenization/worker/textMateWorkerHost.ts`.
//
// Upstream's host is the renderer-side channel used by the web worker for
// grammar reads, token delivery and telemetry. The terminal adaptation uses
// the same channel for the controller callbacks: queue a command, remove a
// controller, drain results and report pending work.
const protocol = @import("./workerProtocol.zig");

pub const Host = struct {
    context: *anyopaque,
    enqueue: *const fn (context: *anyopaque, command: protocol.Command) void,
    remove: *const fn (context: *anyopaque, controller_id: u64) void,
    pump: *const fn (context: *anyopaque) bool,
    isPending: *const fn (context: *anyopaque) bool,
};
