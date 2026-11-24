// Cell rendering for the vertical scrollbar in windowed terminal lists.
const std = @import("std");
const ui = @import("ui");

const track_style = ui.cell.PaintStyle{ .bg = ui.cell.packColor(.{ .r = 30, .g = 32, .b = 40 }) };
const thumb_style = ui.cell.PaintStyle{ .bg = ui.cell.packColor(.{ .r = 105, .g = 108, .b = 122 }) };

pub fn contentWidth(width: usize, rows: usize, content_rows: usize) usize {
    return if (width > 1 and rows > 0 and content_rows > rows) width - 1 else width;
}

pub fn paint(grid: *ui.CellGrid, viewport: ui.Rect, content_rows: usize, scroll_top: f64) void {
    const width = ui.cell.snap(viewport.w);
    const rows = ui.cell.snap(viewport.h);
    if (contentWidth(width, rows, content_rows) == width) return;

    const x: f64 = @floatFromInt(ui.cell.snap(viewport.x) + width - 1);
    const y: f64 = @floatFromInt(ui.cell.snap(viewport.y));
    const height: f64 = @floatFromInt(rows);
    const total: f64 = @floatFromInt(content_rows);
    const thumb_height = @max(1, @round(height * height / total));
    const offset = std.math.clamp(scroll_top, 0, total - height);
    const thumb_top = @round((height - thumb_height) * offset / (total - height));
    grid.fillRect(x, y, 1, height, track_style);
    grid.fillRect(x, y + thumb_top, 1, thumb_height, thumb_style);
}
