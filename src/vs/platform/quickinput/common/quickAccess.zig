// Portable subset of `src/vs/platform/quickinput/common/quickAccess.ts`.
//
// The registry maps a typed prefix to a provider. Upstream descriptors carry
// a constructor and context-key `when` expressions resolved through the
// instantiation service; the TUI has neither, so providers are registered as
// live instances and context keys are not ported.
//
// Upstream `provide()` registers listeners on the picker and returns a
// disposable. The TUI keeps one persistent picker, so the host calls
// `refresh()`/`accept()` directly and providers return no disposable; a
// per-showing cancellation token still bounds stale work.

const std = @import("std");
const cancellation = @import("../../../base/common/cancellation.zig");
const CancellationToken = cancellation.CancellationToken;
const quick_input = @import("quickInput.zig");
const QuickPick = @import("../browser/quickInput.zig").QuickPick;

pub const Provider = struct {
    context: *anyopaque,
    prefix: []const u8,
    placeholder: []const u8 = "",

    provide: *const fn (
        context: *anyopaque,
        picker: *QuickPick,
        token: CancellationToken,
    ) anyerror!void,
    refresh: *const fn (context: *anyopaque, picker: *QuickPick) anyerror!void,
    accept: *const fn (context: *anyopaque, picker: *QuickPick) anyerror!void,
    dispose: ?*const fn (context: *anyopaque) void = null,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    providers: std.array_list.Managed(Provider),
    default_provider: ?Provider = null,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .allocator = allocator,
            .providers = std.array_list.Managed(Provider).init(allocator),
        };
    }

    pub fn deinit(self: *Registry) void {
        if (self.default_provider) |provider| {
            if (provider.dispose) |dispose| dispose(provider.context);
        }
        for (self.providers.items) |provider| {
            if (provider.dispose) |dispose| dispose(provider.context);
        }
        self.providers.deinit();
    }

    pub fn register(self: *Registry, provider: Provider) !void {
        if (provider.prefix.len == 0) {
            if (self.default_provider) |existing| {
                if (existing.dispose) |dispose| dispose(existing.context);
            }
            self.default_provider = provider;
            return;
        }
        try self.providers.append(provider);
        // Longest prefix wins, so `ext install` beats `ext`.
        std.mem.sort(Provider, self.providers.items, {}, struct {
            fn lessThan(_: void, a: Provider, b: Provider) bool {
                return a.prefix.len > b.prefix.len;
            }
        }.lessThan);
    }

    /// Resolves the provider for the value being typed. An empty or unmatched
    /// value falls back to the default provider.
    pub fn get(self: *const Registry, value: []const u8) ?Provider {
        if (value.len > 0) {
            for (self.providers.items) |provider| {
                if (std.mem.startsWith(u8, value, provider.prefix)) return provider;
            }
        }
        return self.default_provider;
    }
};

test "quickAccess: registry uses longest prefix and default fallback" {
    const Dummy = struct {
        fn provide(_: *anyopaque, _: *QuickPick, _: CancellationToken) anyerror!void {}
        fn refresh(_: *anyopaque, _: *QuickPick) anyerror!void {}
        fn accept(_: *anyopaque, _: *QuickPick) anyerror!void {}
    };

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const default = Provider{
        .context = undefined,
        .prefix = "",
        .provide = Dummy.provide,
        .refresh = Dummy.refresh,
        .accept = Dummy.accept,
    };
    const short = Provider{
        .context = undefined,
        .prefix = "ext",
        .provide = Dummy.provide,
        .refresh = Dummy.refresh,
        .accept = Dummy.accept,
    };
    const long = Provider{
        .context = undefined,
        .prefix = "ext install",
        .provide = Dummy.provide,
        .refresh = Dummy.refresh,
        .accept = Dummy.accept,
    };

    try registry.register(short);
    try registry.register(long);
    try registry.register(default);

    try std.testing.expectEqualStrings("", registry.get("anything").?.prefix);
    try std.testing.expectEqualStrings("ext", registry.get("ext").?.prefix);
    try std.testing.expectEqualStrings("ext install", registry.get("ext install foo").?.prefix);
}
