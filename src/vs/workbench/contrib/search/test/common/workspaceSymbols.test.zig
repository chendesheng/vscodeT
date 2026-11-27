// Regression tests for WorkspaceSymbolProviderRegistry and getWorkspaceSymbols
// from `src/vs/workbench/contrib/search/common/search.ts`.
const std = @import("std");
const search = @import("../../common/search.zig");
const IDisposable = @import("../../../../../base/common/lifecycle.zig").IDisposable;

const Provider = struct {
    callback: ?search.WorkspaceSymbolsCallback = null,
    canceled: bool = false,

    fn provide(context: *anyopaque, _: std.mem.Allocator, query: []const u8, callback: search.WorkspaceSymbolsCallback) !IDisposable {
        const self: *Provider = @ptrCast(@alignCast(context));
        try std.testing.expectEqualStrings("symbol", query);
        self.callback = callback;
        return .{ .context = self, .disposeFn = cancel };
    }

    fn cancel(context: *anyopaque) void {
        const self: *Provider = @ptrCast(@alignCast(context));
        self.canceled = true;
        self.callback = null;
    }

    fn reply(self: *Provider, result: anyerror![]const search.IWorkspaceSymbol) void {
        const callback = self.callback.?;
        self.callback = null;
        callback.complete(callback.context, result);
    }
};

test "workspace symbols merge providers, isolate failures, and deduplicate" {
    var registry = search.WorkspaceSymbolProviderRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var first = Provider{};
    var second = Provider{};
    var failed = Provider{};
    const a = try registry.register(.{ .context = &first, .provide = Provider.provide });
    defer a.dispose();
    const b = try registry.register(.{ .context = &second, .provide = Provider.provide });
    defer b.dispose();
    const c = try registry.register(.{ .context = &failed, .provide = Provider.provide });
    defer c.dispose();
    const Receiver = struct {
        called: bool = false,
        count: usize = 0,
        fn ready(context: *anyopaque, items: []const search.WorkspaceSymbolItem) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.called = true;
            self.count = items.len;
        }
    };
    var receiver = Receiver{};
    const request = try search.WorkspaceSymbolsRequest.init(std.testing.allocator, .{ .context = &receiver, .complete = Receiver.ready });
    defer request.deinit();
    try request.getWorkspaceSymbols(&registry, "symbol");
    const symbol: search.IWorkspaceSymbol = .{ .name = "symbol", .kind = 11, .resource = "file:///sample.zig", .range = .init(1, 1, 1, 7) };
    second.reply(&.{symbol});
    try std.testing.expect(!receiver.called);
    failed.reply(error.Failed);
    first.reply(&.{symbol});
    try std.testing.expect(receiver.called);
    try std.testing.expectEqual(@as(usize, 1), receiver.count);
}

test "workspace symbols cancel each pending provider before releasing results" {
    var registry = search.WorkspaceSymbolProviderRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var provider = Provider{};
    const registration = try registry.register(.{ .context = &provider, .provide = Provider.provide });
    defer registration.dispose();
    const request = try search.WorkspaceSymbolsRequest.init(std.testing.allocator, .{ .context = &provider, .complete = struct {
        fn ready(_: *anyopaque, _: []const search.WorkspaceSymbolItem) void {
            @panic("Cancelled request completed");
        }
    }.ready });
    try request.getWorkspaceSymbols(&registry, "symbol");
    try std.testing.expect(provider.callback != null);
    request.deinit();
    try std.testing.expect(provider.canceled);
    try std.testing.expect(provider.callback == null);
}
