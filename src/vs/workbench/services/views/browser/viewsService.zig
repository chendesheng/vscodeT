// Port of the view lookup, opening, closing and visibility behavior in
// `src/vs/workbench/services/views/browser/viewsService.ts`.
// Terminal composites have explicit native view factories. Registrations
// borrow their mounted view slots instead of creating DOM views through
// constructor reflection. Descriptor IDs retain their existing terminal aliases.
const std = @import("std");
const Allocator = std.mem.Allocator;
const api = @import("../common/viewsService.zig");
const descriptors_mod = @import("viewDescriptorService.zig");
const SidebarPart = @import("../../../browser/parts/sidebar/sidebarPart.zig").SidebarPart;
const ViewPaneContainer = @import("../../../browser/parts/views/viewPaneContainer.zig").ViewPaneContainer;
const layout_mod = @import("../../layout/browser/layoutService.zig");
const IPaneCompositePartService = @import("../../panecomposite/browser/panecomposite.zig").IPaneCompositePartService;
const Location = descriptors_mod.ViewContainerLocation;

/// A standalone single-view composite uses its container ID. A view in a
/// ViewPaneContainer resolves its current descriptor model, including moves.
pub const ViewLocation = union(enum) { descriptor: []const u8, container: []const u8 };

pub const ViewRegistration = struct {
    id: []const u8,
    location: ViewLocation,
    context: *anyopaque,
    get: *const fn (*anyopaque) ?*anyopaque,

    pub fn pointerSlot(comptime View: type, slot: *?*View, location: ViewLocation) ViewRegistration {
        return .{ .id = View.ID, .location = location, .context = @ptrCast(slot), .get = struct {
            fn get(context: *anyopaque) ?*anyopaque {
                const value: *?*View = @ptrCast(@alignCast(context));
                return if (value.*) |view| view else null;
            }
        }.get };
    }

    pub fn valueSlot(comptime View: type, slot: *?View, location: ViewLocation) ViewRegistration {
        return .{ .id = View.ID, .location = location, .context = @ptrCast(slot), .get = struct {
            fn get(context: *anyopaque) ?*anyopaque {
                const value: *?View = @ptrCast(@alignCast(context));
                return if (value.*) |*view| view else null;
            }
        }.get };
    }
};

pub const ViewsService = struct {
    allocator: Allocator,
    view_descriptor_service: *descriptors_mod.ViewDescriptorService,
    sidebar: *SidebarPart,
    pane_composite_service: IPaneCompositePartService = undefined,
    layout_service: layout_mod.IWorkbenchLayoutService = undefined,
    view_registrations: std.StringHashMapUnmanaged(ViewRegistration) = .empty,

    pub fn init(allocator: Allocator, descriptors: *descriptors_mod.ViewDescriptorService, sidebar: *SidebarPart) ViewsService {
        return .{ .allocator = allocator, .view_descriptor_service = descriptors, .sidebar = sidebar };
    }

    pub fn deinit(self: *ViewsService) void {
        self.view_registrations.deinit(self.allocator);
    }

    pub fn attach(self: *ViewsService, panes: IPaneCompositePartService, layout: layout_mod.IWorkbenchLayoutService) void {
        self.pane_composite_service = panes;
        self.layout_service = layout;
    }

    pub fn registerView(self: *ViewsService, registration: ViewRegistration) !void {
        try self.view_registrations.putNoClobber(self.allocator, registration.id, registration);
    }

    pub fn deregisterView(self: *ViewsService, id: []const u8) void {
        _ = self.view_registrations.remove(id);
    }

    pub fn interface(self: *ViewsService) api.IViewsService {
        return .{ .context = self, .get_active_view = getActiveViewWithId, .get_view = getViewWithId, .open_view = openView, .is_view_visible = isViewVisible, .close_view = closeView };
    }

    fn containerId(self: *ViewsService, registration: ViewRegistration) ?[]const u8 {
        return switch (registration.location) {
            .container => |id| id,
            .descriptor => |id| if (self.view_descriptor_service.getViewContainerByViewId(id)) |model| model.container.id else null,
        };
    }

    fn getActiveViewPaneContainer(self: *ViewsService, id: []const u8, location: Location) ?*ViewPaneContainer {
        if (!self.isViewContainerVisible(id, location)) return null;
        return if (location == .sidebar) self.sidebar.getViewPaneContainer(id) else null;
    }

    fn partForLocation(location: Location) layout_mod.Parts {
        return switch (location) {
            .sidebar => .sidebar,
            .panel => .panel,
            .auxiliary_bar => .auxiliarybar,
        };
    }

    fn isViewContainerVisible(self: *ViewsService, id: []const u8, location: Location) bool {
        if (!self.layout_service.isVisible(partForLocation(location))) return false;
        const active = self.pane_composite_service.getActivePaneComposite(location) orelse return false;
        return std.mem.eql(u8, id, active.id);
    }

    fn getViewWithId(context: *anyopaque, id: []const u8) ?*anyopaque {
        const self: *ViewsService = @ptrCast(@alignCast(context));
        const registration = self.view_registrations.get(id) orelse return null;
        _ = self.containerId(registration) orelse return null;
        return registration.get(registration.context);
    }

    fn getActiveViewWithId(context: *anyopaque, id: []const u8) ?*anyopaque {
        const self: *ViewsService = @ptrCast(@alignCast(context));
        const registration = self.view_registrations.get(id) orelse return null;
        const container = self.containerId(registration) orelse return null;
        const location = self.view_descriptor_service.getViewContainerLocationById(container) orelse return null;
        if (!self.isViewContainerVisible(container, location)) return null;
        if (registration.location == .descriptor) {
            const pane_container = self.getActiveViewPaneContainer(container, location) orelse return null;
            if (!pane_container.model.isVisible(registration.location.descriptor)) return null;
        }
        return registration.get(registration.context);
    }

    fn isViewVisible(context: *anyopaque, id: []const u8) bool {
        const self: *ViewsService = @ptrCast(@alignCast(context));
        _ = getActiveViewWithId(context, id) orelse return false;
        const registration = self.view_registrations.get(id) orelse return false;
        if (registration.location == .container) return true;
        const container = self.containerId(registration) orelse return false;
        const location = self.view_descriptor_service.getViewContainerLocationById(container) orelse return false;
        const pane_container = self.getActiveViewPaneContainer(container, location) orelse return false;
        return pane_container.isBodyVisible(registration.location.descriptor);
    }

    fn openView(context: *anyopaque, id: []const u8, focus: bool) !?*anyopaque {
        const self: *ViewsService = @ptrCast(@alignCast(context));
        const registration = self.view_registrations.get(id) orelse return null;
        const container = self.containerId(registration) orelse return null;
        const location = self.view_descriptor_service.getViewContainerLocationById(container) orelse return null;
        if (!try self.pane_composite_service.openPaneComposite(container, location, registration.location == .container and focus)) return null;
        if (registration.location == .descriptor) {
            const pane_container = self.getActiveViewPaneContainer(container, location) orelse return null;
            const view_id = registration.location.descriptor;
            pane_container.model.setVisible(view_id, true);
            pane_container.model.setCollapsed(view_id, false);
            pane_container.setActive(view_id);
            if (focus) self.layout_service.focusPart(partForLocation(location));
        }
        return registration.get(registration.context);
    }

    fn closeView(context: *anyopaque, id: []const u8) !void {
        const self: *ViewsService = @ptrCast(@alignCast(context));
        _ = getActiveViewWithId(context, id) orelse return;
        const registration = self.view_registrations.get(id) orelse return;
        const container = self.containerId(registration) orelse return;
        const location = self.view_descriptor_service.getViewContainerLocationById(container) orelse return;
        if (registration.location == .descriptor) {
            const pane_container = self.getActiveViewPaneContainer(container, location) orelse return;
            const visible = try pane_container.model.visibleViews(self.allocator);
            defer self.allocator.free(visible);
            if (visible.len > 1) {
                pane_container.model.setCollapsed(registration.location.descriptor, true);
                return;
            }
        }
        try self.layout_service.setPartHidden(true, partForLocation(location));
    }
};
