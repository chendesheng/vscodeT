//! Terminal tab strip over the ported `EditorGroupModel`.
//!
//! This is the TUI adaptation of the workbench title/tabs control: it paints
//! the labels into the top cell row and reports the hit rectangle of every
//! visible tab. The model owns order, MRU, preview/pinned/sticky state and
//! activation; this file only decides how the labels are laid out in cells.

const std = @import("std");
const ui = @import("ui");
const editor_group_view = @import("../vs/workbench/browser/parts/editor/editorGroupView.zig");

const CellGrid = ui.CellGrid;
const PaintStyle = ui.cell.PaintStyle;

pub const TabInfo = struct {
    label: []const u8,
    dirty: bool = false,
};

/// The terminal tab strip's hit rectangle; the group view keeps this cache.
pub const Hit = editor_group_view.TabHit;

const active_style = PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 245, .g = 245, .b = 245 }),
    .bg = ui.cell.packColor(.{ .r = 50, .g = 50, .b = 50 }),
    .attrs = ui.cell.Attr.inverse,
};
const inactive_style = PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 150, .g = 150, .b = 150 }),
    .bg = 0,
};
const separator_style = PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 70, .g = 70, .b = 70 }),
    .bg = 0,
};

fn textWidth(text: []const u8) usize {
    var width: usize = 0;
    var offset: usize = 0;
    while (offset < text.len) {
        const decoded = ui.dom.decodeAt(text, offset);
        width += ui.dom.defaultMeasureWidth(decoded.cp);
        offset += decoded.len;
    }
    return width;
}

fn tabWidth(label: []const u8, cols: usize) usize {
    const width = textWidth(label) + 2;
    return @min(@max(width, 4), @max(cols -| 1, 1));
}

fn truncateLabel(label: []const u8, max_cells: usize) []const u8 {
    var width: usize = 0;
    var offset: usize = 0;
    while (offset < label.len) {
        const decoded = ui.dom.decodeAt(label, offset);
        const next_width = width + ui.dom.defaultMeasureWidth(decoded.cp);
        if (next_width > max_cells) break;
        width = next_width;
        offset += decoded.len;
    }
    return label[0..offset];
}

fn drawLabel(grid: *CellGrid, label: []const u8, start: usize, row: usize, max_cells: usize, paint: PaintStyle) void {
    const visible = truncateLabel(label, max_cells);
    var col = start;
    var offset: usize = 0;
    while (offset < visible.len) {
        const decoded = ui.dom.decodeAt(visible, offset);
        const width = ui.dom.defaultMeasureWidth(decoded.cp);
        grid.putCodepoint(col, row, decoded.cp, width, paint);
        col += width;
        offset += decoded.len;
    }
}

/// Paints the tab strip in `row` and fills `hits` with the visible tab
/// rectangles. `active` is an index into `tabs`; when it does not fit, the
/// strip scrolls so the active tab is visible on the right.
pub fn draw(
    grid: *CellGrid,
    tabs: []const TabInfo,
    active: usize,
    x: usize,
    row: usize,
    width: usize,
    hits: *std.array_list.Managed(Hit),
) !void {
    hits.clearRetainingCapacity();
    if (row >= grid.rows or tabs.len == 0) return;
    if (x >= grid.cols) return;

    const cols = @min(width, grid.cols - x);
    if (cols == 0) return;
    const widths = try grid.allocator.alloc(usize, tabs.len);
    defer grid.allocator.free(widths);
    for (tabs, 0..) |tab, index| {
        widths[index] = tabWidth(tab.label, cols);
    }

    // Find the first tab to paint. Start at zero unless the active tab would
    // be clipped, in which case walk backwards until it fits.
    var first: usize = 0;
    if (active < tabs.len) {
        var used: usize = 0;
        var index = active + 1;
        while (index > 0) {
            index -= 1;
            const separator: usize = if (used > 0) 1 else 0;
            const extra = widths[index] + separator;
            if (used + extra > cols) break;
            used += extra;
            first = index;
        }
    }

    var col: usize = 0;
    var index = first;
    while (index < tabs.len and col < cols) : (index += 1) {
        if (index > first) {
            if (col >= cols) break;
            grid.putCodepoint(x + col, row, ' ', 1, separator_style);
            col += 1;
            if (col >= cols) break;
        }

        const tab_width = @min(widths[index], cols - col);
        if (tab_width < 2) break;

        const paint = if (index == active) active_style else inactive_style;
        const screen_col = x + col;
        grid.fillRect(@floatFromInt(screen_col), @floatFromInt(row), @floatFromInt(tab_width), 1, paint);

        const label = truncateLabel(tabs[index].label, tab_width - 2);
        drawLabel(grid, label, screen_col + 1, row, tab_width - 2, paint);
        if (tabs[index].dirty and textWidth(label) + 2 < tab_width) {
            const dirty_paint = PaintStyle{
                .fg = paint.fg,
                .bg = paint.bg,
                .attrs = paint.attrs | ui.cell.Attr.bold,
            };
            drawLabel(grid, "*", screen_col + 1 + textWidth(label), row, 1, dirty_paint);
        }

        try hits.append(.{ .start = screen_col, .end = screen_col + tab_width, .index = index });
        col += tab_width;
    }
}

/// Returns the tab index at `col` in the strip painted by `draw`.
pub fn hitAt(hits: []const Hit, col: usize) ?usize {
    for (hits) |hit| {
        if (col >= hit.start and col < hit.end) return hit.index;
    }
    return null;
}

test "tabBar draws labels, active state and hits" {
    const allocator = std.testing.allocator;
    var grid = try CellGrid.init(allocator, 24, 1);
    defer grid.deinit();

    var hits = std.array_list.Managed(Hit).init(allocator);
    defer hits.deinit();

    const tabs = [_]TabInfo{
        .{ .label = "a.txt" },
        .{ .label = "b.txt", .dirty = true },
        .{ .label = "c.txt" },
    };
    try draw(&grid, &tabs, 1, 0, 0, grid.cols, &hits);

    try std.testing.expectEqual(@as(usize, 3), hits.items.len);
    try std.testing.expectEqual(@as(usize, 1), hitAt(hits.items, hits.items[1].start).?);
    try std.testing.expectEqual(@as(?usize, null), hitAt(hits.items, hits.items[0].end));

    const text = try grid.rowText(allocator, 0);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "a.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "b.txt") != null);
}

test "tabBar scrolls to keep the active tab visible" {
    const allocator = std.testing.allocator;
    var grid = try CellGrid.init(allocator, 10, 1);
    defer grid.deinit();

    var hits = std.array_list.Managed(Hit).init(allocator);
    defer hits.deinit();

    const tabs = [_]TabInfo{
        .{ .label = "first.txt" },
        .{ .label = "second.txt" },
        .{ .label = "third.txt" },
    };
    try draw(&grid, &tabs, 2, 0, 0, grid.cols, &hits);

    try std.testing.expect(hits.items.len >= 1);
    try std.testing.expectEqual(@as(usize, 2), hits.items[hits.items.len - 1].index);
    try std.testing.expectEqual(@as(?usize, 2), hitAt(hits.items, hits.items[hits.items.len - 1].start));
}
