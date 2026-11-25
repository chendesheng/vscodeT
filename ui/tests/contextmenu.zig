const std = @import("std");
const ui = @import("ui");
const cell = ui.cell;
const cell_border = ui.cell_border;
const event = ui.event;
const style = ui.style;
const Allocator = std.mem.Allocator;
const CellGrid = cell.CellGrid;
const ItemType = ui.contextmenu.ItemType;
const Event = ui.contextmenu.Event;
const Item = ui.contextmenu.Item;
const Action = ui.contextmenu.Action;
const ContextMenu = ui.contextmenu.ContextMenu;
const popup = ui.contextmenu.popup;

const border_cells = 1;

const TestCtx = struct {
    clicks: usize = 0,
    hides: usize = 0,
    last_event: Event = .{},
    order: [8]u8 = undefined,
    order_len: usize = 0,

    fn onClick(context: ?*anyopaque, click_event: Event) void {
        const self: *TestCtx = @ptrCast(@alignCast(context orelse return));
        self.clicks += 1;
        self.last_event = click_event;
        self.push('c');
    }

    fn onHide(context: ?*anyopaque) void {
        const self: *TestCtx = @ptrCast(@alignCast(context orelse return));
        self.hides += 1;
        self.push('h');
    }

    fn push(self: *TestCtx, value: u8) void {
        if (self.order_len < self.order.len) {
            self.order[self.order_len] = value;
            self.order_len += 1;
        }
    }
};

const Point = struct { x: usize, y: usize };

fn itemPoint(menu: *const ContextMenu, level_index: usize, item_index: usize) Point {
    const level = &menu.levels.items[level_index];
    return .{
        .x = level.rect.x + 3,
        .y = level.rect.y + border_cells + (item_index - level.scroll_top),
    };
}

fn pressKey(menu: *ContextMenu, key: event.Key, mods: event.Modifiers) Action {
    var key_event = event.KeyEvent{ .key = key, .mods = mods };
    return menu.handleKey(&key_event);
}

fn sendMouse(menu: *ContextMenu, kind: event.MouseKind, x: usize, y: usize) Action {
    var mouse_event = event.MouseEvent{ .kind = kind, .x = x, .y = y, .button = .left };
    return menu.handleMouse(&mouse_event);
}

fn expectRowContains(
    allocator: Allocator,
    grid: *const CellGrid,
    row: usize,
    needle: []const u8,
) !void {
    const text = try grid.rowText(allocator, row);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, needle) != null);
}

test "ContextMenu: renders native rows, checks, accelerator, separator and arrow" {
    const allocator = std.testing.allocator;
    var grid = try CellGrid.init(allocator, 60, 24);
    defer grid.deinit();

    const submenu = [_]Item{
        .{ .label = "View as List", .type = .checkbox, .checked = true },
        .{ .label = "View as Tree" },
        .{ .type = .separator },
        .{ .label = "Sort Changes by Name" },
    };
    const items = [_]Item{
        .{ .label = "View as Tree" },
        .{ .label = "View & Sort", .type = .submenu, .submenu = &submenu },
        .{ .type = .separator },
        .{ .label = "Pull", .accelerator = "Ctrl+P" },
        .{ .label = "Changes", .type = .checkbox, .checked = true },
        .{ .label = "Use List", .type = .radio, .checked = true },
        .{ .label = "Disabled", .enabled = false },
        .{ .type = .separator },
        .{ .label = "Show Git Output" },
    };
    const menu = try popup(allocator, &items, .{
        .x = 2,
        .y = 2,
        .min_width = 24,
        .max_width = 40,
    }, null);
    defer menu.deinit();
    menu.render(&grid);

    const root = menu.levels.items[0];
    const top = root.rect.y + border_cells;
    try std.testing.expectEqual(@as(u32, '╭'), grid.cluster[grid.index(root.rect.x, root.rect.y)]);
    try std.testing.expectEqual(
        @as(u32, '╮'),
        grid.cluster[grid.index(root.rect.x + root.rect.width - 1, root.rect.y)],
    );
    try std.testing.expectEqual(
        @as(u32, '╰'),
        grid.cluster[grid.index(root.rect.x, root.rect.y + root.rect.height - 1)],
    );

    try expectRowContains(allocator, &grid, top, "View as Tree");
    try expectRowContains(allocator, &grid, top + 1, "View & Sort");
    try expectRowContains(allocator, &grid, top + 1, "›");
    try expectRowContains(allocator, &grid, top + 2, "─");
    try expectRowContains(allocator, &grid, top + 3, "Pull");
    try expectRowContains(allocator, &grid, top + 3, "Ctrl+P");
    try expectRowContains(allocator, &grid, top + 4, "✓");
    try expectRowContains(allocator, &grid, top + 5, "●");
    try expectRowContains(allocator, &grid, top + 6, "Disabled");

    const pull = itemPoint(menu, 0, 3);
    const disabled = itemPoint(menu, 0, 6);
    try std.testing.expectEqual(style.Pointer.pointer, menu.pointerAt(pull.x, pull.y));
    try std.testing.expectEqual(style.Pointer.default, menu.pointerAt(disabled.x, disabled.y));
    try std.testing.expectEqual(style.Pointer.default, menu.pointerAt(0, 0));
}

test "ContextMenu: focus paints the selection background" {
    const allocator = std.testing.allocator;
    const items = [_]Item{ .{ .label = "A" }, .{ .label = "B" } };
    var grid = try CellGrid.init(allocator, 30, 10);
    defer grid.deinit();
    const menu = try popup(allocator, &items, .{ .x = 2, .y = 2 }, null);
    defer menu.deinit();
    menu.render(&grid);

    try std.testing.expectEqual(Action.none, pressKey(menu, .down, .{}));
    menu.render(&grid);
    const level = menu.levels.items[0];
    const first = itemPoint(menu, 0, 0);
    const first_bg = grid.bg[grid.index(level.rect.x + 1, first.y)];
    try std.testing.expectEqual(cell.packColor(menu.options.theme.selection_background), first_bg);

    try std.testing.expectEqual(Action.none, pressKey(menu, .down, .{}));
    menu.render(&grid);
    const second = itemPoint(menu, 0, 1);
    const second_bg = grid.bg[grid.index(level.rect.x + 1, second.y)];
    try std.testing.expectEqual(cell.packColor(menu.options.theme.selection_background), second_bg);
    const first_bg_after = grid.bg[grid.index(level.rect.x + 1, first.y)];
    try std.testing.expectEqual(cell.packColor(menu.options.theme.background), first_bg_after);
}

test "ContextMenu: native cell borders round the frame" {
    const allocator = std.testing.allocator;
    var grid = try CellGrid.init(allocator, 50, 20);
    defer grid.deinit();

    const items = [_]Item{ .{ .label = "One" }, .{ .label = "Two" } };
    const menu = try popup(allocator, &items, .{ .x = 1, .y = 1 }, null);
    defer menu.deinit();

    const caps = cell_border.parseReply("\x1bP1+bcell-border;ok;1;pen,rect,round,radius,outside\x1b\\").?;
    menu.renderWithBorderCapabilities(&grid, caps);
    const root = menu.levels.items[0];
    try std.testing.expectEqual(
        cell_border.Joint.top_left,
        grid.borderSetAt(root.rect.x, root.rect.y).joints,
    );
    try std.testing.expect(grid.borderSetAt(root.rect.x, root.rect.y).round_style.radius != null);
}

test "ContextMenu: keyboard skips separators and disabled items, wraps and activates in order" {
    const allocator = std.testing.allocator;
    var ctx = TestCtx{};
    const items = [_]Item{
        .{ .label = "A", .click = .{ .context = &ctx, .callback = TestCtx.onClick } },
        .{ .type = .separator },
        .{ .label = "B", .enabled = false },
        .{ .label = "C", .click = .{ .context = &ctx, .callback = TestCtx.onClick } },
        .{ .label = "D", .click = .{ .context = &ctx, .callback = TestCtx.onClick } },
    };
    const menu = try popup(allocator, &items, .{}, .{ .context = &ctx, .callback = TestCtx.onHide });
    defer menu.deinit();

    try std.testing.expect(menu.focusedItem() == null);
    try std.testing.expectEqual(Action.none, pressKey(menu, .down, .{}));
    try std.testing.expectEqualStrings("A", menu.focusedItem().?.label);
    try std.testing.expectEqual(Action.none, pressKey(menu, .down, .{}));
    try std.testing.expectEqualStrings("C", menu.focusedItem().?.label);
    try std.testing.expectEqual(Action.none, pressKey(menu, .down, .{}));
    try std.testing.expectEqualStrings("D", menu.focusedItem().?.label);
    try std.testing.expectEqual(Action.none, pressKey(menu, .down, .{}));
    try std.testing.expectEqualStrings("A", menu.focusedItem().?.label);
    try std.testing.expectEqual(Action.none, pressKey(menu, .up, .{}));
    try std.testing.expectEqualStrings("D", menu.focusedItem().?.label);

    try std.testing.expectEqual(Action.none, pressKey(menu, .home, .{}));
    try std.testing.expectEqualStrings("A", menu.focusedItem().?.label);
    try std.testing.expectEqual(Action.none, pressKey(menu, .end, .{}));
    try std.testing.expectEqualStrings("D", menu.focusedItem().?.label);
    try std.testing.expectEqual(Action.none, pressKey(menu, .tab, .{}));
    try std.testing.expectEqualStrings("D", menu.focusedItem().?.label);

    try std.testing.expectEqual(
        Action.closed,
        pressKey(menu, .enter, .{ .ctrl = true }),
    );
    try std.testing.expect(!menu.isOpen());
    try std.testing.expectEqual(@as(usize, 1), ctx.clicks);
    try std.testing.expectEqual(@as(usize, 1), ctx.hides);
    try std.testing.expectEqual(@as(u8, 'h'), ctx.order[0]);
    try std.testing.expectEqual(@as(u8, 'c'), ctx.order[1]);
    try std.testing.expect(ctx.last_event.ctrl_key);
}

test "ContextMenu: submenus open with Right/Enter and collapse one level at a time" {
    const allocator = std.testing.allocator;
    var ctx = TestCtx{};
    const submenu = [_]Item{
        .{ .label = "Child A", .click = .{ .context = &ctx, .callback = TestCtx.onClick } },
        .{ .label = "Child B" },
    };
    const items = [_]Item{
        .{ .label = "First" },
        .{ .label = "Sub", .type = .submenu, .submenu = &submenu },
        .{ .label = "Last" },
    };
    const menu = try popup(allocator, &items, .{ .x = 1, .y = 1 }, null);
    defer menu.deinit();
    var grid = try CellGrid.init(allocator, 50, 16);
    defer grid.deinit();
    menu.render(&grid);

    try std.testing.expectEqual(Action.none, pressKey(menu, .down, .{}));
    try std.testing.expectEqual(Action.none, pressKey(menu, .down, .{}));
    try std.testing.expectEqual(Action.none, pressKey(menu, .right, .{}));
    try std.testing.expectEqual(@as(usize, 2), menu.levels.items.len);
    try std.testing.expectEqualStrings("Child A", menu.focusedItem().?.label);

    try std.testing.expectEqual(Action.none, pressKey(menu, .left, .{}));
    try std.testing.expectEqual(@as(usize, 1), menu.levels.items.len);
    try std.testing.expectEqualStrings("Sub", menu.focusedItem().?.label);

    try std.testing.expectEqual(Action.none, pressKey(menu, .enter, .{}));
    try std.testing.expectEqual(@as(usize, 2), menu.levels.items.len);
    try std.testing.expectEqual(Action.none, pressKey(menu, .escape, .{}));
    try std.testing.expectEqual(@as(usize, 1), menu.levels.items.len);

    try std.testing.expectEqual(Action.none, pressKey(menu, .right, .{}));
    try std.testing.expectEqual(Action.closed, pressKey(menu, .enter, .{}));
    try std.testing.expectEqual(@as(usize, 1), ctx.clicks);
    try std.testing.expect(!menu.isOpen());
}

test "ContextMenu: hover opens submenus without selecting and mouse up activates" {
    const allocator = std.testing.allocator;
    var ctx = TestCtx{};
    const submenu = [_]Item{
        .{ .label = "Child A" },
        .{ .label = "Child B" },
    };
    const items = [_]Item{
        .{ .label = "First", .click = .{ .context = &ctx, .callback = TestCtx.onClick } },
        .{ .label = "Sub", .type = .submenu, .submenu = &submenu },
        .{ .label = "Last", .click = .{ .context = &ctx, .callback = TestCtx.onClick } },
    };
    const menu = try popup(allocator, &items, .{
        .x = 2,
        .y = 2,
    }, .{ .context = &ctx, .callback = TestCtx.onHide });
    defer menu.deinit();
    var grid = try CellGrid.init(allocator, 50, 16);
    defer grid.deinit();
    menu.render(&grid);

    const sub_point = itemPoint(menu, 0, 1);
    _ = sendMouse(menu, .move, sub_point.x, sub_point.y);
    try std.testing.expectEqual(@as(usize, 2), menu.levels.items.len);
    try std.testing.expect(menu.levels.items[1].focused == null);

    const child_point = itemPoint(menu, 1, 1);
    _ = sendMouse(menu, .move, child_point.x, child_point.y);
    try std.testing.expectEqualStrings("Child B", menu.focusedItem().?.label);

    // Close the child, then press/release the first item.
    _ = pressKey(menu, .left, .{});
    const first = itemPoint(menu, 0, 0);
    _ = sendMouse(menu, .down, first.x, first.y);
    try std.testing.expectEqual(Action.closed, sendMouse(menu, .up, first.x, first.y));
    try std.testing.expectEqual(@as(usize, 1), ctx.clicks);
    try std.testing.expectEqual(@as(usize, 1), ctx.hides);
}

test "ContextMenu: outside up dismisses without a click and press mismatch does not activate" {
    const allocator = std.testing.allocator;
    var ctx = TestCtx{};
    const items = [_]Item{
        .{ .label = "A", .click = .{ .context = &ctx, .callback = TestCtx.onClick } },
        .{ .label = "B", .click = .{ .context = &ctx, .callback = TestCtx.onClick } },
        .{ .type = .separator },
        .{ .label = "C", .click = .{ .context = &ctx, .callback = TestCtx.onClick } },
    };

    const menu = try popup(allocator, &items, .{
        .x = 2,
        .y = 2,
    }, .{ .context = &ctx, .callback = TestCtx.onHide });
    defer menu.deinit();
    var grid = try CellGrid.init(allocator, 50, 16);
    defer grid.deinit();
    menu.render(&grid);

    const a = itemPoint(menu, 0, 0);
    const c = itemPoint(menu, 0, 3);
    _ = sendMouse(menu, .down, a.x, a.y);
    _ = sendMouse(menu, .up, c.x, c.y);
    try std.testing.expect(menu.isOpen());
    try std.testing.expectEqual(@as(usize, 0), ctx.clicks);

    _ = sendMouse(menu, .down, 0, 0);
    try std.testing.expectEqual(Action.closed, sendMouse(menu, .up, 0, 0));
    try std.testing.expectEqual(@as(usize, 0), ctx.clicks);
    try std.testing.expectEqual(@as(usize, 1), ctx.hides);

    const second = try popup(allocator, &items, .{ .x = 2, .y = 2 }, null);
    defer second.deinit();
    second.render(&grid);
    const point = itemPoint(second, 0, 0);
    try std.testing.expectEqual(Action.closed, sendMouse(second, .click, point.x, point.y));
    try std.testing.expectEqual(@as(usize, 1), ctx.clicks);
}

test "ContextMenu: positioning item places the row at the anchor" {
    const allocator = std.testing.allocator;
    const items = [_]Item{
        .{ .label = "0" }, .{ .label = "1" }, .{ .label = "2" },
        .{ .label = "3" }, .{ .label = "4" }, .{ .label = "5" },
    };
    var grid = try CellGrid.init(allocator, 40, 20);
    defer grid.deinit();

    const menu = try popup(allocator, &items, .{
        .x = 10,
        .y = 10,
        .positioning_item = 3,
        .min_width = 12,
    }, null);
    defer menu.deinit();
    menu.render(&grid);

    const root = menu.levels.items[0];
    const item_top = root.rect.y + border_cells + 3;
    try std.testing.expectEqual(@as(usize, 10), item_top);
    _ = sendMouse(menu, .move, root.rect.x + 3, item_top);
    try std.testing.expectEqualStrings("3", menu.focusedItem().?.label);
    try std.testing.expect(root.rect.x + root.rect.width <= grid.cols);
    try std.testing.expect(root.rect.y + root.rect.height <= grid.rows);
}

test "ContextMenu: submenus flip left when the right edge does not fit" {
    const allocator = std.testing.allocator;
    const submenu = [_]Item{.{ .label = "Child" }};
    const items = [_]Item{
        .{ .label = "Open" },
        .{ .label = "Sub", .type = .submenu, .submenu = &submenu },
    };
    var grid = try CellGrid.init(allocator, 60, 20);
    defer grid.deinit();
    const menu = try popup(allocator, &items, .{
        .x = 40,
        .y = 1,
        .min_width = 20,
        .max_width = 20,
    }, null);
    defer menu.deinit();
    menu.render(&grid);

    try std.testing.expectEqual(Action.none, pressKey(menu, .down, .{}));
    try std.testing.expectEqual(Action.none, pressKey(menu, .down, .{}));
    try std.testing.expectEqual(Action.none, pressKey(menu, .right, .{}));
    try std.testing.expectEqual(@as(usize, 2), menu.levels.items.len);
    const root = menu.levels.items[0];
    const child = menu.levels.items[1];
    try std.testing.expect(child.rect.x < root.rect.x);
    try std.testing.expect(child.rect.x + child.rect.width <= grid.cols);
}

test "ContextMenu: tall menus clamp and wheel scrolls while focus stays off-screen" {
    const allocator = std.testing.allocator;
    const items = [_]Item{
        .{ .label = "0" },  .{ .label = "1" },  .{ .label = "2" },  .{ .label = "3" },
        .{ .label = "4" },  .{ .label = "5" },  .{ .label = "6" },  .{ .label = "7" },
        .{ .label = "8" },  .{ .label = "9" },  .{ .label = "10" }, .{ .label = "11" },
        .{ .label = "12" }, .{ .label = "13" }, .{ .label = "14" },
    };
    var grid = try CellGrid.init(allocator, 30, 10);
    defer grid.deinit();

    const menu = try popup(allocator, &items, .{
        .x = 0,
        .y = 0,
        .min_width = 12,
    }, null);
    defer menu.deinit();
    menu.render(&grid);

    const root = menu.levels.items[0];
    try std.testing.expect(root.rect.width <= 30);
    try std.testing.expect(root.rect.height <= 10);
    try std.testing.expect(root.visible < items.len);

    try std.testing.expectEqual(Action.none, pressKey(menu, .home, .{}));
    menu.render(&grid);
    try std.testing.expectEqual(@as(usize, 0), menu.levels.items[0].scroll_top);
    var wheel = event.MouseEvent{
        .kind = .wheel,
        .x = root.rect.x + 3,
        .y = root.rect.y + border_cells,
        .delta_y = 3,
    };
    _ = menu.handleMouse(&wheel);
    menu.render(&grid);
    try std.testing.expectEqual(@as(usize, 3), menu.levels.items[0].scroll_top);

    try std.testing.expectEqual(Action.none, pressKey(menu, .end, .{}));
    menu.render(&grid);
    const level = menu.levels.items[0];
    try std.testing.expect(level.focused.? >= level.scroll_top);
    try std.testing.expect(level.focused.? < level.scroll_top + level.visible);
}

test "ContextMenu: cleans invisible items and separators and rejects empty menus" {
    const allocator = std.testing.allocator;
    const submenu = [_]Item{
        .{ .label = "Kept" },
        .{ .label = "Hidden", .visible = false },
    };
    const items = [_]Item{
        .{ .type = .separator },
        .{ .label = "A" },
        .{ .type = .separator },
        .{ .type = .separator },
        .{ .label = "Hidden", .visible = false },
        .{ .label = "B", .type = .submenu, .submenu = &submenu },
        .{ .label = "Empty", .type = .submenu },
        .{ .type = .separator },
    };
    const menu = try popup(allocator, &items, .{}, null);
    defer menu.deinit();
    try std.testing.expectEqual(@as(usize, 3), menu.items.len);
    try std.testing.expectEqualStrings("A", menu.items[0].label);
    try std.testing.expectEqual(ItemType.separator, menu.items[1].type);
    try std.testing.expectEqualStrings("B", menu.items[2].label);
    try std.testing.expectEqual(ItemType.submenu, menu.items[2].type);
    try std.testing.expectEqual(@as(usize, 1), menu.items[2].submenu.len);
    try std.testing.expectEqualStrings("Kept", menu.items[2].submenu[0].label);

    const empty = [_]Item{.{ .visible = false }};
    try std.testing.expectError(error.EmptyContextMenu, popup(allocator, &empty, .{}, null));
}

test "ContextMenu: popup copies item text" {
    const allocator = std.testing.allocator;
    var label_buffer: [8]u8 = undefined;
    @memcpy(label_buffer[0..5], "Temp!");
    label_buffer[5] = 0;
    const items = [_]Item{.{ .label = label_buffer[0..5] }};
    const menu = try popup(allocator, &items, .{ .x = 1, .y = 1 }, null);
    defer menu.deinit();
    @memset(&label_buffer, 'x');

    var grid = try CellGrid.init(allocator, 30, 10);
    defer grid.deinit();
    menu.render(&grid);
    try expectRowContains(allocator, &grid, menu.levels.items[0].rect.y + 1, "Temp!");
}
