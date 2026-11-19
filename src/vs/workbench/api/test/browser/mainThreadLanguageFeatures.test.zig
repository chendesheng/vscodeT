// Focused tests for the baseline `MainThreadLanguageFeatures` actor.
// Upstream covers this through `extHostLanguageFeatures.test.ts`; the Zig
// host side is reused, so these tests use a fake ExtHost proxy.

const std = @import("std");
const rpc = @import("../../../services/extensions/common/rpcProtocol.zig");
const actor_mod = @import("../../browser/mainThreadLanguageFeatures.zig");
const MainThreadLanguageFeatures = actor_mod.MainThreadLanguageFeatures;
const LanguageFeaturesService = @import("../../../../editor/common/services/languageFeaturesService.zig").LanguageFeaturesService;
const TestModel = @import("../../../../editor/test/common/port/testSupport.zig").TestModel;

const Fake = struct {
    request_calls: usize = 0,
    arena: std.heap.ArenaAllocator,

    fn request(context: *anyopaque, allocator: std.mem.Allocator, method: []const u8, args: []const rpc.Arg, token: ?@import("../../../../base/common/cancellation.zig").CancellationToken, timeout_ms: u32) anyerror!std.json.Value {
        _ = allocator;
        _ = args;
        _ = token;
        _ = timeout_ms;
        const self: *Fake = @ptrCast(@alignCast(context));
        self.request_calls += 1;
        if (std.mem.eql(u8, method, "$provideHover")) {
            var object: std.json.ObjectMap = .empty;
            try object.put(self.arena.allocator(), "id", .{ .integer = 1 });
            try object.put(self.arena.allocator(), "contents", .{ .string = "fake hover" });
            var range: std.json.ObjectMap = .empty;
            try range.put(self.arena.allocator(), "startLineNumber", .{ .integer = 1 });
            try range.put(self.arena.allocator(), "startColumn", .{ .integer = 1 });
            try range.put(self.arena.allocator(), "endLineNumber", .{ .integer = 1 });
            try range.put(self.arena.allocator(), "endColumn", .{ .integer = 2 });
            try object.put(self.arena.allocator(), "range", .{ .object = range });
            return rpc.cloneJsonValue(self.arena.allocator(), .{ .object = object });
        }
        if (std.mem.eql(u8, method, "$provideCompletionItems")) {
            var item: std.json.ObjectMap = .empty;
            try item.put(self.arena.allocator(), "a", .{ .string = "fake" });
            try item.put(self.arena.allocator(), "h", .{ .string = "fake" });
            var items = std.json.Array.init(self.arena.allocator());
            try items.append(.{ .object = item });
            var object: std.json.ObjectMap = .empty;
            try object.put(self.arena.allocator(), "b", .{ .array = items });
            try object.put(self.arena.allocator(), "c", .{ .bool = false });
            return rpc.cloneJsonValue(self.arena.allocator(), .{ .object = object });
        }
        return .null;
    }

    fn notify(_: *anyopaque, _: []const u8, _: []const rpc.Arg) anyerror!void {}
};

test "mainThreadLanguageFeatures: hover registration and provider call" {
    const allocator = std.testing.allocator;
    var model = try TestModel.init(allocator, "hello", "typescript");
    defer model.deinit();
    var features = LanguageFeaturesService.init(allocator);
    defer features.deinit();
    var fake = Fake{ .arena = std.heap.ArenaAllocator.init(allocator) };
    defer fake.arena.deinit();
    var actor = MainThreadLanguageFeatures.init(allocator, &features, .{
        .context = &fake,
        .request = Fake.request,
        .notify = Fake.notify,
    });
    defer actor.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const selectors = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "[{\"language\":\"typescript\"}]", .{});
    const register_args = [_]rpc.Arg{
        .{ .json = .{ .integer = 1 } },
        .{ .json = selectors },
    };
    _ = try actor.invoke("$registerHoverProvider", &register_args, null, arena.allocator());

    const providers = try features.hover_provider.ordered(arena.allocator(), model.model, false);
    try std.testing.expectEqual(@as(usize, 1), providers.len);
    const hover = try providers[0].provide_hover(providers[0].context, model.model, @import("../../../../editor/common/core/position.zig").Position.init(1, 1), @import("../../../../base/common/cancellation.zig").CancellationToken.None, null);
    try std.testing.expect(hover != null);
    try std.testing.expectEqualStrings("fake hover", hover.?.contents[0].value);

    _ = try actor.invoke("$unregister", &.{.{ .json = .{ .integer = 1 } }}, null, arena.allocator());
    try std.testing.expect(!features.hover_provider.has(model.model));
}

test "mainThreadLanguageFeatures: completion registration and result conversion" {
    const allocator = std.testing.allocator;
    var model = try TestModel.init(allocator, "hello", "typescript");
    defer model.deinit();
    var features = LanguageFeaturesService.init(allocator);
    defer features.deinit();
    var fake = Fake{ .arena = std.heap.ArenaAllocator.init(allocator) };
    defer fake.arena.deinit();
    var actor = MainThreadLanguageFeatures.init(allocator, &features, .{
        .context = &fake,
        .request = Fake.request,
        .notify = Fake.notify,
    });
    defer actor.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const selectors = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "[{\"language\":\"*\"}]", .{});
    const register_args = [_]rpc.Arg{
        .{ .json = .{ .integer = 2 } },
        .{ .json = selectors },
        .{ .json = .{ .array = std.json.Array.init(arena.allocator()) } },
        .{ .json = .{ .bool = false } },
        .{ .json = .{ .object = .empty } },
    };
    _ = try actor.invoke("$registerCompletionsProvider", &register_args, null, arena.allocator());
    const providers = try features.completion_provider.ordered(arena.allocator(), model.model, false);
    try std.testing.expectEqual(@as(usize, 1), providers.len);
    const list = try providers[0].provide_completion_items(
        providers[0].context,
        arena.allocator(),
        model.model,
        @import("../../../../editor/common/core/position.zig").Position.init(1, 1),
        .{},
        @import("../../../../base/common/cancellation.zig").CancellationToken.None,
    );
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqualStrings("fake", list.items[0].label);
}
