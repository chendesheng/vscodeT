// Cross-thread protocol for the terminal adaptation of
// `textMateTokenizationWorker.worker.ts` and `textMateWorkerHost.ts`.
//
// Upstream sends these values through the browser `postMessage` boundary.
// Here one dedicated thread owns the worker side and the renderer thread
// drains results through two `std.Io.Queue` channels; all transferred buffers
// use the page allocator so either side can release them.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const Range = @import("../../../../../../editor/common/core/range.zig").Range;
const EOL = @import("../../../../../../editor/common/core/misc/eolCounter.zig").EOL;
const tm_main = @import("vscode_textmate").main;

pub const Change = struct {
    range: Range,
    text: []u8,

    pub fn deinit(self: *Change, allocator: Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub const ModelChanged = struct {
    controller_id: u64,
    version_id: i64,
    eol: EOL,
    changes: []Change,

    pub fn deinit(self: *ModelChanged, allocator: Allocator) void {
        for (self.changes) |*change| change.deinit(allocator);
        allocator.free(self.changes);
        self.* = undefined;
    }
};

pub const RawModelData = struct {
    controller_id: u64,
    version_id: i64,
    text: []u8,
    eol: EOL,
    language_id: []u8,
    encoded_language_id: u8,
    max_tokenization_line_length: usize,

    pub fn deinit(self: *RawModelData, allocator: Allocator) void {
        allocator.free(self.text);
        allocator.free(self.language_id);
        self.* = undefined;
    }
};

pub const StateDeltas = struct {
    start_line_number: usize,
    // Null means the state for that line did not change.
    state_deltas: []?*tm_main.StackDiff,

    pub fn deinit(self: *StateDeltas, allocator: Allocator) void {
        for (self.state_deltas) |maybe_delta| {
            if (maybe_delta) |delta| {
                delta.deinit(allocator);
                allocator.destroy(delta);
            }
        }
        allocator.free(self.state_deltas);
        self.* = undefined;
    }
};

pub const TokensAndStates = struct {
    controller_id: u64,
    version_id: i64,
    token_bytes: []u8,
    state_deltas: []StateDeltas,

    pub fn deinit(self: *TokensAndStates, allocator: Allocator) void {
        allocator.free(self.token_bytes);
        for (self.state_deltas) |*deltas| deltas.deinit(allocator);
        allocator.free(self.state_deltas);
        self.* = undefined;
    }
};

pub const Command = union(enum) {
    accept_new_model: RawModelData,
    accept_model_changed: ModelChanged,
    retokenize: struct {
        controller_id: u64,
        start_line_number: usize,
        end_line_number_exclusive: usize,
    },
    accept_language_changed: struct {
        controller_id: u64,
        language_id: []u8,
        encoded_language_id: u8,
    },
    accept_removed_model: u64,
    accept_max_tokenization_line_length: struct {
        controller_id: u64,
        value: usize,
    },
    pub fn deinit(self: *Command, allocator: Allocator) void {
        switch (self.*) {
            .accept_new_model => |*data| data.deinit(allocator),
            .accept_model_changed => |*event| event.deinit(allocator),
            .accept_language_changed => |*event| allocator.free(event.language_id),
            else => {},
        }
        self.* = undefined;
    }
};

/// Renderer/worker postMessage channels. `std.Io.Queue` supplies the
/// cross-thread hand-off; the atomics only let the renderer decide whether it
/// needs to keep polling while the worker is still tokenizing.
pub const Context = struct {
    io: Io,
    commands: *CommandQueue,
    results: *ResultQueue,
    delivery: @import("../../../../../../base/common/windowDispatch.zig").Task = .{},
    command_count: std.atomic.Value(usize) = .init(0),
    working: std.atomic.Value(bool) = .init(false),
    results_pending: std.atomic.Value(usize) = .init(0),

    pub fn enqueue(self: *Context, command: Command) void {
        _ = self.command_count.fetchAdd(1, .seq_cst);
        self.commands.putOneUncancelable(self.io, command) catch {
            _ = self.command_count.fetchSub(1, .seq_cst);
            var owned = command;
            owned.deinit(std.heap.page_allocator);
        };
    }

    /// Non-blocking worker-side command poll. Returns null when the queue is
    /// empty; `closed` is set when the renderer closed the channel.
    pub fn popCommand(self: *Context, closed: *bool) ?Command {
        var buffer: [1]Command = undefined;
        const count = self.commands.getUncancelable(self.io, &buffer, 0) catch {
            closed.* = true;
            return null;
        };
        if (count == 0) return null;
        self.working.store(true, .seq_cst);
        _ = self.command_count.fetchSub(1, .seq_cst);
        return buffer[0];
    }

    pub fn waitForCommand(self: *Context) ?Command {
        const command = self.commands.getOneUncancelable(self.io) catch return null;
        self.working.store(true, .seq_cst);
        _ = self.command_count.fetchSub(1, .seq_cst);
        return command;
    }

    pub fn pushResult(self: *Context, result: TokensAndStates) void {
        _ = self.results_pending.fetchAdd(1, .seq_cst);
        const count = self.results.putUncancelable(self.io, &.{result}, 0) catch 0;
        if (count == 0) {
            _ = self.results_pending.fetchSub(1, .seq_cst);
            var owned = result;
            owned.deinit(std.heap.page_allocator);
        } else self.delivery.post();
    }

    pub fn getResults(self: *Context, buffer: []TokensAndStates) usize {
        const count = self.results.getUncancelable(self.io, buffer, 0) catch 0;
        if (count > 0) _ = self.results_pending.fetchSub(count, .seq_cst);
        return count;
    }

    pub fn hasPendingWork(self: *Context) bool {
        return self.command_count.load(.acquire) > 0 or
            self.results_pending.load(.acquire) > 0 or
            self.working.load(.acquire);
    }
};

pub const CommandQueue = std.Io.Queue(Command);
pub const ResultQueue = std.Io.Queue(TokensAndStates);
