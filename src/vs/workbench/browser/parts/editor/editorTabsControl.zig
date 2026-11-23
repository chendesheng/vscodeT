// Port of the local drag behavior in
// src/vs/workbench/browser/parts/editor/editorTabsControl.ts.
const builtin = @import("builtin");
const std = @import("std");
const ui = @import("ui");
const ThemeColors = @import("../../themeColors.zig").ThemeColors;

pub fn isCopyIntoOtherGroup(mods: ui.Modifiers, singleton: bool) bool {
    return !singleton and if (builtin.os.tag == .macos) mods.alt else mods.ctrl;
}

pub fn isToggleSplitOperation(mods: ui.Modifiers) bool {
    return if (builtin.os.tag == .macos) mods.shift else mods.alt;
}

/// The cell equivalent of the upstream applyDragImage and its .monaco-drag-image
/// styles. The caller places this image one cell away from the pointer.
pub fn applyDragImage(
    allocator: std.mem.Allocator,
    label: []const u8,
    theme: ?*const ThemeColors,
    cell_borders: bool,
) !ui.CellGrid {
    const max_width = 18;
    var text_width: usize = 0;
    var offset: usize = 0;
    while (offset < label.len and text_width < max_width) {
        const decoded = ui.dom.decodeAt(label, offset);
        text_width += ui.dom.defaultMeasureWidth(decoded.cp);
        offset += decoded.len;
    }
    const width = @min(text_width + 2, max_width);
    const fg: ui.Color = if (theme) |colors| colors.color("list.activeSelectionForeground", .{ 255, 255, 255 }) else .{ .r = 255, .g = 255, .b = 255 };
    const bg: ui.Color = if (theme) |colors| colors.color("list.activeSelectionBackground", .{ 4, 57, 94 }) else .{ .r = 4, .g = 57, .b = 94 };
    const paint: ui.cell.PaintStyle = .{ .fg = ui.cell.packColor(fg), .bg = ui.cell.packColor(bg) };
    var image = try ui.CellGrid.init(allocator, width, 1);
    image.fillRect(0, 0, @floatFromInt(width), 1, paint);
    offset = 0;
    var col: usize = 1;
    while (offset < label.len and col < width - 1) {
        const decoded = ui.dom.decodeAt(label, offset);
        const cells = ui.dom.defaultMeasureWidth(decoded.cp);
        if (col + cells >= width or (col + cells == width - 1 and offset + decoded.len < label.len)) {
            image.putCodepoint(col, 0, '…', 1, paint);
            break;
        }
        image.putCodepoint(col, 0, decoded.cp, cells, paint);
        col += cells;
        offset += decoded.len;
    }
    if (cell_borders) {
        const color = if (theme) |colors| colors.color("list.focusOutline", .{ 0, 127, 212 }) else ui.Color{ .r = 0, .g = 127, .b = 212 };
        const stroke: ui.cell_border.Stroke = .{ .width = 32, .color = .{ .rgb = color }, .priority = 3 };
        const edge = ui.cell_border.Segment;
        for (0..width) |x| image.addBorder(x, 0, edge.top | edge.bottom, stroke);
        image.addBorder(0, 0, edge.left, stroke);
        image.addBorder(width - 1, 0, edge.right, stroke);
    }
    return image;
}
