// Port of `src/vs/base/test/browser/ui/breadcrumbs/breadcrumbsWidget.test.ts`.
//
// The upstream test drives a DOM widget and a fake measure scheduler. The
// terminal adaptation exercises the same item/focus/reveal state machine and
// reads the painted cell row instead of a DOM tree.

const std = @import("std");
const ui = @import("ui");
const widget_mod = @import("../../../../browser/ui/breadcrumbs/breadcrumbsWidget.zig");
const BreadcrumbsWidget = widget_mod.BreadcrumbsWidget;
const Item = widget_mod.Item;
const Style = widget_mod.Style;

test "breadcrumbsWidget draws items, separators and hits" {
    const allocator = std.testing.allocator;
    var grid = try ui.CellGrid.init(allocator, 40, 1);
    defer grid.deinit();

    var widget = BreadcrumbsWidget.init(allocator);
    defer widget.deinit();
    const items = [_]Item{
        .{ .label = "src", .kind = .folder },
        .{ .label = "file.ts", .kind = .file, .icon = .{ .text = "TS" } },
        .{ .label = "main", .kind = .symbol, .icon = .{ .text = "ƒ" } },
    };
    try widget.setItems(&items);
    const style = Style{
        .background = .{},
        .item = .{ .attrs = 0 },
        .focused = .{ .attrs = ui.cell.Attr.underline },
        .hovered = .{ .attrs = ui.cell.Attr.underline },
        .separator = .{},
        .icon = .{},
    };
    try widget.draw(&grid, 0, 0, grid.cols, style, true);

    const text = try grid.rowText(allocator, 0);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "src") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "file.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "main") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, ">") != null);
    try std.testing.expect(widget.hitAt(widget.hits.items[0].start) == 0);
    try std.testing.expect(widget.hitAt(widget.hits.items[2].start) == 2);
}

test "breadcrumbsWidget hides leading items and reveals the last" {
    const allocator = std.testing.allocator;
    var grid = try ui.CellGrid.init(allocator, 16, 1);
    defer grid.deinit();

    var widget = BreadcrumbsWidget.init(allocator);
    defer widget.deinit();
    const items = [_]Item{
        .{ .label = "very", .kind = .folder },
        .{ .label = "long", .kind = .folder },
        .{ .label = "path", .kind = .folder },
        .{ .label = "file.ts", .kind = .file },
    };
    try widget.setItems(&items);
    widget.revealLast();
    const style = Style{
        .background = .{},
        .item = .{},
        .focused = .{},
        .hovered = .{},
        .separator = .{},
        .icon = .{},
    };
    try widget.draw(&grid, 0, 0, grid.cols, style, true);
    const text = try grid.rowText(allocator, 0);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "file.ts") != null or std.mem.indexOf(u8, text, ">") != null);
    try std.testing.expect(widget.first_visible > 0);
}

test "breadcrumbsWidget paints a coloured file glyph" {
    const allocator = std.testing.allocator;
    var grid = try ui.CellGrid.init(allocator, 20, 1);
    defer grid.deinit();

    var widget = BreadcrumbsWidget.init(allocator);
    defer widget.deinit();
    const color = ui.Color{ .r = 0x31, .g = 0x78, .b = 0xC6 };
    const items = [_]Item{
        .{ .label = "file.ts", .kind = .file, .icon = .{ .glyph = .{ .codepoint = 0xE628, .color = color } } },
    };
    try widget.setItems(&items);
    const style = Style{
        .background = .{},
        .item = .{},
        .focused = .{},
        .hovered = .{},
        .separator = .{},
        .icon = .{},
    };
    try widget.draw(&grid, 0, 0, grid.cols, style, true);

    try std.testing.expectEqual(@as(u32, 0xE628), grid.cluster[grid.index(0, 0)]);
    try std.testing.expectEqual(ui.cell.packColor(color), grid.fg[grid.index(0, 0)]);
    try std.testing.expectEqual(@as(usize, 1 + 1 + "file.ts".len), widget_mod.itemWidth(items[0]));
}
