// Tests for the terminal `ViewPaneContainer` layout/collapse subset. Upstream
// `viewPaneContainer.test.ts` only covers CSS spacing; these cases pin the
// terminal row split, collapsed sections, merged single view, header hits and
// the click-only expansion contract.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui");
const views = @import("../../../../common/views.zig");
const model_mod = @import("../../../../services/views/common/viewContainerModel.zig");
const container_mod = @import("../../../../browser/parts/views/viewPaneContainer.zig");

const TestPane = struct {
    renders: usize = 0,
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
        .{ .id = "graph", .title = "Graph", .context = &second, .render_body = TestPane.render, .handle_key = TestPane.key, .handle_mouse = TestPane.mouse, .title_actions = TestPane.actions },
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
    try testing.expect(container.sections.items[0].body_rect.h >= 4);
    try testing.expect(container.sections.items[1].body_rect.h >= 4);
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
    var click = ui.MouseEvent{ .kind = .down, .x = 1, .y = graph_header_y, .button = .left };
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
        .{ .id = "graph", .title = "Graph", .context = &second, .render_body = TestPane.render, .handle_key = TestPane.key, .handle_mouse = TestPane.mouse, .title_actions = TestPane.actions },
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
    var click = ui.MouseEvent{ .kind = .down, .x = 1, .y = header_y, .button = .left };
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
        .{ .id = "graph", .title = "Graph", .context = &second, .render_body = TestPane.render, .handle_key = TestPane.key, .handle_mouse = TestPane.mouse, .title_actions = TestPane.actions },
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
