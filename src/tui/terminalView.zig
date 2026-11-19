// Terminal cell rendering into the workbench frame.
//
// This is the terminal view counterpart of VS Code's xterm.js DOM renderer.
// It reads libghostty-vt's render state (colors resolved from the workbench
// terminal palette) and paints cells into the shared cell grid. Cursor
// placement is reported to the workbench so the real terminal cursor is used.

const std = @import("std");
const ui = @import("ui");
const emulator_mod = @import("../vs/workbench/contrib/terminal/browser/terminalEmulator.zig");

const TerminalEmulator = emulator_mod.TerminalEmulator;

pub fn paint(emulator: *TerminalEmulator, grid: *ui.CellGrid, rect: ui.Rect) !void {
    emulator.update() catch return;
    const state = &emulator.render_state;
    const origin_x = ui.cell.snap(rect.x);
    const origin_y = ui.cell.snap(rect.y);
    const width = @min(ui.cell.snap(rect.w), grid.cols -| origin_x);
    const height = @min(ui.cell.snap(rect.h), grid.rows -| origin_y);
    if (width == 0 or height == 0) return;

    const rows = @min(@as(usize, state.rows), height);
    var row_index: usize = 0;
    while (row_index < rows) : (row_index += 1) {
        if (row_index >= state.row_data.len) break;
        const row = state.row_data.get(row_index);
        const raw_cells = row.cells.items(.raw);
        const graphemes = row.cells.items(.grapheme);
        const styles = row.cells.items(.style);
        const cells = @min(@as(usize, state.cols), width);
        var x: usize = 0;
        while (x < cells) {
            const raw = raw_cells[x];
            switch (raw.wide) {
                .spacer_tail, .spacer_head => {
                    x += 1;
                    continue;
                },
                else => {},
            }
            const style: emulator_mod.Style = if (raw.hasStyling()) styles[x] else .{};
            var fg = style.fg(.{
                .default = state.colors.foreground,
                .palette = &state.colors.palette,
                .bold = .bright,
            });
            var bg = style.bg(&raw, &state.colors.palette) orelse state.colors.background;
            if (style.flags.inverse) {
                const tmp = fg;
                fg = bg;
                bg = tmp;
            }
            if (style.flags.invisible) fg = bg;

            var attrs: u16 = 0;
            if (style.flags.bold) attrs |= ui.cell.Attr.bold;
            if (style.flags.faint) attrs |= ui.cell.Attr.dim;
            if (style.flags.italic) attrs |= ui.cell.Attr.italic;
            if (style.flags.underline != .none) attrs |= ui.cell.Attr.underline;
            if (style.flags.strikethrough) attrs |= ui.cell.Attr.strikethrough;
            if (style.flags.blink) attrs |= ui.cell.Attr.blink;
            if (style.flags.overline) attrs |= ui.cell.Attr.overline;

            const paint_style = ui.cell.PaintStyle{
                .fg = ui.cell.packColor(.{ .r = fg.r, .g = fg.g, .b = fg.b }),
                .bg = ui.cell.packColor(.{ .r = bg.r, .g = bg.g, .b = bg.b }),
                .attrs = attrs,
            };
            const cell_width: usize = raw.gridWidth();

            if (raw.hasText()) {
                if (raw.hasGrapheme() and graphemes[x].len > 0) {
                    var utf8: [256]u8 = undefined;
                    const len = encodeGrapheme(graphemes[x], &utf8);
                    if (len > 0) {
                        try grid.putGrapheme(origin_x + x, origin_y + row_index, utf8[0..len], cell_width, paint_style);
                    } else {
                        grid.putSpace(origin_x + x, origin_y + row_index, paint_style);
                    }
                } else {
                    grid.putCodepoint(origin_x + x, origin_y + row_index, raw.codepoint(), cell_width, paint_style);
                }
            } else {
                grid.putSpace(origin_x + x, origin_y + row_index, paint_style);
            }
            if (cell_width == 0) {
                x += 1;
            } else {
                x += cell_width;
            }
        }
    }

    if (!emulator.render_hold) emulator.cleanRenderState();
}

pub const Cursor = struct {
    col: usize,
    row: usize,
};

/// Reports the shell cursor in global cells when it is visible in the viewport.
/// The caller decides whether the terminal owns focus.
pub fn cursorCell(emulator: *const TerminalEmulator, rect: ui.Rect) ?Cursor {
    const state = &emulator.render_state;
    if (!state.cursor.visible) return null;
    const viewport = state.cursor.viewport orelse return null;
    const origin_x = ui.cell.snap(rect.x);
    const origin_y = ui.cell.snap(rect.y);
    const width = ui.cell.snap(rect.w);
    const height = ui.cell.snap(rect.h);
    if (viewport.x >= width or viewport.y >= height) return null;
    return .{ .col = origin_x + viewport.x, .row = origin_y + viewport.y };
}

fn encodeGrapheme(codepoints: []const u21, buffer: *[256]u8) usize {
    var len: usize = 0;
    for (codepoints) |codepoint| {
        var encoded: [4]u8 = undefined;
        const size = std.unicode.utf8Encode(codepoint, &encoded) catch continue;
        if (len + size > buffer.len) break;
        @memcpy(buffer[len .. len + size], encoded[0..size]);
        len += size;
    }
    return len;
}
