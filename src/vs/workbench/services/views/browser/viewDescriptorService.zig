// Port of the portable view-container location state in
// `src/vs/workbench/services/views/browser/viewDescriptorService.ts`.
//
// The terminal service consumes registered views and containers, owns their
// model registrations, availability changes, default locations and custom
// moves. Generated containers and full view-scoped context keys are unported.
// Workspace view state is persisted by ViewDescriptorsState; container
// location overrides are not yet persisted in the profile
// `views.customizations` key.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const views = @import("../../../common/views.zig");

const ViewContainerModel = @import("../common/viewContainerModel.zig").ViewContainerModel;
pub const ViewContainerChange = struct { views: []const []const u8, from: *ViewContainerModel, to: *ViewContainerModel };

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
    views_registry: ?*views.ViewsRegistry = null,
    views_registered: ?@import("../../../../base/common/event.zig").SignalSubscription = null,
    views_deregistered: ?@import("../../../../base/common/event.zig").SignalSubscription = null,
    models: std.StringHashMapUnmanaged(*ViewContainerModel) = .empty,
    on_did_change_container: Emitter(ViewContainerChange),
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
            .on_did_change_container = .init(allocator),
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
        errdefer {
            if (self.deregister_listener) |listener| self.registry.on_did_deregister.unlisten(listener);
            self.deregister_listener = null;
        }
        if (self.views_registry) |registry| {
            self.views_registered = try registry.on_views_registered.listenDisposable(self, onViewsRegistered);
            errdefer {
                self.views_registered.?.dispose();
                self.views_registered = null;
            }
            self.views_deregistered = try registry.on_views_deregistered.listenDisposable(self, onViewsDeregistered);
        }
    }

    fn onContainerRegistered(registration: views.ContainerRegistration, self: *ViewDescriptorService) !void {
        const added = [_]*const ViewContainer{registration.container};
        try self.on_did_change_view_containers.fire(.{ .added = &added });
    }

    fn onContainerDeregistered(registration: views.ContainerRegistration, self: *ViewDescriptorService) !void {
        const removed = [_]*const ViewContainer{registration.container};
        try self.on_did_change_view_containers.fire(.{ .removed = &removed });
    }

    fn descriptorInContainer(model: *ViewContainerModel, descriptor: views.ViewDescriptor, owner: []const u8) views.ViewDescriptor {
        var result = descriptor;
        // The terminal model retains templates for movable views so a move
        // between native containers can preserve its state without DOM reparenting.
        result.in_container = std.mem.eql(u8, model.container.id, owner);
        return result;
    }

    fn onViewsRegistered(registration: views.ViewRegistration, self: *ViewDescriptorService) !void {
        var models = self.models.valueIterator();
        while (models.next()) |model| {
            for (registration.views) |descriptor| try model.*.addView(descriptorInContainer(model.*, descriptor, registration.container_id));
        }
    }

    fn onViewsDeregistered(registration: views.ViewRegistration, self: *ViewDescriptorService) !void {
        var models = self.models.valueIterator();
        while (models.next()) |model| for (registration.views) |descriptor| model.*.removeView(descriptor.id);
    }

    fn populateModel(self: *ViewDescriptorService, model: *ViewContainerModel) !void {
        const registry = self.views_registry orelse return;
        for (registry.entries.items) |entry| try model.addView(descriptorInContainer(model, entry.descriptor, entry.container_id));
    }

    /// Workspace storage loads view state on top of these default registrations.
    pub fn resetRegisteredModels(self: *ViewDescriptorService) !void {
        var models = self.models.valueIterator();
        while (models.next()) |model| try self.populateModel(model.*);
    }

    /// The existing native provider checks adapt the upstream when expressions.
    /// Deliver active/visible descriptor changes to mounted containers immediately.
    pub fn setViewAvailable(self: *ViewDescriptorService, id: []const u8, available: bool) void {
        const registry = self.views_registry orelse return;
        for (registry.entries.items) |*entry| {
            if (!std.mem.eql(u8, entry.descriptor.id, id)) continue;
            entry.descriptor.available = available;
            break;
        }
        var models = self.models.valueIterator();
        while (models.next()) |model| model.*.setAvailable(id, available);
    }

    pub fn registerViewContainerModel(self: *ViewDescriptorService, model: *ViewContainerModel) !void {
        try self.populateModel(model);
        try self.models.putNoClobber(self.allocator, model.container.id, model);
    }

    pub fn unregisterViewContainerModel(self: *ViewDescriptorService, model: *ViewContainerModel) void {
        _ = self.models.remove(model.container.id);
    }

    pub fn getViewContainerByViewId(self: *ViewDescriptorService, id: []const u8) ?*ViewContainerModel {
        var models = self.models.valueIterator();
        while (models.next()) |model| if (model.*.contains(id)) return model.*;
        return null;
    }

    pub fn moveViewsToContainer(self: *ViewDescriptorService, ids: []const []const u8, destination: *ViewContainerModel) bool {
        if (ids.len == 0) return false;
        const source = self.getViewContainerByViewId(ids[0]) orelse return false;
        for (ids) |id| if (!source.canMoveTo(id, destination)) return false;
        for (ids) |id| _ = source.moveTo(id, destination);
        self.on_did_change_container.fire(.{ .views = ids, .from = source, .to = destination }) catch {};
        return true;
    }

    pub fn deinit(self: *ViewDescriptorService) void {
        if (self.views_registered) |listener| listener.dispose();
        if (self.views_deregistered) |listener| listener.dispose();
        self.models.deinit(self.allocator);
        self.on_did_change_container.deinit();
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
        .glyph = '\u{f07b}',
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

test "moveViewsToContainer updates all view memberships before firing onDidChangeContainer" {
    const allocator = std.testing.allocator;
    var registry = ViewContainersRegistry.init(allocator);
    defer registry.deinit();
    var service = ViewDescriptorService.init(allocator, &registry);
    defer service.deinit();
    var source = ViewContainerModel.init(allocator, .{ .id = "source", .title = "Source", .icon = "" });
    defer source.deinit();
    var destination = ViewContainerModel.init(allocator, .{ .id = "destination", .title = "Destination", .icon = "" });
    defer destination.deinit();
    const ids = [_][]const u8{ "one", "two" };
    for (ids) |id| {
        try source.addView(.{ .id = id, .name = id });
        try destination.addView(.{ .id = id, .name = id, .in_container = false });
    }
    try service.registerViewContainerModel(&source);
    try service.registerViewContainerModel(&destination);
    var events: usize = 0;
    const Listener = struct {
        fn changed(event: ViewContainerChange, count: *usize) !void {
            try std.testing.expectEqual(@as(usize, 2), event.views.len);
            for (event.views) |id| {
                try std.testing.expect(!event.from.contains(id));
                try std.testing.expect(event.to.contains(id));
            }
            count.* += 1;
        }
    };
    _ = try service.on_did_change_container.listen(&events, Listener.changed);
    try std.testing.expect(!service.moveViewsToContainer(&.{ "one", "missing" }, &destination));
    try std.testing.expect(source.contains("one"));
    try std.testing.expect(service.moveViewsToContainer(&ids, &destination));
    try std.testing.expect(!service.moveViewsToContainer(&ids, &destination));
    try std.testing.expectEqual(&destination, service.getViewContainerByViewId("one").?);
    try std.testing.expectEqual(@as(usize, 1), events);
}
