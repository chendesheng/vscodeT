// Regression coverage for `src/vs/editor/contrib/codelens/browser/codelens.ts`.
const std = @import("std");
const testing = std.testing;
const model = @import("../../browser/codelens.zig");
const languages = @import("../../../../common/languages.zig");
const Range = @import("../../../../common/core/range.zig").Range;
const TextModel = @import("../../../../common/model/textModel.zig").TextModel;
const TestModel = @import("../../../../test/common/port/testSupport.zig").TestModel;
const CancellationToken = @import("../../../../../base/common/cancellation.zig").CancellationToken;
const Disposable = @import("../../../../../base/common/lifecycle.zig").IDisposable;

const Provider = struct {
    lenses: []const languages.CodeLens,
    pending: ?languages.CodeLensCallback = null,
    releases: usize = 0,
    cancels: usize = 0,

    fn provide(context: *anyopaque, _: std.mem.Allocator, _: *TextModel, _: CancellationToken) !?languages.CodeLensList {
        const self: *Provider = @ptrCast(@alignCast(context));
        return self.list();
    }

    fn request(context: *anyopaque, _: std.mem.Allocator, _: *TextModel, callback: languages.CodeLensCallback) !?Disposable {
        const self: *Provider = @ptrCast(@alignCast(context));
        self.pending = callback;
        return .{ .context = self, .disposeFn = cancel };
    }

    fn cancel(context: *anyopaque) void {
        const self: *Provider = @ptrCast(@alignCast(context));
        self.pending = null;
        self.cancels += 1;
    }

    fn release(context: *anyopaque) void {
        const self: *Provider = @ptrCast(@alignCast(context));
        self.releases += 1;
    }

    fn list(self: *Provider) languages.CodeLensList {
        return .{ .lenses = self.lenses, .disposable = .{ .context = self, .disposeFn = release } };
    }

    fn publish(self: *Provider) void {
        const callback = self.pending.?;
        self.pending = null;
        callback.complete(callback.context, self.list());
    }

    fn interface(self: *Provider, asynchronous: bool) languages.CodeLensProvider {
        return .{ .context = self, .provide_code_lenses = provide, .request_code_lenses = if (asynchronous) request else null };
    }
};

fn lens(line: usize, column: usize, title: []const u8) languages.CodeLens {
    return .{ .range = Range.init(line, column, line, column), .command = .{ .id = title, .title = title } };
}

const Receiver = struct {
    result: ?*model.CodeLensModel = null,
    fn complete(context: *anyopaque, result: *model.CodeLensModel) void {
        const self: *Receiver = @ptrCast(@alignCast(context));
        self.result = result;
    }
};

test "CodeLens: gather all providers in rank and column order and release every list" {
    const a = testing.allocator;
    var text = try TestModel.init(a, "one\ntwo\nthree", "nullLanguage");
    defer text.deinit();
    var first: Provider = .{ .lenses = &.{ lens(2, 3, "first c3"), lens(2, 1, "first c1") } };
    var second: Provider = .{ .lenses = &.{ lens(2, 2, "second c2"), lens(1, 1, "second line1") } };
    var receiver: Receiver = .{};
    const active = try model.Request.start(a, text.model, &.{ first.interface(true), second.interface(true) }, &receiver, Receiver.complete);
    try testing.expect(active != null);
    second.publish();
    try testing.expect(receiver.result == null);
    first.publish();
    const result = receiver.result.?;
    var disposed = false;
    defer if (!disposed) result.dispose();
    try testing.expectEqual(4, result.lenses.items.len);
    const expected = [_][]const u8{ "second line1", "first c1", "first c3", "second c2" };
    for (result.lenses.items, expected) |item, title| try testing.expectEqualStrings(title, item.symbol.command.?.title);
    try testing.expectEqual(0, first.releases);
    try testing.expectEqual(0, second.releases);
    result.dispose();
    disposed = true;
    try testing.expectEqual(1, first.releases);
    try testing.expectEqual(1, second.releases);
}

test "CodeLens: cancelled aggregate disposes acquired lists and pending providers" {
    const a = testing.allocator;
    var text = try TestModel.init(a, "one\ntwo", "nullLanguage");
    defer text.deinit();
    var first: Provider = .{ .lenses = &.{lens(1, 1, "first")} };
    var second: Provider = .{ .lenses = &.{lens(2, 1, "second")} };
    var receiver: Receiver = .{};
    const active = (try model.Request.start(a, text.model, &.{ first.interface(false), second.interface(true) }, &receiver, Receiver.complete)).?;
    active.cancel();
    try testing.expectEqual(1, first.releases);
    try testing.expectEqual(1, second.cancels);
    try testing.expectEqual(0, second.releases);
    try testing.expect(receiver.result == null);
}

test "CodeLens: cache retains inert labels and stores only line numbers at shutdown" {
    const a = testing.allocator;
    const Cache = @import("../../browser/codeLensCache.zig").CodeLensCache;
    const Storage = @import("../../../../../platform/storage/common/storage.zig").InMemoryStorageService;
    var text = try TestModel.init(a, "one\ntwo\nthree", "nullLanguage");
    defer text.deinit();
    var storage = Storage.init(a);
    defer storage.deinit();
    var cache: Cache = .{ .allocator = a };
    defer cache.deinit();
    try cache.attachStorage(storage.interface());
    var provider: Provider = .{ .lenses = &.{ lens(2, 1, "one command"), lens(2, 3, "other command") } };
    const data = try model.CodeLensModel.create(a);
    defer data.dispose();
    try data.add(provider.list(), provider.interface(false), 0);
    try cache.put(text.model, data);
    const saved = (try cache.get(text.model)).?;
    defer saved.dispose();
    try testing.expectEqualStrings("", saved.lenses.items[0].symbol.command.?.id);
    try testing.expectEqualStrings("one command", saved.lenses.items[0].symbol.command.?.title);
    try storage.flush(.shutdown);
    const raw = storage.get("codelens/cache2", .workspace, null).?;
    try testing.expect(std.mem.indexOf(u8, raw, "one command") == null);
    var restored: Cache = .{ .allocator = a };
    defer restored.deinit();
    try restored.deserialize(raw);
    const restored_model = (try restored.get(text.model)).?;
    defer restored_model.dispose();
    try testing.expectEqual(1, restored_model.lenses.items.len);
    try testing.expectEqual(2, restored_model.lenses.items[0].symbol.range.startLineNumber);
    try testing.expect(restored_model.lenses.items[0].symbol.command == null);
}

test "CodeLens: execute provider returns commands first and resolves only the requested number" {
    const a = testing.allocator;
    var text = try TestModel.init(a, "one\ntwo\nthree\nfour", "nullLanguage");
    defer text.deinit();
    const Resolver = struct {
        calls: usize = 0,
        fn provide(_: *anyopaque, _: std.mem.Allocator, _: *TextModel, _: CancellationToken) !?languages.CodeLensList {
            return .{ .lenses = &.{
                .{ .range = Range.init(1, 1, 1, 1) },
                lens(2, 1, "already resolved"),
                .{ .range = Range.init(3, 1, 3, 1) },
                .{ .range = Range.init(4, 1, 4, 1) },
            } };
        }
        fn resolve(context: *anyopaque, _: std.mem.Allocator, _: *TextModel, symbol: languages.CodeLens, _: CancellationToken) !?languages.CodeLens {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            if (symbol.range.startLineNumber != 1) return null;
            return lens(1, 1, "newly resolved");
        }
    };
    const Receiver2 = struct {
        result: ?[]const languages.CodeLens = null,
        fn complete(context: *anyopaque, result: anyerror![]const languages.CodeLens) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.result = result catch null;
        }
    };
    var resolver: Resolver = .{};
    const provider: languages.CodeLensProvider = .{ .context = &resolver, .provide_code_lenses = Resolver.provide, .resolve_code_lens = Resolver.resolve };
    var receiver: Receiver2 = .{};
    var execution: model.Execution = .{ .allocator = a, .model = text.model, .resolve_count = 2, .context = &receiver, .complete = Receiver2.complete };
    defer execution.deinit();
    try execution.start(&.{provider});
    try testing.expectEqual(@as(usize, 2), resolver.calls);
    const result = receiver.result.?;
    try testing.expectEqual(@as(usize, 3), result.len);
    try testing.expectEqualStrings("already resolved", result[0].command.?.title);
    try testing.expectEqualStrings("newly resolved", result[1].command.?.title);
    try testing.expectEqual(@as(usize, 3), result[2].range.startLineNumber);
    try testing.expect(result[2].command == null);
    var receiver_all: Receiver2 = .{};
    var all: model.Execution = .{ .allocator = a, .model = text.model, .resolve_count = null, .context = &receiver_all, .complete = Receiver2.complete };
    defer all.deinit();
    try all.start(&.{provider});
    try testing.expectEqual(@as(usize, 2), resolver.calls);
    try testing.expectEqual(@as(usize, 4), receiver_all.result.?.len);
    try testing.expect(receiver_all.result.?[0].command == null);
}
