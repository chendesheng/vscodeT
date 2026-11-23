// Port of terminalTabsList.ts row layout and SplitView width thresholds.
// One cell row represents one list entry; codicons use single-cell glyphs.

const std = @import("std");
const ui = @import("ui");
const TerminalService = @import("./terminalService.zig").TerminalService;
const ThemeColors = @import("../../../browser/themeColors.zig").ThemeColors;

pub const narrow_view_width = 5;
pub const wide_view_minimum_width = 10;
pub const default_width = 16;
pub const midpoint_view_width = (narrow_view_width + wide_view_minimum_width) / 2;
pub const action_bar_minimum_width = 14;
pub const maximum_width = 62;
pub const terminal_icon = "❯";
pub const split_icon = "⊞";
pub const kill_icon = "×";

pub const TerminalTabList = struct {
    width: usize = default_width,
    first_visible: usize = 0,
    hovered: ?usize = null,
    focused: bool = false,
    dragging_sash: bool = false,
    last_clicked: ?usize = null,
    last_click_ms: i64 = 0,
    last_sash_click_ms: ?i64 = null,
    dragging_pane_sash: ?usize = null,
    dragged_instance: ?usize = null,
    drag_start_y: usize = 0,
    drag_target: ?usize = null,

    pub fn scroll(self: *TerminalTabList, amount: isize, count: usize, height: usize) void {
        const next = @as(isize, @intCast(self.first_visible)) + amount;
        self.first_visible = @min(@as(usize, @intCast(@max(next, 0))), count -| height);
    }

    pub fn reveal(self: *TerminalTabList, index: usize, count: usize, height: usize) void {
        if (height == 0) return;
        if (index < self.first_visible) self.first_visible = index;
        if (index >= self.first_visible + height) self.first_visible = index + 1 - height;
        self.scroll(0, count, height);
    }

    pub fn resize(self: *TerminalTabList, width: usize) void {
        self.width = if (width < midpoint_view_width)
            narrow_view_width
        else
            std.math.clamp(width, wide_view_minimum_width, maximum_width);
    }

    pub fn render(self: *const TerminalTabList, grid: *ui.CellGrid, service: *const TerminalService, rect: ui.Rect, palette: ?*const ThemeColors) void {
        const x = ui.cell.snap(rect.x);
        const y = ui.cell.snap(rect.y);
        const width = ui.cell.snap(rect.w);
        const height = ui.cell.snap(rect.h);
        const first = @min(self.first_visible, service.count() -| height);
        const has_text = width >= midpoint_view_width;
        for (first..@min(first + height, service.count())) |index| {
            const row = y + index - first;
            const instance = service.at(index).?;
            const active = service.group.active == index or instance.tab_selected;
            const hovered = self.hovered == index;
            const bg = if (active)
                color(palette, if (self.focused) "list.activeSelectionBackground" else "list.inactiveSelectionBackground", .{ 55, 55, 60 })
            else if (hovered)
                color(palette, "list.hoverBackground", .{ 41, 45, 46 })
            else
                color(palette, "panel.background", .{ 30, 30, 33 });
            const fg = color(palette, if (active) "list.activeSelectionForeground" else "foreground", .{ 204, 204, 204 });
            const style: ui.cell.PaintStyle = .{ .fg = ui.cell.packColor(fg), .bg = ui.cell.packColor(bg) };
            grid.fillRect(rect.x, @floatFromInt(row), rect.w, 1, style);
            if (self.drag_target == index and self.dragged_instance != instance.id) {
                grid.putCodepoint(x, row, '▸', 1, style);
            }
            const actions = hasActionBar(width) and (hovered or (active and self.focused));
            const end = width -| if (actions) @as(usize, 4) else 0;
            const group = service.group.groupRange(index);
            var used: usize = @min(1, end);
            if (group.end - group.first > 1) {
                const prefix = if (index == group.first) "┌ " else if (index + 1 == group.end) "└ " else "├ ";
                used += drawText(grid, x + used, row, end -| used, prefix, style);
            }
            used += drawText(grid, x + used, row, end -| used, if (instance.isRunning()) terminal_icon else "!", style);
            if (has_text and used + 1 < end) {
                used += 1;
                used += drawText(grid, x + used, row, end -| used, instance.displayTitle(), style);
                if (instance.labels.description.len > 0 and used + 1 < end) {
                    const description = color(palette, "descriptionForeground", .{ 150, 150, 150 });
                    _ = drawText(grid, x + used + 1, row, end -| (used + 1), instance.labels.description, .{
                        .fg = ui.cell.packColor(description),
                        .bg = style.bg,
                    });
                }
            }
            if (actions) {
                _ = drawText(grid, x + width - 4, row, 1, split_icon, style);
                _ = drawText(grid, x + width - 2, row, 1, kill_icon, style);
            }
        }
    }

    pub fn idealWidth(service: *const TerminalService) usize {
        var width: usize = wide_view_minimum_width;
        for (0..service.count()) |index| {
            const instance = service.at(index).?;
            const group = service.group.groupRange(index);
            const group_marker_width: usize = if (group.end - group.first > 1) 2 else 0;
            width = @max(width, textWidth(instance.displayTitle()) + textWidth(instance.labels.description) + 6 + group_marker_width);
        }
        return @min(width, maximum_width);
    }

    pub fn hasActionBar(width: usize) bool {
        return width >= action_bar_minimum_width;
    }
};

pub fn color(palette: ?*const ThemeColors, key: []const u8, fallback: [3]u8) ui.Color {
    return if (palette) |colors| colors.color(key, fallback) else ui.Color{ .r = fallback[0], .g = fallback[1], .b = fallback[2] };
}

fn textWidth(text: []const u8) usize {
    const view = std.unicode.Utf8View.init(text) catch return 0;
    var iterator = view.iterator();
    var width: usize = 0;
    while (iterator.nextCodepoint()) |glyph| width += ui.dom.defaultMeasureWidth(glyph);
    return width;
}

pub fn drawText(grid: *ui.CellGrid, x: usize, y: usize, max_width: usize, text: []const u8, style: ui.cell.PaintStyle) usize {
    var col: usize = 0;
    var view = std.unicode.Utf8View.init(text) catch return 0;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        const width = ui.dom.defaultMeasureWidth(codepoint);
        if (col + width > max_width) break;
        grid.putCodepoint(x + col, y, codepoint, width, style);
        col += width;
    }
    return col;
}
