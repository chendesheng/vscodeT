// Port of `src/vs/editor/contrib/codelens/browser/codelens.ts`.
// Providers return owned request-arena data and optional disposable cache
// handles. Callback continuations replace the browser Promise.all.
const std = @import("std");
const Allocator = std.mem.Allocator;
const languages = @import("../../../common/languages.zig");
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const CancellationToken = @import("../../../../base/common/cancellation.zig").CancellationToken;
const Disposable = @import("../../../../base/common/lifecycle.zig").IDisposable;

pub const CodeLensItem = struct {
    symbol: languages.CodeLens,
    provider: languages.CodeLensProvider,
    provider_rank: usize,
};

pub const CodeLensModel = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    lenses: std.ArrayList(CodeLensItem) = .empty,
    disposables: std.ArrayList(Disposable) = .empty,

    pub fn create(allocator: Allocator) !*CodeLensModel {
        const self = try allocator.create(CodeLensModel);
        self.* = .{ .allocator = allocator, .arena = std.heap.ArenaAllocator.init(allocator) };
        return self;
    }

    pub fn dispose(self: *CodeLensModel) void {
        for (self.disposables.items) |disposable| disposable.dispose();
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    pub fn add(self: *CodeLensModel, list: languages.CodeLensList, provider: languages.CodeLensProvider, rank: usize) !void {
        const a = self.arena.allocator();
        if (list.disposable) |d| self.disposables.append(a, d) catch |err| {
            d.dispose();
            return err;
        };
        try self.lenses.ensureUnusedCapacity(a, list.lenses.len);
        for (list.lenses) |symbol| self.lenses.appendAssumeCapacity(.{ .symbol = symbol, .provider = provider, .provider_rank = rank });
    }

    pub fn sort(self: *CodeLensModel) void {
        std.mem.sort(CodeLensItem, self.lenses.items, {}, struct {
            fn lessThan(_: void, a: CodeLensItem, b: CodeLensItem) bool {
                if (a.symbol.range.startLineNumber != b.symbol.range.startLineNumber) return a.symbol.range.startLineNumber < b.symbol.range.startLineNumber;
                if (a.provider_rank != b.provider_rank) return a.provider_rank < b.provider_rank;
                return a.symbol.range.startColumn < b.symbol.range.startColumn;
            }
        }.lessThan);
    }
};

/// getCodeLensModel: invoke every ordered provider, wait for all results,
/// ignore a provider error, then sort by line, provider rank and column.
pub const Request = struct {
    result: *CodeLensModel,
    slots: []Slot,
    remaining: usize,
    starting: bool = true,
    context: *anyopaque,
    complete: *const fn (*anyopaque, *CodeLensModel) void,

    const Slot = struct {
        owner: *Request,
        provider: languages.CodeLensProvider,
        rank: usize,
        pending: ?Disposable = null,
        done: bool = false,

        fn ready(context: *anyopaque, list: ?languages.CodeLensList) void {
            const slot: *Slot = @ptrCast(@alignCast(context));
            if (slot.done) return;
            slot.done = true;
            slot.pending = null;
            const self = slot.owner;
            if (list) |value| self.result.add(value, slot.provider, slot.rank) catch {};
            self.remaining -= 1;
            if (!self.starting and self.remaining == 0) self.finish();
        }
    };

    pub fn start(allocator: Allocator, model: *TextModel, providers: []const languages.CodeLensProvider, context: *anyopaque, complete: *const fn (*anyopaque, *CodeLensModel) void) !?*Request {
        const result = try CodeLensModel.create(allocator);
        errdefer result.dispose();
        const a = result.arena.allocator();
        const self = try a.create(Request);
        self.* = .{ .result = result, .slots = try a.alloc(Slot, providers.len), .remaining = providers.len, .context = context, .complete = complete };
        for (providers, self.slots, 0..) |provider, *slot, rank| {
            slot.* = .{ .owner = self, .provider = provider, .rank = rank };
            if (provider.request_code_lenses) |request| {
                const pending = request(provider.context, a, model, .{ .context = slot, .complete = Slot.ready }) catch null;
                if (!slot.done) {
                    slot.pending = pending;
                    if (pending == null) Slot.ready(slot, null);
                }
            } else {
                const list = provider.provide_code_lenses(provider.context, a, model, CancellationToken.None) catch null;
                Slot.ready(slot, list);
            }
        }
        self.starting = false;
        if (self.remaining != 0) return self;
        self.finish();
        return null;
    }

    pub fn cancel(self: *Request) void {
        for (self.slots) |slot| if (slot.pending) |pending| pending.dispose();
        self.result.dispose();
    }

    fn finish(self: *Request) void {
        self.result.sort();
        self.complete(self.context, self.result);
    }
};
