// Port of
// `src/vs/workbench/services/textMate/browser/backgroundTokenization/worker/textMateTokenizationWorker.workerMain.ts`.
// The web-worker bootstrap is a dedicated Zig thread entry point here.
const protocol = @import("./workerProtocol.zig");
const Worker = @import("./textMateTokenizationWorker.worker.zig").Worker;

pub fn run(context: *protocol.Context) void {
    const worker = Worker.init(context.allocator, context) catch {
        context.working.store(false, .seq_cst);
        return;
    };
    defer worker.deinit();
    worker.run();
}
