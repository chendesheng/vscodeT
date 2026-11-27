// Port of `src/vs/editor/contrib/inlayHints/browser/inlayHints.ts`.
// Fragments own their provider results and chained-cache lifetimes. Native
// cancellable callbacks replace Promise.all; items retain tracked anchors.
const std = @import("std");
const languages = @import("../../../common/languages.zig");
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const Position = @import("../../../common/core/position.zig").Position;
const Range = @import("../../../common/core/range.zig").Range;
const Registry = @import("../../../common/languageFeatureRegistry.zig").LanguageFeatureRegistry(languages.InlayHintsProvider);
const IDisposable = @import("../../../../base/common/lifecycle.zig").IDisposable;

pub const InlayHintAnchor = struct { range: Range, direction: enum { before, after } };
pub const InlayHintItem = struct {
    hint: languages.InlayHint,
    anchor: InlayHintAnchor,
    provider: languages.InlayHintsProvider,
    resolved: bool = false,
};
pub const RenderedInlayHintLabelPart = struct { item: *InlayHintItem, index: usize };

pub fn anchorAtPosition(model: *TextModel, position_: Position) InlayHintAnchor {
    const position = model.validatePosition(position_);
    var word_range = Range.init(position.lineNumber, position.column, position.lineNumber, position.column);
    if (model.getWordAtPosition(position)) |value| {
        var word = value;
        defer word.deinit();
        word_range = Range.init(position.lineNumber, word.startColumn, position.lineNumber, word.endColumn);
    } else {
        var tokens = model.tokenization().getLineTokens(position.lineNumber) catch return .{ .range = word_range, .direction = .before };
        defer tokens.deinit();
        if (tokens.getCount() > 0) {
            const offset = position.column - 1;
            const idx = tokens.findTokenIndexAtOffset(offset);
            var start = tokens.getStartOffset(idx);
            var end = tokens.getEndOffset(idx);
            if (end -| start == 1) {
                if (start == offset and idx > 1) {
                    start = tokens.getStartOffset(idx - 1);
                    end = tokens.getEndOffset(idx - 1);
                } else if (end == offset and idx + 1 < tokens.getCount()) {
                    start = tokens.getStartOffset(idx + 1);
                    end = tokens.getEndOffset(idx + 1);
                }
            }
            word_range = .init(position.lineNumber, start + 1, position.lineNumber, end + 1);
        }
    }
    return if (word_range.startColumn < position.column)
        .{ .range = Range.init(position.lineNumber, word_range.startColumn, position.lineNumber, position.column), .direction = .after }
    else
        .{ .range = Range.init(position.lineNumber, position.column, position.lineNumber, word_range.endColumn), .direction = .before };
}

pub const InlayHintsFragments = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    model: *TextModel,
    range: Range,
    slots: []Slot = &.{},
    items: []InlayHintItem = &.{},
    remaining: usize = 0,
    starting: bool = true,
    callback: Callback,
    const Slot = struct {
        owner: *InlayHintsFragments,
        provider: languages.InlayHintsProvider,
        result: ?languages.InlayHintList = null,
        pending: ?IDisposable = null,
        done: bool = false,
        fn ready(context: *anyopaque, result: anyerror!?languages.InlayHintList) void {
            const self: *Slot = @ptrCast(@alignCast(context));
            self.pending = null;
            self.done = true;
            self.result = result catch null;
            self.owner.remaining -= 1;
            self.owner.finishIfReady();
        }
    };
    pub const Callback = struct { context: *anyopaque, complete: *const fn (*anyopaque, *InlayHintsFragments) void };
    pub fn create(a: std.mem.Allocator, registry: *Registry, model: *TextModel, range: Range, callback: Callback) !*InlayHintsFragments {
        const self = try a.create(InlayHintsFragments);
        self.* = .{ .allocator = a, .arena = .init(a), .model = model, .range = range, .callback = callback };
        errdefer self.deinit();
        const scratch = self.arena.allocator();
        const ordered = try registry.ordered(scratch, model, false);
        self.slots = try scratch.alloc(Slot, ordered.len);
        for (self.slots, 0..) |*slot, i| slot.* = .{ .owner = self, .provider = ordered[ordered.len - 1 - i] };
        self.remaining = ordered.len;
        return self;
    }
    pub fn start(self: *InlayHintsFragments) void {
        for (self.slots) |*slot| {
            const request = slot.provider.request_inlay_hints(slot.provider.context, self.arena.allocator(), self.model, self.range, .{ .context = slot, .complete = Slot.ready }) catch |err| {
                Slot.ready(slot, err);
                continue;
            };
            if (!slot.done) slot.pending = request;
        }
        self.starting = false;
        self.finishIfReady();
    }
    fn finishIfReady(self: *InlayHintsFragments) void {
        if (self.starting or self.remaining != 0) return;
        const a = self.arena.allocator();
        var items: std.ArrayList(InlayHintItem) = .empty;
        for (self.slots) |slot| if (slot.result) |list| {
            for (list.hints) |hint| {
                if (!self.range.containsPosition(&hint.position)) continue;
                items.append(a, .{ .hint = hint, .anchor = anchorAtPosition(self.model, hint.position), .provider = slot.provider }) catch break;
            }
        };
        std.mem.sort(InlayHintItem, items.items, {}, struct {
            fn lessThan(_: void, left: InlayHintItem, right: InlayHintItem) bool {
                return left.hint.position.lineNumber < right.hint.position.lineNumber or (left.hint.position.lineNumber == right.hint.position.lineNumber and left.hint.position.column < right.hint.position.column);
            }
        }.lessThan);
        self.items = items.items;
        self.callback.complete(self.callback.context, self);
    }
    pub fn deinit(self: *InlayHintsFragments) void {
        for (self.slots) |*slot| {
            if (slot.pending) |pending| pending.dispose();
            if (slot.result) |*list| list.dispose();
        }
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};
