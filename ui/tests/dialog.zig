const std = @import("std");
const ui = @import("ui");
const Allocator = std.mem.Allocator;
const cell = ui.cell;
const events = ui.event;
const style = ui.style;
const CellGrid = cell.CellGrid;
const cell_border = ui.cell_border;
const Action = ui.dialog.Action;
const Dialog = ui.dialog.Dialog;

test "Dialog: rounded corners use glyphs or zero-cell strokes" {
    const allocator = std.testing.allocator;
    const dialog = try Dialog.init(allocator, "Save changes?", "Changes are unsaved.", &.{ "Save", "Cancel" });
    defer dialog.deinit();
    var grid = try CellGrid.init(allocator, 60, 20);
    defer grid.deinit();
    dialog.render(&grid);
    const fallback = dialog.layout;
    try std.testing.expectEqual(@as(u32, '╭'), grid.cluster[grid.index(fallback.x, fallback.y)]);
    try std.testing.expectEqual(@as(u32, '╯'), grid.cluster[grid.index(fallback.x + fallback.width - 1, fallback.y + fallback.height - 1)]);

    grid.clear();
    const caps = cell_border.parseReply("\x1bP1+bcell-border;ok;1;pen,rect,round,radius,outside\x1b\\").?;
    dialog.renderWithBorderCapabilities(&grid, caps);
    const native = dialog.layout;
    try std.testing.expectEqual(fallback.height - 2, native.height);
    try std.testing.expectEqual(cell_border.Joint.top_left, grid.borderSetAt(native.x, native.y).joints);
    try std.testing.expectEqual(@as(?u9, 128), grid.borderSetAt(native.x, native.y).round_style.radius);
    try std.testing.expect(dialog.buttonRect(0) != null);
}

test "Dialog: renders warning, message, detail and vertical buttons" {
    const allocator = std.testing.allocator;
    const dialog = try Dialog.init(
        allocator,
        "Do you want to save the changes you made to http-proxy.js?",
        "Your changes will be lost if you don't save them.",
        &.{ "Save", "Don't Save", "Cancel" },
    );
    defer dialog.deinit();

    var grid = try CellGrid.init(allocator, 60, 20);
    defer grid.deinit();
    dialog.render(&grid);
    try std.testing.expect(!dialog.layout.compact);
    try std.testing.expect(dialog.layout.height > 0);
    try std.testing.expect(dialog.buttonRect(0) != null);
    try std.testing.expect(dialog.buttonRect(2) != null);
    try std.testing.expect(dialog.buttonRect(0).?.y < dialog.buttonRect(2).?.y);
    try std.testing.expect(grid.attrs[grid.index(0, 0)] & cell.Attr.dim != 0);

    const rows = try allRows(allocator, &grid);
    defer allocator.free(rows);
    try std.testing.expect(std.mem.indexOf(u8, rows, "Do you want to save the changes") != null);
    try std.testing.expect(std.mem.indexOf(u8, rows, "Your changes will be lost") != null);
    try std.testing.expect(std.mem.indexOf(u8, rows, "Save") != null);
    try std.testing.expect(std.mem.indexOf(u8, rows, "Don't Save") != null);
    try std.testing.expect(std.mem.indexOf(u8, rows, "Cancel") != null);
    try std.testing.expect(std.mem.indexOf(u8, rows, "\u{26A0}") != null);
}

test "Dialog: custom theme colors" {
    const allocator = std.testing.allocator;
    const dialog = try Dialog.init(allocator, "Message", "Detail", &.{"OK"});
    defer dialog.deinit();
    dialog.theme = .{
        .background = .{ .r = 10, .g = 20, .b = 30 },
        .text = .{ .r = 200, .g = 210, .b = 220 },
    };
    var grid = try CellGrid.init(allocator, 40, 10);
    defer grid.deinit();
    dialog.render(&grid);
    try std.testing.expectEqual(
        cell.packColor(.{ .r = 10, .g = 20, .b = 30 }),
        grid.bg[grid.index(dialog.layout.x + 1, dialog.layout.y + 1)],
    );
}

test "Dialog: compact layout keeps the actions on a short terminal" {
    const allocator = std.testing.allocator;
    const dialog = try Dialog.init(
        allocator,
        "Do you want to save the changes you made to close.txt?",
        "Your changes will be lost if you don't save them.",
        &.{ "Save", "Don't Save", "Cancel" },
    );
    defer dialog.deinit();

    var grid = try CellGrid.init(allocator, 40, 9);
    defer grid.deinit();
    dialog.render(&grid);
    try std.testing.expect(dialog.layout.compact);
    try std.testing.expectEqual(@as(usize, 9), dialog.layout.height);
    try std.testing.expect(dialog.buttonRect(0) != null);
    try std.testing.expect(dialog.buttonRect(1) != null);
    try std.testing.expect(dialog.buttonRect(2) != null);
    try std.testing.expectEqual(dialog.buttonRect(0).?.y, dialog.buttonRect(2).?.y);

    const rows = try allRows(allocator, &grid);
    defer allocator.free(rows);
    try std.testing.expect(std.mem.indexOf(u8, rows, "Don't Save") != null);
    try std.testing.expect(std.mem.indexOf(u8, rows, "Cancel") != null);
}

test "Dialog: keyboard wraps focus, activates and cancels" {
    const allocator = std.testing.allocator;
    const dialog = try Dialog.init(
        allocator,
        "message",
        "detail",
        &.{ "Save", "Don't Save", "Cancel" },
    );
    defer dialog.deinit();

    try std.testing.expectEqual(@as(usize, 0), dialog.focused);
    var right = events.KeyEvent{ .key = .right };
    try std.testing.expectEqual(Action.none, dialog.handleKey(&right));
    try std.testing.expectEqual(@as(usize, 1), dialog.focused);
    var down = events.KeyEvent{ .key = .down };
    try std.testing.expectEqual(Action.none, dialog.handleKey(&down));
    try std.testing.expectEqual(@as(usize, 2), dialog.focused);
    try std.testing.expectEqual(Action.none, dialog.handleKey(&right));
    try std.testing.expectEqual(@as(usize, 0), dialog.focused);

    var enter = events.KeyEvent{ .key = .enter };
    try std.testing.expectEqual(Action{ .activate = 0 }, dialog.handleKey(&enter));

    var escape = events.KeyEvent{ .key = .escape };
    try std.testing.expectEqual(Action.cancel, dialog.handleKey(&escape));

    var shift_tab = events.KeyEvent{ .key = .tab, .mods = .{ .shift = true } };
    try std.testing.expectEqual(Action.none, dialog.handleKey(&shift_tab));
    try std.testing.expectEqual(@as(usize, 2), dialog.focused);

    var keys = try ui.input.decodeKeys(allocator, " ");
    defer keys.deinit(allocator);
    try std.testing.expectEqual(Action{ .activate = 2 }, dialog.handleKey(&keys.items[0]));
}

test "Dialog: mouse press and release activate a button" {
    const allocator = std.testing.allocator;
    const dialog = try Dialog.init(
        allocator,
        "message",
        "detail",
        &.{ "Save", "Don't Save", "Cancel" },
    );
    defer dialog.deinit();

    var grid = try CellGrid.init(allocator, 60, 20);
    defer grid.deinit();
    dialog.render(&grid);

    const rect = dialog.buttonRect(1).?;
    var move = events.MouseEvent{ .kind = .move, .x = rect.x + 1, .y = rect.y };
    try std.testing.expectEqual(@as(?usize, null), dialog.handleMouse(&move));
    try std.testing.expectEqual(@as(?usize, 1), dialog.hovered);

    var down = events.MouseEvent{ .kind = .down, .x = rect.x + 1, .y = rect.y, .button = .left };
    try std.testing.expectEqual(@as(?usize, null), dialog.handleMouse(&down));
    var up = events.MouseEvent{ .kind = .up, .x = rect.x + 1, .y = rect.y, .button = .left };
    try std.testing.expectEqual(@as(?usize, 1), dialog.handleMouse(&up));

    var outside = events.MouseEvent{ .kind = .down, .x = 0, .y = 0, .button = .left };
    try std.testing.expectEqual(@as(?usize, null), dialog.handleMouse(&outside));

    try std.testing.expectEqual(style.Pointer.pointer, dialog.pointerAt(rect.x + 1, rect.y));
    try std.testing.expectEqual(style.Pointer.default, dialog.pointerAt(0, 0));
}

fn allRows(allocator: Allocator, grid: *const CellGrid) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    var row: usize = 0;
    while (row < grid.rows) : (row += 1) {
        const text = try grid.rowText(allocator, row);
        defer allocator.free(text);
        try out.appendSlice(text);
        try out.append('\n');
    }
    return out.toOwnedSlice();
}

test "Dialog: compact layout keeps the focused choice visible with many buttons" {
    const allocator = std.testing.allocator;
    const dialog = try Dialog.init(allocator, "Long prompt", "Detail", &.{ "A", "B", "C", "D", "E", "F", "G", "H", "I", "J" });
    defer dialog.deinit();
    var grid = try CellGrid.init(allocator, 20, 8);
    defer grid.deinit();
    dialog.render(&grid);
    try std.testing.expect(dialog.layout.compact);
    try std.testing.expect(dialog.buttonRect(0) != null);
    try std.testing.expect(dialog.buttonRect(9) == null);
    dialog.focusPrevious();
    grid.clear();
    dialog.render(&grid);
    try std.testing.expectEqual(@as(usize, 9), dialog.focused);
    try std.testing.expect(dialog.buttonRect(9) != null);
    try std.testing.expect(dialog.buttonRect(0) == null);
    var enter: events.KeyEvent = .{ .key = .enter };
    try std.testing.expectEqual(Action{ .activate = 9 }, dialog.handleKey(&enter));
}
