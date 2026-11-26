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

/// The portable `_executeCodeLensProvider` continuation. Already resolved
/// entries are returned unconditionally. When a budget is supplied, unresolved
/// entries consume it in the sorted provider order and are appended on resolve
/// completion, just as upstream's Promise.all. The caller owns the execution
/// until its result has been delivered and the delayed cache release completes.
pub const Execution = struct {
    allocator: Allocator,
    model: *TextModel,
    resolve_count: ?usize,
    context: *anyopaque,
    complete: *const fn (*anyopaque, anyerror![]const languages.CodeLens) void,
    gather: ?*Request = null,
    result: ?*CodeLensModel = null,
    values: std.ArrayList(languages.CodeLens) = .empty,
    slots: []ResolveSlot = &.{},
    remaining: usize = 0,
    starting: bool = false,
    finished: bool = false,

    const ResolveSlot = struct {
        owner: *Execution,
        original: languages.CodeLens,
        pending: ?Disposable = null,
        done: bool = false,

        fn ready(context: *anyopaque, resolved: ?languages.CodeLens) void {
            const self: *ResolveSlot = @ptrCast(@alignCast(context));
            if (self.done) return;
            const owner = self.owner;
            self.done = true;
            self.pending = null;
            owner.values.appendAssumeCapacity(resolved orelse self.original);
            owner.remaining -= 1;
            if (!owner.starting and owner.remaining == 0) owner.finish(owner.values.items);
        }
    };

    pub fn start(self: *Execution, providers: []const languages.CodeLensProvider) !void {
        self.gather = try Request.start(self.allocator, self.model, providers, self, onGathered);
    }

    fn onGathered(context: *anyopaque, result: *CodeLensModel) void {
        const self: *Execution = @ptrCast(@alignCast(context));
        self.gather = null;
        self.result = result;
        self.resolve(result) catch |err| self.finish(err);
    }

    fn resolve(self: *Execution, result: *CodeLensModel) !void {
        const a = result.arena.allocator();
        try self.values.ensureTotalCapacity(a, result.lenses.items.len);
        self.slots = try a.alloc(ResolveSlot, result.lenses.items.len);
        self.starting = true;
        var budget = self.resolve_count;
        for (result.lenses.items, self.slots) |item, *slot| {
            slot.* = .{ .owner = self, .original = item.symbol, .done = true };
            if (budget == null or item.symbol.command != null) {
                self.values.appendAssumeCapacity(item.symbol);
                continue;
            }
            const can_resolve = budget.? > 0;
            budget.? -|= 1;
            if (!can_resolve or (item.provider.resolve_code_lens == null and item.provider.request_resolve_code_lens == null)) continue;
            slot.done = false;
            self.remaining += 1;
        }
        for (result.lenses.items, self.slots) |item, *slot| {
            if (slot.done) continue;
            if (item.provider.request_resolve_code_lens) |request| {
                const pending = request(item.provider.context, a, self.model, item.symbol, .{ .context = slot, .complete = ResolveSlot.ready }) catch null;
                if (!slot.done) {
                    slot.pending = pending;
                    if (pending == null) ResolveSlot.ready(slot, null);
                }
            } else if (item.provider.resolve_code_lens) |sync_resolve| {
                const symbol = sync_resolve(item.provider.context, a, self.model, item.symbol, CancellationToken.None) catch null;
                ResolveSlot.ready(slot, symbol);
            }
        }
        self.starting = false;
        if (self.remaining == 0) self.finish(self.values.items);
    }

    fn finish(self: *Execution, result: anyerror![]const languages.CodeLens) void {
        if (self.finished) return;
        self.finished = true;
        self.complete(self.context, result);
    }

    pub fn deinit(self: *Execution) void {
        if (self.gather) |gather| gather.cancel();
        for (self.slots) |slot| if (slot.pending) |pending| pending.dispose();
        if (self.result) |result| result.dispose();
        self.* = undefined;
    }
};

pub const ExecuteCodeLensProviderArgs = struct {
    execution: *Execution,
    providers: []const languages.CodeLensProvider,
};

const actions = @import("../../../../platform/actions/common/actions.zig");
const ServicesAccessor = @import("../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const CommandArgument = @import("../../../../platform/commands/common/commands.zig").CommandArgument;
pub const execute_provider_action: actions.Action2 = .{
    .command = .{ .id = "_executeCodeLensProvider", .title = "Execute CodeLens Provider" },
    .context = @constCast(&{}),
    .run_fn = struct {
        fn run(_: *anyopaque, _: ServicesAccessor) !void {
            return error.InvalidArgument;
        }
    }.run,
    .run_with_argument_fn = struct {
        fn run(_: *anyopaque, _: ServicesAccessor, argument: CommandArgument) !void {
            const args = argument.as(ExecuteCodeLensProviderArgs) orelse return error.InvalidArgument;
            try args.execution.start(args.providers);
        }
    }.run,
};
