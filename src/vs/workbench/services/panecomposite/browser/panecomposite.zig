// Port of the terminal-supported IPaneCompositePartService methods from
// src/vs/workbench/services/panecomposite/browser/panecomposite.ts.
// Auxiliary bar and browser progress indicators have no terminal part.
const std = @import("std");
const instantiation = @import("../../../../platform/instantiation/common/instantiation.zig");
const Location = @import("../../../common/views.zig").ViewContainerLocation;
const Descriptor = @import("../../../browser/parts/paneCompositePart.zig").PaneCompositeDescriptor;

pub const pane_composite_part_service_id = instantiation.ServiceIdentifier(IPaneCompositePartService, "paneCompositePartService");

pub const IPaneCompositePartService = struct {
    context: *anyopaque,
    allocator: std.mem.Allocator,
    open_composite: *const fn (*anyopaque, []const u8, Location, bool) anyerror!bool,
    active_composite: *const fn (*anyopaque, Location) ?Descriptor,
    last_active_id: *const fn (*anyopaque, Location) ?[]const u8,
    visible_ids: *const fn (*anyopaque, Location, std.mem.Allocator) anyerror![][]const u8,
    hide_active: *const fn (*anyopaque, Location) anyerror!void,

    pub fn openPaneComposite(self: IPaneCompositePartService, id: []const u8, location: Location, focus: bool) !bool {
        return self.open_composite(self.context, id, location, focus);
    }

    pub fn getActivePaneComposite(self: IPaneCompositePartService, location: Location) ?Descriptor {
        return self.active_composite(self.context, location);
    }

    pub fn getLastActivePaneCompositeId(self: IPaneCompositePartService, location: Location) ?[]const u8 {
        return self.last_active_id(self.context, location);
    }

    pub fn getVisiblePaneCompositeIds(self: IPaneCompositePartService, location: Location, allocator: std.mem.Allocator) ![][]const u8 {
        return self.visible_ids(self.context, location, allocator);
    }

    pub fn hideActivePaneComposite(self: IPaneCompositePartService, location: Location) !void {
        try self.hide_active(self.context, location);
    }
};
