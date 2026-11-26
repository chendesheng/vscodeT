// Port of `src/vs/platform/accessibility/browser/accessibleViewRegistry.ts`.
// Explicit, window-owned registration replaces the module singleton.
const std = @import("std");
const api = @import("accessibleView.zig");
const contextkey = @import("../../contextkey/common/contextkey.zig");
const ServicesAccessor = @import("../../instantiation/common/instantiation.zig").ServicesAccessor;

pub const IAccessibleViewImplementation = struct {
    kind: api.AccessibleViewType,
    priority: i32,
    name: []const u8,
    when: ?*const contextkey.Expr = null,
    get_provider: *const fn (std.mem.Allocator, ServicesAccessor) anyerror!?api.AccessibleContentProvider,
};

pub const AccessibleViewRegistry = struct {
    allocator: std.mem.Allocator,
    implementations: std.ArrayList(IAccessibleViewImplementation) = .empty,

    pub fn init(allocator: std.mem.Allocator) AccessibleViewRegistry {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *AccessibleViewRegistry) void {
        self.implementations.deinit(self.allocator);
    }
    pub fn register(self: *AccessibleViewRegistry, implementation: IAccessibleViewImplementation) !void {
        try self.implementations.append(self.allocator, implementation);
        std.mem.sort(IAccessibleViewImplementation, self.implementations.items, {}, struct {
            fn lt(_: void, a: IAccessibleViewImplementation, b: IAccessibleViewImplementation) bool {
                return a.priority > b.priority;
            }
        }.lt);
    }
    pub fn getProvider(self: *AccessibleViewRegistry, kind: api.AccessibleViewType, context: contextkey.IContext, accessor: ServicesAccessor) !?api.AccessibleContentProvider {
        for (self.implementations.items) |implementation| {
            if (implementation.kind != kind) continue;
            if (implementation.when) |expression| if (!expression.evaluate(context)) continue;
            if (try implementation.get_provider(self.allocator, accessor)) |provider| return provider;
        }
        return null;
    }
};
