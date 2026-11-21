// Port of the portable `CompositeBarModel` in
// `src/vs/workbench/browser/parts/compositeBar.ts`.
//
// The browser class also builds actions, hover feedback, overflow menus and
// drag-and-drop. The terminal model keeps the ordered item list, visibility,
// pinning and the active item; the activity bar and panel title paint it.
//
// `activityAction`/`pinnedAction`/`toggleBadgeAction` are replaced by the
// part's own pinned/active flags; badges are passed to the view separately.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const CompositeBarItem = struct {
    id: []const u8,
    name: []const u8,
    order: ?usize = null,
    pinned: bool = true,
    visible: bool = true,
};

pub const CompositeBarModel = struct {
    allocator: Allocator,
    items: std.array_list.Managed(CompositeBarItem),
    active_id: ?[]const u8 = null,

    pub fn init(allocator: Allocator) CompositeBarModel {
        return .{
            .allocator = allocator,
            .items = std.array_list.Managed(CompositeBarItem).init(allocator),
        };
    }

    pub fn deinit(self: *CompositeBarModel) void {
        self.items.deinit();
    }

    /// Adds or updates an item. Existing items keep their position and become
    /// visible again; new items are inserted by `requested_index` (visible
    /// items only) or by `order`. Returns whether the model changed.
    pub fn add(self: *CompositeBarModel, id: []const u8, name: []const u8, order: ?usize, requested_index: ?usize) !bool {
        if (self.findItem(id)) |item| {
            var changed = false;
            item.name = name;
            if (order) |value| {
                changed = item.order == null or item.order.? != value;
                item.order = value;
            }
            if (!item.visible) {
                item.visible = true;
                changed = true;
            }
            return changed;
        }

        const item = CompositeBarItem{
            .id = id,
            .name = name,
            .order = order,
            .pinned = true,
            .visible = true,
        };
        if (requested_index) |wanted| {
            var index: usize = 0;
            var remaining = wanted;
            while (remaining > 0 and index < self.items.items.len) {
                if (self.items.items[index].visible) remaining -= 1;
                index += 1;
            }
            try self.items.insert(index, item);
        } else if (order == null) {
            try self.items.append(item);
        } else {
            var index: usize = 0;
            while (index < self.items.items.len) : (index += 1) {
                const existing_order = self.items.items[index].order orelse break;
                if (existing_order >= order.?) break;
            }
            try self.items.insert(index, item);
        }
        return true;
    }

    pub fn remove(self: *CompositeBarModel, id: []const u8) bool {
        for (self.items.items, 0..) |item, index| {
            if (!std.mem.eql(u8, item.id, id)) continue;
            _ = self.items.orderedRemove(index);
            if (self.active_id != null and std.mem.eql(u8, self.active_id.?, id)) self.active_id = null;
            return true;
        }
        return false;
    }

    pub fn hide(self: *CompositeBarModel, id: []const u8) bool {
        for (self.items.items) |*item| {
            if (!std.mem.eql(u8, item.id, id)) continue;
            if (!item.visible) return false;
            item.visible = false;
            return true;
        }
        return false;
    }

    /// Upstream models re-showing a composite through `add`; the bar view also
    /// needs the direct toggle for `hideIfEmpty` containers.
    pub fn show(self: *CompositeBarModel, id: []const u8) bool {
        for (self.items.items) |*item| {
            if (!std.mem.eql(u8, item.id, id)) continue;
            if (item.visible) return false;
            item.visible = true;
            return true;
        }
        return false;
    }

    /// Moves `composite_id` in front of `to_composite_id` and pins it. The
    /// order matches upstream: remove the source first, then insert at the
    /// target's original index, so a forward move lands after the target.
    pub fn move(self: *CompositeBarModel, composite_id: []const u8, to_composite_id: []const u8) bool {
        const from_index = self.findIndex(composite_id);
        const to_index = self.findIndex(to_composite_id);
        if (from_index == null or to_index == null) return false;

        const source = self.items.orderedRemove(from_index.?);
        const insert_index = @min(to_index.?, self.items.items.len);
        self.items.insert(insert_index, source) catch {
            // Keep the source in the model when the insert cannot be served.
            self.items.append(source) catch {};
            return false;
        };
        self.items.items[insert_index].pinned = true;
        return true;
    }

    pub fn setPinned(self: *CompositeBarModel, id: []const u8, pinned: bool) bool {
        for (self.items.items) |*item| {
            if (!std.mem.eql(u8, item.id, id)) continue;
            if (item.pinned == pinned) return false;
            item.pinned = pinned;
            return true;
        }
        return false;
    }

    pub fn activate(self: *CompositeBarModel, id: []const u8) bool {
        if (self.active_id != null and std.mem.eql(u8, self.active_id.?, id)) return false;
        for (self.items.items) |*item| {
            if (!std.mem.eql(u8, item.id, id)) continue;
            self.active_id = item.id;
            return true;
        }
        return false;
    }

    pub fn deactivate(self: *CompositeBarModel) bool {
        if (self.active_id == null) return false;
        self.active_id = null;
        return true;
    }

    pub fn findItem(self: *CompositeBarModel, id: []const u8) ?*CompositeBarItem {
        for (self.items.items) |*item| {
            if (std.mem.eql(u8, item.id, id)) return item;
        }
        return null;
    }

    pub fn findItemConst(self: *const CompositeBarModel, id: []const u8) ?*const CompositeBarItem {
        for (self.items.items) |*item| {
            if (std.mem.eql(u8, item.id, id)) return item;
        }
        return null;
    }

    pub fn activeItem(self: *CompositeBarModel) ?*CompositeBarItem {
        const id = self.active_id orelse return null;
        return self.findItem(id);
    }

    pub fn findIndex(self: *const CompositeBarModel, id: []const u8) ?usize {
        for (self.items.items, 0..) |item, index| {
            if (std.mem.eql(u8, item.id, id)) return index;
        }
        return null;
    }

    /// Visible items in bar order. The returned slice is owned by the caller.
    pub fn visibleItems(self: *const CompositeBarModel, allocator: Allocator) ![]CompositeBarItem {
        var result = std.array_list.Managed(CompositeBarItem).init(allocator);
        errdefer result.deinit();
        for (self.items.items) |item| {
            if (item.visible) try result.append(item);
        }
        return result.toOwnedSlice();
    }

    /// Visible and pinned items in bar order. The returned slice is owned by
    /// the caller.
    pub fn pinnedItems(self: *const CompositeBarModel, allocator: Allocator) ![]CompositeBarItem {
        var result = std.array_list.Managed(CompositeBarItem).init(allocator);
        errdefer result.deinit();
        for (self.items.items) |item| {
            if (item.visible and item.pinned) try result.append(item);
        }
        return result.toOwnedSlice();
    }
};

test "compositeBar: order, hide, show and move" {
    const allocator = std.testing.allocator;
    var model = CompositeBarModel.init(allocator);
    defer model.deinit();

    try std.testing.expect(try model.add("problems", "Problems", 0, null));
    try std.testing.expect(try model.add("terminal", "Terminal", 3, null));
    try std.testing.expect(try model.add("output", "Output", 2, null));

    try std.testing.expectEqual(@as(usize, 3), model.items.items.len);
    try std.testing.expectEqualStrings("problems", model.items.items[0].id);
    try std.testing.expectEqualStrings("output", model.items.items[1].id);
    try std.testing.expectEqualStrings("terminal", model.items.items[2].id);

    try std.testing.expect(model.hide("output"));
    try std.testing.expect(!model.hide("output"));
    try std.testing.expect(model.show("output"));
    try std.testing.expect(!model.show("output"));

    try std.testing.expect(model.move("terminal", "problems"));
    try std.testing.expectEqualStrings("terminal", model.items.items[0].id);
    try std.testing.expect(model.setPinned("terminal", false));
    try std.testing.expect(!model.setPinned("terminal", false));

    try std.testing.expect(model.activate("terminal"));
    try std.testing.expectEqualStrings("terminal", model.activeItem().?.id);
    try std.testing.expect(!model.activate("terminal"));
    try std.testing.expect(model.deactivate());
    try std.testing.expect(model.activeItem() == null);

    const pinned = try model.pinnedItems(allocator);
    defer allocator.free(pinned);
    try std.testing.expectEqual(@as(usize, 2), pinned.len);
}

test "compositeBar: add updates an existing item in place" {
    const allocator = std.testing.allocator;
    var model = CompositeBarModel.init(allocator);
    defer model.deinit();

    _ = try model.add("terminal", "Terminal", 3, null);
    _ = try model.add("problems", "Problems", 0, null);
    try std.testing.expect(model.hide("terminal"));
    try std.testing.expect(try model.add("terminal", "Terminal (renamed)", 4, null));
    try std.testing.expectEqualStrings("problems", model.items.items[0].id);
    try std.testing.expectEqualStrings("terminal", model.items.items[1].id);
    try std.testing.expect(model.items.items[1].visible);
    try std.testing.expectEqualStrings("Terminal (renamed)", model.items.items[1].name);
    try std.testing.expect(!try model.add("terminal", "Terminal (renamed)", 4, null));
}
