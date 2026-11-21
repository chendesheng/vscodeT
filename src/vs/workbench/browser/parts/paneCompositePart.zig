// Port of the portable pane-composite state in
// `src/vs/workbench/browser/parts/paneCompositePart.ts`.
//
// `AbstractPaneCompositePart` owns a DOM container, a composite bar, menus and
// view-container services. The terminal model keeps the descriptor registry,
// the composite bar model, the active/last-active container and visibility.
// The activity bar, the side bar and the panel title paint the entries and
// route focus; the part subclasses (`sidebarPart.zig`, `panel/panelPart.zig`)
// own their visibility and size.
//
// Terminal adaptation: opening a composite reveals the part in the browser
// (`layoutService.setPartHidden`); here the workbench reveals the owning part
// after `openPaneComposite` succeeds.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../../base/common/event.zig").Emitter;
const composite_bar = @import("./compositeBar.zig");
const views = @import("../../common/views.zig");

pub const PaneCompositeDescriptor = struct {
    id: []const u8,
    name: []const u8,
    order: usize = 0,
    /// Single-cell glyph used by the terminal composite bars.
    glyph: u21 = '?',
};

/// Port of `IPaneCompositePart`. The generic parameter of the browser class is
/// dropped: a composite is a registered container, painted by the TUI.
pub const PaneCompositePart = struct {
    allocator: Allocator,
    registry_id: []const u8,
    part_id: []const u8,
    location: views.ViewContainerLocation,
    pane_composites: std.array_list.Managed(PaneCompositeDescriptor),
    bar: composite_bar.CompositeBarModel,
    active_id: ?[]const u8 = null,
    last_active_id: ?[]const u8 = null,
    visible: bool = false,
    on_did_pane_composite_open: Emitter([]const u8),
    on_did_pane_composite_close: Emitter([]const u8),
    on_did_change: Emitter(void),

    pub fn init(
        allocator: Allocator,
        registry_id: []const u8,
        part_id: []const u8,
        location: views.ViewContainerLocation,
    ) PaneCompositePart {
        return .{
            .allocator = allocator,
            .registry_id = registry_id,
            .part_id = part_id,
            .location = location,
            .pane_composites = std.array_list.Managed(PaneCompositeDescriptor).init(allocator),
            .bar = composite_bar.CompositeBarModel.init(allocator),
            .on_did_pane_composite_open = Emitter([]const u8).init(allocator),
            .on_did_pane_composite_close = Emitter([]const u8).init(allocator),
            .on_did_change = Emitter(void).init(allocator),
        };
    }

    pub fn deinit(self: *PaneCompositePart) void {
        self.on_did_change.deinit();
        self.on_did_pane_composite_open.deinit();
        self.on_did_pane_composite_close.deinit();
        self.bar.deinit();
        self.pane_composites.deinit();
    }

    /// Registers a composite in the part and in its composite bar.
    pub fn addPaneComposite(self: *PaneCompositePart, descriptor: PaneCompositeDescriptor) !void {
        for (self.pane_composites.items, 0..) |*existing, index| {
            if (std.mem.eql(u8, existing.id, descriptor.id)) {
                existing.* = descriptor;
                _ = index;
                _ = try self.bar.add(descriptor.id, descriptor.name, descriptor.order, null);
                try self.on_did_change.fire({});
                return;
            }
        }
        try self.pane_composites.append(descriptor);
        _ = try self.bar.add(descriptor.id, descriptor.name, descriptor.order, null);
        try self.on_did_change.fire({});
    }

    pub fn removePaneComposite(self: *PaneCompositePart, id: []const u8) !void {
        for (self.pane_composites.items, 0..) |descriptor, index| {
            if (!std.mem.eql(u8, descriptor.id, id)) continue;
            _ = self.pane_composites.orderedRemove(index);
            _ = self.bar.remove(id);
            if (self.active_id != null and std.mem.eql(u8, self.active_id.?, id)) {
                self.active_id = null;
            }
            try self.on_did_change.fire({});
            return;
        }
    }

    pub fn getPaneComposite(self: *const PaneCompositePart, id: []const u8) ?PaneCompositeDescriptor {
        for (self.pane_composites.items) |descriptor| {
            if (std.mem.eql(u8, descriptor.id, id)) return descriptor;
        }
        return null;
    }

    /// Composites sorted by descriptor `order`, like upstream.
    pub fn getPaneComposites(self: *const PaneCompositePart, allocator: Allocator) ![]PaneCompositeDescriptor {
        const result = try allocator.dupe(PaneCompositeDescriptor, self.pane_composites.items);
        std.sort.insertion(PaneCompositeDescriptor, result, {}, struct {
            fn lessThan(_: void, a: PaneCompositeDescriptor, b: PaneCompositeDescriptor) bool {
                return a.order < b.order;
            }
        }.lessThan);
        return result;
    }

    /// Hides or shows a composite in the composite bar.
    pub fn setPaneCompositeVisible(self: *PaneCompositePart, id: []const u8, visible: bool) !bool {
        const changed = if (visible)
            self.bar.show(id)
        else
            self.bar.hide(id);
        if (changed) try self.on_did_change.fire({});
        return changed;
    }

    pub fn hidePaneComposite(self: *PaneCompositePart, id: []const u8) !bool {
        return self.setPaneCompositeVisible(id, false);
    }

    /// Opens (activates) `id`. Reveals the part, records the previously active
    /// composite and fires the open event. Returns the descriptor when the
    /// composite exists and is visible in the bar.
    pub fn openPaneComposite(self: *PaneCompositePart, id: []const u8, focus: bool) !?PaneCompositeDescriptor {
        _ = focus; // Focus routing belongs to the TUI host.
        const descriptor = self.getPaneComposite(id) orelse return null;
        // An explicit open re-shows a `hideIfEmpty` composite in the bar.
        _ = try self.bar.add(descriptor.id, descriptor.name, descriptor.order, null);
        if (self.active_id) |current| {
            if (std.mem.eql(u8, current, id)) {
                self.visible = true;
                return descriptor;
            }
            self.last_active_id = current;
        }
        self.active_id = descriptor.id;
        self.visible = true;
        _ = self.bar.activate(descriptor.id);
        try self.on_did_change.fire({});
        try self.on_did_pane_composite_open.fire(descriptor.id);
        return descriptor;
    }

    pub fn getActivePaneComposite(self: *const PaneCompositePart) ?PaneCompositeDescriptor {
        const id = self.active_id orelse return null;
        return self.getPaneComposite(id);
    }

    pub fn getLastActivePaneCompositeId(self: *const PaneCompositePart) []const u8 {
        return self.last_active_id orelse "";
    }

    /// Hides the part and clears the active composite, like upstream
    /// `hideActivePaneComposite`.
    pub fn hideActivePaneComposite(self: *PaneCompositePart) !void {
        if (self.active_id) |current| {
            self.last_active_id = current;
            self.active_id = null;
            _ = self.bar.deactivate();
            try self.on_did_pane_composite_close.fire(current);
        }
        if (self.visible) {
            self.visible = false;
        }
        try self.on_did_change.fire({});
    }

    pub fn getPinnedPaneCompositeIds(self: *const PaneCompositePart, allocator: Allocator) ![][]const u8 {
        const items = try self.bar.pinnedItems(allocator);
        defer allocator.free(items);
        var ids = std.array_list.Managed([]const u8).init(allocator);
        errdefer ids.deinit();
        for (items) |item| try ids.append(item.id);
        return ids.toOwnedSlice();
    }

    pub fn getVisiblePaneCompositeIds(self: *const PaneCompositePart, allocator: Allocator) ![][]const u8 {
        const items = try self.bar.visibleItems(allocator);
        defer allocator.free(items);
        var ids = std.array_list.Managed([]const u8).init(allocator);
        errdefer ids.deinit();
        for (items) |item| try ids.append(item.id);
        return ids.toOwnedSlice();
    }

    pub fn getPaneCompositeIds(self: *const PaneCompositePart, allocator: Allocator) ![][]const u8 {
        const items = try allocator.alloc([]const u8, self.bar.items.items.len);
        errdefer allocator.free(items);
        for (self.bar.items.items, 0..) |item, index| items[index] = item.id;
        return items;
    }

    pub fn setVisible(self: *PaneCompositePart, visible: bool) !void {
        if (self.visible == visible) return;
        self.visible = visible;
        try self.on_did_change.fire({});
    }

    pub fn isVisible(self: *const PaneCompositePart) bool {
        return self.visible;
    }

    /// Ordered, visible descriptors for the bar view. The returned slice is
    /// owned by the caller.
    pub fn visibleComposites(self: *const PaneCompositePart, allocator: Allocator) ![]PaneCompositeDescriptor {
        const ids = try self.getVisiblePaneCompositeIds(allocator);
        defer allocator.free(ids);
        var result = std.array_list.Managed(PaneCompositeDescriptor).init(allocator);
        errdefer result.deinit();
        for (ids) |id| {
            const descriptor = self.getPaneComposite(id) orelse continue;
            try result.append(descriptor);
        }
        return result.toOwnedSlice();
    }
};

test "paneCompositePart: open, hide and last active" {
    const allocator = std.testing.allocator;
    var part = PaneCompositePart.init(allocator, "workbench.registry.view.containers.panel", "workbench.parts.panel", .panel);
    defer part.deinit();

    try part.addPaneComposite(.{ .id = "workbench.panel.markers", .name = "Problems", .order = 0 });
    try part.addPaneComposite(.{ .id = "terminal", .name = "Terminal", .order = 3 });

    try std.testing.expect(!part.isVisible());
    const opened = try part.openPaneComposite("workbench.panel.markers", true);
    try std.testing.expectEqualStrings("workbench.panel.markers", opened.?.id);
    try std.testing.expect(part.isVisible());
    try std.testing.expectEqualStrings("workbench.panel.markers", part.getActivePaneComposite().?.id);

    _ = try part.openPaneComposite("terminal", false);
    try std.testing.expectEqualStrings("workbench.panel.markers", part.getLastActivePaneCompositeId());

    try part.hideActivePaneComposite();
    try std.testing.expect(!part.isVisible());
    try std.testing.expectEqualStrings("terminal", part.getLastActivePaneCompositeId());

    try std.testing.expect(try part.setPaneCompositeVisible("terminal", false));
    try std.testing.expect(part.bar.findItemConst("terminal").?.visible == false);
    // Opening a hidden composite re-shows it, like the browser bar.
    try std.testing.expect(try part.openPaneComposite("terminal", false) != null);
    const missing = try part.openPaneComposite("missing", false);
    try std.testing.expect(missing == null);
}
