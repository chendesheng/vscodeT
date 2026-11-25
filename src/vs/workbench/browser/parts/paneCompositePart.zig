// Port of the portable composite state in
// `src/vs/workbench/browser/parts/compositePart.ts` and
// `src/vs/workbench/browser/parts/paneCompositePart.ts`.
//
// `AbstractPaneCompositePart` extends `CompositePart`: it owns a composite bar
// (`workbench.contributions.panels` / `workbench.contributions.viewlets`), the
// pane composite registry, the title area and the composite lifecycle. The
// browser classes also build DOM containers, toolbars, menus, progress
// indicators and drag-and-drop. The terminal keeps the portable state here:
// the descriptor list, the composite bar model, the active/last-active
// composite, the title label, the title toolbar actions and the composite bar
// position. The part subclasses (`sidebarPart.zig`, `panel/panelPart.zig`)
// own their visibility, size and title view.
//
// Terminal adaptation: this file merges the two upstream classes because the
// terminal part has no DOM container, no composite instantiation and no shared
// registry beyond the descriptors the workbench fills in. Method names and
// ordering stay upstream-shaped (`updateTitle`, `onTitleAreaUpdate`,
// `hideActiveComposite`, `updateCompositeBar`). Opening a composite reveals the
// part in the browser (`layoutService.setPartHidden`); here the workbench
// reveals the owning part after `openPaneComposite` succeeds.

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

/// Port of `CompositeBarPosition`: where the pane composite bar lives when the
/// part shows it. `title` is the side bar title area, `top`/`bottom` are the
/// header/footer areas the activity bar takes over when it moves into the side
/// bar.
pub const CompositeBarPosition = enum { top, title, bottom };

/// Terminal projection of a title toolbar action; shared with the collapsible
/// view headers.
pub const TitleAction = views.TitleAction;

/// Port of `ICompositeTitleLabel`: the shared title label and the keybinding
/// label upstream shows in its tooltip.
pub const TitleLabel = struct {
    title: []const u8 = "",
    keybinding: ?[]const u8 = null,
};

pub const OpenEvent = struct {
    id: []const u8,
    focus: bool,
};

/// A composite-bar badge. Upstream badges come from the activity service; the
/// workbench passes a container's current description to the bar view.
pub const Badge = struct {
    id: []const u8,
    text: []const u8,
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
    /// Layout visibility of the owning part, like
    /// `layoutService.isVisible(partId)` upstream.
    visible: bool = false,
    /// `ICompositePartOptions.hasTitle` / `trailingSeparator`.
    has_title: bool = true,
    trailing_separator: bool = false,
    /// `CompositePart.activeComposite` / `lastActiveCompositeId`.
    active_id: ?[]const u8 = null,
    last_active_id: ?[]const u8 = null,
    title_label: TitleLabel = .{},
    /// `CompositePart.collectCompositeActions` result.
    primary_actions: std.array_list.Managed(TitleAction),
    secondary_actions: std.array_list.Managed(TitleAction),
    /// Upstream toggles the `has-actions` class on the title area.
    has_actions: bool = false,
    /// `AbstractPaneCompositePart.compositeBarPosition`: `null` while the part
    /// does not host the composite bar.
    composite_bar_position: ?CompositeBarPosition = null,
    on_did_pane_composite_open: Emitter(OpenEvent),
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
            .primary_actions = std.array_list.Managed(TitleAction).init(allocator),
            .secondary_actions = std.array_list.Managed(TitleAction).init(allocator),
            .on_did_pane_composite_open = Emitter(OpenEvent).init(allocator),
            .on_did_pane_composite_close = Emitter([]const u8).init(allocator),
            .on_did_change = Emitter(void).init(allocator),
        };
    }

    pub fn deinit(self: *PaneCompositePart) void {
        self.on_did_change.deinit();
        self.on_did_pane_composite_open.deinit();
        self.on_did_pane_composite_close.deinit();
        self.secondary_actions.deinit();
        self.primary_actions.deinit();
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

    /// Port of the `registry.onDidDeregister` listener: when the active
    /// composite disappears, open the first remaining visible composite, or
    /// hide the part when there is none left.
    pub fn removePaneComposite(self: *PaneCompositePart, id: []const u8) !void {
        for (self.pane_composites.items, 0..) |descriptor, index| {
            if (!std.mem.eql(u8, descriptor.id, id)) continue;
            _ = self.pane_composites.orderedRemove(index);
            _ = self.bar.remove(id);
            if (self.active_id != null and std.mem.eql(u8, self.active_id.?, id)) {
                self.active_id = null;
                if (self.firstVisibleCompositeId()) |next| {
                    _ = try self.openPaneComposite(next, false);
                } else {
                    self.visible = false;
                }
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

    /// Opens (activates) `id`, like `AbstractPaneCompositePart.openPaneComposite`.
    /// An active composite only receives focus; any other composite hides the
    /// current one first, which fires the close event exactly like
    /// `CompositePart.doOpenComposite`.
    pub fn openPaneComposite(self: *PaneCompositePart, id: []const u8, focus: bool) !?PaneCompositeDescriptor {
        const descriptor = self.getPaneComposite(id) orelse return null;
        // An explicit open re-shows a `hideIfEmpty` composite in the bar.
        _ = try self.bar.add(descriptor.id, descriptor.name, descriptor.order, null);
        if (self.active_id) |current| {
            if (std.mem.eql(u8, current, id)) {
                // Upstream focuses the already active composite and returns.
                self.visible = true;
                return descriptor;
            }
            _ = try self.hideActiveComposite();
        }

        // `CompositePart.doOpenComposite` updates the title before showing.
        self.updateTitle(descriptor.id, descriptor.name, null);
        self.active_id = descriptor.id;
        self.last_active_id = descriptor.id;
        self.visible = true;
        _ = self.bar.activate(descriptor.id);
        try self.on_did_change.fire({});
        try self.on_did_pane_composite_open.fire(.{ .id = descriptor.id, .focus = focus });
        return descriptor;
    }

    /// Port of `CompositePart.hideActiveComposite`: clears the active
    /// composite, empties the title actions and fires the close event.
    pub fn hideActiveComposite(self: *PaneCompositePart) !?[]const u8 {
        const current = self.active_id orelse return null;
        self.active_id = null;
        self.last_active_id = current;
        _ = self.bar.deactivate();
        try self.setTitleActions(&.{}, &.{});
        try self.on_did_pane_composite_close.fire(current);
        return current;
    }

    /// Port of `AbstractPaneCompositePart.hideActivePaneComposite`: hides the
    /// part first, then hides the active composite (which empties the title
    /// label, like `layoutEmptyMessage`).
    pub fn hideActivePaneComposite(self: *PaneCompositePart) !void {
        if (self.visible) {
            self.visible = false;
            try self.on_did_change.fire({});
        }
        _ = try self.hideActiveComposite();
        self.title_label = .{};
    }

    pub fn getActivePaneComposite(self: *const PaneCompositePart) ?PaneCompositeDescriptor {
        const id = self.active_id orelse return null;
        return self.getPaneComposite(id);
    }

    /// Restore the persisted CompositePart.activeCompositeSettingsKey without
    /// mounting a hidden viewlet. Use the descriptor-owned ID, not the parsed
    /// storage buffer, so the last-active state remains valid after restore.
    pub fn restoreLastActivePaneCompositeId(self: *PaneCompositePart, id: ?[]const u8) void {
        const value = id orelse return;
        const descriptor = self.getPaneComposite(value) orelse return;
        self.last_active_id = descriptor.id;
    }

    pub fn getLastActivePaneCompositeId(self: *const PaneCompositePart) []const u8 {
        return self.last_active_id orelse "";
    }

    /// Port of `CompositePart.updateTitle`: the title label is shared by all
    /// composites of the part, so an update for a non-active composite is
    /// dropped.
    pub fn updateTitle(self: *PaneCompositePart, id: []const u8, title: []const u8, keybinding: ?[]const u8) void {
        if (self.active_id) |active| {
            if (!std.mem.eql(u8, active, id)) return;
        }
        self.title_label = .{ .title = title, .keybinding = keybinding };
    }

    /// Port of `CompositePart.onTitleAreaUpdate`: the active composite changed
    /// its title or actions.
    pub fn onTitleAreaUpdate(
        self: *PaneCompositePart,
        id: []const u8,
        title: []const u8,
        primary: []const TitleAction,
        secondary: []const TitleAction,
    ) !void {
        if (self.active_id == null or !std.mem.eql(u8, self.active_id.?, id)) return;
        self.updateTitle(id, title, null);
        try self.setTitleActions(primary, secondary);
    }

    /// Port of `CompositePart.collectCompositeActions`.
    pub fn setTitleActions(
        self: *PaneCompositePart,
        primary: []const TitleAction,
        secondary: []const TitleAction,
    ) !void {
        self.primary_actions.clearRetainingCapacity();
        self.secondary_actions.clearRetainingCapacity();
        try self.primary_actions.appendSlice(primary);
        try self.secondary_actions.appendSlice(secondary);
        self.has_actions = self.primary_actions.items.len > 0 or self.secondary_actions.items.len > 0;
    }

    /// Port of `CompositePart.getProgressIndicator`. The terminal view has no
    /// progress indicator inside a composite, so there is nothing to return.
    pub fn getProgressIndicator(self: *const PaneCompositePart, id: []const u8) ?*anyopaque {
        _ = self;
        _ = id;
        return null;
    }

    /// Port of `AbstractPaneCompositePart.snap`: always allow snapping closed,
    /// only allow dragging open when the part contains visible containers.
    pub fn snap(self: *const PaneCompositePart) bool {
        if (self.visible) return true;
        for (self.bar.items.items) |item| {
            if (item.visible) return true;
        }
        return false;
    }

    /// Port of `AbstractPaneCompositePart.updateCompositeBar` state: the part
    /// hosts the composite bar at `position`, or not at all. The DOM container
    /// creation (header/footer/title area) is the owning part's job.
    pub fn setCompositeBar(
        self: *PaneCompositePart,
        show: bool,
        position: CompositeBarPosition,
    ) !bool {
        const wanted: ?CompositeBarPosition = if (show) position else null;
        if (self.composite_bar_position == wanted) return false;
        self.composite_bar_position = wanted;
        try self.on_did_change.fire({});
        return true;
    }

    pub fn shouldShowCompositeBar(self: *const PaneCompositePart) bool {
        return self.composite_bar_position != null;
    }

    pub fn getCompositeBarPosition(self: *const PaneCompositePart) ?CompositeBarPosition {
        return self.composite_bar_position;
    }

    pub fn getPinnedPaneCompositeIds(self: *const PaneCompositePart, allocator: Allocator) ![][]const u8 {
        if (!self.shouldShowCompositeBar()) return allocator.alloc([]const u8, 0);
        const items = try self.bar.pinnedItems(allocator);
        defer allocator.free(items);
        var ids = std.array_list.Managed([]const u8).init(allocator);
        errdefer ids.deinit();
        for (items) |item| try ids.append(item.id);
        return ids.toOwnedSlice();
    }

    pub fn getVisiblePaneCompositeIds(self: *const PaneCompositePart, allocator: Allocator) ![][]const u8 {
        if (!self.shouldShowCompositeBar()) return allocator.alloc([]const u8, 0);
        const items = try self.bar.visibleItems(allocator);
        defer allocator.free(items);
        var ids = std.array_list.Managed([]const u8).init(allocator);
        errdefer ids.deinit();
        for (items) |item| try ids.append(item.id);
        return ids.toOwnedSlice();
    }

    pub fn getPaneCompositeIds(self: *const PaneCompositePart, allocator: Allocator) ![][]const u8 {
        if (!self.shouldShowCompositeBar()) return allocator.alloc([]const u8, 0);
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

    /// First visible composite in bar order.
    pub fn firstVisibleCompositeId(self: *const PaneCompositePart) ?[]const u8 {
        for (self.bar.items.items) |item| {
            if (item.visible and self.getPaneComposite(item.id) != null) return item.id;
        }
        return null;
    }

    /// Ordered, visible descriptors for the bar view. The returned slice is
    /// owned by the caller.
    pub fn visibleComposites(self: *const PaneCompositePart, allocator: Allocator) ![]PaneCompositeDescriptor {
        const ids = try self.getVisibleBarIds(allocator);
        defer allocator.free(ids);
        var result = std.array_list.Managed(PaneCompositeDescriptor).init(allocator);
        errdefer result.deinit();
        for (ids) |id| {
            const descriptor = self.getPaneComposite(id) orelse continue;
            try result.append(descriptor);
        }
        return result.toOwnedSlice();
    }

    /// Visible bar ids regardless of whether the composite bar is hosted by the
    /// part. `visibleComposites` uses this so hiding the bar does not erase the
    /// model; the `get*PaneCompositeIds` API keeps the upstream empty-list
    /// behavior for a hidden bar.
    fn getVisibleBarIds(self: *const PaneCompositePart, allocator: Allocator) ![][]const u8 {
        const items = try self.bar.visibleItems(allocator);
        defer allocator.free(items);
        var ids = std.array_list.Managed([]const u8).init(allocator);
        errdefer ids.deinit();
        for (items) |item| try ids.append(item.id);
        return ids.toOwnedSlice();
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
    try std.testing.expectEqualStrings("Problems", part.title_label.title);

    _ = try part.openPaneComposite("terminal", false);
    // `showComposite` remembers the composite that is now active.
    try std.testing.expectEqualStrings("terminal", part.getLastActivePaneCompositeId());
    try std.testing.expectEqualStrings("Terminal", part.title_label.title);

    try part.hideActivePaneComposite();
    try std.testing.expect(!part.isVisible());
    try std.testing.expectEqualStrings("terminal", part.getLastActivePaneCompositeId());
    try std.testing.expectEqualStrings("", part.title_label.title);
    try std.testing.expect(!part.has_actions);

    try std.testing.expect(try part.setPaneCompositeVisible("terminal", false));
    try std.testing.expect(part.bar.findItemConst("terminal").?.visible == false);
    // Opening a hidden composite re-shows it, like the browser bar.
    try std.testing.expect(try part.openPaneComposite("terminal", false) != null);
    const missing = try part.openPaneComposite("missing", false);
    try std.testing.expect(missing == null);
}

test "paneCompositePart: title actions and composite bar position" {
    const allocator = std.testing.allocator;
    var part = PaneCompositePart.init(allocator, "workbench.contributions.viewlets", "workbench.parts.sidebar", .sidebar);
    defer part.deinit();

    try part.addPaneComposite(.{ .id = "explorer", .name = "Explorer", .order = 0 });
    try part.addPaneComposite(.{ .id = "search", .name = "Search", .order = 1 });

    // `snap` allows closing the part and dragging it open while it contains
    // visible view containers, whether or not it hosts the composite bar.
    try std.testing.expect(part.snap());
    try std.testing.expectEqual(@as(usize, 0), (try part.getVisiblePaneCompositeIds(allocator)).len);

    try std.testing.expect(try part.setCompositeBar(true, .title));
    try std.testing.expect(part.snap());
    try std.testing.expectEqual(CompositeBarPosition.title, part.getCompositeBarPosition().?);
    const visible = try part.getVisiblePaneCompositeIds(allocator);
    defer allocator.free(visible);
    try std.testing.expectEqual(@as(usize, 2), visible.len);
    try std.testing.expectEqualStrings("explorer", visible[0]);

    _ = try part.openPaneComposite("search", true);
    try std.testing.expectEqualStrings("Search", part.title_label.title);

    try part.setTitleActions(&.{.{ .id = "search.action.clearSearchResults", .label = "Clear Search Results", .glyph = 'x' }}, &.{});
    try std.testing.expect(part.has_actions);

    // Updates for an inactive composite are ignored.
    try part.onTitleAreaUpdate("explorer", "Explorer (renamed)", &.{}, &.{});
    try std.testing.expectEqualStrings("Search", part.title_label.title);
    try std.testing.expectEqualStrings("search.action.clearSearchResults", part.primary_actions.items[0].id);

    try part.onTitleAreaUpdate("search", "Search (renamed)", &.{}, &.{});
    try std.testing.expectEqualStrings("Search (renamed)", part.title_label.title);
    try std.testing.expect(!part.has_actions);
}

test "paneCompositePart: removing the active composite opens the next visible one" {
    const allocator = std.testing.allocator;
    var part = PaneCompositePart.init(allocator, "workbench.contributions.viewlets", "workbench.parts.sidebar", .sidebar);
    defer part.deinit();

    try part.addPaneComposite(.{ .id = "explorer", .name = "Explorer", .order = 0 });
    try part.addPaneComposite(.{ .id = "search", .name = "Search", .order = 1 });
    _ = try part.openPaneComposite("explorer", false);

    try part.removePaneComposite("explorer");
    try std.testing.expectEqualStrings("search", part.getActivePaneComposite().?.id);

    try part.removePaneComposite("search");
    try std.testing.expect(part.getActivePaneComposite() == null);
    try std.testing.expect(!part.isVisible());
}
