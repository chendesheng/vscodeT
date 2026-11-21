// Port of the portable state in
// `src/vs/workbench/services/views/common/viewContainerModel.ts`.
//
// Upstream tracks context keys, storage and visibility/order per workspace.
// The terminal port keeps the container/view descriptors, visibility and
// collapsed state, active view and the visible-view projection. Storage and
// context-key services are not ported yet.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ViewDescriptor = struct {
    id: []const u8,
    name: []const u8,
    visible: bool = true,
    collapsed: bool = false,
    order: usize = 0,
    /// Share of the container body; the terminal splits expanded views by it.
    weight: usize = 20,
};

pub const ViewContainer = struct {
    id: []const u8,
    title: []const u8,
    icon: []const u8,
};

pub const ViewContainerModel = struct {
    allocator: Allocator,
    container: ViewContainer,
    views: std.array_list.Managed(ViewDescriptor),
    active_view: ?[]const u8 = null,

    pub fn init(allocator: Allocator, container: ViewContainer) ViewContainerModel {
        return .{
            .allocator = allocator,
            .container = container,
            .views = std.array_list.Managed(ViewDescriptor).init(allocator),
        };
    }

    pub fn deinit(self: *ViewContainerModel) void {
        self.views.deinit();
    }

    pub fn addView(self: *ViewContainerModel, view: ViewDescriptor) !void {
        for (self.views.items) |*existing| {
            if (std.mem.eql(u8, existing.id, view.id)) {
                existing.* = view;
                return;
            }
        }
        try self.views.append(view);
        if (self.active_view == null and view.visible) self.active_view = view.id;
    }

    pub fn removeView(self: *ViewContainerModel, id: []const u8) void {
        for (self.views.items, 0..) |view, index| {
            if (std.mem.eql(u8, view.id, id)) {
                _ = self.views.orderedRemove(index);
                if (self.active_view != null and std.mem.eql(u8, self.active_view.?, id)) {
                    self.active_view = null;
                }
                return;
            }
        }
    }

    pub fn setVisible(self: *ViewContainerModel, id: []const u8, visible: bool) void {
        for (self.views.items) |*view| {
            if (std.mem.eql(u8, view.id, id)) {
                view.visible = visible;
                return;
            }
        }
    }

    pub fn isVisible(self: *const ViewContainerModel, id: []const u8) bool {
        for (self.views.items) |view| {
            if (std.mem.eql(u8, view.id, id)) return view.visible;
        }
        return false;
    }

    pub fn isCollapsed(self: *const ViewContainerModel, id: []const u8) bool {
        for (self.views.items) |view| {
            if (std.mem.eql(u8, view.id, id)) return view.collapsed;
        }
        return false;
    }

    pub fn setCollapsed(self: *ViewContainerModel, id: []const u8, collapsed: bool) void {
        for (self.views.items) |*view| {
            if (std.mem.eql(u8, view.id, id)) {
                view.collapsed = collapsed;
                return;
            }
        }
    }

    pub fn setActiveView(self: *ViewContainerModel, id: []const u8) void {
        for (self.views.items) |view| {
            if (std.mem.eql(u8, view.id, id) and view.visible) {
                self.active_view = view.id;
                return;
            }
        }
    }

    pub fn activeView(self: *const ViewContainerModel) ?[]const u8 {
        return self.active_view;
    }

    /// Visible views in `order` order. The returned slice is allocated; the
    /// caller owns it.
    pub fn visibleViews(self: *const ViewContainerModel, allocator: Allocator) ![]ViewDescriptor {
        var result = std.array_list.Managed(ViewDescriptor).init(allocator);
        errdefer result.deinit();
        for (self.views.items) |view| {
            if (view.visible) try result.append(view);
        }
        std.sort.insertion(ViewDescriptor, result.items, {}, struct {
            fn lessThan(_: void, a: ViewDescriptor, b: ViewDescriptor) bool {
                return a.order < b.order;
            }
        }.lessThan);
        return result.toOwnedSlice();
    }
};
