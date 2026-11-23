// Port of the portable group management and grid layout of
// `src/vs/workbench/browser/parts/editor/editorPart.ts`.
//
// The browser part owns the DOM grid widget, the group views and their sash
// controls. This port keeps the group registry, the oriented split tree from
// `src/vs/base/browser/ui/grid/grid.zig`, branch demotion when a group
// collapses, and the sash hit-test/resize math. Group rendering and tab
// interaction stay in `src/vs/workbench/browser/workbench.zig`.
//
// `GroupView` is a comptime parameter with this contract:
//
//   group: *EditorGroup
//   rect: ui.Rect
//   init(allocator, group) GroupView
//   deinit() void
//   layout() void
//
// The part owns the group views and destroys them in `deinit`; the TUI group
// view destroys its tab views there as well.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");

const grid = @import("../../../../base/browser/ui/grid/grid.zig");
const editor_groups = @import("../../../services/editor/common/editorGroupsService.zig");
const editor_mod = @import("../../../common/editor.zig");

const GroupDirection = editor_groups.GroupDirection;
const Orientation = grid.Orientation;

/// Upstream's terminal-adapted minimum pane sizes. The browser uses pixel
/// minima on its grid views; cells are the terminal unit.
pub const min_pane_width: usize = 10;
pub const min_pane_height: usize = 3;

pub fn EditorPart(comptime GroupView: type) type {
    return struct {
        const Self = @This();
        const LayoutNode = grid.Node(*GroupView);

        allocator: Allocator,
        service: *editor_groups.EditorGroupsService,
        group_views: std.array_list.Managed(*GroupView),
        root: *LayoutNode,
        /// Cell-border terminals draw dividers on cell edges. The glyph
        /// fallback needs a gutter cell.
        cell_borders: bool = false,
        cell_border_capabilities: ui.cell_border.Capabilities = .{},
        /// The split whose boundary is being dragged, if any.
        active_sash: ?*LayoutNode = null,
        /// Last viewport assigned by `layout`; sash resizes reuse it.
        viewport: ui.Rect = .{},

        /// Creates the part and the group view for the service's first group.
        pub fn init(
            allocator: Allocator,
            service: *editor_groups.EditorGroupsService,
        ) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            self.* = .{
                .allocator = allocator,
                .service = service,
                .group_views = std.array_list.Managed(*GroupView).init(allocator),
                .root = undefined,
            };
            errdefer self.group_views.deinit();

            const first = try self.createView(service.groups.items[0]);
            errdefer {
                first.deinit();
                allocator.destroy(first);
            }
            self.root = try grid.initNode(*GroupView, allocator, first);
            return self;
        }

        pub fn deinit(self: *Self) void {
            for (self.group_views.items) |view| {
                view.deinit();
                self.allocator.destroy(view);
            }
            self.group_views.deinit();
            grid.deinitRoot(*GroupView, self.allocator, self.root);
            self.allocator.destroy(self);
        }

        pub fn count(self: *const Self) usize {
            return self.group_views.items.len;
        }

        pub fn activeView(self: *const Self) ?*GroupView {
            return self.viewForGroup(self.service.activeGroup());
        }

        pub fn viewForGroup(self: *const Self, group: *editor_groups.EditorGroup) ?*GroupView {
            for (self.group_views.items) |view| {
                if (view.group == group) return view;
            }
            return null;
        }

        /// Upstream restores every serialized group into the grid. The TUI
        /// restores the groups as equal horizontal splits, because the split
        /// grid itself is not serialized yet.
        pub fn restoreGroups(self: *Self) !void {
            var index: usize = 1;
            while (index < self.service.groups.items.len) : (index += 1) {
                const view = try self.createView(self.service.groups.items[index]);
                errdefer {
                    _ = self.group_views.pop();
                    view.deinit();
                    self.allocator.destroy(view);
                }
                try grid.splitRoot(
                    *GroupView,
                    self.allocator,
                    &self.root,
                    self.group_views.items[index - 1],
                    .horizontal,
                    view,
                    false,
                );
            }
        }

        /// Upstream `addGroup(location, direction)`: creates the group view and
        /// inserts it into the split tree beside `target`.
        pub fn splitGroup(
            self: *Self,
            target: *GroupView,
            direction: Orientation,
            new_first: bool,
        ) !*GroupView {
            const group_direction: GroupDirection = switch (direction) {
                .horizontal => if (new_first) .LEFT else .RIGHT,
                .vertical => if (new_first) .UP else .DOWN,
            };
            const group = try self.service.addGroup(target.group, group_direction);
            errdefer _ = self.service.removeGroup(group) catch {};

            const view = try self.createView(group);
            errdefer {
                _ = self.group_views.pop();
                view.deinit();
                self.allocator.destroy(view);
            }

            try grid.splitRoot(
                *GroupView,
                self.allocator,
                &self.root,
                target,
                direction,
                view,
                new_first,
            );
            return view;
        }

        /// Upstream `removeGroup`: removes the view from the grid and the
        /// service, then disposes the view. The last group is kept.
        pub fn removeView(self: *Self, view: *GroupView) bool {
            if (self.group_views.items.len <= 1) return false;
            self.active_sash = null;
            if (!grid.removeRoot(*GroupView, self.allocator, &self.root, view)) return false;

            for (self.group_views.items, 0..) |candidate, index| {
                if (candidate == view) {
                    _ = self.group_views.orderedRemove(index);
                    break;
                }
            }
            // `removeGroup` unlistens the model from the group's inputs; run it
            // before the view (and its tabs) are disposed.
            self.service.removeGroup(view.group) catch {};
            view.deinit();
            self.allocator.destroy(view);
            return true;
        }

        /// Collapses an empty group out of the grid, keeping the last group so
        /// the part always has a target for the next editor.
        pub fn collapseView(self: *Self, view: *GroupView) bool {
            if (view.group.model.count() != 0 or self.service.count() <= 1) return false;
            if (!self.removeView(view)) return false;
            self.layout(self.viewport);
            return true;
        }

        pub fn setCellBorders(self: *Self, enabled: bool) void {
            if (self.cell_borders == enabled) return;
            self.cell_borders = enabled;
            self.layout(self.viewport);
        }

        /// Assigns rectangles to every group view and lays out its title
        /// control and active editor pane.
        pub fn layout(self: *Self, rect: ui.Rect) void {
            self.viewport = rect;
            grid.layoutRoot(*GroupView, self.root, self.contentRect(), self, gapCallback);
            self.syncRects(self.root);
            for (self.group_views.items) |view| view.layout();
        }

        /// Groups in `GroupsOrder.GRID_APPEARANCE` order: depth-first over the
        /// binary split tree (first branch before second). The workbench uses
        /// this for first/last/next/previous group commands.
        pub fn orderedViews(self: *Self, allocator: Allocator) ![]*GroupView {
            var views = std.array_list.Managed(*GroupView).init(allocator);
            errdefer views.deinit();
            try collectOrdered(GroupView, self.root, &views);
            return views.toOwnedSlice();
        }

        /// Moves `source` beside `target` without destroying either view.
        /// Mirrors the terminal subset of `Grid.moveView`.
        pub fn moveGroupView(
            self: *Self,
            source: *GroupView,
            target: *GroupView,
            direction: Orientation,
            new_first: bool,
        ) !void {
            self.active_sash = null;
            try grid.moveRoot(*GroupView, self.allocator, &self.root, source, target, direction, new_first);
            self.layout(self.viewport);
        }

        pub fn viewAt(self: *const Self, x: usize, y: usize) ?*GroupView {
            for (self.group_views.items) |view| {
                const rect = view.rect;
                if (x >= ui.cell.snap(rect.x) and x < ui.cell.snap(rect.right()) and
                    y >= ui.cell.snap(rect.y) and y < ui.cell.snap(rect.bottom()))
                {
                    return view;
                }
            }
            return null;
        }

        /// The split boundary under a cell, if any. Cell-border terminals put
        /// the shared edge between two cells, so both adjacent columns/rows are
        /// in the hit zone.
        pub fn dividerAt(self: *const Self, x: usize, y: usize) ?*LayoutNode {
            return findDivider(self, self.root, x, y);
        }

        /// The resize pointer a split boundary asks for: horizontal splits put
        /// panes side by side, so their boundary is an east-west resize handle;
        /// vertical splits use the north-south shape.
        pub fn sashPointer(self: *const Self, node: *LayoutNode) ui.Pointer {
            _ = self;
            return switch (node.kind) {
                .split => |split| if (split.direction == .horizontal) .ew_resize else .ns_resize,
                .leaf => .default,
            };
        }

        /// Starts, updates and ends a sash drag. Returns true while the pointer
        /// belongs to the sash.
        pub fn resizeSash(self: *Self, node: *LayoutNode, x: usize, y: usize) void {
            const split = switch (node.kind) {
                .split => |*value| value,
                .leaf => return,
            };
            const rect = node.rect;
            if (split.direction == .horizontal) {
                const available = rect.w - self.gap(.horizontal, rect);
                if (available < 2 * min_pane_width) return;
                const target = @as(f64, @floatFromInt(x)) - rect.x;
                const clamped = std.math.clamp(
                    target,
                    @as(f64, @floatFromInt(min_pane_width)),
                    available - @as(f64, @floatFromInt(min_pane_width)),
                );
                split.ratio = clamped / available;
            } else {
                const available = rect.h - self.gap(.vertical, rect);
                if (available < 2 * min_pane_height) return;
                const target = @as(f64, @floatFromInt(y)) - rect.y;
                const clamped = std.math.clamp(
                    target,
                    @as(f64, @floatFromInt(min_pane_height)),
                    available - @as(f64, @floatFromInt(min_pane_height)),
                );
                split.ratio = clamped / available;
            }
            self.layout(self.viewport);
        }

        /// Gutter cells between two panes. Cell borders need none.
        pub fn gap(self: *const Self, direction: Orientation, rect: ui.Rect) f64 {
            if (self.cell_borders) return 0;
            return switch (direction) {
                .horizontal => if (rect.w >= 6) 1 else 0,
                .vertical => if (rect.h >= 6) 1 else 0,
            };
        }

        /// Reserve edge cells only around the entire grid. Compact terminals
        /// keep those cells available for content.
        pub fn glyphFrame(self: *const Self) bool {
            return !self.cell_borders and self.viewport.w >= 24 and self.viewport.h >= 14;
        }

        pub fn contentRect(self: *const Self) ui.Rect {
            const rect = self.viewport;
            if (!self.glyphFrame()) return rect;
            return .{ .x = rect.x + 1, .y = rect.y + 1, .w = rect.w - 2, .h = rect.h - 2 };
        }

        fn gapCallback(self: *const Self, direction: Orientation, rect: ui.Rect) f64 {
            return self.gap(direction, rect);
        }

        fn createView(self: *Self, group: *editor_groups.EditorGroup) !*GroupView {
            const view = try self.allocator.create(GroupView);
            errdefer self.allocator.destroy(view);
            view.* = GroupView.init(self.allocator, group);
            errdefer view.deinit();
            try self.group_views.append(view);
            return view;
        }

        fn findDivider(
            self: *const Self,
            node: *LayoutNode,
            x: usize,
            y: usize,
        ) ?*LayoutNode {
            switch (node.kind) {
                .leaf => return null,
                .split => |split| {
                    const rect = node.rect;
                    if (split.direction == .horizontal) {
                        const edge = ui.cell.snap(split.first.rect.right());
                        const on_edge = x == edge or (self.gap(split.direction, rect) == 0 and x + 1 == edge);
                        if (on_edge and y >= ui.cell.snap(rect.y) and y < ui.cell.snap(rect.bottom())) {
                            return node;
                        }
                    } else {
                        const edge = ui.cell.snap(split.first.rect.bottom());
                        const on_edge = y == edge or (self.gap(split.direction, rect) == 0 and y + 1 == edge);
                        if (on_edge and x >= ui.cell.snap(rect.x) and x < ui.cell.snap(rect.right())) {
                            return node;
                        }
                    }
                    return self.findDivider(split.first, x, y) orelse
                        self.findDivider(split.second, x, y);
                },
            }
        }

        fn syncRects(self: *const Self, node: *LayoutNode) void {
            switch (node.kind) {
                .leaf => |view| view.rect = node.rect,
                .split => |split| {
                    self.syncRects(split.first);
                    self.syncRects(split.second);
                },
            }
        }
    };
}

fn collectOrdered(comptime T: type, node: *grid.Node(*T), views: *std.array_list.Managed(*T)) !void {
    switch (node.kind) {
        .leaf => |value| try views.append(value),
        .split => |split| {
            try collectOrdered(T, split.first, views);
            try collectOrdered(T, split.second, views);
        },
    }
}

const TestView = struct {
    group: *editor_groups.EditorGroup,
    rect: ui.Rect = .{},
    layouts: usize = 0,
    deinited: bool = false,

    pub fn init(allocator: Allocator, group: *editor_groups.EditorGroup) TestView {
        _ = allocator;
        return .{ .group = group };
    }

    pub fn deinit(self: *TestView) void {
        self.deinited = true;
    }

    pub fn layout(self: *TestView) void {
        self.layouts += 1;
    }
};

const TestPart = EditorPart(TestView);

test "EditorPart: creates the first group view and lays it out" {
    const allocator = std.testing.allocator;
    const service = try editor_groups.EditorGroupsService.init(allocator, .{});
    defer service.deinit();

    const part = try TestPart.init(allocator, service);
    defer part.deinit();

    try std.testing.expectEqual(@as(usize, 1), part.count());
    try std.testing.expectEqual(part.group_views.items[0], part.activeView().?);

    part.layout(.{ .x = 0, .y = 0, .w = 40, .h = 10 });
    try std.testing.expectEqual(@as(usize, 40), ui.cell.snap(part.group_views.items[0].rect.w));
    try std.testing.expectEqual(@as(usize, 1), part.group_views.items[0].layouts);
}

test "EditorPart: splitGroup inserts a view and removeView demotes the branch" {
    const allocator = std.testing.allocator;
    const service = try editor_groups.EditorGroupsService.init(allocator, .{});
    defer service.deinit();

    const part = try TestPart.init(allocator, service);
    defer part.deinit();

    const first = part.group_views.items[0];
    const second = try part.splitGroup(first, .horizontal, false);
    try std.testing.expectEqual(@as(usize, 2), part.count());
    try std.testing.expectEqual(second, part.activeView().?);

    part.layout(.{ .x = 0, .y = 0, .w = 50, .h = 10 });
    try std.testing.expectEqual(@as(usize, 24), ui.cell.snap(first.rect.w));
    try std.testing.expectEqual(ui.cell.snap(first.rect.right()) + 1, ui.cell.snap(second.rect.x));

    // The empty second group collapses and the first view is promoted.
    try std.testing.expect(part.collapseView(second));
    try std.testing.expectEqual(@as(usize, 1), part.count());
    switch (part.root.kind) {
        .leaf => |view| try std.testing.expectEqual(first, view),
        .split => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 50), ui.cell.snap(first.rect.w));
}

test "EditorPart: cell borders remove the gutter and expose both shared-edge cells" {
    const allocator = std.testing.allocator;
    const service = try editor_groups.EditorGroupsService.init(allocator, .{});
    defer service.deinit();

    const part = try TestPart.init(allocator, service);
    defer part.deinit();

    const first = part.group_views.items[0];
    _ = try part.splitGroup(first, .horizontal, false);
    part.setCellBorders(true);
    part.layout(.{ .x = 0, .y = 0, .w = 50, .h = 10 });

    const second = part.group_views.items[1];
    try std.testing.expectEqual(ui.cell.snap(first.rect.right()), ui.cell.snap(second.rect.x));
    const boundary = ui.cell.snap(first.rect.right());
    try std.testing.expectEqual(part.root, part.dividerAt(boundary, 2).?);
    try std.testing.expectEqual(part.root, part.dividerAt(boundary - 1, 2).?);
}

test "EditorPart: sash drag clamps the split ratio to the pane minimums" {
    const allocator = std.testing.allocator;
    const service = try editor_groups.EditorGroupsService.init(allocator, .{});
    defer service.deinit();

    const part = try TestPart.init(allocator, service);
    defer part.deinit();

    const first = part.group_views.items[0];
    _ = try part.splitGroup(first, .horizontal, false);
    part.setCellBorders(true);
    part.layout(.{ .x = 0, .y = 0, .w = 50, .h = 10 });

    part.resizeSash(part.root, 30, 2);
    try std.testing.expectEqual(@as(f64, 0.6), part.root.kind.split.ratio);
    try std.testing.expectEqual(@as(usize, 30), ui.cell.snap(first.rect.w));

    // Dragging past the minimum clamps to the minimum pane width.
    part.resizeSash(part.root, 1, 2);
    try std.testing.expectEqual(@as(usize, min_pane_width), ui.cell.snap(first.rect.w));
}
