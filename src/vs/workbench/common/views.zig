// Port of the portable view-container registry in
// `src/vs/workbench/common/views.ts`.
//
// The registries retain named view and container descriptors, locations and
// registration events. Explicit terminal factories mount their portable views;
// extension-generated containers and view welcome-content registration are
// still unported.
//
// Terminal adaptation: container icons are single-cell glyphs instead of
// theme icons, and open commands are registered by the workbench command
// registry rather than by the view-container registry.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../base/common/event.zig").Emitter;

/// Upstream `ViewContainerLocation`. The numeric values match so persisted
/// layout state keeps the same meaning.
pub const ViewContainerLocation = enum(u2) {
    sidebar = 0,
    panel = 1,
    auxiliary_bar = 2,
};

pub fn viewContainerLocationToString(location: ViewContainerLocation) []const u8 {
    return switch (location) {
        .sidebar => "sidebar",
        .panel => "panel",
        .auxiliary_bar => "auxiliarybar",
    };
}

/// A registered view container. `location`, `is_default` and
/// `do_not_register_open_command` are filled in by the registry.
pub const ViewContainer = struct {
    id: []const u8,
    title: []const u8,
    /// Single-cell glyph used by the terminal composite bars.
    glyph: u21 = '?',
    hide_if_empty: bool = false,
    order: usize = 0,
    storage_id: ?[]const u8 = null,
    location: ViewContainerLocation = .sidebar,
    is_default: bool = false,
    do_not_register_open_command: bool = false,
};

/// Registration input, mirroring `IViewContainerDescriptor`.
pub const ViewContainerDescriptor = struct {
    id: []const u8,
    title: []const u8,
    glyph: u21 = '?',
    hide_if_empty: bool = false,
    order: usize = 0,
    storage_id: ?[]const u8 = null,
};

pub const RegisterOptions = struct {
    is_default: bool = false,
    do_not_register_open_command: bool = false,
};

pub const ContainerRegistration = struct {
    container: *const ViewContainer,
    location: ViewContainerLocation,
};

/// Terminal subset of IViewDescriptor. The actual view factory is supplied
/// by its contribution; cell weights and native aliases preserve existing
/// terminal settings/state. Availability adapts the upstream `when` condition.
pub const ViewDescriptor = struct {
    id: []const u8,
    name: []const u8,
    visible: bool = true,
    available: bool = true,
    in_container: bool = true,
    can_toggle_visibility: bool = true,
    can_move: bool = true,
    collapsed: bool = false,
    order: usize = 0,
    /// Share of the container body; the terminal splits expanded views by it.
    weight: usize = 20,
    size: ?f64 = null,
};

pub const ViewRegistration = struct {
    container_id: []const u8,
    views: []const ViewDescriptor,
};

/// Port of the view registration and lookup portions of IViewsRegistry.
/// Custom user view moves and workspace state remain in ViewDescriptorService
/// and ViewContainerModel. View welcome-content contributions are not ported.
pub const ViewsRegistry = struct {
    allocator: Allocator,
    entries: std.array_list.Managed(RegisteredView),
    on_views_registered: Emitter(ViewRegistration),
    on_views_deregistered: Emitter(ViewRegistration),

    pub const RegisteredView = struct { container_id: []const u8, descriptor: ViewDescriptor };

    pub fn init(allocator: Allocator) ViewsRegistry {
        return .{
            .allocator = allocator,
            .entries = .init(allocator),
            .on_views_registered = .init(allocator),
            .on_views_deregistered = .init(allocator),
        };
    }

    pub fn deinit(self: *ViewsRegistry) void {
        self.on_views_registered.deinit();
        self.on_views_deregistered.deinit();
        self.entries.deinit();
    }

    pub fn registerViews(self: *ViewsRegistry, descriptors: []const ViewDescriptor, container_id: []const u8) !void {
        for (descriptors, 0..) |descriptor, index| {
            if (self.getView(descriptor.id) != null) return error.AlreadyRegistered;
            for (descriptors[0..index]) |previous| if (std.mem.eql(u8, previous.id, descriptor.id)) return error.AlreadyRegistered;
        }
        try self.entries.ensureUnusedCapacity(descriptors.len);
        for (descriptors) |descriptor| self.entries.appendAssumeCapacity(.{ .container_id = container_id, .descriptor = descriptor });
        try self.on_views_registered.fire(.{ .container_id = container_id, .views = descriptors });
    }

    pub fn deregisterViews(self: *ViewsRegistry, ids: []const []const u8, container_id: []const u8) !void {
        var removed = std.array_list.Managed(ViewDescriptor).init(self.allocator);
        defer removed.deinit();
        try removed.ensureUnusedCapacity(ids.len);
        for (ids) |id| {
            for (self.entries.items, 0..) |entry, index| {
                if (!std.mem.eql(u8, entry.container_id, container_id) or !std.mem.eql(u8, entry.descriptor.id, id)) continue;
                removed.appendAssumeCapacity(entry.descriptor);
                _ = self.entries.orderedRemove(index);
                break;
            }
        }
        if (removed.items.len > 0) try self.on_views_deregistered.fire(.{ .container_id = container_id, .views = removed.items });
    }

    pub fn getView(self: *const ViewsRegistry, id: []const u8) ?ViewDescriptor {
        for (self.entries.items) |entry| if (std.mem.eql(u8, entry.descriptor.id, id)) return entry.descriptor;
        return null;
    }

    pub fn getViewContainer(self: *const ViewsRegistry, id: []const u8) ?[]const u8 {
        for (self.entries.items) |entry| if (std.mem.eql(u8, entry.descriptor.id, id)) return entry.container_id;
        return null;
    }

    pub fn getViews(self: *const ViewsRegistry, container_id: []const u8, allocator: Allocator) ![]ViewDescriptor {
        var result = std.array_list.Managed(ViewDescriptor).init(allocator);
        errdefer result.deinit();
        for (self.entries.items) |entry| if (std.mem.eql(u8, entry.container_id, container_id)) try result.append(entry.descriptor);
        return result.toOwnedSlice();
    }
};

/// Port of IViewContainersRegistry, with explicit native view factories.
pub const ViewContainersRegistry = struct {
    allocator: Allocator,
    containers: std.array_list.Managed(*ViewContainer),
    on_did_register: Emitter(ContainerRegistration),
    on_did_deregister: Emitter(ContainerRegistration),

    pub fn init(allocator: Allocator) ViewContainersRegistry {
        return .{
            .allocator = allocator,
            .containers = std.array_list.Managed(*ViewContainer).init(allocator),
            .on_did_register = Emitter(ContainerRegistration).init(allocator),
            .on_did_deregister = Emitter(ContainerRegistration).init(allocator),
        };
    }

    pub fn deinit(self: *ViewContainersRegistry) void {
        for (self.containers.items) |container| self.allocator.destroy(container);
        self.containers.deinit();
        self.on_did_register.deinit();
        self.on_did_deregister.deinit();
    }

    /// Registers a container at `location`. Returns the existing container
    /// when one with the same id is already registered, like upstream.
    pub fn register(
        self: *ViewContainersRegistry,
        descriptor: ViewContainerDescriptor,
        location: ViewContainerLocation,
        options: RegisterOptions,
    ) !*const ViewContainer {
        if (self.get(descriptor.id)) |existing| return existing;

        const container = try self.allocator.create(ViewContainer);
        errdefer self.allocator.destroy(container);
        container.* = .{
            .id = descriptor.id,
            .title = descriptor.title,
            .glyph = descriptor.glyph,
            .hide_if_empty = descriptor.hide_if_empty,
            .order = descriptor.order,
            .storage_id = descriptor.storage_id,
            .location = location,
            .is_default = options.is_default,
            .do_not_register_open_command = options.do_not_register_open_command,
        };
        try self.containers.append(container);
        try self.on_did_register.fire(.{ .container = container, .location = location });
        return container;
    }

    pub fn deregister(self: *ViewContainersRegistry, id: []const u8) !void {
        for (self.containers.items, 0..) |container, index| {
            if (!std.mem.eql(u8, container.id, id)) continue;
            _ = self.containers.orderedRemove(index);
            const registration = ContainerRegistration{
                .container = container,
                .location = container.location,
            };
            // Listeners may inspect the registration, so fire before freeing.
            try self.on_did_deregister.fire(registration);
            self.allocator.destroy(container);
            return;
        }
    }

    pub fn get(self: *const ViewContainersRegistry, id: []const u8) ?*const ViewContainer {
        for (self.containers.items) |container| {
            if (std.mem.eql(u8, container.id, id)) return container;
        }
        return null;
    }

    /// All registered containers in registration order.
    pub fn all(self: *const ViewContainersRegistry, allocator: Allocator) ![]*const ViewContainer {
        return allocator.dupe(*const ViewContainer, self.containers.items);
    }

    /// Containers registered at `location`, in registration order.
    pub fn getAll(self: *const ViewContainersRegistry, location: ViewContainerLocation, allocator: Allocator) ![]*const ViewContainer {
        var result = std.array_list.Managed(*const ViewContainer).init(allocator);
        errdefer result.deinit();
        for (self.containers.items) |container| {
            if (container.location == location) try result.append(container);
        }
        return result.toOwnedSlice();
    }

    pub fn getViewContainerLocation(self: *const ViewContainersRegistry, id: []const u8) ?ViewContainerLocation {
        const container = self.get(id) orelse return null;
        return container.location;
    }
};

/// Orders containers like the pane composite bar: `order`, then registration
/// order for equal orders.
pub fn sortByOrder(containers: []*const ViewContainer) void {
    std.sort.insertion(*const ViewContainer, containers, {}, struct {
        fn lessThan(_: void, a: *const ViewContainer, b: *const ViewContainer) bool {
            return a.order < b.order;
        }
    }.lessThan);
}

/// A single-cell title action, shared by the panel/side-bar titles and the
/// collapsible view headers. Port of the terminal projection of `IAction`.
pub const TitleAction = struct {
    id: []const u8,
    label: []const u8,
    glyph: u21,
    enabled: bool = true,
    /// Render the label after the glyph (the Graph reference picker does).
    show_label: bool = false,
    /// Upstream secondary actions collapse into the toolbar overflow menu. The
    /// terminal paints them after the primary actions; there is no overflow.
    secondary: bool = false,
};

test "views: registration, location and duplicate handling" {
    const allocator = std.testing.allocator;
    var registry = ViewContainersRegistry.init(allocator);
    defer registry.deinit();

    var registered: usize = 0;
    const Listener = struct {
        fn onRegister(_: ContainerRegistration, ctx: *usize) anyerror!void {
            ctx.* += 1;
        }
    };
    _ = try registry.on_did_register.listen(&registered, Listener.onRegister);

    const terminal = try registry.register(.{
        .id = "terminal",
        .title = "Terminal",
        .glyph = '>',
        .hide_if_empty = true,
        .order = 3,
    }, .panel, .{ .is_default = true });
    try std.testing.expectEqual(ViewContainerLocation.panel, terminal.location);
    try std.testing.expect(terminal.is_default);
    try std.testing.expectEqual(@as(usize, 1), registered);

    const duplicate = try registry.register(.{ .id = "terminal", .title = "Other" }, .sidebar, .{});
    try std.testing.expect(duplicate == terminal);
    try std.testing.expectEqual(@as(usize, 1), registered);
    try std.testing.expectEqual(ViewContainerLocation.panel, duplicate.location);

    const problems = try registry.register(.{
        .id = "workbench.panel.markers",
        .title = "Problems",
        .glyph = '!',
        .hide_if_empty = true,
        .order = 0,
    }, .panel, .{});
    const panel_containers = try registry.getAll(.panel, allocator);
    defer allocator.free(panel_containers);
    try std.testing.expectEqual(@as(usize, 2), panel_containers.len);
    sortByOrder(panel_containers);
    try std.testing.expectEqualStrings(problems.id, panel_containers[0].id);
    try std.testing.expectEqualStrings(terminal.id, panel_containers[1].id);

    try std.testing.expectEqual(@as(?ViewContainerLocation, .panel), registry.getViewContainerLocation("workbench.panel.markers"));
    try registry.deregister("workbench.panel.markers");
    try std.testing.expect(registry.get("workbench.panel.markers") == null);
    try std.testing.expectEqualStrings("panel", viewContainerLocationToString(.panel));
}
