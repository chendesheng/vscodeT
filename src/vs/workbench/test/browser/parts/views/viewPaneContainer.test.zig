// Terminal coverage for the PaneView layout, focus, toolbar, and drag paths.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui");
const views = @import("../../../../common/views.zig");
const model_mod = @import("../../../../services/views/common/viewContainerModel.zig");
const container_mod = @import("../../../../browser/parts/views/viewPaneContainer.zig");

const TestPane = struct {
    renders: usize = 0,
    actions_run: usize = 0,
    actions_list: []const views.TitleAction = &.{},

    fn render(context: *anyopaque, _: *ui.CellGrid, _: ui.Rect, _: bool) anyerror!void {
        const self: *TestPane = @ptrCast(@alignCast(context));
        self.renders += 1;
    }
    fn key(_: *anyopaque, _: *ui.KeyEvent) anyerror!bool {
        return false;
    }
    fn mouse(_: *anyopaque, _: *const ui.MouseEvent, _: ui.Rect) anyerror!bool {
        return false;
    }
    fn runAction(context: *anyopaque, _: []const u8) void {
        const self: *TestPane = @ptrCast(@alignCast(context));
        self.actions_run += 1;
    }
    fn actions(context: *anyopaque) []const views.TitleAction {
        const self: *TestPane = @ptrCast(@alignCast(context));
        return self.actions_list;
    }
};

test "ViewPaneContainer: splits rows by weight and collapses to a header" {
    const allocator = testing.allocator;
    var model = model_mod.ViewContainerModel.init(allocator, .{ .id = "scm", .title = "Source Control", .icon = "" });
    defer model.deinit();
    try model.addView(.{ .id = "changes", .name = "Changes", .order = 1, .weight = 40 });
    try model.addView(.{ .id = "graph", .name = "Graph", .order = 2, .weight = 40 });

    var first = TestPane{};
    var second = TestPane{};
    const panes = [_]container_mod.Pane{
        .{ .id = "changes", .title = "Changes", .context = &first, .render_body = TestPane.render, .handle_key = TestPane.key, .handle_mouse = TestPane.mouse, .title_actions = TestPane.actions },
        .{ .id = "graph", .title = "Graph", .context = &second, .render_body = TestPane.render, .handle_key = TestPane.key, .handle_mouse = TestPane.mouse, .title_actions = TestPane.actions, .show_actions = .when_expanded },
    };
    const container = try container_mod.ViewPaneContainer.init(allocator, &model, &panes);
    defer {
        container.deinit();
        allocator.destroy(container);
    }

    const rect = ui.Rect{ .x = 0, .y = 0, .w = 20, .h = 10 };
    try container.layout(rect);
    try testing.expectEqual(@as(usize, 2), container.sections.items.len);
    try testing.expectEqual(@as(f64, 1), container.sections.items[0].header_rect.h);
    try testing.expectEqual(@as(f64, 4), container.sections.items[0].body_rect.h);
    try testing.expectEqual(@as(f64, 3), container.sections.items[1].body_rect.h);
    const changes_body = container.sections.items[0].body_rect.h;
    const graph_body = container.sections.items[1].body_rect.h;

    model.setCollapsed("graph", true);
    try container.layout(rect);
    try testing.expectEqual(@as(f64, 0), container.sections.items[1].body_rect.h);
    try testing.expect(container.sections.items[0].body_rect.h > changes_body);
    try testing.expect(container.sections.items[0].body_rect.h >= changes_body + graph_body - 1);

    // Clicking the (now bottom) Graph header toggles it.
    const graph_header_y = ui.cell.snap(container.sections.items[1].header_rect.y);
    const header_hit = container.hitTest(rect, 1, graph_header_y);
    try testing.expect(header_hit != null);
    var click = ui.MouseEvent{ .kind = .click, .x = 1, .y = graph_header_y, .button = .left };
    try testing.expect(try container.handleMouse(&click, rect));
    try testing.expect(!model.isCollapsed("graph"));
}

test "ViewPaneContainer: pointer motion over a header never toggles the section" {
    const allocator = testing.allocator;
    var model = model_mod.ViewContainerModel.init(allocator, .{ .id = "scm", .title = "Source Control", .icon = "" });
    defer model.deinit();
    try model.addView(.{ .id = "changes", .name = "Changes", .order = 1, .weight = 40 });
    try model.addView(.{ .id = "graph", .name = "Graph", .order = 2, .weight = 40 });

    var first = TestPane{};
    var graph_actions = [_]views.TitleAction{
        .{ .id = "graph.refresh", .label = "Refresh", .glyph = '\u{27F3}' },
    };
    var second = TestPane{ .actions_list = &graph_actions };
    const panes = [_]container_mod.Pane{
        .{ .id = "changes", .title = "Changes", .context = &first, .render_body = TestPane.render, .handle_key = TestPane.key, .handle_mouse = TestPane.mouse, .title_actions = TestPane.actions },
        .{ .id = "graph", .title = "Graph", .context = &second, .render_body = TestPane.render, .handle_key = TestPane.key, .handle_mouse = TestPane.mouse, .title_actions = TestPane.actions, .show_actions = .when_expanded },
    };
    const container = try container_mod.ViewPaneContainer.init(allocator, &model, &panes);
    defer {
        container.deinit();
        allocator.destroy(container);
    }

    const rect = ui.Rect{ .x = 0, .y = 0, .w = 20, .h = 10 };
    var grid = try ui.CellGrid.init(allocator, 20, 10);
    defer grid.deinit();
    try container.render(&grid, rect, false, null);

    const header_y = ui.cell.snap(container.sections.items[1].header_rect.y);
    const action_node = blk: {
        for (container.headers.items[1].nodes.items) |entry| {
            if (entry.id.len != 0) break :blk entry.node;
        }
        return error.TestUnexpectedResult;
    };
    var over_title = ui.MouseEvent{ .kind = .move, .x = 1, .y = header_y };
    try testing.expect(try container.handleMouse(&over_title, rect));
    try testing.expect(!model.isCollapsed("graph"));
    try testing.expect(!action_node.isHovered());

    // Motion over a title action marks it hovered (the ui library paints the
    // declared HoverStyle) but never runs it or toggles the section.
    var action_x: ?usize = null;
    var x: usize = 19;
    while (x > 0) : (x -= 1) {
        const hit = container.hitTest(rect, x, header_y) orelse continue;
        if (std.meta.activeTag(hit) == .action) {
            action_x = x;
            break;
        }
    }
    try testing.expect(action_x != null);
    container.setHoveredAt(action_x.?, header_y);
    try testing.expect(action_node.isHovered());
    var over_action = ui.MouseEvent{ .kind = .move, .x = action_x.?, .y = header_y };
    try testing.expect(try container.handleMouse(&over_action, rect));
    try testing.expect(!model.isCollapsed("graph"));

    // Leaving the header clears the action hover.
    container.setHoveredAt(1, header_y + 1);
    try testing.expect(!action_node.isHovered());
    container.setHoveredAt(action_x.?, header_y);
    try testing.expect(action_node.isHovered());
    container.clearHover();
    try testing.expect(container.headers.items[1].surface.?.document().hoverTarget() == null);
    try testing.expect(!action_node.isHovered());

    // A header rebuild (here: activation + focus changes the signature) keeps
    // the pointer cell; the surface re-resolves it against the new nodes.
    container.setHoveredAt(action_x.?, header_y);
    container.setActive("graph");
    try container.render(&grid, rect, true, null);
    const rebuilt_action = blk: {
        for (container.headers.items[1].nodes.items) |entry| {
            if (entry.id.len != 0) break :blk entry.node;
        }
        return error.TestUnexpectedResult;
    };
    try testing.expect(rebuilt_action.isHovered());
    container.clearHover();

    // Releasing the pointer or a non-left press does not toggle either.
    var release = ui.MouseEvent{ .kind = .up, .x = 1, .y = header_y, .button = .left };
    try testing.expect(try container.handleMouse(&release, rect));
    try testing.expect(!model.isCollapsed("graph"));
    var right_press = ui.MouseEvent{ .kind = .down, .x = 1, .y = header_y, .button = .right };
    try testing.expect(try container.handleMouse(&right_press, rect));
    try testing.expect(!model.isCollapsed("graph"));

    // The left click (upstream's header click listener) toggles.
    var click = ui.MouseEvent{ .kind = .click, .x = 1, .y = header_y, .button = .left };
    try testing.expect(try container.handleMouse(&click, rect));
    try testing.expect(model.isCollapsed("graph"));
}

test "ViewPaneContainer: a single visible view merges into the container" {
    const allocator = testing.allocator;
    var model = model_mod.ViewContainerModel.init(allocator, .{ .id = "scm", .title = "Source Control", .icon = "" });
    defer model.deinit();
    try model.addView(.{ .id = "changes", .name = "Changes", .order = 1, .weight = 40 });
    try model.addView(.{ .id = "graph", .name = "Graph", .order = 2, .weight = 40, .visible = false });

    var first = TestPane{};
    var second = TestPane{};
    const panes = [_]container_mod.Pane{
        .{ .id = "changes", .title = "Changes", .context = &first, .render_body = TestPane.render, .handle_key = TestPane.key, .handle_mouse = TestPane.mouse, .title_actions = TestPane.actions },
        .{ .id = "graph", .title = "Graph", .context = &second, .render_body = TestPane.render, .handle_key = TestPane.key, .handle_mouse = TestPane.mouse, .title_actions = TestPane.actions, .show_actions = .when_expanded },
    };
    const container = try container_mod.ViewPaneContainer.init(allocator, &model, &panes);
    defer {
        container.deinit();
        allocator.destroy(container);
    }

    const rect = ui.Rect{ .x = 0, .y = 0, .w = 20, .h = 10 };
    try container.layout(rect);
    try testing.expectEqual(@as(usize, 1), container.sections.items.len);
    try testing.expectEqual(@as(f64, 0), container.sections.items[0].header_rect.h);
    try testing.expectEqual(@as(f64, 10), container.sections.items[0].body_rect.h);
    try testing.expectEqualStrings("changes", container.sections.items[0].id);
}

test "ViewPaneContainer: CSS action visibility and keyboard focus follow pane state" {
    const allocator = testing.allocator;
    var model = model_mod.ViewContainerModel.init(allocator, .{ .id = "scm", .title = "Source Control", .icon = "" });
    defer model.deinit();
    try model.addView(.{ .id = "changes", .name = "Changes", .order = 1 });
    try model.addView(.{ .id = "graph", .name = "Graph", .order = 2 });
    var first = TestPane{ .actions_list = &.{.{ .id = "changes.refresh", .label = "Refresh", .glyph = '↻' }} };
    var second = TestPane{ .actions_list = &.{.{ .id = "graph.refresh", .label = "Refresh", .glyph = '↻' }} };
    const panes = [_]container_mod.Pane{
        .{ .id = "changes", .title = "Changes", .context = &first, .render_body = TestPane.render, .handle_key = TestPane.key, .handle_mouse = TestPane.mouse, .title_actions = TestPane.actions, .run_title_action = TestPane.runAction },
        .{ .id = "graph", .title = "Graph", .context = &second, .render_body = TestPane.render, .handle_key = TestPane.key, .handle_mouse = TestPane.mouse, .title_actions = TestPane.actions, .show_actions = .when_expanded },
    };
    const container = try container_mod.ViewPaneContainer.init(allocator, &model, &panes);
    defer {
        container.deinit();
        allocator.destroy(container);
    }
    const rect: ui.Rect = .{ .x = 0, .y = 0, .w = 20, .h = 12 };
    var grid = try ui.CellGrid.init(allocator, 20, 12);
    defer grid.deinit();
    try container.render(&grid, rect, false, null);
    try testing.expectEqual(@as(usize, 0), container.headers.items[0].actions.len);
    try testing.expectEqual(@as(usize, 1), container.headers.items[1].actions.len);
    container.always_show_header_actions = true;
    try container.render(&grid, rect, false, null);
    try testing.expectEqual(@as(usize, 1), container.headers.items[0].actions.len);
    container.always_show_header_actions = false;

    container.setHoveredAt(3, 2); // Hovering the body also reveals the header toolbar.
    try container.render(&grid, rect, false, null);
    try testing.expectEqual(@as(usize, 1), container.headers.items[0].actions.len);
    container.clearHover();

    var key: ui.KeyEvent = .{ .key = .backtab };
    try testing.expect(try container.handleKey(&key));
    try testing.expectEqualStrings("changes", container.focused_header.?);
    key.key = .tab;
    try testing.expect(try container.handleKey(&key));
    key.key = .enter;
    try testing.expect(try container.handleKey(&key));
    try testing.expectEqual(@as(usize, 1), first.actions_run);
    try testing.expect(!model.isCollapsed("changes"));

    key.key = .backtab;
    try testing.expect(try container.handleKey(&key));
    key.key = .down;
    try testing.expect(try container.handleKey(&key));
    try testing.expectEqualStrings("graph", container.focused_header.?);
    key.key = .left;
    try testing.expect(try container.handleKey(&key));
    try container.render(&grid, rect, true, null);
    try testing.expect(model.isCollapsed("graph"));
    try testing.expectEqual(@as(usize, 0), container.headers.items[1].actions.len);
    key.key = .right;
    try testing.expect(try container.handleKey(&key));
    try testing.expect(!model.isCollapsed("graph"));
}

test "ViewPaneContainer: a sash resizes the nearest expanded panes and dragging a header moves it" {
    const allocator = testing.allocator;
    var model = model_mod.ViewContainerModel.init(allocator, .{ .id = "test", .title = "Views", .icon = "" });
    defer model.deinit();
    try model.addView(.{ .id = "a", .name = "A", .order = 1 });
    try model.addView(.{ .id = "b", .name = "B", .order = 2 });
    try model.addView(.{ .id = "c", .name = "C", .order = 3 });

    var first = TestPane{};
    var second = TestPane{};
    var third = TestPane{};
    const panes = [_]container_mod.Pane{
        .{ .id = "a", .title = "A", .context = &first, .render_body = TestPane.render, .handle_key = TestPane.key, .handle_mouse = TestPane.mouse, .title_actions = TestPane.actions },
        .{ .id = "b", .title = "B", .context = &second, .render_body = TestPane.render, .handle_key = TestPane.key, .handle_mouse = TestPane.mouse, .title_actions = TestPane.actions },
        .{ .id = "c", .title = "C", .context = &third, .render_body = TestPane.render, .handle_key = TestPane.key, .handle_mouse = TestPane.mouse, .title_actions = TestPane.actions },
    };
    const container = try container_mod.ViewPaneContainer.init(allocator, &model, &panes);
    defer {
        container.deinit();
        allocator.destroy(container);
    }

    const rect: ui.Rect = .{ .x = 0, .y = 0, .w = 20, .h = 20 };
    try container.layout(rect);
    try testing.expectEqual(@as(usize, 2), container.sashes.items.len);
    const first_size = container.bodyRect("a").?.h;
    const middle_size = container.bodyRect("b").?.h;
    var event: ui.MouseEvent = .{ .kind = .down, .button = .left, .x = 3, .y = ui.cell.snap(container.sashes.items[1].rect.y) };
    try testing.expect(container.handleSashMouse(&event));
    event.kind = .up;
    event.y += 2;
    try testing.expect(container.handleSashMouse(&event));
    try container.layout(rect);
    try testing.expectEqual(first_size, container.bodyRect("a").?.h);
    try testing.expectEqual(middle_size + 2, container.bodyRect("b").?.h);

    var grid = try ui.CellGrid.init(allocator, 20, 20);
    defer grid.deinit();
    event.kind = .down;
    event.y = ui.cell.snap(container.sections.items[2].header_rect.y);
    try testing.expect(try container.handleMouse(&event, rect));
    const source_y = event.y;
    try container.render(&grid, rect, true, null);
    const upper_body_y: usize = 1;
    const lower_body_y = ui.cell.snap(container.sections.items[0].body_rect.bottom()) - 1;
    const upper_bg = grid.bg[grid.index(event.x, upper_body_y)];
    const lower_bg = grid.bg[grid.index(event.x, lower_body_y)];
    const header_bg = grid.bg[grid.index(event.x, 0)];
    event.kind = .move;
    event.y = upper_body_y;
    try testing.expect(try container.handleMouse(&event, rect));
    try container.render(&grid, rect, true, null);
    try testing.expect(upper_bg != grid.bg[grid.index(event.x, upper_body_y)]);
    try testing.expectEqual(lower_bg, grid.bg[grid.index(event.x, lower_body_y)]);
    event.y = lower_body_y;
    try testing.expect(try container.handleMouse(&event, rect));
    try container.render(&grid, rect, true, null);
    try testing.expectEqual(header_bg, grid.bg[grid.index(event.x, 0)]);
    try testing.expectEqual(upper_bg, grid.bg[grid.index(event.x, upper_body_y)]);
    try testing.expect(lower_bg != grid.bg[grid.index(event.x, lower_body_y)]);
    event.y = source_y;
    try testing.expect(try container.handleMouse(&event, rect));
    try testing.expect(container.drop_target == null);
    event.y = lower_body_y;
    event.kind = .up;
    try testing.expect(try container.handleMouse(&event, rect));
    try container.layout(rect);
    try testing.expectEqualStrings("a", container.sections.items[0].id);
    try testing.expectEqualStrings("c", container.sections.items[1].id);
    try testing.expect(container.drop_target == null);

    event.kind = .down;
    event.y = ui.cell.snap(container.sections.items[1].header_rect.y);
    try testing.expect(try container.handleMouse(&event, rect));
    event.kind = .move;
    event.y = 0;
    try testing.expect(try container.handleMouse(&event, rect));
    event.kind = .up;
    try testing.expect(try container.handleMouse(&event, rect));
    try container.layout(rect);
    try testing.expectEqualStrings("c", container.sections.items[0].id);
    try testing.expect(!model.isCollapsed("c"));

    model.setCollapsed("a", true);
    try container.layout(rect);
    try testing.expectEqual(@as(usize, 2), container.sashes.items.len);
    try testing.expectEqual(@as(usize, 0), container.sashes.items[0].first);
    try testing.expectEqual(@as(usize, 2), container.sashes.items[0].second);
}

test "ViewPaneContainer: body visibility follows collapse, descriptor and composite events without layout" {
    const allocator = testing.allocator;
    var model = model_mod.ViewContainerModel.init(allocator, .{ .id = "test", .title = "Views", .icon = "" });
    defer model.deinit();
    try model.addView(.{ .id = "first", .name = "First", .order = 0 });
    try model.addView(.{ .id = "second", .name = "Second", .order = 1, .collapsed = true });
    const Probe = struct {
        visible: bool = false,
        body: bool = false,
        changes: usize = 0,
        fn visibleChanged(context: *anyopaque, visible: bool) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.visible = visible;
        }
        fn bodyChanged(context: *anyopaque, visible: bool) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.body = visible;
            self.changes += 1;
        }
        fn render(_: *anyopaque, _: *ui.CellGrid, _: ui.Rect, _: bool) !void {}
        fn actions(_: *anyopaque) []const views.TitleAction {
            return &.{};
        }
    };
    var first = Probe{};
    var second = Probe{};
    const panes = [_]container_mod.Pane{
        .{ .id = "first", .title = "First", .context = &first, .render_body = Probe.render, .handle_key = TestPane.key, .handle_mouse = TestPane.mouse, .title_actions = Probe.actions, .set_visible = Probe.visibleChanged, .set_body_visible = Probe.bodyChanged },
        .{ .id = "second", .title = "Second", .context = &second, .render_body = Probe.render, .handle_key = TestPane.key, .handle_mouse = TestPane.mouse, .title_actions = Probe.actions, .set_visible = Probe.visibleChanged, .set_body_visible = Probe.bodyChanged },
    };
    const container = try container_mod.ViewPaneContainer.init(allocator, &model, &panes);
    defer {
        container.deinit();
        allocator.destroy(container);
    }
    container.setVisible(true);
    try testing.expect(first.visible and first.body);
    try testing.expect(second.visible and !second.body);
    model.setCollapsed("second", false);
    try testing.expect(second.body);
    model.setCollapsed("second", true);
    try testing.expect(!second.body);
    model.setVisible("first", false);
    try testing.expect(!first.visible and !first.body);
    // A single merged view has no collapsible header.
    try testing.expect(second.visible and second.body);
    container.setVisible(false);
    try testing.expect(!second.visible and !second.body);
    const changes = second.changes;
    try container.layout(.{ .x = 0, .y = 0, .w = 20, .h = 10 });
    try testing.expectEqual(changes, second.changes);
    container.setVisible(true);
    try testing.expect(second.visible and second.body);
}
