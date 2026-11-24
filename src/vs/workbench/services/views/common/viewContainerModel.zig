// Port of the portable state in
// `src/vs/workbench/services/views/common/viewContainerModel.ts`.
//
// The workbench supplies the workspace storage location for these view states.

const std = @import("std");
const Allocator = std.mem.Allocator;

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

pub const ViewState = struct {
    id: []const u8,
    container: []const u8,
    visible: bool,
    collapsed: bool,
    order: usize,
    size: ?f64 = null,
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

    pub fn contains(self: *const ViewContainerModel, id: []const u8) bool {
        for (self.views.items) |view| {
            if (std.mem.eql(u8, view.id, id)) return view.in_container and view.available;
        }
        return false;
    }

    pub fn isVisible(self: *const ViewContainerModel, id: []const u8) bool {
        for (self.views.items) |view| {
            if (std.mem.eql(u8, view.id, id)) return view.in_container and view.available and view.visible;
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
            if (std.mem.eql(u8, view.id, id) and view.in_container and view.available and view.visible) {
                self.active_view = view.id;
                return;
            }
        }
    }

    pub fn setSize(self: *ViewContainerModel, id: []const u8, size: f64) void {
        for (self.views.items) |*view| {
            if (std.mem.eql(u8, view.id, id)) {
                view.size = size;
                return;
            }
        }
    }

    pub fn toggleVisibility(self: *ViewContainerModel, id: []const u8) void {
        var visible_count: usize = 0;
        for (self.views.items) |view| {
            if (view.in_container and view.available and view.visible) visible_count += 1;
        }
        for (self.views.items) |*view| {
            if (!std.mem.eql(u8, view.id, id)) continue;
            if (view.in_container and view.available and view.can_toggle_visibility and (!view.visible or visible_count > 1)) {
                view.visible = !view.visible;
            }
            return;
        }
    }

    pub const DropPosition = enum { before, after };

    pub fn canMoveView(self: *const ViewContainerModel, id: []const u8) bool {
        for (self.views.items) |view| {
            if (std.mem.eql(u8, view.id, id)) return view.in_container and view.available and view.can_move;
        }
        return false;
    }

    pub fn move(self: *ViewContainerModel, from: []const u8, to: []const u8, position: DropPosition) void {
        std.mem.sort(ViewDescriptor, self.views.items, {}, lessThan);
        var source: ?usize = null;
        var target: ?usize = null;
        for (self.views.items, 0..) |view, index| {
            if (view.in_container and view.can_move and std.mem.eql(u8, view.id, from)) source = index;
            if (view.in_container and std.mem.eql(u8, view.id, to)) target = index;
        }
        const first = source orelse return;
        const anchor = target orelse return;
        if (first == anchor) return;
        const insertion = anchor + @intFromBool(position == .after) - @intFromBool(first < anchor);
        if (first == insertion) return;
        const view = self.views.orderedRemove(first);
        self.views.insertAssumeCapacity(insertion, view);
        for (self.views.items, 0..) |*item, index| item.order = index;
    }

    pub fn canMoveTo(self: *const ViewContainerModel, id: []const u8, target: *const ViewContainerModel) bool {
        if (self == target or !self.canMoveView(id)) return false;
        for (target.views.items) |view| {
            if (std.mem.eql(u8, view.id, id)) return view.available and !view.in_container;
        }
        return false;
    }

    pub fn moveTo(self: *ViewContainerModel, id: []const u8, target: *ViewContainerModel) bool {
        if (!self.canMoveTo(id, target)) return false;
        var order: usize = 0;
        for (target.views.items) |view| {
            if (view.in_container) order = @max(order, view.order +| 1);
        }
        for (self.views.items) |*source| {
            if (!std.mem.eql(u8, source.id, id)) continue;
            for (target.views.items) |*destination| {
                if (!std.mem.eql(u8, destination.id, id)) continue;
                destination.* = source.*;
                destination.visible = true;
                destination.collapsed = false;
                destination.order = order;
                destination.size = null;
                source.in_container = false;
                return true;
            }
        }
        return false;
    }

    pub fn restoreState(self: *ViewContainerModel, states: []const ViewState) void {
        for (self.views.items) |*view| {
            for (states) |state| {
                if (!std.mem.eql(u8, state.id, view.id)) continue;
                view.in_container = std.mem.eql(u8, state.container, self.container.id);
                if (!view.in_container) break;
                if (view.can_toggle_visibility) view.visible = state.visible;
                view.collapsed = state.collapsed;
                view.order = state.order;
                if (state.size) |size| {
                    if (std.math.isFinite(size) and size > 0 and size <= 1_000_000) view.size = size;
                }
                break;
            }
        }
        for (self.views.items) |view| {
            if (view.in_container and view.available and view.visible) return;
        }
        for (self.views.items) |*view| {
            if (!view.in_container or !view.available) continue;
            view.visible = true;
            return;
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
            if (view.in_container and view.available and view.visible) try result.append(view);
        }
        std.sort.insertion(ViewDescriptor, result.items, {}, lessThan);
        return result.toOwnedSlice();
    }
};

fn lessThan(_: void, a: ViewDescriptor, b: ViewDescriptor) bool {
    return a.order < b.order;
}
