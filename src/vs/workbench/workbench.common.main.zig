// Port of the shared contribution registrations in `src/vs/workbench/workbench.common.main.ts`.
// Each Zig window owns its registries and delayed singleton instances.
const std = @import("std");
const ServiceCollection = @import("../platform/instantiation/common/serviceCollection.zig").ServiceCollection;
const MenuRegistry = @import("../platform/actions/common/actions.zig").MenuRegistry;

pub fn createServices(allocator: std.mem.Allocator) !ServiceCollection {
    var services = ServiceCollection.init(allocator);
    errdefer services.deinit();
    try @import("../editor/contrib/documentSymbols/browser/outlineModel.zig").registerSingleton(&services);
    return services;
}

pub fn registerMenus(menus: *MenuRegistry) !void {
    try @import("contrib/scm/browser/scmViewPane.zig").registerMenus(menus);
    try @import("contrib/scm/browser/scmHistoryViewPane.zig").registerMenus(menus);
    try @import("contrib/outline/browser/outlineActions.zig").registerMenus(menus);
}
