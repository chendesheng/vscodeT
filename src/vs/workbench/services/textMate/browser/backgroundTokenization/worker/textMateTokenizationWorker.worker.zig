// Port of
// `src/vs/workbench/services/textMate/browser/backgroundTokenization/worker/textMateTokenizationWorker.worker.ts`.
//
// The worker owns one mirror/tokenizer per controller id and streams
// serialized token updates plus state-stack diffs back to the renderer.
//
// Adaptation: upstream receives `grammarDefinitions` and the oniguruma WASM
// blob through `$init`; the terminal worker builds the same per-worker
// registry from the bundled `vscode_syntax` data in `textMateTokenizer`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const AutoHashMap = std.AutoHashMap;
const textMateTokenizer = @import("../../../../../../editor/common/model/tokens/textMateTokenizer.zig");
const protocol = @import("./workerProtocol.zig");
const Tokenizer = @import("./textMateWorkerTokenizer.zig").Tokenizer;
const time_compat = @import("../../../../../../base/common/timeCompat.zig");

pub const Worker = struct {
    allocator: Allocator,
    context: *protocol.Context,
    registry: ?textMateTokenizer.WorkerRegistry = null,
    tokenizers: AutoHashMap(u64, *Tokenizer),

    pub fn init(allocator: Allocator, context: *protocol.Context) !*Worker {
        const self = try allocator.create(Worker);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .context = context,
            .tokenizers = AutoHashMap(u64, *Tokenizer).init(allocator),
        };
        self.registry = textMateTokenizer.WorkerRegistry.init(allocator) catch null;
        return self;
    }

    pub fn deinit(self: *Worker) void {
        var iterator = self.tokenizers.valueIterator();
        while (iterator.next()) |tokenizer| tokenizer.*.deinit();
        self.tokenizers.deinit();
        if (self.registry) |*registry| registry.deinit();
        self.allocator.destroy(self);
    }

    pub fn run(self: *Worker) void {
        while (true) {
            var closed = false;
            while (self.context.popCommand(&closed)) |command| {
                self.context.working.store(true, .seq_cst);
                var owned = command;
                defer owned.deinit(self.allocator);
                self.handleCommand(&owned);
            }
            if (closed) return;

            const now = time_compat.milliTimestamp(self.context.io);
            var next_deadline: ?i64 = null;
            var ids = self.tokenizers.keyIterator();
            while (ids.next()) |id| {
                const tokenizer = self.tokenizers.get(id.*) orelse continue;
                if (!tokenizer.hasPendingWork()) continue;

                if (now >= tokenizer.nextDeadline()) {
                    if (tokenizer.tokenizeBatch()) |result| {
                        var owned = result;
                        owned.controller_id = id.*;
                        self.context.pushResult(owned);
                    }
                }
                if (tokenizer.hasPendingWork()) {
                    const deadline = @max(tokenizer.nextDeadline(), now);
                    next_deadline = if (next_deadline) |current| @min(current, deadline) else deadline;
                }
            }

            if (next_deadline == null) {
                self.context.working.store(false, .seq_cst);
                if (self.context.waitForCommand()) |command| {
                    var owned = command;
                    defer owned.deinit(self.allocator);
                    self.handleCommand(&owned);
                    self.context.working.store(true, .seq_cst);
                    continue;
                }
                return;
            }

            self.context.working.store(true, .seq_cst);
            const remaining = next_deadline.? - time_compat.milliTimestamp(self.context.io);
            const wait_ms = @max(@min(remaining, 20), 0);
            if (wait_ms > 0) {
                std.Io.sleep(self.context.io, .fromMilliseconds(wait_ms), .awake) catch {};
            }
        }
    }

    fn handleCommand(self: *Worker, command: *protocol.Command) void {
        switch (command.*) {
            .accept_new_model => |data| self.acceptNewModel(data),
            .accept_model_changed => |*event| {
                if (self.tokenizers.get(event.controller_id)) |tokenizer| tokenizer.acceptChange(event);
            },
            .retokenize => |event| {
                if (self.tokenizers.get(event.controller_id)) |tokenizer| {
                    tokenizer.retokenize(event.start_line_number, event.end_line_number_exclusive);
                }
            },
            .accept_language_changed => |*event| {
                if (self.tokenizers.get(event.controller_id)) |tokenizer| {
                    tokenizer.onLanguageId(event.language_id, event.encoded_language_id);
                }
            },
            .accept_removed_model => |controller_id| self.removeModel(controller_id),
            .accept_max_tokenization_line_length => |event| {
                if (self.tokenizers.get(event.controller_id)) |tokenizer| {
                    tokenizer.acceptMaxTokenizationLineLength(event.value);
                }
            },
        }
    }

    fn acceptNewModel(self: *Worker, data: protocol.RawModelData) void {
        const registry = if (self.registry) |*value| value else return;
        self.removeModel(data.controller_id);

        const tokenizer = Tokenizer.init(self.allocator, registry, self.context.io, data) catch return;
        self.tokenizers.put(data.controller_id, tokenizer) catch {
            tokenizer.deinit();
            return;
        };
    }

    fn removeModel(self: *Worker, controller_id: u64) void {
        if (self.tokenizers.fetchRemove(controller_id)) |entry| {
            entry.value.deinit();
        }
    }
};
