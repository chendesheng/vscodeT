// Port of the portable layout state exercised by
// `src/vs/workbench/test/browser/layout.test.ts`.
//
// The pinned browser tests use CSS floating-panel gap offsets and DOM
// bounding rectangles, neither of which exists in cell geometry. The terminal
// cases below assert the corresponding immediate panel/sash boundary updates
// for normal and compact rails, alongside part visibility and size events.
// Layout owns the registered parts and grid; the host supplies cell dimensions.

const std = @import("std");
const layout_mod = @import("../../browser/layout.zig");
const LayoutModel = layout_mod.Layout;
const Parts = layout_mod.Parts;
const Position = layout_mod.Position;

test "LayoutModel: defaults and part visibility" {
    var layout = LayoutModel.init(std.testing.allocator);
    defer layout.deinit();

    try std.testing.expect(layout.isVisible(.titlebar));
    try std.testing.expect(layout.isVisible(.activitybar));
    try std.testing.expect(layout.isVisible(.sidebar));
    try std.testing.expect(layout.isVisible(.editor));
    try std.testing.expect(layout.isVisible(.statusbar));
    try std.testing.expectEqual(Position.left, layout.getSideBarPosition());

    try layout.setPartHidden(true, .sidebar);
    try std.testing.expect(!layout.isVisible(.sidebar));
    try layout.setPartHidden(true, .sidebar);
    try std.testing.expect(!layout.isVisible(.sidebar));
    try layout.setPartHidden(false, .sidebar);
    try std.testing.expect(layout.isVisible(.sidebar));
}

test "LayoutModel: sizes and sidebar position fire changes" {
    var layout = LayoutModel.init(std.testing.allocator);
    defer layout.deinit();

    var changes: usize = 0;
    try layout.on_did_change.event(&changes, struct {
        fn callback(_: void, context: *usize) !void {
            context.* += 1;
        }
    }.callback);

    try layout.setSize(.sidebar, 28);
    try std.testing.expectEqual(@as(usize, 28), layout.size(.sidebar));
    try std.testing.expectEqual(@as(usize, 1), changes);

    try layout.setSize(.sidebar, 28);
    try std.testing.expectEqual(@as(usize, 1), changes);

    try layout.setSideBarPosition(.right);
    try std.testing.expectEqual(Position.right, layout.getSideBarPosition());
    try std.testing.expectEqual(@as(usize, 2), changes);
}

test "LayoutModel: zen mode and centered layout state fire their events" {
    var layout = LayoutModel.init(std.testing.allocator);
    defer layout.deinit();

    var zen_changes: usize = 0;
    try layout.on_did_change_zen_mode.event(&zen_changes, struct {
        fn callback(_: bool, context: *usize) !void {
            context.* += 1;
        }
    }.callback);
    var centered_changes: usize = 0;
    try layout.on_did_change_main_editor_centered.event(&centered_changes, struct {
        fn callback(_: bool, context: *usize) !void {
            context.* += 1;
        }
    }.callback);

    try std.testing.expect(!layout.isZenModeActive());
    layout.setZenModeActive(true);
    try layout.fireZenModeChanged();
    try std.testing.expect(layout.isZenModeActive());
    try std.testing.expectEqual(@as(usize, 1), zen_changes);
    layout.setZenModeActive(false);
    try layout.fireZenModeChanged();
    try std.testing.expectEqual(@as(usize, 2), zen_changes);

    try std.testing.expect(!layout.isMainEditorCentered());
    try std.testing.expect(!layout.isMainEditorCenteredEffective());
    try layout.centerMainEditorLayout(true, false);
    try std.testing.expect(layout.isMainEditorCentered());
    try std.testing.expect(layout.isMainEditorCenteredEffective());
    try std.testing.expectEqual(@as(usize, 1), centered_changes);
}

test "registered panel changes reach layout listeners in grid notification order" {
    const service = @import("../../services/layout/browser/layoutService.zig");
    var layout = layout_mod.Layout.init(std.testing.allocator);
    defer layout.deinit();
    const api = layout.interface();
    var panel = PanelPart.init(std.testing.allocator);
    var panel_alive = true;
    defer if (panel_alive) panel.deinit();
    try panel.base.register(api);
    try layout.createWorkbenchLayout();
    try std.testing.expectEqual(&panel.base, try layout.getPart(.panel));
    const Trace = struct {
        layout: *layout_mod.Layout,
        events: [4]u8 = undefined,
        count: usize = 0,
        fn visibility(event: service.IPartVisibilityChangeEvent, self: *@This()) !void {
            try std.testing.expectEqual(Parts.panel, event.part_id);
            try std.testing.expectEqual(event.visible, self.layout.isVisible(.panel));
            self.events[self.count] = if (event.visible) 'V' else 'H';
            self.count += 1;
        }
        fn changed(_: void, self: *@This()) !void {
            self.events[self.count] = 'L';
            self.count += 1;
        }
    };
    var trace = Trace{ .layout = &layout };
    _ = try api.on_did_change_part_visibility.listen(&trace, Trace.visibility);
    _ = try layout.on_did_change.listen(&trace, Trace.changed);
    try api.setPartHidden(false, .panel);
    try api.setPartHidden(false, .panel);
    try panel.setVisible(false);
    try std.testing.expectEqualStrings("VLHL", trace.events[0..trace.count]);
    panel.deinit();
    panel_alive = false;
    try std.testing.expectError(error.UnknownPart, layout.getPart(.panel));
}

test "Layout.initLayout observes the active editor after group restore and detaches on disposal" {
    const Tab = @import("../../browser/parts/editor/editorPane.zig").Tab;
    const Group = @import("../../browser/parts/editor/editorGroupView.zig").EditorGroupView(*Tab);
    const GroupService = @import("../../services/editor/common/editorGroupsService.zig").EditorGroupsService;
    const EditorPart = @import("../../browser/parts/editor/editorPart.zig").EditorPart(Group);
    const allocator = std.testing.allocator;
    const service = try GroupService.init(allocator, .{});
    defer service.deinit();
    const part = try EditorPart.init(allocator, service);
    defer part.deinit();
    const before = service.on_did_active_editor_change.listenerCount();

    // A window can be closed while its editor groups are still restoring.
    {
        var layout = LayoutModel.init(allocator);
        defer layout.deinit();
        try layout.initLayout(part);
        try std.testing.expectEqual(before, service.on_did_active_editor_change.listenerCount());
        try std.testing.expectEqual(1, part.on_did_add_group.listenerCount());
    }
    try std.testing.expectEqual(0, part.on_did_add_group.listenerCount());
    {
        var layout = LayoutModel.init(allocator);
        defer layout.deinit();
        try layout.initLayout(part);
        try part.when_restored.open(allocator);
        try std.testing.expectEqual(before + 1, service.on_did_active_editor_change.listenerCount());
        var changes: usize = 0;
        try layout.on_did_change_main_editor_centered.event(&changes, struct {
            fn changed(_: bool, count: *usize) !void {
                count.* += 1;
            }
        }.changed);
        try service.on_did_active_editor_change.fire(null);
        try std.testing.expectEqual(1, changes);
    }
    try std.testing.expectEqual(before, service.on_did_active_editor_change.listenerCount());
}

const PanelPart = @import("../../browser/parts/panel/panelPart.zig").PanelPart;
const PanelAlignment = @import("../../services/layout/browser/layoutService.zig").PanelAlignment;
const Grid = layout_mod.WorkbenchGrid;
const ui = @import("ui");

const SashEndpointHarness = struct {
    layout: *LayoutModel,
    panel: *PanelPart,
    activity_width: usize,
    rects: Grid.Rects = undefined,
    position_events: usize = 0,
    alignment_events: usize = 0,

    fn changed(_: void, self: *@This()) !void {
        self.rects = Grid.layout(.{ .x = 0, .y = 0, .w = 80, .h = 23 }, self.activity_width, self.layout.size(.sidebar), self.layout.size(.panel), self.layout.getSideBarPosition(), self.layout.getPanelPosition(), self.layout.getPanelAlignment());
        self.layout.layout(80, 24, self.rects, .{ .x = 0, .y = 23, .w = 80, .h = 1 });
    }

    fn assertEndpoints(self: *@This()) !void {
        const rects = self.rects;
        try std.testing.expectEqual(rects.panel, self.panel.base.bounds.?);
        try std.testing.expectEqual(@as(f64, @floatFromInt(self.activity_width)), rects.activity_bar.w);
        try std.testing.expectEqual(ui.cell.snap(rects.sidebar.right()) - 1, rects.sidebarSashCell());
        switch (rects.panel_position) {
            .top => try std.testing.expectEqual(rects.panel.bottom(), rects.editor.y),
            .bottom => try std.testing.expectEqual(rects.editor.bottom(), rects.panel.y),
            .left => try std.testing.expectEqual(rects.panel.right(), rects.editor.x),
            .right => try std.testing.expectEqual(rects.editor.right(), rects.panel.x),
        }
    }

    fn positionChanged(position: Position, self: *@This()) !void {
        // Layout's synchronous grid/layout event must have run before the
        // position event, not on a later input tick or render.
        try std.testing.expectEqual(position, self.rects.panel_position);
        try std.testing.expectEqual(position, self.panel.getPosition());
        try self.assertEndpoints();
        self.position_events += 1;
    }

    fn alignmentChanged(alignment: PanelAlignment, self: *@This()) !void {
        try std.testing.expectEqual(alignment, self.rects.panel_alignment);
        try self.assertEndpoints();
        if (alignment == .justify) {
            try std.testing.expectEqual(self.rects.activity_bar.right(), self.rects.panel.x);
            try std.testing.expectEqual(@as(f64, 80), self.rects.panel.right());
        } else {
            try std.testing.expectEqual(self.rects.editor_column.x, self.rects.panel.x);
        }
        self.alignment_events += 1;
    }
};

test "refreshes cell sash endpoints immediately after panel position changes, normal and compact" {
    const allocator = std.testing.allocator;
    for ([_]usize{ 3, 2 }) |activity_width| {
        var layout = LayoutModel.init(allocator);
        defer layout.deinit();
        var panel = PanelPart.init(allocator);
        defer panel.deinit();
        try panel.base.register(layout.interface());
        try layout.createWorkbenchLayout();
        try layout.setSize(.sidebar, 20);
        try layout.setPartHidden(false, .panel);
        try layout.setSize(.panel, 6);
        var harness = SashEndpointHarness{ .layout = &layout, .panel = &panel, .activity_width = activity_width };
        _ = try layout.on_did_change.listen(&harness, SashEndpointHarness.changed);
        _ = try layout.on_did_change_panel_position.listen(&harness, SashEndpointHarness.positionChanged);
        try SashEndpointHarness.changed({}, &harness);
        for ([_]Position{ .right, .top, .bottom }) |position| try layout.setPanelPosition(position);
        try std.testing.expectEqual(@as(usize, 3), harness.position_events);
    }
}

test "refreshes cell sash endpoints immediately after panel alignment changes, normal and compact" {
    const allocator = std.testing.allocator;
    for ([_]usize{ 3, 2 }) |activity_width| {
        var layout = LayoutModel.init(allocator);
        defer layout.deinit();
        var panel = PanelPart.init(allocator);
        defer panel.deinit();
        try panel.base.register(layout.interface());
        try layout.createWorkbenchLayout();
        try layout.setSize(.sidebar, 20);
        try layout.setPartHidden(false, .panel);
        try layout.setSize(.panel, 6);
        var harness = SashEndpointHarness{ .layout = &layout, .panel = &panel, .activity_width = activity_width };
        _ = try layout.on_did_change.listen(&harness, SashEndpointHarness.changed);
        _ = try layout.on_did_change_panel_alignment.listen(&harness, SashEndpointHarness.alignmentChanged);
        try SashEndpointHarness.changed({}, &harness);
        for ([_]PanelAlignment{ .justify, .right, .center }) |alignment| try layout.setPanelAlignment(alignment);
        try std.testing.expectEqual(@as(usize, 3), harness.alignment_events);
    }
}
