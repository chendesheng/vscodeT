// Port of the row rendering in
// `src/vs/workbench/contrib/extensions/browser/extensionsList.ts`.
//
// Terminal adaptation: the browser template (72 px icon/name/description/
// publisher/footer action bar) becomes two cell rows. Images, ratings, install
// counts, verified-publisher badges, badges/action bars and hovers need DOM
// layout or assets and are not ported. A single generic extension glyph
// replaces the extension icon; the managed/enablement actions live in the
// row's context menu (see `extensionsViews.zig`).
const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const list = @import("../../../../base/browser/ui/list/list.zig");
const theme_colors_mod = @import("../../../browser/themeColors.zig");
const model = @import("../common/extensions.zig");
const IExtension = model.IExtension;

/// Codicon `extensions` (EAE6), available in the Nerd Font the terminal uses.
pub const extension_glyph: u21 = 0xEAE6;

pub const Colors = struct {
    background: ui.Color,
    foreground: ui.Color,
    dim: ui.Color,
    disabled: ui.Color,
    hover: ui.Color,
    active_selection: ui.Color,
    inactive_selection: ui.Color,
    selection_foreground: ui.Color,
    input_background: ui.Color,
    input_foreground: ui.Color,
    input_placeholder: ui.Color,
    icon_foreground: ui.Color,
};

pub const ThemeGetter = struct {
    context: *anyopaque,
    get: *const fn (context: *anyopaque) ?*const theme_colors_mod.ThemeColors,

    pub fn palette(self: ThemeGetter) ?*const theme_colors_mod.ThemeColors {
        return self.get(self.context);
    }
};

pub fn colors(theme: ?*const theme_colors_mod.ThemeColors) Colors {
    var result = Colors{
        .background = .{ .r = 30, .g = 30, .b = 33 },
        .foreground = .{ .r = 190, .g = 190, .b = 190 },
        .dim = .{ .r = 150, .g = 150, .b = 150 },
        .disabled = .{ .r = 120, .g = 120, .b = 120 },
        .hover = .{ .r = 42, .g = 45, .b = 46 },
        .active_selection = .{ .r = 4, .g = 57, .b = 94 },
        .inactive_selection = .{ .r = 55, .g = 55, .b = 61 },
        .selection_foreground = .{ .r = 255, .g = 255, .b = 255 },
        .input_background = .{ .r = 60, .g = 60, .b = 60 },
        .input_foreground = .{ .r = 204, .g = 204, .b = 204 },
        .input_placeholder = .{ .r = 150, .g = 150, .b = 150 },
        .icon_foreground = .{ .r = 197, .g = 197, .b = 197 },
    };
    if (theme) |palette| {
        result.background = palette.colorOr("sideBar.background", result.background);
        result.foreground = palette.colorOr("sideBar.foreground", result.foreground);
        result.dim = palette.colorOr("descriptionForeground", result.dim);
        result.disabled = palette.colorOr("disabledForeground", result.disabled);
        result.hover = palette.colorOr("list.hoverBackground", result.hover);
        result.active_selection = palette.colorOr("list.activeSelectionBackground", result.active_selection);
        result.inactive_selection = palette.colorOr("list.inactiveSelectionBackground", result.inactive_selection);
        result.selection_foreground = palette.colorOr("list.activeSelectionForeground", result.selection_foreground);
        result.input_background = palette.colorOr("input.background", result.input_background);
        result.input_foreground = palette.colorOr("input.foreground", result.input_foreground);
        result.input_placeholder = palette.colorOr("input.placeholderForeground", result.input_placeholder);
        result.icon_foreground = palette.colorOr("icon.foreground", result.icon_foreground);
    }
    return result;
}

/// Row background following the list selection/hover rules.
pub fn rowBackground(colors_value: Colors, row: *const list.Row) ui.Color {
    if (row.selected) return if (row.focused) colors_value.active_selection else colors_value.inactive_selection;
    if (row.hovered) return colors_value.hover;
    return colors_value.background;
}

pub const DrawnText = struct { used: usize, truncated: bool };

pub fn displayWidth(text: []const u8) usize {
    var width: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const decoded = ui.dom.decodeAt(text, index);
        if (decoded.len == 0) break;
        width += ui.dom.defaultMeasureWidth(decoded.cp);
        index += decoded.len;
    }
    return width;
}

pub fn drawTextEllipsis(grid: *ui.CellGrid, x: usize, y: usize, width: usize, text: []const u8, style: ui.cell.PaintStyle) DrawnText {
    if (width == 0 or text.len == 0) return .{ .used = 0, .truncated = text.len > 0 };
    var column: usize = 0;
    var index: usize = 0;
    var last_start: usize = 0;
    var last_width: usize = 1;
    while (index < text.len) {
        const decoded = ui.dom.decodeAt(text, index);
        if (decoded.len == 0) break;
        const cell_width = ui.dom.defaultMeasureWidth(decoded.cp);
        if (cell_width == 0) {
            index += decoded.len;
            continue;
        }
        if (column + cell_width > width) break;
        last_start = column;
        last_width = cell_width;
        grid.putCodepoint(x + column, y, decoded.cp, cell_width, style);
        column += cell_width;
        index += decoded.len;
    }
    if (index >= text.len) return .{ .used = column, .truncated = false };
    if (column > 0) {
        if (last_width > 1) {
            var cell: usize = 0;
            while (cell < last_width and last_start + cell < width) : (cell += 1) {
                grid.putSpace(x + last_start + cell, y, style);
            }
            grid.putCodepoint(x + last_start, y, '\u{2026}', 1, style);
            return .{ .used = last_start + 1, .truncated = true };
        }
        grid.putCodepoint(x + column - 1, y, '\u{2026}', 1, style);
        return .{ .used = column, .truncated = true };
    }
    grid.putCodepoint(x, y, '\u{2026}', 1, style);
    return .{ .used = 1, .truncated = true };
}

/// Paints one extension row into the cell grid.
pub fn renderRow(grid: *ui.CellGrid, row: *const list.Row, extension: *const IExtension, colors_value: Colors) void {
    grid.fillRect(@floatFromInt(row.x), @floatFromInt(row.y), @floatFromInt(row.width), @floatFromInt(row.height), .{
        .bg = ui.cell.packColor(rowBackground(colors_value, row)),
    });
    const background = rowBackground(colors_value, row);
    const selected = row.selected;
    const foreground = if (selected and row.focused) colors_value.selection_foreground else if (extension.isEnabled()) colors_value.foreground else colors_value.disabled;
    const dim = if (selected and row.focused) colors_value.selection_foreground else colors_value.dim;
    const icon = if (extension.isEnabled()) colors_value.icon_foreground else colors_value.disabled;
    const name_style = ui.cell.PaintStyle{ .fg = ui.cell.packColor(foreground), .bg = ui.cell.packColor(background) };
    const dim_style = ui.cell.PaintStyle{ .fg = ui.cell.packColor(dim), .bg = ui.cell.packColor(background) };
    const icon_style = ui.cell.PaintStyle{ .fg = ui.cell.packColor(icon), .bg = ui.cell.packColor(background) };
    if (row.width == 0) return;

    // First line: glyph + display name (+ disabled marker), version right-aligned.
    grid.putCodepoint(row.x, row.y, extension_glyph, 1, icon_style);
    const name_width = row.width -| 2;
    var version_text: []const u8 = "";
    var version_buffer: [64]u8 = undefined;
    if (extension.version.len > 0) {
        version_text = std.fmt.bufPrint(&version_buffer, "v{s}", .{extension.version}) catch "";
    }
    var version_width: usize = if (version_text.len > 0) displayWidth(version_text) + 1 else 0;
    if (version_width + 8 > name_width) version_width = 0;
    const name_space = name_width -| version_width;
    const disabled_suffix = if (extension.isEnabled()) "" else " (disabled)";
    var name_buffer: [256]u8 = undefined;
    const name_text = std.fmt.bufPrint(&name_buffer, "{s}{s}", .{ extension.display_name, disabled_suffix }) catch extension.display_name;
    _ = drawTextEllipsis(grid, row.x + 2, row.y, name_space, name_text, name_style);
    if (version_width > 0 and row.width > version_width) {
        _ = drawTextEllipsis(grid, row.x + row.width - version_width, row.y, version_width, version_text, dim_style);
    }
    if (row.height < 2) return;

    // Second line: origin, then description (or the identifier when empty).
    const detail = if (extension.description.len > 0) extension.description else extension.identifier;
    var detail_buffer: [512]u8 = undefined;
    const detail_text = std.fmt.bufPrint(&detail_buffer, "{s} · {s}", .{
        if (extension.is_builtin) "Built-in" else "Installed",
        detail,
    }) catch detail;
    _ = drawTextEllipsis(grid, row.x + 2, row.y + 1, name_width, detail_text, dim_style);
}
