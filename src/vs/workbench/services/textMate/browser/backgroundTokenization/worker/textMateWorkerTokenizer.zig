// Port of
// `src/vs/workbench/services/textMate/browser/backgroundTokenization/worker/textMateWorkerTokenizer.ts`.
//
// Adaptation: upstream is a web worker `MirrorTextModel`; here the worker
// thread owns the mirror and the tokenization state stores, and hands batches
// of serialized tokens plus state-stack diffs back through `workerProtocol`.
//
// Adaptation: upstream sends a raw theme to the worker and rebuilds its token
// colors there. This port shares the renderer's compiled `TokenTheme` through
// the read/write lock in `tokenization.zig`; token reads are cheap and a theme
// swap cannot free the trie under an active worker.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const LineRange = @import("../../../../../../editor/common/core/ranges/lineRange.zig").LineRange;
const ModelContentChange = @import("../../../../../../editor/common/textModelEvents.zig").ModelContentChange;
const ModelContentChangedEvent = @import("../../../../../../editor/common/textModelEvents.zig").ModelContentChangedEvent;
const String = @import("../../../../../../base/common/strings.zig").String;
const strings = @import("../../../../../../base/common/strings.zig");
const MirrorTextModel = @import("../../../../../../editor/common/model/mirrorTextModel.zig").MirrorTextModel;
const TokenizerWithStateStore = @import("../../../../../../editor/common/model/textModelTokens.zig").TokenizerWithStateStore;
const ContiguousMultilineTokensBuilder = @import("../../../../../../editor/common/tokens/contiguousMultilineTokensBuilder.zig").ContiguousMultilineTokensBuilder;
const LineTokens = @import("../../../../../../editor/common/tokens/lineTokens.zig").LineTokens;
const EncodedTokenizationResult = @import("../../../../../../editor/common/languages.zig").EncodedTokenizationResult;
const IState = @import("../../../../../../editor/common/languages.zig").IState;
const ITokenizationSupport = @import("../../../../../../editor/common/languages.zig").ITokenizationSupport;
const nullTokenizeEncoded = @import("../../../../../../editor/common/languages/nullTokenize.zig").nullTokenizeEncoded;
const textMateTokenizer = @import("../../../../../../editor/common/model/tokens/textMateTokenizer.zig");
const tm_main = @import("vscode_textmate").main;
const protocol = @import("./workerProtocol.zig");
const time_compat = @import("../../../../../../base/common/timeCompat.zig");

const tokenize_debounce_ms: i64 = 10;
const tokenize_chunk_deadline_ms: i64 = 20;
const max_lines_per_chunk: usize = 200;

pub const Tokenizer = struct {
    allocator: Allocator,
    registry: *textMateTokenizer.WorkerRegistry,
    mirror: MirrorTextModel,
    language_id: []u8,
    encoded_language_id: u8,
    max_tokenization_line_length: usize,
    support: ?ITokenizationSupport = null,
    tokenizer: ?TokenizerWithStateStore = null,
    next_tokenize_at_ms: i64 = 0,
    disposed: bool = false,

    pub fn init(
        allocator: Allocator,
        registry: *textMateTokenizer.WorkerRegistry,
        data: protocol.RawModelData,
    ) !*Tokenizer {
        var line_list = try strings.splitLines(allocator, data.text);
        defer line_list.deinit();

        const self = try allocator.create(Tokenizer);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .registry = registry,
            .mirror = try MirrorTextModel.init(allocator, "", line_list.items, data.eol, data.version_id),
            .language_id = try allocator.dupe(u8, data.language_id),
            .encoded_language_id = data.encoded_language_id,
            .max_tokenization_line_length = data.max_tokenization_line_length,
        };
        errdefer {
            self.mirror.deinit();
            allocator.free(self.language_id);
        }
        errdefer if (self.support) |support| support.dispose();
        errdefer if (self.tokenizer) |*tokenizer| tokenizer.deinit();
        try self.resetTokenization();
        self.next_tokenize_at_ms = 0;
        return self;
    }

    pub fn deinit(self: *Tokenizer) void {
        self.disposed = true;
        if (self.tokenizer) |*tokenizer| tokenizer.deinit();
        self.tokenizer = null;
        if (self.support) |support| support.dispose();
        self.support = null;
        self.mirror.deinit();
        self.allocator.free(self.language_id);
        self.allocator.destroy(self);
    }

    pub fn acceptChange(self: *Tokenizer, event: *const protocol.ModelChanged) void {
        var changes = ArrayList(ModelContentChange).init(self.allocator);
        defer {
            for (changes.items) |*change| change.text.deinit();
            changes.deinit();
        }
        for (event.changes) |change| {
            changes.append(.{
                .range = change.range,
                .rangeOffset = 0,
                .rangeLength = 0,
                .text = String.initBorrowed(change.text),
            }) catch return;
        }
        var model_event = ModelContentChangedEvent{
            .changes = changes,
            .eol = event.eol,
            .versionId = event.version_id,
            .isUndoing = false,
            .isRedoing = false,
            .isFlush = false,
            .isEolChange = false,
        };
        self.mirror.onEvents(&model_event) catch return;
        if (self.tokenizer) |*tokenizer| {
            tokenizer.store.acceptChanges(changes.items) catch {};
        }
        self.scheduleTokenization();
    }

    pub fn retokenize(self: *Tokenizer, start_line_number: usize, end_line_number_exclusive: usize) void {
        if (self.tokenizer) |*tokenizer| {
            tokenizer.store.invalidateEndStateRange(LineRange.init(start_line_number, end_line_number_exclusive)) catch {};
        }
        self.scheduleTokenization();
    }

    pub fn acceptMaxTokenizationLineLength(self: *Tokenizer, value: usize) void {
        self.max_tokenization_line_length = value;
        self.scheduleTokenization();
    }

    pub fn onLanguageId(self: *Tokenizer, language_id: []const u8, encoded_language_id: u8) void {
        const copy = self.allocator.dupe(u8, language_id) catch return;
        self.allocator.free(self.language_id);
        self.language_id = copy;
        self.encoded_language_id = encoded_language_id;
        self.resetTokenization() catch return;
        self.next_tokenize_at_ms = 0;
    }

    pub fn versionId(self: *const Tokenizer) i64 {
        return self.mirror.version();
    }

    pub fn isFinished(self: *Tokenizer) bool {
        const tokenizer = &(self.tokenizer orelse return true);
        return tokenizer.store.allStatesValid();
    }

    pub fn hasPendingWork(self: *Tokenizer) bool {
        return !self.disposed and !self.isFinished();
    }

    pub fn nextDeadline(self: *const Tokenizer) i64 {
        return self.next_tokenize_at_ms;
    }

    fn scheduleTokenization(self: *Tokenizer) void {
        self.next_tokenize_at_ms = time_compat.milliTimestamp() + tokenize_debounce_ms;
    }

    fn resetTokenization(self: *Tokenizer) !void {
        if (self.tokenizer) |*tokenizer| tokenizer.deinit();
        self.tokenizer = null;
        if (self.support) |support| support.dispose();
        self.support = null;

        const grammar = (try self.registry.loadGrammarForLanguage(self.language_id, @as(u32, self.encoded_language_id))) orelse return;
        const support = try textMateTokenizer.createFromGrammar(self.allocator, self.language_id, grammar);
        self.support = support;
        self.tokenizer = try TokenizerWithStateStore.init(self.allocator, self.mirror.getLineCount(), support);
    }

    /// Tokenizes one batch. Returns null when there is nothing invalid left.
    pub fn tokenizeBatch(self: *Tokenizer) ?protocol.TokensAndStates {
        const tokenizer = &(self.tokenizer orelse return null);
        if (self.disposed) return null;

        var builder = ContiguousMultilineTokensBuilder.init(self.allocator);
        errdefer builder.deinit();
        var delta_builder = StateDeltaBuilder.init(self.allocator);
        errdefer delta_builder.deinit();

        const start_ms = time_compat.milliTimestamp();
        var tokenized_lines: usize = 0;
        while (tokenized_lines < max_lines_per_chunk) {
            if (time_compat.milliTimestamp() - start_ms > tokenize_chunk_deadline_ms) break;

            const line_to_tokenize = tokenizer.getFirstInvalidLine() catch break orelse break;
            tokenized_lines += 1;

            const line = self.mirror.getLineContent(line_to_tokenize.first);
            const result = self.tokenizeLine(line, line_to_tokenize.second) orelse break;
            const changed = tokenizer.store.setEndState(line_to_tokenize.first, result.endState) catch false;
            if (changed) {
                const start_stack = textMateTokenizer.stackOfState(line_to_tokenize.second) orelse tm_main.INITIAL;
                const end_stack = textMateTokenizer.stackOfState(result.endState) orelse tm_main.INITIAL;
                const delta = tm_main.diffStateStacksRefEq(self.allocator, start_stack, end_stack) catch null;
                if (delta) |stack_diff| {
                    const owned = self.allocator.create(tm_main.StackDiff) catch {
                        var diff = stack_diff;
                        diff.deinit(self.allocator);
                        break;
                    };
                    owned.* = stack_diff;
                    delta_builder.setState(line_to_tokenize.first, owned);
                } else {
                    delta_builder.setState(line_to_tokenize.first, null);
                }
            } else {
                delta_builder.setState(line_to_tokenize.first, null);
            }

            LineTokens.convertToEndOffset(result.tokens, line.len);
            builder.add(line_to_tokenize.first, result.tokens) catch break;
        }

        if (tokenized_lines == 0) {
            builder.deinit();
            delta_builder.deinit();
            return null;
        }

        var serialized = builder.serialize() catch {
            builder.deinit();
            delta_builder.deinit();
            return null;
        };
        builder.deinit();
        const token_bytes = serialized.toOwnedSlice() catch {
            serialized.deinit();
            delta_builder.deinit();
            return null;
        };
        const state_deltas = delta_builder.finalize();
        delta_builder.deinit();
        return .{
            .controller_id = 0,
            .version_id = self.mirror.version(),
            .token_bytes = token_bytes,
            .state_deltas = state_deltas,
        };
    }

    fn tokenizeLine(self: *Tokenizer, line: []const u8, state: IState) ?EncodedTokenizationResult {
        const support = self.support orelse return null;
        if (self.max_tokenization_line_length != 0 and self.max_tokenization_line_length != std.math.maxInt(usize) and line.len >= self.max_tokenization_line_length) {
            return nullTokenizeEncoded(self.allocator, @fromBackingInt(@intCast(self.encoded_language_id)), state) catch null;
        }
        const tokenizer = if (self.tokenizer) |*value| value else return null;
        if (support.tokenizeEncoded(tokenizer.stateAllocator(), line, true, state)) |result| {
            return result;
        } else |_| {}
        return nullTokenizeEncoded(self.allocator, @fromBackingInt(@intCast(self.encoded_language_id)), state) catch null;
    }
};

const StateDeltaBuilder = struct {
    allocator: Allocator,
    groups: ArrayList(Group),
    last_start_line_number: usize = 0,
    has_last: bool = false,

    const Group = struct {
        start_line_number: usize,
        deltas: ArrayList(?*tm_main.StackDiff),
    };

    fn init(allocator: Allocator) StateDeltaBuilder {
        return .{ .allocator = allocator, .groups = ArrayList(Group).init(allocator) };
    }

    fn deinit(self: *StateDeltaBuilder) void {
        for (self.groups.items) |*group| {
            for (group.deltas.items) |maybe_delta| {
                if (maybe_delta) |delta| {
                    delta.deinit(self.allocator);
                    self.allocator.destroy(delta);
                }
            }
            group.deltas.deinit();
        }
        self.groups.deinit();
    }

    fn setState(self: *StateDeltaBuilder, line_number: usize, delta: ?*tm_main.StackDiff) void {
        if (self.has_last and line_number == self.last_start_line_number + self.groups.items[self.groups.items.len - 1].deltas.items.len) {
            self.groups.items[self.groups.items.len - 1].deltas.append(delta) catch {};
        } else {
            var group = Group{
                .start_line_number = line_number,
                .deltas = ArrayList(?*tm_main.StackDiff).init(self.allocator),
            };
            group.deltas.append(delta) catch return;
            self.groups.append(group) catch {
                group.deltas.deinit();
                return;
            };
        }
        self.has_last = true;
        self.last_start_line_number = self.groups.items[self.groups.items.len - 1].start_line_number;
    }

    fn finalize(self: *StateDeltaBuilder) []protocol.StateDeltas {
        const result = self.allocator.alloc(protocol.StateDeltas, self.groups.items.len) catch return &.{};
        for (self.groups.items, 0..) |*group, i| {
            result[i] = .{
                .start_line_number = group.start_line_number,
                .state_deltas = group.deltas.toOwnedSlice() catch &.{},
            };
        }
        self.groups.clearRetainingCapacity();
        return result;
    }
};
