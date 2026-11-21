// Port of the portable view-container location state in
// `src/vs/workbench/services/views/browser/viewDescriptorService.ts`.
//
// The browser service also owns view descriptors, generated containers,
// context-key scopes and profile storage. The terminal service keeps the
// container registry, the per-container location overrides, the default
// location lookup and the change events used by the side bar and panel parts.
//
// Terminal adaptation: customizations live in memory. The port has no profile
// storage service in the workbench shell yet, so a moved container resets on
// restart (upstream persists the same map under `views.customizations`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const views = @import("../../../common/views.zig");

pub const ViewContainerLocation = views.ViewContainerLocation;
pub const ViewContainer = views.ViewContainer;
pub const ViewContainersRegistry = views.ViewContainersRegistry;

pub const ContainersChange = struct {
    added: []const *const ViewContainer = &.{},
    removed: []const *const ViewContainer = &.{},
};

pub const ContainerLocationChange = struct {
    container: *const ViewContainer,
    from: ViewContainerLocation,
    to: ViewContainerLocation,
};

/// Port of `IViewDescriptorService` for the portable container surface.
pub const ViewDescriptorService = struct {
    allocator: Allocator,
    registry: *ViewContainersRegistry,
    /// Container id -> location override, mirroring
    /// `viewContainersCustomLocations`.
    custom_locations: std.StringHashMapUnmanaged(ViewContainerLocation) = .{},
    on_did_change_view_containers: Emitter(ContainersChange),
    on_did_change_container_location: Emitter(ContainerLocationChange),
    register_listener: ?Emitter(views.ContainerRegistration).ListenerId = null,
    deregister_listener: ?Emitter(views.ContainerRegistration).ListenerId = null,

    pub fn init(allocator: Allocator, registry: *ViewContainersRegistry) ViewDescriptorService {
        return .{
            .allocator = allocator,
            .registry = registry,
            .on_did_change_view_containers = Emitter(ContainersChange).init(allocator),
            .on_did_change_container_location = Emitter(ContainerLocationChange).init(allocator),
        };
    }

    /// Relays registry registrations to `onDidChangeViewContainers`. The
    /// browser service subscribes in its constructor; the TUI keeps the
    /// service by value, so the workbench calls this after the field settles.
    pub fn attach(self: *ViewDescriptorService) !void {
        if (self.register_listener != null) return;
        self.register_listener = try self.registry.on_did_register.listen(self, onContainerRegistered);
        errdefer {
            if (self.register_listener) |listener| self.registry.on_did_register.unlisten(listener);
            self.register_listener = null;
        }
        self.deregister_listener = try self.registry.on_did_deregister.listen(self, onContainerDeregistered);
    }

    fn onContainerRegistered(registration: views.ContainerRegistration, self: *ViewDescriptorService) !void {
        const added = [_]*const ViewContainer{registration.container};
        try self.on_did_change_view_containers.fire(.{ .added = &added });
    }

    fn onContainerDeregistered(registration: views.ContainerRegistration, self: *ViewDescriptorService) !void {
        const removed = [_]*const ViewContainer{registration.container};
        try self.on_did_change_view_containers.fire(.{ .removed = &removed });
    }

    pub fn deinit(self: *ViewDescriptorService) void {
        if (self.register_listener) |listener| self.registry.on_did_register.unlisten(listener);
        if (self.deregister_listener) |listener| self.registry.on_did_deregister.unlisten(listener);
        self.register_listener = null;
        self.deregister_listener = null;
        self.custom_locations.deinit(self.allocator);
        self.on_did_change_view_containers.deinit();
        self.on_did_change_container_location.deinit();
    }

    pub fn getViewContainerById(self: *const ViewDescriptorService, id: []const u8) ?*const ViewContainer {
        return self.registry.get(id);
    }

    pub fn getViewContainerLocationById(self: *const ViewDescriptorService, id: []const u8) ?ViewContainerLocation {
        const container = self.registry.get(id) orelse return null;
        return self.getViewContainerLocation(container);
    }

    /// Custom location wins over the registry default.
    pub fn getViewContainerLocation(self: *const ViewDescriptorService, container: *const ViewContainer) ViewContainerLocation {
        return self.custom_locations.get(container.id) orelse container.location;
    }

    pub fn getDefaultViewContainerLocation(self: *const ViewDescriptorService, container: *const ViewContainer) ViewContainerLocation {
        return self.registry.getViewContainerLocation(container.id) orelse container.location;
    }

    /// First container at `location` registered with `isDefault`, like
    /// upstream `getDefaultViewContainer`.
    pub fn getDefaultViewContainer(self: *const ViewDescriptorService, location: ViewContainerLocation) ?*const ViewContainer {
        for (self.registry.containers.items) |container| {
            if (!container.is_default) continue;
            if (self.getViewContainerLocation(container) == location) return container;
        }
        return null;
    }

    /// Containers currently located at `location`, in registration order.
    pub fn getViewContainersByLocation(self: *const ViewDescriptorService, location: ViewContainerLocation, allocator: Allocator) ![]*const ViewContainer {
        var result = std.array_list.Managed(*const ViewContainer).init(allocator);
        errdefer result.deinit();
        for (self.registry.containers.items) |container| {
            if (self.getViewContainerLocation(container) == location) try result.append(container);
        }
        return result.toOwnedSlice();
    }

    /// Moves a container between locations. Returns false when the container
    /// is unknown or already at `location`; upstream logs and rewrites the
    /// stored customization in that case.
    pub fn moveViewContainerToLocation(
        self: *ViewDescriptorService,
        container: *const ViewContainer,
        location: ViewContainerLocation,
    ) !bool {
        const from = self.getViewContainerLocation(container);
        if (from == location) return false;
        try self.custom_locations.put(self.allocator, container.id, location);
        try self.on_did_change_container_location.fire(.{
            .container = container,
            .from = from,
            .to = location,
        });
        return true;
    }

    /// Resets every container to its default location.
    pub fn reset(self: *ViewDescriptorService) !void {
        var iterator = self.custom_locations.iterator();
        while (iterator.next()) |entry| {
            const container = self.registry.get(entry.key_ptr.*) orelse continue;
            try self.on_did_change_container_location.fire(.{
                .container = container,
                .from = entry.value_ptr.*,
                .to = container.location,
            });
        }
        self.custom_locations.clearRetainingCapacity();
    }

    pub fn hasCustomLocations(self: *const ViewDescriptorService) bool {
        return self.custom_locations.count() > 0;
    }
};

test "viewDescriptorService: default and custom locations" {
    const allocator = std.testing.allocator;
    var registry = ViewContainersRegistry.init(allocator);
    defer registry.deinit();
    var service = ViewDescriptorService.init(allocator, &registry);
    defer service.deinit();
    try service.attach();

    var container_events: usize = 0;
    const ContainerListener = struct {
        fn onChange(_: ContainersChange, ctx: *usize) anyerror!void {
            ctx.* += 1;
        }
    };
    _ = try service.on_did_change_view_containers.listen(&container_events, ContainerListener.onChange);

    const terminal = try registry.register(.{
        .id = "terminal",
        .title = "Terminal",
        .glyph = '>',
        .hide_if_empty = true,
        .order = 3,
    }, .panel, .{ .is_default = true });
    const problems = try registry.register(.{
        .id = "workbench.panel.markers",
        .title = "Problems",
        .glyph = '!',
        .hide_if_empty = true,
        .order = 0,
    }, .panel, .{});
    const explorer = try registry.register(.{
        .id = "workbench.view.explorer",
        .title = "Explorer",
        .glyph = 'E',
        .order = 0,
    }, .sidebar, .{ .is_default = true });

    try std.testing.expectEqual(@as(usize, 3), container_events);
    try std.testing.expectEqual(ViewContainerLocation.panel, service.getViewContainerLocation(problems));
    try std.testing.expectEqual(ViewContainerLocation.sidebar, service.getViewContainerLocation(explorer));
    const default_panel = service.getDefaultViewContainer(.panel) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(terminal.id, default_panel.id);

    var changes: usize = 0;
    const Listener = struct {
        fn onChange(_: ContainerLocationChange, ctx: *usize) anyerror!void {
            ctx.* += 1;
        }
    };
    _ = try service.on_did_change_container_location.listen(&changes, Listener.onChange);

    try std.testing.expect(try service.moveViewContainerToLocation(problems, .sidebar));
    try std.testing.expectEqual(@as(usize, 1), changes);
    try std.testing.expectEqual(ViewContainerLocation.sidebar, service.getViewContainerLocation(problems));
    try std.testing.expect(!try service.moveViewContainerToLocation(problems, .sidebar));

    const sidebar_containers = try service.getViewContainersByLocation(.sidebar, allocator);
    defer allocator.free(sidebar_containers);
    try std.testing.expectEqual(@as(usize, 2), sidebar_containers.len);
    try std.testing.expectEqualStrings(problems.id, sidebar_containers[0].id);
    try std.testing.expectEqualStrings(explorer.id, sidebar_containers[1].id);

    try service.reset();
    try std.testing.expectEqual(@as(usize, 2), changes);
    try std.testing.expectEqual(ViewContainerLocation.panel, service.getViewContainerLocation(problems));
    try std.testing.expect(!service.hasCustomLocations());
}
