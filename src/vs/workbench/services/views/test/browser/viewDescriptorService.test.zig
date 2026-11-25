// Terminal registration/descriptor state coverage for
// src/vs/workbench/services/views/test/browser/viewDescriptorService.test.ts.
// Native cell panes retain templates for movable views; extension-generated
// containers and profile-level container location storage remain unported.
const std = @import("std");
const views = @import("../../../../common/views.zig");
const ViewDescriptorService = @import("../../browser/viewDescriptorService.zig").ViewDescriptorService;
const ViewContainerModel = @import("../../common/viewContainerModel.zig").ViewContainerModel;

test "ViewDescriptorService: registry registrations, visibility and default location" {
    const allocator = std.testing.allocator;
    var containers = views.ViewContainersRegistry.init(allocator);
    defer containers.deinit();
    var registry = views.ViewsRegistry.init(allocator);
    defer registry.deinit();
    _ = try containers.register(.{ .id = "a", .title = "A" }, .sidebar, .{});
    _ = try containers.register(.{ .id = "b", .title = "B" }, .sidebar, .{});
    var service = ViewDescriptorService.init(allocator, &containers);
    defer service.deinit();
    service.views_registry = &registry;
    try service.attach();
    var first = ViewContainerModel.init(allocator, .{ .id = "a", .title = "A", .icon = "" });
    defer first.deinit();
    var second = ViewContainerModel.init(allocator, .{ .id = "b", .title = "B", .icon = "" });
    defer second.deinit();
    try service.registerViewContainerModel(&first);
    defer service.unregisterViewContainerModel(&first);
    try service.registerViewContainerModel(&second);
    defer service.unregisterViewContainerModel(&second);
    const descriptors: []const views.ViewDescriptor = &.{
        .{ .id = "moving", .name = "Moving", .order = 1 },
        .{ .id = "conditional", .name = "Conditional", .order = 2, .available = false },
    };
    try registry.registerViews(descriptors, "a");
    try std.testing.expectError(error.AlreadyRegistered, registry.registerViews(descriptors, "b"));
    try std.testing.expectEqual(&first, service.getViewContainerByViewId("moving").?);
    try std.testing.expect(!second.contains("moving"));
    try std.testing.expect(!first.isVisible("conditional"));
    const Probe = struct {
        fn changed(_: void, count: *usize) !void {
            count.* += 1;
        }
    };
    var additions: usize = 0;
    const listener = try first.on_did_add_visible_view_descriptors.listenDisposable(&additions, Probe.changed);
    defer listener.dispose();
    service.setViewAvailable("conditional", true);
    try std.testing.expect(first.isVisible("conditional"));
    try std.testing.expectEqual(@as(usize, 1), additions);
    try std.testing.expect(service.moveViewsToContainer(&.{"moving"}, &second));
    try std.testing.expectEqual(&second, service.getViewContainerByViewId("moving").?);
    try std.testing.expectEqualStrings("a", registry.getViewContainer("moving").?);
    try service.resetRegisteredModels();
    try std.testing.expectEqual(&first, service.getViewContainerByViewId("moving").?);
    try std.testing.expect(first.isVisible("conditional"));
    const default_views = try registry.getViews("a", allocator);
    defer allocator.free(default_views);
    try std.testing.expectEqual(@as(usize, 2), default_views.len);
    try registry.deregisterViews(&.{"conditional"}, "a");
    try std.testing.expect(registry.getView("conditional") == null);
    try std.testing.expect(!first.contains("conditional"));
    try std.testing.expect(!second.contains("conditional"));
}
