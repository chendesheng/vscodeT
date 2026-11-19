// Terminal panel view: a one-row tab strip and the active terminal's cells.
// This adapts the terminal tabs view (`terminalTabbedView.ts` /
// `terminalTabsList.ts`) to the workbench cell grid. Tab hit testing is kept
// here; the workbench owns focus and key routing.

const std = @import("std");
const ui = @import("ui");
const service_mod = @import("../vs/workbench/contrib/terminal/browser/terminalService.zig");
const terminal_view = @import("./terminalView.zig");

const TerminalService = service_mod.TerminalService;

pub const Layout = struct {
    /// The single tab-strip row.
    tab_y: usize,
    /// Panel content rows, below the tab strip.
    content_x: usize,
    content_y: usize,
    content_width: usize,
    content_height: usize,
};

pub fn layout(rect: ui.Rect) Layout {
    const x = ui.cell.snap(rect.x);
    const y = ui.cell.snap(rect.y);
    const width = ui.cell.snap(rect.w);
    const height = ui.cell.snap(rect.h);
    const content_height = height -| 1;
    return .{
        .tab_y = y,
        .content_x = x,
        .content_y = y + 1,
        .content_width = width,
        .content_height = content_height,
    };
}

pub fn contentRect(rect: ui.Rect) ui.Rect {
    const l = layout(rect);
    return .{
        .x = @floatFromInt(l.content_x),
        .y = @floatFromInt(l.content_y),
        .w = @floatFromInt(l.content_width),
        .h = @floatFromInt(l.content_height),
    };
}

pub fn render(grid: *ui.CellGrid, service: *TerminalService, rect: ui.Rect, focused: bool) !void {
    const l = layout(rect);
    if (l.content_width == 0 or ui.cell.snap(rect.h) == 0) return;

    const bar_bg = if (focused)
        ui.cell.PaintStyle{ .bg = ui.cell.packColor(.{ .r = 30, .g = 30, .b = 33 }) }
    else
        ui.cell.PaintStyle{ .bg = ui.cell.packColor(.{ .r = 37, .g = 37, .b = 38 }) };
    grid.fillRect(rect.x, @floatFromInt(l.tab_y), rect.w, 1, bar_bg);

    var x = l.content_x;
    const right_limit = l.content_x + l.content_width;
    var index: usize = 0;
    while (index < service.count()) : (index += 1) {
        const instance = service.at(index).?;
        const active = index == service.group.active;
        const text = instance.displayTitle();
        const tab_width: usize = 18;
        if (x + tab_width + 3 > right_limit) break;
        const style = ui.cell.PaintStyle{
            .fg = ui.cell.packColor(if (active)
                .{ .r = 255, .g = 255, .b = 255 }
            else
                .{ .r = 150, .g = 150, .b = 150 }),
            .bg = if (active)
                ui.cell.packColor(.{ .r = 45, .g = 45, .b = 48 })
            else
                bar_bg.bg,
        };
        grid.fillRect(@floatFromInt(x), @floatFromInt(l.tab_y), @floatFromInt(tab_width), 1, style);
        _ = drawText(grid, x + 1, l.tab_y, tab_width - 2, text, style);
        if (!instance.isRunning()) {
            _ = drawText(grid, x + tab_width - 7, l.tab_y, 6, " [x]", style);
        }
        x += tab_width + 1;
    }

    const actions = "+ x";
    if (right_limit >= actions.len) {
        const action_style = ui.cell.PaintStyle{
            .fg = ui.cell.packColor(.{ .r = 190, .g = 190, .b = 190 }),
            .bg = bar_bg.bg,
        };
        _ = drawText(grid, right_limit - actions.len, l.tab_y, actions.len, actions, action_style);
    }

    if (service.active()) |instance| {
        try terminal_view.paint(&instance.emulator, grid, contentRect(rect));
    } else {
        grid.fillRect(
            @floatFromInt(l.content_x),
            @floatFromInt(l.content_y),
            @floatFromInt(l.content_width),
            @floatFromInt(l.content_height),
            .{ .bg = ui.cell.packColor(.{ .r = 30, .g = 30, .b = 33 }) },
        );
        _ = drawText(
            grid,
            l.content_x + 1,
            l.content_y,
            l.content_width -| 1,
            "No terminals",
            .{ .fg = ui.cell.packColor(.{ .r = 150, .g = 150, .b = 150 }) },
        );
    }
}

pub const Hit = union(enum) {
    none,
    tab: usize,
    new_terminal,
    kill_terminal,
    content,
};

pub fn hitTest(service: *TerminalService, rect: ui.Rect, mouse_x: usize, mouse_y: usize) Hit {
    const l = layout(rect);
    const width = l.content_width;
    const right_limit = l.content_x + width;
    if (mouse_y != l.tab_y) {
        if (mouse_y >= l.content_y and mouse_y < l.content_y + l.content_height and
            mouse_x >= l.content_x and mouse_x < right_limit)
        {
            return .content;
        }
        return .none;
    }

    const actions = "+ x";
    if (right_limit >= actions.len) {
        const action_x = right_limit - actions.len;
        if (mouse_x == action_x) return .new_terminal;
        if (mouse_x == action_x + 2) return .kill_terminal;
    }

    var x = l.content_x;
    var index: usize = 0;
    while (index < service.count()) : (index += 1) {
        const tab_width: usize = 18;
        if (x + tab_width + 3 > right_limit) break;
        if (mouse_x >= x and mouse_x < x + tab_width) return .{ .tab = index };
        x += tab_width + 1;
    }
    return .none;
}

fn drawText(
    grid: *ui.CellGrid,
    x: usize,
    y: usize,
    max_width: usize,
    text: []const u8,
    style: ui.cell.PaintStyle,
) usize {
    var col: usize = 0;
    var view = std.unicode.Utf8View.init(text) catch return 0;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        const width: usize = ui.dom.defaultMeasureWidth(codepoint);
        if (col + width > max_width) break;
        grid.putCodepoint(x + col, y, codepoint, width, style);
        col += width;
    }
    return col;
}

test "terminalPanel: layouts leave one row for the tab strip" {
    const rect = ui.Rect{ .x = 2, .y = 3, .w = 20, .h = 8 };
    const l = layout(rect);
    try std.testing.expectEqual(@as(usize, 3), l.tab_y);
    try std.testing.expectEqual(@as(usize, 4), l.content_y);
    try std.testing.expectEqual(@as(usize, 7), l.content_height);
}
