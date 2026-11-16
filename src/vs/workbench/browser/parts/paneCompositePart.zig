// Port of the portable pane-composite state in
// `src/vs/workbench/browser/parts/paneCompositePart.ts`.
//
// `AbstractPaneCompositePart` owns a DOM container, a composite bar, menus and
// view-container services. The terminal model keeps the descriptor registry,
// the active/last-active container and visibility. The activity bar and the
// terminal sidebar view paint the entries and route focus.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../../base/common/event.zig").Emitter;

pub const PaneCompositeDescriptor = struct {
    id: []const u8,
    name: []const u8,
    order: usize = 0,
    visible: bool = true,
};

pub const PaneCompositePart = struct {
    allocator: Allocator,
    composites: std.array_list.Managed(PaneCompositeDescriptor),
    active_id: ?[]const u8 = null,
    last_active_id: ?[]const u8 = null,
    visible: bool = false,
    on_did_change: Emitter(void),

    pub fn init(allocator: Allocator) PaneCompositePart {
        return .{
            .allocator = allocator,
            .composites = std.array_list.Managed(PaneCompositeDescriptor).init(allocator),
            .on_did_change = Emitter(void).init(allocator),
        };
    }

    pub fn deinit(self: *PaneCompositePart) void {
        self.on_did_change.deinit();
        self.composites.deinit();
    }

    pub fn addComposite(self: *PaneCompositePart, descriptor: PaneCompositeDescriptor) !void {
        for (self.composites.items, 0..) |*existing, index| {
            if (std.mem.eql(u8, existing.id, descriptor.id)) {
                existing.* = descriptor;
                _ = index;
                try self.on_did_change.fire({});
                return;
            }
        }
        try self.composites.append(descriptor);
        try self.on_did_change.fire({});
    }

    pub fn removeComposite(self: *PaneCompositePart, id: []const u8) !void {
        for (self.composites.items, 0..) |descriptor, index| {
            if (!std.mem.eql(u8, descriptor.id, id)) continue;
            _ = self.composites.orderedRemove(index);
            if (self.active_id != null and std.mem.eql(u8, self.active_id.?, id)) {
                self.active_id = null;
            }
            try self.on_did_change.fire({});
            return;
        }
    }

    pub fn getComposite(self: *const PaneCompositePart, id: []const u8) ?PaneCompositeDescriptor {
        for (self.composites.items) |descriptor| {
            if (std.mem.eql(u8, descriptor.id, id)) return descriptor;
        }
        return null;
    }

    pub fn setActive(self: *PaneCompositePart, id: ?[]const u8) !bool {
        if (id) |wanted| {
            var found = false;
            for (self.composites.items) |descriptor| {
                if (!std.mem.eql(u8, descriptor.id, wanted)) continue;
                if (!descriptor.visible) return false;
                found = true;
                break;
            }
            if (!found) return false;
        }
        if (self.active_id) |current| self.last_active_id = current;
        self.active_id = id;
        if (id != null) self.visible = true;
        try self.on_did_change.fire({});
        return true;
    }

    pub fn active(self: *const PaneCompositePart) ?PaneCompositeDescriptor {
        const id = self.active_id orelse return null;
        return self.getComposite(id);
    }

    pub fn hideActive(self: *PaneCompositePart) !void {
        if (self.active_id) |current| self.last_active_id = current;
        if (self.active_id == null) return;
        self.active_id = null;
        self.visible = false;
        try self.on_did_change.fire({});
    }

    pub fn setVisible(self: *PaneCompositePart, visible: bool) !void {
        if (self.visible == visible) return;
        self.visible = visible;
        try self.on_did_change.fire({});
    }

    /// Visible composites in model order. The returned slice is owned by the
    /// caller.
    pub fn visibleComposites(self: *const PaneCompositePart, allocator: Allocator) ![]PaneCompositeDescriptor {
        var result = std.array_list.Managed(PaneCompositeDescriptor).init(allocator);
        errdefer result.deinit();
        for (self.composites.items) |descriptor| {
            if (descriptor.visible) try result.append(descriptor);
        }
        std.mem.sort(PaneCompositeDescriptor, result.items, {}, lessThanOrder);
        return result.toOwnedSlice();
    }

    pub fn visibleIds(self: *const PaneCompositePart, allocator: Allocator) ![][]const u8 {
        const descriptors = try self.visibleComposites(allocator);
        defer allocator.free(descriptors);
        var ids = std.array_list.Managed([]const u8).init(allocator);
        errdefer ids.deinit();
        for (descriptors) |descriptor| try ids.append(descriptor.id);
        return ids.toOwnedSlice();
    }
};

fn lessThanOrder(_: void, a: PaneCompositeDescriptor, b: PaneCompositeDescriptor) bool {
    if (a.order != b.order) return a.order < b.order;
    return false;
}
