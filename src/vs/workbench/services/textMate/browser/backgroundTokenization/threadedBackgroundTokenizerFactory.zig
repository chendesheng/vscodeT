// Port of
// `src/vs/workbench/services/textMate/browser/backgroundTokenization/threadedBackgroundTokenizerFactory.ts`.
//
// Upstream creates a web worker and talks to it through `postMessage`. The
// terminal creates one dedicated thread for the whole process; commands and
// results cross through `std.Io.Queue`; each worker result wakes the window.
const std = @import("std");
const Allocator = std.mem.Allocator;
const AutoHashMap = std.AutoHashMap;
const Io = std.Io;
const IBackgroundTokenizer = @import("../../../../../editor/common/languages.zig").IBackgroundTokenizer;
const IBackgroundTokenizerFactory = @import("../../../../../editor/common/languages.zig").IBackgroundTokenizerFactory;
const IBackgroundTokenizationStore = @import("../../../../../editor/common/languages.zig").IBackgroundTokenizationStore;
const TextModel = @import("../../../../../editor/common/model/textModel.zig").TextModel;
const textMateTokenizer = @import("../../../../../editor/common/model/tokens/textMateTokenizer.zig");
const protocol = @import("./worker/workerProtocol.zig");
const Controller = @import("./textMateWorkerTokenizerController.zig").Controller;
const workerMain = @import("./worker/textMateTokenizationWorker.workerMain.zig");

pub const Factory = struct {
    allocator: Allocator,
    io_state: std.Io.Threaded,
    io: Io,
    command_buffer: [1024]protocol.Command,
    result_buffer: [1024]protocol.TokensAndStates,
    command_queue: protocol.CommandQueue,
    result_queue: protocol.ResultQueue,
    context: protocol.Context,
    thread: ?std.Thread = null,
    controllers: AutoHashMap(u64, *Controller),
    next_id: u64 = 1,
    disabled: bool = false,

    pub fn init(allocator: Allocator) !*Factory {
        const self = try allocator.create(Factory);
        errdefer allocator.destroy(self);
        self.allocator = allocator;
        self.io_state = std.Io.Threaded.init(allocator, .{});
        self.io = self.io_state.io();
        self.command_buffer = undefined;
        self.result_buffer = undefined;
        self.command_queue = protocol.CommandQueue.init(&self.command_buffer);
        self.result_queue = protocol.ResultQueue.init(&self.result_buffer);
        self.context = .{
            .io = self.io,
            .commands = &self.command_queue,
            .results = &self.result_queue,
        };
        self.controllers = AutoHashMap(u64, *Controller).init(allocator);
        self.thread = null;
        self.next_id = 1;
        self.disabled = false;
        return self;
    }

    pub fn attachWindow(self: *Factory, window: *@import("../../../../../base/common/windowDispatch.zig").Queue) void {
        self.context.delivery = .{ .queue = window, .context = self, .run = onResults, .progress = true };
    }

    fn onResults(context: *anyopaque, _: i64, _: bool) bool {
        return pump(context);
    }

    pub fn interface(self: *Factory) IBackgroundTokenizerFactory {
        return .{ .context = self, .create = create };
    }

    pub fn hasPendingWork(self: *Factory) bool {
        return isPending(self);
    }

    pub fn controllerCount(self: *const Factory) usize {
        return self.controllers.count();
    }

    /// Stops the worker thread but keeps controller objects alive until their
    /// editor backends are disposed (the workbench does this before tabs).
    pub fn shutdown(self: *Factory) void {
        if (self.disabled) return;
        self.disabled = true;
        self.command_queue.close(self.io);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        self.context.delivery.schedule(null);
        self.result_queue.close(self.io);
        self.drainQueues();
    }

    fn drainQueues(self: *Factory) void {
        var commands: [32]protocol.Command = undefined;
        while (true) {
            const count = self.command_queue.getUncancelable(self.io, &commands, 0) catch break;
            if (count == 0) break;
            for (commands[0..count]) |*command| command.deinit(std.heap.page_allocator);
        }
        var results: [32]protocol.TokensAndStates = undefined;
        while (true) {
            const count = self.result_queue.getUncancelable(self.io, &results, 0) catch break;
            if (count == 0) break;
            for (results[0..count]) |*result| result.deinit(std.heap.page_allocator);
        }
    }

    pub fn deinit(self: *Factory) void {
        self.shutdown();
        var iterator = self.controllers.valueIterator();
        while (iterator.next()) |controller| controller.*.deinit();
        self.controllers.deinit();
        self.io_state.deinit();
        self.allocator.destroy(self);
    }

    fn startWorker(self: *Factory) !void {
        if (self.thread != null) return;
        self.thread = try std.Thread.spawn(.{}, workerMain.run, .{&self.context});
    }

    fn create(context: *anyopaque, model: *TextModel, store: IBackgroundTokenizationStore) ?IBackgroundTokenizer {
        const self: *Factory = @ptrCast(@alignCast(context));
        if (self.disabled or model.isTooLargeForSyncing() or model.isTooLargeForTokenization()) return null;
        if (!textMateTokenizer.hasGrammar(model.getLanguageId())) return null;
        self.startWorker() catch return null;

        const id = self.next_id;
        self.next_id += 1;
        const controller = Controller.init(self.allocator, .{
            .context = self,
            .enqueue = enqueue,
            .remove = remove,
            .pump = pump,
            .isPending = isPending,
        }, id, model, store) catch return null;

        self.controllers.put(id, controller) catch {
            controller.deinit();
            return null;
        };
        return controller.backgroundTokenizer();
    }

    fn enqueue(context: *anyopaque, command: protocol.Command) void {
        const self: *Factory = @ptrCast(@alignCast(context));
        if (self.disabled) {
            var owned = command;
            owned.deinit(std.heap.page_allocator);
            return;
        }
        self.context.enqueue(command);
    }

    fn remove(context: *anyopaque, controller_id: u64) void {
        const self: *Factory = @ptrCast(@alignCast(context));
        if (!self.disabled) {
            self.context.enqueue(.{ .accept_removed_model = controller_id });
        }
        if (self.controllers.fetchRemove(controller_id)) |entry| {
            entry.value.deinit();
        }
    }

    fn pump(context: *anyopaque) bool {
        const self: *Factory = @ptrCast(@alignCast(context));
        var buffer: [64]protocol.TokensAndStates = undefined;
        var changed = false;
        while (true) {
            const count = self.context.getResults(&buffer);
            if (count == 0) break;
            for (buffer[0..count]) |*result| {
                if (self.controllers.get(result.controller_id)) |controller| {
                    controller.applyResult(result);
                    changed = true;
                } else {
                    result.deinit(std.heap.page_allocator);
                }
            }
        }
        return changed;
    }

    fn isPending(context: *anyopaque) bool {
        const self: *Factory = @ptrCast(@alignCast(context));
        return self.context.hasPendingWork();
    }
};
