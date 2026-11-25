// Port of src/vs/workbench/browser/parts/paneCompositePartService.ts.
// The terminal mounts the sidebar and panel (no auxiliary bar). The native
// opener supplies lazy view creation and host focus; part state remains in
// the corresponding PaneCompositePart rather than the command handlers.
const std = @import("std");
const views = @import("../../common/views.zig");
const SidebarPart = @import("sidebar/sidebarPart.zig").SidebarPart;
const PanelPart = @import("panel/panelPart.zig").PanelPart;
const pane = @import("paneCompositePart.zig");
const IPaneCompositePartService = @import("../../services/panecomposite/browser/panecomposite.zig").IPaneCompositePartService;

pub const PaneCompositePartService = struct {
    sidebar: *SidebarPart,
    panel: *PanelPart,
    host: struct {
        context: *anyopaque,
        open: *const fn (*anyopaque, []const u8, views.ViewContainerLocation, bool) anyerror!bool,
    },

    pub fn interface(self: *PaneCompositePartService) IPaneCompositePartService {
        return .{
            .context = self,
            .allocator = self.sidebar.allocator,
            .open_composite = openPaneComposite,
            .active_composite = getActivePaneComposite,
            .last_active_id = getLastActivePaneCompositeId,
            .visible_ids = getVisiblePaneCompositeIds,
            .hide_active = hideActivePaneComposite,
        };
    }

    fn getPartByLocation(self: *PaneCompositePartService, location: views.ViewContainerLocation) ?*pane.PaneCompositePart {
        return switch (location) {
            .sidebar => &self.sidebar.pane,
            .panel => &self.panel.pane,
            .auxiliary_bar => null,
        };
    }

    fn openPaneComposite(context: *anyopaque, id: []const u8, location: views.ViewContainerLocation, focus: bool) !bool {
        const self: *PaneCompositePartService = @ptrCast(@alignCast(context));
        const part = self.getPartByLocation(location) orelse return false;
        if (part.getPaneComposite(id) == null) return false;
        return self.host.open(self.host.context, id, location, focus);
    }

    fn getActivePaneComposite(context: *anyopaque, location: views.ViewContainerLocation) ?pane.PaneCompositeDescriptor {
        const self: *PaneCompositePartService = @ptrCast(@alignCast(context));
        const part = self.getPartByLocation(location) orelse return null;
        return part.getActivePaneComposite();
    }

    fn getLastActivePaneCompositeId(context: *anyopaque, location: views.ViewContainerLocation) ?[]const u8 {
        const self: *PaneCompositePartService = @ptrCast(@alignCast(context));
        const part = self.getPartByLocation(location) orelse return null;
        return part.last_active_id;
    }

    fn getVisiblePaneCompositeIds(context: *anyopaque, location: views.ViewContainerLocation, allocator: std.mem.Allocator) ![][]const u8 {
        const self: *PaneCompositePartService = @ptrCast(@alignCast(context));
        return switch (location) {
            .sidebar => self.sidebar.getVisiblePaneCompositeIds(allocator),
            .panel => self.panel.pane.getVisiblePaneCompositeIds(allocator),
            .auxiliary_bar => allocator.alloc([]const u8, 0),
        };
    }

    fn hideActivePaneComposite(context: *anyopaque, location: views.ViewContainerLocation) !void {
        const self: *PaneCompositePartService = @ptrCast(@alignCast(context));
        switch (location) {
            .sidebar => try self.sidebar.hideActivePaneComposite(),
            .panel => try self.panel.hideActivePaneComposite(),
            .auxiliary_bar => {},
        }
    }
};
