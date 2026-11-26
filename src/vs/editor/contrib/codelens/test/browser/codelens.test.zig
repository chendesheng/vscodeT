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
