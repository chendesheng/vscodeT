// Port of `src/vs/editor/contrib/hover/browser/getHover.ts`.
// Concurrent provider requests emit valid results in resolution order, with
// a detachable continuation replacing the browser async iterable. The older
// synchronous entry point remains available to immediate native providers.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const Position = @import("../../../common/core/position.zig").Position;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const languages = @import("../../../common/languages.zig");
const Hover = languages.Hover;
const HoverProvider = languages.HoverProvider;
const CancellationToken = @import("../../../../base/common/cancellation.zig").CancellationToken;
const Disposable = @import("../../../../base/common/lifecycle.zig").IDisposable;
const Registry = @import("../../../common/languageFeatureRegistry.zig").LanguageFeatureRegistry(HoverProvider);

pub const HoverProviderResult = struct {
    provider: HoverProvider,
    hover: Hover,
    ordinal: usize,
};

pub const HoverResultListener = struct {
    context: *anyopaque,
    emit: *const fn (*anyopaque, HoverProviderResult) void,
    complete: *const fn (*anyopaque) void,
};

pub const ProviderSource = union(enum) { registry: *Registry, providers: []const HoverProvider };

const HoverRequest = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    model: *TextModel,
    position: Position,
    token: CancellationToken,
    listener: HoverResultListener,
    registry: ?*Registry = null,
    slots: []Slot = &.{},
    remaining: usize = 0,
    starting: bool = true,
    dispatching: bool = false,
    canceled: bool = false,
    finished: bool = false,

    const Slot = struct {
        owner: *HoverRequest,
        provider: HoverProvider,
        ordinal: usize,
        registration_time: ?u64 = null,
        pending: ?Disposable = null,
        done: bool = false,

        fn ready(context: *anyopaque, result: anyerror!?Hover) void {
            const slot: *Slot = @ptrCast(@alignCast(context));
            const self = slot.owner;
            if (slot.done or self.canceled) return;
            slot.done = true;
            slot.pending = null;
            self.remaining -= 1;
            if (result catch null) |hover| {
                if (isValid(hover)) {
                    self.dispatching = true;
                    self.listener.emit(self.listener.context, .{ .provider = slot.provider, .hover = hover, .ordinal = slot.ordinal });
                    self.dispatching = false;
                }
            }
            if (self.starting) return;
            if (self.canceled) {
                self.destroy();
            } else if (self.remaining == 0) self.finish();
        }
    };

    fn start(self: *HoverRequest, hover_context: ?*const languages.HoverContext) ?Disposable {
        const a = self.arena.allocator();
        for (self.slots) |*slot| {
            if (self.canceled) break;
            if (slot.registration_time) |identity| if (!self.registry.?.hasRegistration(identity)) {
                Slot.ready(slot, null);
                continue;
            };
            const provider = slot.provider;
            if (provider.request_hover) |request| {
                const pending = request(provider.context, a, self.model, self.position, self.token, hover_context, .{ .context = slot, .complete = Slot.ready }) catch |err| blk: {
                    Slot.ready(slot, err);
                    break :blk null;
                };
                if (!slot.done) {
                    if (self.canceled) {
                        if (pending) |handle| handle.dispose();
                    } else {
                        slot.pending = pending;
                        if (pending == null) Slot.ready(slot, null);
                    }
                }
            } else Slot.ready(slot, provider.provide_hover(provider.context, self.model, self.position, self.token, hover_context));
        }
        self.starting = false;
        if (self.canceled) {
            self.destroy();
            return null;
        }
        if (self.remaining == 0) {
            self.finish();
            return null;
        }
        return Disposable.from(HoverRequest, self, cancel);
    }

    fn finish(self: *HoverRequest) void {
        self.finished = true;
        self.listener.complete(self.listener.context);
        self.destroy();
    }

    fn cancel(self: *HoverRequest) void {
        if (self.canceled or self.finished) return;
        self.canceled = true;
        for (self.slots) |*slot| {
            if (slot.pending) |pending| pending.dispose();
            slot.pending = null;
        }
        if (!self.starting and !self.dispatching) self.destroy();
    }

    fn destroy(self: *HoverRequest) void {
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};

/// Port of getHoverProviderResultsAsAsyncIterable. Provider DTOs and slots
/// remain alive until their result or disposal; the consumer copies emitted
/// values synchronously before the request arena can be released.
pub fn requestHoverProviderResults(allocator: Allocator, source: ProviderSource, model: *TextModel, position: Position, token: CancellationToken, hover_context: ?*const languages.HoverContext, recursive: bool, listener: HoverResultListener) !?Disposable {
    const request = try allocator.create(HoverRequest);
    request.* = .{ .allocator = allocator, .arena = .init(allocator), .model = model, .position = position, .token = token, .listener = listener };
    errdefer request.destroy();
    const a = request.arena.allocator();
    switch (source) {
        .registry => |registry| {
            request.registry = registry;
            const providers = try registry.orderedWithSelectors(a, model, recursive);
            request.slots = try a.alloc(HoverRequest.Slot, providers.len);
            for (providers, request.slots, 0..) |entry, *slot, ordinal| slot.* = .{ .owner = request, .provider = entry.provider, .ordinal = ordinal, .registration_time = entry.registration_time };
        },
        .providers => |providers| {
            request.slots = try a.alloc(HoverRequest.Slot, providers.len);
            for (providers, request.slots, 0..) |provider, *slot, ordinal| slot.* = .{ .owner = request, .provider = provider, .ordinal = ordinal };
        },
    }
    request.remaining = request.slots.len;
    return request.start(hover_context);
}

/// Does not throw or reject; invalid provider results are skipped.
fn executeProvider(
    provider: HoverProvider,
    ordinal: usize,
    model: *TextModel,
    position: Position,
    token: CancellationToken,
    hover_context: ?*const languages.HoverContext,
) ?HoverProviderResult {
    const result = provider.provide_hover(provider.context, model, position, token, hover_context) catch return null;
    const hover = result orelse return null;
    if (!isValid(hover)) return null;
    return .{ .provider = provider, .hover = hover, .ordinal = ordinal };
}

pub fn getHoverProviderResults(
    allocator: Allocator,
    providers: []const HoverProvider,
    model: *TextModel,
    position: Position,
    token: CancellationToken,
    hover_context: ?*const languages.HoverContext,
) ![]HoverProviderResult {
    var result = ArrayList(HoverProviderResult).init(allocator);
    errdefer result.deinit();
    for (providers, 0..) |provider, index| {
        if (executeProvider(provider, index, model, position, token, hover_context)) |item| {
            try result.append(item);
        }
    }
    return try result.toOwnedSlice();
}

pub fn getHovers(
    allocator: Allocator,
    providers: []const HoverProvider,
    model: *TextModel,
    position: Position,
    token: CancellationToken,
    hover_context: ?*const languages.HoverContext,
) ![]Hover {
    const results = try getHoverProviderResults(allocator, providers, model, position, token, hover_context);
    defer allocator.free(results);

    var hovers = ArrayList(Hover).init(allocator);
    errdefer hovers.deinit();
    for (results) |result| try hovers.append(result.hover);
    return try hovers.toOwnedSlice();
}

pub fn isValid(hover: Hover) bool {
    if (hover.range == null) return false;
    for (hover.contents) |content| {
        if (content.value.len > 0) return true;
    }
    return false;
}

test "getHover: aggregates valid provider results" {
    const std_testing = std.testing;
    const TestModel = @import("../../../test/common/port/testSupport.zig").TestModel;

    const ProviderState = struct {
        text: []const u8,
        fail: bool = false,
        contents: [1]languages.IMarkdownString = undefined,

        fn provide(context: *anyopaque, model: *TextModel, position: Position, token: CancellationToken, hover_context: ?*const languages.HoverContext) anyerror!?Hover {
            _ = model;
            _ = position;
            _ = token;
            _ = hover_context;
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.fail) return error.ProviderFailed;
            self.contents[0] = .{ .value = self.text };
            return Hover{ .contents = &self.contents, .range = @import("../../../common/core/range.zig").Range.init(1, 1, 1, 2) };
        }
    };

    const allocator = std_testing.allocator;
    var ctx = try TestModel.init(allocator, "hello", "nullLanguage");
    defer ctx.deinit();

    var first = ProviderState{ .text = "first" };
    var second = ProviderState{ .text = "second" };
    var failing = ProviderState{ .text = "ignored", .fail = true };
    const providers = [_]HoverProvider{
        .{ .context = &first, .provide_hover = ProviderState.provide },
        .{ .context = &failing, .provide_hover = ProviderState.provide },
        .{ .context = &second, .provide_hover = ProviderState.provide },
    };

    const results = try getHoverProviderResults(allocator, &providers, ctx.model, Position.init(1, 1), CancellationToken.None, null);
    defer allocator.free(results);
    try std_testing.expectEqual(@as(usize, 2), results.len);
    try std_testing.expectEqual(@as(usize, 0), results[0].ordinal);
    try std_testing.expectEqual(@as(usize, 2), results[1].ordinal);
}

test "getHover: concurrent provider results stream in resolution order and cancellation detaches all pending slots" {
    const a = std.testing.allocator;
    const TestModel = @import("../../../test/common/port/testSupport.zig").TestModel;
    const Range = @import("../../../common/core/range.zig").Range;
    const Provider = struct {
        callback: ?languages.HoverCallback = null,
        token: CancellationToken = .None,
        canceled: bool = false,
        fn interface(self: *@This()) HoverProvider {
            return .{ .context = self, .provide_hover = sync, .request_hover = request };
        }
        fn sync(_: *anyopaque, _: *TextModel, _: Position, _: CancellationToken, _: ?*const languages.HoverContext) !?Hover {
            return error.MustUseAsyncRequest;
        }
        fn request(context: *anyopaque, _: Allocator, _: *TextModel, _: Position, token: CancellationToken, _: ?*const languages.HoverContext, callback: languages.HoverCallback) !?Disposable {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.callback = callback;
            self.token = token;
            return Disposable.from(@This(), self, cancel);
        }
        fn cancel(self: *@This()) void {
            self.canceled = self.token.isCancellationRequested();
            self.callback = null;
        }
        fn resolve(self: *@This(), text: []const u8) void {
            const callback = self.callback orelse return;
            self.callback = null;
            callback.complete(callback.context, .{ .range = Range.init(1, 1, 1, 2), .contents = &.{.{ .value = text }} });
        }
    };
    const Receiver = struct {
        ordinals: std.ArrayList(usize) = .empty,
        completed: bool = false,
        fn emit(context: *anyopaque, value: HoverProviderResult) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.ordinals.append(std.testing.allocator, value.ordinal) catch unreachable;
        }
        fn complete(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.completed = true;
        }
        fn listener(self: *@This()) HoverResultListener {
            return .{ .context = self, .emit = emit, .complete = complete };
        }
    };
    var text = try TestModel.init(a, "word", "plaintext");
    defer text.deinit();
    var first: Provider = .{};
    var second: Provider = .{};
    var receiver: Receiver = .{};
    defer receiver.ordinals.deinit(a);
    const providers = [_]HoverProvider{ first.interface(), second.interface() };
    var source = try @import("../../../../base/common/cancellation.zig").CancellationTokenSource.init(a);
    defer source.deinit();
    const token = try source.token();
    try std.testing.expect((try requestHoverProviderResults(a, .{ .providers = &providers }, text.model, Position.init(1, 1), token, null, false, receiver.listener())) != null);
    try std.testing.expect(first.callback != null and second.callback != null);
    second.resolve("second");
    try std.testing.expectEqualSlices(usize, &.{1}, receiver.ordinals.items);
    try std.testing.expect(!receiver.completed);
    first.resolve("first");
    try std.testing.expectEqualSlices(usize, &.{ 1, 0 }, receiver.ordinals.items);
    try std.testing.expect(receiver.completed);
    receiver.completed = false;
    const pending = (try requestHoverProviderResults(a, .{ .providers = &providers }, text.model, Position.init(1, 1), token, null, false, receiver.listener())).?;
    source.cancel();
    pending.dispose();
    try std.testing.expect(first.canceled and second.canceled);
    first.resolve("late");
    try std.testing.expectEqual(2, receiver.ordinals.items.len);
    try std.testing.expect(!receiver.completed);
}
