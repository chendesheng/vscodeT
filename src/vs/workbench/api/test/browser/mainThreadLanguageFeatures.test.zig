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
        if (std.mem.eql(u8, method, "$provideDefinition") or
            std.mem.eql(u8, method, "$provideDeclaration") or
            std.mem.eql(u8, method, "$provideImplementation") or
            std.mem.eql(u8, method, "$provideTypeDefinition"))
        {
            return try locationLinksJson(self.arena.allocator(), 1);
        }
        if (std.mem.eql(u8, method, "$provideReferences")) {
            return try locationsJson(self.arena.allocator());
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

    fn uriJson(arena: std.mem.Allocator, path: []const u8) !std.json.Value {
        var uri: std.json.ObjectMap = .empty;
        try uri.put(arena, "$mid", .{ .integer = 1 });
        try uri.put(arena, "scheme", .{ .string = "file" });
        try uri.put(arena, "authority", .{ .string = "" });
        try uri.put(arena, "path", .{ .string = path });
        try uri.put(arena, "query", .{ .string = "" });
        try uri.put(arena, "fragment", .{ .string = "" });
        return .{ .object = uri };
    }

    fn rangeJson(arena: std.mem.Allocator, line: usize) !std.json.Value {
        var range: std.json.ObjectMap = .empty;
        try range.put(arena, "startLineNumber", .{ .integer = @intCast(line) });
        try range.put(arena, "startColumn", .{ .integer = 1 });
        try range.put(arena, "endLineNumber", .{ .integer = @intCast(line) });
        try range.put(arena, "endColumn", .{ .integer = 2 });
        return .{ .object = range };
    }

    fn locationLinksJson(arena: std.mem.Allocator, line: usize) !std.json.Value {
        var item: std.json.ObjectMap = .empty;
        try item.put(arena, "uri", try uriJson(arena, "/tmp/fake.ts"));
        try item.put(arena, "range", try rangeJson(arena, line));
        try item.put(arena, "targetSelectionRange", try rangeJson(arena, line));
        var items = std.json.Array.init(arena);
        try items.append(.{ .object = item });
        return rpc.cloneJsonValue(arena, .{ .array = items });
    }

    fn locationsJson(arena: std.mem.Allocator) !std.json.Value {
        var items = std.json.Array.init(arena);
        for ([_]usize{ 1, 2 }) |line| {
            var item: std.json.ObjectMap = .empty;
            try item.put(arena, "uri", try uriJson(arena, "/tmp/fake.ts"));
            try item.put(arena, "range", try rangeJson(arena, line));
            try items.append(.{ .object = item });
        }
        return rpc.cloneJsonValue(arena, .{ .array = items });
    }
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

test "mainThreadLanguageFeatures: declaration, implementation and type definition conversion" {
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
    const CancellationToken = @import("../../../../base/common/cancellation.zig").CancellationToken;
    const Position = @import("../../../../editor/common/core/position.zig").Position;

    const declarations = [_]rpc.Arg{
        .{ .json = .{ .integer = 3 } },
        .{ .json = selectors },
    };
    _ = try actor.invoke("$registerDeclarationSupport", &declarations, null, arena.allocator());
    const declaration_providers = try features.declaration_provider.ordered(arena.allocator(), model.model, false);
    try std.testing.expectEqual(@as(usize, 1), declaration_providers.len);
    const declaration_links = try declaration_providers[0].provide_declaration(
        declaration_providers[0].context,
        arena.allocator(),
        model.model,
        Position.init(1, 1),
        CancellationToken.None,
    );
    try std.testing.expectEqual(@as(usize, 1), declaration_links.len);
    try std.testing.expectEqualStrings("file:///tmp/fake.ts", declaration_links[0].uri);
    try std.testing.expectEqual(@as(usize, 1), declaration_links[0].target_selection_range.startLineNumber);

    const implementations = [_]rpc.Arg{
        .{ .json = .{ .integer = 4 } },
        .{ .json = selectors },
    };
    _ = try actor.invoke("$registerImplementationSupport", &implementations, null, arena.allocator());
    const implementation_providers = try features.implementation_provider.ordered(arena.allocator(), model.model, false);
    try std.testing.expectEqual(@as(usize, 1), implementation_providers.len);

    const type_definitions = [_]rpc.Arg{
        .{ .json = .{ .integer = 5 } },
        .{ .json = selectors },
    };
    _ = try actor.invoke("$registerTypeDefinitionSupport", &type_definitions, null, arena.allocator());
    const type_providers = try features.type_definition_provider.ordered(arena.allocator(), model.model, false);
    try std.testing.expectEqual(@as(usize, 1), type_providers.len);
}

test "mainThreadLanguageFeatures: reference registration and result conversion" {
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
        .{ .json = .{ .integer = 6 } },
        .{ .json = selectors },
    };
    _ = try actor.invoke("$registerReferenceSupport", &register_args, null, arena.allocator());
    const providers = try features.reference_provider.ordered(arena.allocator(), model.model, false);
    try std.testing.expectEqual(@as(usize, 1), providers.len);
    const locations = try providers[0].provide_references(
        providers[0].context,
        arena.allocator(),
        model.model,
        @import("../../../../editor/common/core/position.zig").Position.init(1, 1),
        .{ .include_declaration = true },
        @import("../../../../base/common/cancellation.zig").CancellationToken.None,
    );
    try std.testing.expectEqual(@as(usize, 2), locations.len);
    try std.testing.expectEqualStrings("file:///tmp/fake.ts", locations[0].uri);
    try std.testing.expectEqual(@as(usize, 2), locations[1].range.startLineNumber);
}

test "mainThreadLanguageFeatures: CodeLens async provide resolve change and release" {
    const a = std.testing.allocator;
    const languages = @import("../../../../editor/common/languages.zig");
    const Disposable = @import("../../../../base/common/lifecycle.zig").IDisposable;
    const CancellationToken = @import("../../../../base/common/cancellation.zig").CancellationToken;
    const Proxy = struct {
        pending: ?rpc.ReplyCallback = null,
        last_method: []const u8 = "",
        releases: usize = 0,
        cancels: usize = 0,
        resolved_cache: i64 = -1,
        fn request(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const rpc.Arg, _: ?CancellationToken, _: u32) !std.json.Value {
            return error.MustUseAsyncRequest;
        }
        fn asyncRequest(context: *anyopaque, method: []const u8, args: []const rpc.Arg, callback: rpc.ReplyCallback) !Disposable {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.last_method = method;
            self.pending = callback;
            if (std.mem.eql(u8, method, "$resolveCodeLens")) self.resolved_cache = args[1].json.object.get("cacheId").?.array.items[0].integer;
            return .{ .context = self, .disposeFn = cancel };
        }
        fn cancel(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.pending = null;
            self.cancels += 1;
        }
        fn notify(context: *anyopaque, method: []const u8, args: []const rpc.Arg) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqualStrings("$releaseCodeLenses", method);
            try std.testing.expectEqual(31, args[0].json.integer);
            try std.testing.expectEqual(42, args[1].json.integer);
            self.releases += 1;
        }
        fn complete(self: *@This(), value: std.json.Value) void {
            const callback = self.pending.?;
            self.pending = null;
            callback.call(.{ .json = value });
        }
    };
    const Receiver = struct {
        list: ?languages.CodeLensList = null,
        resolved: ?languages.CodeLens = null,
        changes: usize = 0,
        fn provide(context: *anyopaque, list: ?languages.CodeLensList) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.list = list;
        }
        fn resolve(context: *anyopaque, lens: ?languages.CodeLens) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.resolved = lens;
        }
        fn changed(_: void, self: *@This()) !void {
            self.changes += 1;
        }
    };
    var model = try TestModel.init(a, "😀hello", "typescript");
    defer model.deinit();
    var features = LanguageFeaturesService.init(a);
    defer features.deinit();
    var proxy: Proxy = .{};
    var actor = MainThreadLanguageFeatures.init(a, &features, .{ .context = &proxy, .request = Proxy.request, .notify = Proxy.notify, .request_async = Proxy.asyncRequest });
    defer actor.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const selector = try std.json.parseFromSliceLeaky(std.json.Value, scratch, "[{\"language\":\"typescript\"}]", .{});
    _ = try actor.invoke("$registerCodeLensSupport", &.{ .{ .json = .{ .integer = 31 } }, .{ .json = selector }, .{ .json = .{ .integer = 32 } } }, null, scratch);
    const providers = try features.code_lens_provider.ordered(scratch, model.model, false);
    try std.testing.expectEqual(1, providers.len);
    const provider = providers[0];
    var receiver: Receiver = .{};
    const change_listener = try provider.on_did_change.?.listen(&receiver, Receiver.changed);
    _ = try actor.invoke("$emitCodeLensEvent", &.{.{ .json = .{ .integer = 32 } }}, null, scratch);
    try std.testing.expectEqual(1, receiver.changes);
    provider.on_did_change.?.unlisten(change_listener);
    _ = try provider.request_code_lenses.?(provider.context, scratch, model.model, .{ .context = &receiver, .complete = Receiver.provide });
    try std.testing.expectEqualStrings("$provideCodeLenses", proxy.last_method);
    try std.testing.expect(receiver.list == null);
    proxy.complete(try std.json.parseFromSliceLeaky(std.json.Value, scratch, "{\"cacheId\":42,\"lenses\":[{\"cacheId\":[42,0],\"range\":{\"startLineNumber\":1,\"startColumn\":3,\"endLineNumber\":1,\"endColumn\":4}}]}", .{}));
    const list = receiver.list.?;
    try std.testing.expectEqual(1, list.lenses.len);
    try std.testing.expectEqual(5, list.lenses[0].range.startColumn);
    _ = try provider.request_resolve_code_lens.?(provider.context, scratch, model.model, list.lenses[0], .{ .context = &receiver, .complete = Receiver.resolve });
    try std.testing.expectEqualStrings("$resolveCodeLens", proxy.last_method);
    try std.testing.expectEqual(42, proxy.resolved_cache);
    proxy.complete(try std.json.parseFromSliceLeaky(std.json.Value, scratch, "{\"cacheId\":[42,0],\"range\":{\"startLineNumber\":1,\"startColumn\":3,\"endLineNumber\":1,\"endColumn\":4},\"command\":{\"id\":\"internal.run\",\"title\":\"Run\",\"arguments\":[7]}}", .{}));
    try std.testing.expectEqualStrings("internal.run", receiver.resolved.?.command.?.id);
    try std.testing.expectEqual(7, receiver.resolved.?.command.?.arguments.?.array.items[0].integer);
    list.disposable.?.dispose();
    try std.testing.expectEqual(1, proxy.releases);
    const pending = (try provider.request_code_lenses.?(provider.context, scratch, model.model, .{ .context = &receiver, .complete = Receiver.provide })).?;
    pending.dispose();
    try std.testing.expectEqual(1, proxy.cancels);
    _ = try actor.invoke("$unregister", &.{.{ .json = .{ .integer = 31 } }}, null, scratch);
    try std.testing.expect(!features.code_lens_provider.has(model.model));
}
