// Port of `src/vs/editor/contrib/semanticTokens/common/getSemanticTokens.ts`.
// Highest-scoring providers run concurrently; results are selected in provider
// order, not completion order. Unselected result IDs are released.
const std = @import("std");
const languages = @import("../../../common/languages.zig");
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const Registry = @import("../../../common/languageFeatureRegistry.zig").LanguageFeatureRegistry(languages.DocumentSemanticTokensProvider);
const IDisposable = @import("../../../../base/common/lifecycle.zig").IDisposable;
const Delta = @import("../../../common/services/semanticTokensDto.zig").DecodedDelta;

pub const FullRequest = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    slots: []Slot = &.{},
    remaining: usize = 0,
    starting: bool = true,
    callback: Callback,
    selected: ?usize = null,
    const Slot = struct {
        owner: *FullRequest,
        provider: languages.DocumentSemanticTokensProvider,
        pending: ?IDisposable = null,
        result: ?languages.SemanticTokensResult = null,
        failure: ?anyerror = null,
        done: bool = false,
        fn ready(context: *anyopaque, result: anyerror!?languages.SemanticTokensResult) void {
            const self: *Slot = @ptrCast(@alignCast(context));
            self.pending = null;
            if (result) |value| self.result = value else |err| self.failure = err;
            self.done = true;
            self.owner.remaining -= 1;
            self.owner.finishIfReady();
        }
    };
    pub const Callback = struct { context: *anyopaque, complete: *const fn (*anyopaque, *FullRequest) void };
    pub fn create(a: std.mem.Allocator, registry: *Registry, model: *TextModel, callback: Callback) !*FullRequest {
        const self = try a.create(FullRequest);
        self.* = .{ .allocator = a, .arena = .init(a), .callback = callback };
        errdefer self.deinit();
        const scratch = self.arena.allocator();
        const groups = try registry.orderedGroups(scratch, model);
        if (groups.len > 0) {
            self.slots = try scratch.alloc(Slot, groups[0].len);
            for (self.slots, groups[0]) |*slot, provider| slot.* = .{ .owner = self, .provider = provider };
        }
        self.remaining = self.slots.len;
        return self;
    }
    pub fn start(self: *FullRequest, model: *TextModel, previous_provider: ?*anyopaque, previous_id: ?u32) void {
        for (self.slots) |*slot| {
            const prior = if (slot.provider.context == previous_provider) previous_id else null;
            const request = slot.provider.request_document_semantic_tokens(slot.provider.context, self.arena.allocator(), model, prior, .{ .context = slot, .complete = Slot.ready }) catch |err| {
                Slot.ready(slot, err);
                continue;
            };
            if (!slot.done) slot.pending = request;
        }
        self.starting = false;
        self.finishIfReady();
    }
    fn finishIfReady(self: *FullRequest) void {
        if (self.starting or self.remaining != 0) return;
        self.callback.complete(self.callback.context, self);
    }
    pub const Selection = struct { provider: languages.DocumentSemanticTokensProvider, result: languages.SemanticTokensResult };
    pub fn takeSelected(self: *FullRequest) !?Selection {
        for (self.slots, 0..) |slot, index| {
            if (slot.failure) |err| return err;
            if (slot.result) |result| {
                self.selected = index;
                return .{ .provider = slot.provider, .result = result };
            }
        }
        return null;
    }
    pub fn deinit(self: *FullRequest) void {
        for (self.slots, 0..) |slot, index| {
            if (slot.pending) |pending| pending.dispose();
            if (self.selected != index) if (slot.result) |result| slot.provider.release_document_semantic_tokens(slot.provider.context, result.id);
        }
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};

/// Apply incremental edits in their original-data coordinates. Reject invalid
/// or out-of-order edits so that the next request can restart with a full set.
pub fn applyDelta(a: std.mem.Allocator, previous: []const u32, edits: []const Delta) ![]u32 {
    var data: std.ArrayList(u32) = .empty;
    errdefer data.deinit(a);
    var offset: usize = 0;
    for (edits) |edit| {
        const start: usize = edit.start;
        const end = std.math.add(usize, start, edit.delete_count) catch return error.InvalidSemanticDelta;
        if (start < offset or end > previous.len) return error.InvalidSemanticDelta;
        try data.appendSlice(a, previous[offset..start]);
        try data.appendSlice(a, edit.data);
        offset = end;
    }
    try data.appendSlice(a, previous[offset..]);
    if (data.items.len % 5 != 0) return error.InvalidSemanticDelta;
    return data.toOwnedSlice(a);
}
