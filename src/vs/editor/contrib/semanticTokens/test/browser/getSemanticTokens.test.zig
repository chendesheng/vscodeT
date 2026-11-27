// Port of `src/vs/editor/contrib/semanticTokens/test/browser/getSemanticTokens.test.ts`.
// Additional regressions cover binary delta validation and async range groups.
const std = @import("std");
const tokens = @import("../../common/getSemanticTokens.zig");
test "Semantic tokens: delta edits address the original data and reject invalid spans" {
    const a = std.testing.allocator;
    const original = [_]u32{ 0, 0, 1, 0, 0, 1, 2, 3, 4, 0 };
    const changed = try tokens.applyDelta(a, &original, &.{ .{ .start = 2, .delete_count = 1, .data = @constCast(&[_]u32{2}) }, .{ .start = 5, .delete_count = 5, .data = &.{} } });
    defer a.free(changed);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 2, 0, 0 }, changed);
    try std.testing.expectError(error.InvalidSemanticDelta, tokens.applyDelta(a, &original, &.{.{ .start = 12, .delete_count = 1, .data = &.{} }}));
    try std.testing.expectError(error.InvalidSemanticDelta, tokens.applyDelta(a, &original, &.{.{ .start = 2, .delete_count = 1, .data = &.{} }}));
}

const TestModel = @import("../../../../test/common/port/testSupport.zig").TestModel;
const TextModel = @import("../../../../common/model/textModel.zig").TextModel;
const Range = @import("../../../../common/core/range.zig").Range;
const languages = @import("../../../../common/languages.zig");
const Disposable = @import("../../../../../base/common/lifecycle.zig").IDisposable;

const RangeProvider = struct {
    callback: ?languages.SemanticTokensCallback = null,
    cancelled: bool = false,
    allocator: ?std.mem.Allocator = null,

    fn request(context: *anyopaque, a: std.mem.Allocator, _: *TextModel, _: Range, callback: languages.SemanticTokensCallback) !Disposable {
        const self: *RangeProvider = @ptrCast(@alignCast(context));
        self.callback = callback;
        self.allocator = a;
        return Disposable.from(RangeProvider, self, cancel);
    }
    fn cancel(self: *RangeProvider) void {
        self.callback = null;
        self.cancelled = true;
    }
    fn complete(self: *RangeProvider, id: u32) !void {
        const callback = self.callback.?;
        self.callback = null;
        const a = self.allocator.?;
        callback.complete(callback.context, .{ .allocator = a, .id = id, .payload = .{ .full = try a.dupe(u32, &.{ 0, 0, 1, 0, 0 }) } });
    }
    fn interface(self: *RangeProvider) languages.DocumentRangeSemanticTokensProvider {
        return .{ .context = self, .legend = .{ .token_types = &.{"variable"}, .token_modifiers = &.{} }, .request_document_range_semantic_tokens = request };
    }
};

const RangeReceiver = struct {
    ready: bool = false,
    selected: ?u32 = null,
    fn complete(context: *anyopaque, request: *tokens.RangeRequest) void {
        const self: *RangeReceiver = @ptrCast(@alignCast(context));
        self.ready = true;
        if (request.selected()) |selection| self.selected = selection.result.id;
    }
};

test "Semantic tokens: range providers in the highest group run concurrently and choose in registry order" {
    const a = std.testing.allocator;
    var fixture = try TestModel.init(a, "abc", "plaintext");
    defer fixture.deinit();
    var registry = tokens.RangeRegistry.init(a);
    defer registry.deinit();
    var lower: RangeProvider = .{};
    var older: RangeProvider = .{};
    var newer: RangeProvider = .{};
    _ = try registry.register(.{ .language = "*" }, lower.interface());
    _ = try registry.register(.{ .language = "plaintext" }, older.interface());
    _ = try registry.register(.{ .language = "plaintext" }, newer.interface());
    var receiver: RangeReceiver = .{};
    const request = try tokens.RangeRequest.create(a, &registry, fixture.model, .{ .context = &receiver, .complete = RangeReceiver.complete });
    defer request.deinit();
    request.start(fixture.model, fixture.model.getFullModelRange());
    try std.testing.expect(older.callback != null and newer.callback != null and lower.callback == null);
    try older.complete(1);
    try std.testing.expect(!receiver.ready);
    try newer.complete(2);
    try std.testing.expect(receiver.ready);
    try std.testing.expectEqual(@as(?u32, 2), receiver.selected);
    try std.testing.expect(lower.callback == null);
}

test "Semantic tokens: cancellation detaches all outstanding range providers" {
    const a = std.testing.allocator;
    var fixture = try TestModel.init(a, "abc", "plaintext");
    defer fixture.deinit();
    var registry = tokens.RangeRegistry.init(a);
    defer registry.deinit();
    var older: RangeProvider = .{};
    var newer: RangeProvider = .{};
    _ = try registry.register(.{ .language = "plaintext" }, older.interface());
    _ = try registry.register(.{ .language = "plaintext" }, newer.interface());
    var receiver: RangeReceiver = .{};
    const request = try tokens.RangeRequest.create(a, &registry, fixture.model, .{ .context = &receiver, .complete = RangeReceiver.complete });
    request.start(fixture.model, fixture.model.getFullModelRange());
    request.deinit();
    try std.testing.expect(older.cancelled and newer.cancelled and !receiver.ready);
}

test "getSemanticTokens: issue #136540: semantic highlighting flickers" {
    const a = std.testing.allocator;
    const Registry = @import("../../../../common/languageFeatureRegistry.zig").LanguageFeatureRegistry(languages.DocumentSemanticTokensProvider);
    const Provider = struct {
        fn request(_: *anyopaque, _: std.mem.Allocator, _: *TextModel, _: ?u32, _: languages.SemanticTokensCallback) !Disposable {
            return error.Canceled;
        }
        fn release(_: *anyopaque, _: u32) void {}
        fn interface(self: *@This()) languages.DocumentSemanticTokensProvider {
            return .{ .context = self, .legend = .{ .token_types = &.{"test"}, .token_modifiers = &.{} }, .request_document_semantic_tokens = request, .release_document_semantic_tokens = release };
        }
    };
    const Receiver = struct {
        failure: ?anyerror = null,
        ready: bool = false,
        fn complete(context: *anyopaque, request: *tokens.FullRequest) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.ready = true;
            _ = request.takeSelected() catch |err| {
                self.failure = err;
                return;
            };
        }
    };
    var fixture = try TestModel.init(a, "example", "testLang");
    defer fixture.deinit();
    var registry = Registry.init(a);
    defer registry.deinit();
    var provider: Provider = .{};
    _ = try registry.register(.{ .language = "testLang" }, provider.interface());
    var receiver: Receiver = .{};
    const request = try tokens.FullRequest.create(a, &registry, fixture.model, .{ .context = &receiver, .complete = Receiver.complete });
    defer request.deinit();
    request.start(fixture.model, null, null);
    try std.testing.expect(receiver.ready);
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), receiver.failure);
}
