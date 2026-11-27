// Port of
// `src/vs/workbench/services/textMate/browser/backgroundTokenization/textMateWorkerTokenizerController.ts`.
//
// The controller keeps the renderer-side state store and pending model
// changes, transforms worker results through those changes
// (`MonotonousIndexTransformer`) and applies states before tokens, exactly
// like upstream. Worker messages are drained from the terminal main loop.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const ContiguousMultilineTokensBuilder = @import("../../../../../editor/common/tokens/contiguousMultilineTokensBuilder.zig").ContiguousMultilineTokensBuilder;
const IBackgroundTokenizer = @import("../../../../../editor/common/languages.zig").IBackgroundTokenizer;
const IBackgroundTokenizationStore = @import("../../../../../editor/common/languages.zig").IBackgroundTokenizationStore;
const IState = @import("../../../../../editor/common/languages.zig").IState;
const ModelContentChange = @import("../../../../../editor/common/textModelEvents.zig").ModelContentChange;
const ModelContentChangedEvent = @import("../../../../../editor/common/textModelEvents.zig").ModelContentChangedEvent;
const TextModel = @import("../../../../../editor/common/model/textModel.zig").TextModel;
const TokenizationStateStore = @import("../../../../../editor/common/model/textModelTokens.zig").TokenizationStateStore;
const linesLengthEditFromModelContentChange = @import("../../../../../editor/common/model/textModelStringEdit.zig").linesLengthEditFromModelContentChange;
const String = @import("../../../../../base/common/strings.zig").String;
const LengthEdit = @import("../../../../../editor/common/core/edits/lengthEdit.zig").LengthEdit;
const textMateTokenizer = @import("../../../../../editor/common/model/tokens/textMateTokenizer.zig");
const tm_main = @import("vscode_textmate").main;
const protocol = @import("./worker/workerProtocol.zig");
const index_transformer = @import("../indexTransformer.zig");
const Host = @import("./worker/textMateWorkerHost.zig").Host;

const PendingChange = struct {
    version_id: i64,
    changes: []ModelContentChange,

    fn init(allocator: Allocator, event: *const ModelContentChangedEvent) !PendingChange {
        const changes = try allocator.alloc(ModelContentChange, event.changes.items.len);
        errdefer allocator.free(changes);
        var built: usize = 0;
        errdefer {
            for (changes[0..built]) |*change| change.text.deinit();
        }
        for (event.changes.items, 0..) |change, i| {
            const text = try allocator.dupe(u8, change.text.items());
            changes[i] = .{
                .range = change.range,
                .rangeOffset = change.rangeOffset,
                .rangeLength = change.rangeLength,
                .text = String.initOwned(ArrayList(u8).fromOwnedSlice(allocator, text)),
            };
            built += 1;
        }
        return .{ .version_id = event.versionId, .changes = changes };
    }

    fn deinit(self: *PendingChange, allocator: Allocator) void {
        for (self.changes) |*change| change.text.deinit();
        allocator.free(self.changes);
        self.* = undefined;
    }
};

pub const Controller = struct {
    allocator: Allocator,
    host: Host,
    id: u64,
    model: *TextModel,
    store: IBackgroundTokenizationStore,
    states: TokenizationStateStore,
    pending_changes: ArrayList(PendingChange),
    state_arena: std.heap.ArenaAllocator,
    initial_state: IState,
    disposed: bool = false,

    pub fn init(
        allocator: Allocator,
        host: Host,
        id: u64,
        model: *TextModel,
        store: IBackgroundTokenizationStore,
    ) !*Controller {
        const self = try allocator.create(Controller);
        errdefer allocator.destroy(self);
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const initial = try textMateTokenizer.stateFromStack(arena.allocator(), null, true);
        self.* = .{
            .allocator = allocator,
            .host = host,
            .id = id,
            .model = model,
            .store = store,
            .states = TokenizationStateStore.init(allocator),
            .pending_changes = ArrayList(PendingChange).init(allocator),
            .state_arena = arena,
            .initial_state = initial,
        };
        errdefer self.states.deinit();
        errdefer self.pending_changes.deinit();

        var text = try model.getValue(.TextDefined, false);
        defer text.deinit();
        const owned_text = try allocator.dupe(u8, text.items);
        errdefer allocator.free(owned_text);
        const language_id = try allocator.dupe(u8, model.getLanguageId());
        errdefer allocator.free(language_id);

        host.enqueue(host.context, .{ .accept_new_model = .{
            .controller_id = id,
            .version_id = @intCast(model.getVersionId()),
            .text = owned_text,
            .eol = model.getEOL(),
            .language_id = language_id,
            .encoded_language_id = @intCast(try model.tokenization().tokens.super._languageIdCodec.encodeLanguageId(language_id)),
            .max_tokenization_line_length = model.max_tokenization_line_length,
        } });
        return self;
    }

    pub fn deinit(self: *Controller) void {
        self.disposed = true;
        for (self.pending_changes.items) |*change| change.deinit(self.allocator);
        self.pending_changes.deinit();
        self.states.deinit();
        self.state_arena.deinit();
        self.allocator.destroy(self);
    }

    pub fn backgroundTokenizer(self: *Controller) IBackgroundTokenizer {
        return .{ .context = self, .vtable = &vtable };
    }

    /// Applies one worker result. Takes ownership of `result` (including its
    /// serialized tokens and state diffs).
    pub fn applyResult(self: *Controller, result: *protocol.TokensAndStates) void {
        defer result.deinit(self.allocator);
        if (self.disposed or result.controller_id != self.id) return;

        // Apply changes the worker has already incorporated to the local
        // states first, so future states are expressed in the newest
        // coordinate space.
        while (self.pending_changes.items.len > 0 and self.pending_changes.items[0].version_id <= result.version_id) {
            var change = self.pending_changes.orderedRemove(0);
            defer change.deinit(self.allocator);
            self.states.acceptChanges(change.changes) catch {};
        }

        var reader = Io.Reader.fixed(result.token_bytes);
        var token_blocks = ContiguousMultilineTokensBuilder.deserialize(self.allocator, &reader) catch return;
        defer {
            for (token_blocks.items) |*block| block.deinit();
            token_blocks.deinit();
        }

        var filtered = ContiguousMultilineTokensBuilder.init(self.allocator);
        var use_filtered = false;
        var token_transformers = std.array_list.Managed(index_transformer.MonotonousIndexTransformer).init(self.allocator);
        var token_edits = std.array_list.Managed(LengthEdit).init(self.allocator);
        defer {
            for (token_edits.items) |*edit| edit.deinit();
            token_edits.deinit();
            token_transformers.deinit();
            filtered.deinit();
        }

        if (self.pending_changes.items.len > 0) {
            use_filtered = true;
            for (self.pending_changes.items) |*pending| {
                token_edits.append(linesLengthEditFromModelContentChange(self.allocator, pending.changes) catch continue) catch continue;
            }
            var edit_ptrs = ArrayList(*const LengthEdit).init(self.allocator);
            defer edit_ptrs.deinit();
            for (token_edits.items) |*edit| edit_ptrs.append(edit) catch {};
            const transformers = index_transformer.fromMany(self.allocator, edit_ptrs.items) catch &.{};
            defer if (transformers.len > 0) self.allocator.free(transformers);
            for (transformers) |transformer| token_transformers.append(transformer) catch {};

            for (token_blocks.items) |*block| {
                var line = block.getStartLineNumber();
                const end_line = block.getEndLineNumber();
                while (line <= end_line) : (line += 1) {
                    var current = line - 1;
                    var touched = false;
                    for (token_transformers.items) |*transformer| {
                        current = transformer.transform(current) orelse {
                            touched = true;
                            break;
                        };
                    }
                    if (touched) continue;
                    if (block.getLineTokens(line)) |tokens| {
                        filtered.add(line, tokens) catch {};
                    }
                }
            }

            // Apply future changes to the surviving token lines.
            const filtered_blocks = filtered.finalize();
            for (self.pending_changes.items) |*pending| {
                for (pending.changes) |*change| {
                    for (filtered_blocks) |*block| {
                        block.applyEdit(change.range, change.text.items()) catch {};
                    }
                }
            }
        }

        const final_tokens = if (use_filtered) filtered.finalize() else token_blocks.items;

        // Apply state deltas before setting tokens, so consumers reading a
        // token event never observe an invalid state.
        var state_transformers = std.array_list.Managed(index_transformer.MonotonousIndexTransformer).init(self.allocator);
        var state_edits = std.array_list.Managed(LengthEdit).init(self.allocator);
        defer {
            for (state_edits.items) |*edit| edit.deinit();
            state_edits.deinit();
            state_transformers.deinit();
        }
        if (self.pending_changes.items.len > 0) {
            for (self.pending_changes.items) |*pending| {
                state_edits.append(linesLengthEditFromModelContentChange(self.allocator, pending.changes) catch continue) catch continue;
            }
            var state_edit_ptrs = ArrayList(*const LengthEdit).init(self.allocator);
            defer state_edit_ptrs.deinit();
            for (state_edits.items) |*edit| state_edit_ptrs.append(edit) catch {};
            const transformers = index_transformer.fromMany(self.allocator, state_edit_ptrs.items) catch &.{};
            defer if (transformers.len > 0) self.allocator.free(transformers);
            for (transformers) |transformer| state_transformers.append(transformer) catch {};
        }

        for (result.state_deltas) |*deltas| {
            const start_line = deltas.start_line_number;
            var prev_state = if (start_line <= 1) self.initial_state else (self.states.getEndState(start_line - 1) orelse self.initial_state);
            for (deltas.state_deltas, 0..) |maybe_delta, i| {
                var state = prev_state;
                if (maybe_delta) |delta| {
                    const prev_stack = textMateTokenizer.stackOfState(prev_state) orelse tm_main.INITIAL;
                    if (tm_main.applyStateStackDiff(self.state_arena.allocator(), prev_stack, delta.*) catch null) |new_stack| {
                        state = textMateTokenizer.stateFromStack(self.state_arena.allocator(), new_stack, false) catch prev_state;
                    }
                    _ = self.states.setEndState(start_line + i, state) catch {};
                } else {
                    state = self.states.getEndState(start_line + i) orelse prev_state;
                }

                var current = start_line + i - 1;
                var touched = false;
                for (state_transformers.items) |*transformer| {
                    current = transformer.transform(current) orelse {
                        touched = true;
                        break;
                    };
                }
                if (!touched) self.store.setEndState(self.store.context, current + 1, state);

                if (start_line + i >= self.model.getLineCount() - 1) {
                    self.store.backgroundTokenizationFinished(self.store.context);
                }
                prev_state = state;
            }
        }

        self.store.setTokens(self.store.context, final_tokens);
    }

    fn dispose(ctx: *anyopaque) void {
        const self: *Controller = @ptrCast(@alignCast(ctx));
        if (self.disposed) return;
        self.host.remove(self.host.context, self.id);
    }

    fn requestTokens(ctx: *anyopaque, start_line_number: usize, end_line_number_exclusive: usize) void {
        const self: *Controller = @ptrCast(@alignCast(ctx));
        if (self.disposed) return;
        self.host.enqueue(self.host.context, .{ .retokenize = .{
            .controller_id = self.id,
            .start_line_number = start_line_number,
            .end_line_number_exclusive = end_line_number_exclusive,
        } });
    }

    fn poll(ctx: *anyopaque) bool {
        const self: *Controller = @ptrCast(@alignCast(ctx));
        return self.host.pump(self.host.context);
    }

    fn isPending(ctx: *anyopaque) bool {
        const self: *Controller = @ptrCast(@alignCast(ctx));
        return self.host.isPending(self.host.context);
    }

    fn onDidChangeContent(ctx: *anyopaque, event: *const ModelContentChangedEvent) void {
        const self: *Controller = @ptrCast(@alignCast(ctx));
        if (self.disposed) return;
        const pending = PendingChange.init(self.allocator, event) catch return;
        self.pending_changes.append(pending) catch {
            var owned = pending;
            owned.deinit(self.allocator);
            return;
        };

        const changes = self.allocator.alloc(protocol.Change, event.changes.items.len) catch return;
        var built: usize = 0;
        for (event.changes.items, 0..) |change, i| {
            const text = self.allocator.dupe(u8, change.text.items()) catch break;
            changes[i] = .{ .range = change.range, .text = text };
            built += 1;
        }
        if (built != event.changes.items.len) {
            for (changes[0..built]) |*change| change.deinit(self.allocator);
            self.allocator.free(changes);
            return;
        }
        self.host.enqueue(self.host.context, .{ .accept_model_changed = .{
            .controller_id = self.id,
            .version_id = event.versionId,
            .eol = event.eol,
            .changes = changes,
        } });
    }

    const vtable = IBackgroundTokenizer.VTable{
        .requestTokens = requestTokens,
        .dispose = dispose,
        .poll = poll,
        .isPending = isPending,
        .onDidChangeContent = onDidChangeContent,
    };
};
