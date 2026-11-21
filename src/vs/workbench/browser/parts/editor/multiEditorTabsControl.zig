//! Terminal tab strip over the ported `EditorGroupModel`.
//!
//! This is the TUI adaptation of the workbench title/tabs control
//! (`src/vs/workbench/browser/parts/editor/editorTabsControl.ts` and
//! `multiEditorTabsControl.ts`): it paints the labels into the top cell row
//! and reports the hit rectangle of every visible tab and of its close action.
//! The model owns order, MRU, preview/pinned/sticky state and activation; this
//! file only decides how the labels are laid out in cells.
//!
//! Terminal adaptations, documented in `README.md` and `docs/terminal-ui.md`:
//! - The file icon theme is not ported, so the tab icon is a two-cell language
//!   badge (`JS`); see `fileIcon.zig`.
//! - The browser's 1px active-tab top border has no partial-cell equivalent;
//!   the active tab uses its background and bold text instead.
//! - Tab action space is always reserved (`tabActionReserveSpace`), but only
//!   the active/hovered tab and the dirty dot paint a glyph. Clicking the dot
//!   or the close glyph closes the tab.
//! - Overflow clips leading tabs behind an ellipsis and reveals the active tab
//!   with its close cell, instead of a horizontal scrollbar.

const std = @import("std");
const ui = @import("ui");
const theme_colors_mod = @import("../../themeColors.zig");
const editor_group_view = @import("./editorGroupView.zig");

const CellGrid = ui.CellGrid;
const PaintStyle = ui.cell.PaintStyle;

pub const TabInfo = struct {
    label: []const u8,
    language: []const u8 = "",
    dirty: bool = false,
    /// Upstream `!isPinned`: preview tabs are italic.
    pinned: bool = true,
    sticky: bool = false,
    closeable: bool = true,
};

pub const TitleAction = struct {
    /// The two-cell markdown preview icon `◫⌕` (U+25EB U+2315).
    glyphs: []const u8 = "◫⌕",
    active: bool = false,
    hovered: bool = false,
};

pub const TitleActionHit = struct {
    start: usize,
    end: usize,
};

pub const DrawOptions = struct {
    group_active: bool = true,
    hovered: ?usize = null,
    title_action: ?TitleAction = null,
};

/// The terminal tab strip's hit rectangle; the group view keeps this cache.
pub const Hit = editor_group_view.TabHit;

const base_strip_background = PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 190, .g = 190, .b = 190 }),
    .bg = ui.cell.packColor(.{ .r = 37, .g = 37, .b = 38 }),
};
const base_active_style = PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 245, .g = 245, .b = 245 }),
    .bg = ui.cell.packColor(.{ .r = 30, .g = 30, .b = 30 }),
    .attrs = ui.cell.Attr.bold,
};
const base_inactive_group_active_style = PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 205, .g = 205, .b = 205 }),
    .bg = ui.cell.packColor(.{ .r = 45, .g = 45, .b = 45 }),
};
const base_inactive_style = PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 150, .g = 150, .b = 150 }),
    .bg = ui.cell.packColor(.{ .r = 37, .g = 37, .b = 38 }),
};
const base_separator_style = PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 70, .g = 70, .b = 70 }),
    .bg = ui.cell.packColor(.{ .r = 37, .g = 37, .b = 38 }),
};
const base_dirty_style = PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 230, .g = 170, .b = 70 }),
    .attrs = ui.cell.Attr.bold,
};
const base_title_action_style = PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 150, .g = 150, .b = 150 }),
    .bg = ui.cell.packColor(.{ .r = 37, .g = 37, .b = 38 }),
};
const base_title_action_hover_style = PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 235, .g = 235, .b = 235 }),
    .bg = ui.cell.packColor(.{ .r = 55, .g = 55, .b = 58 }),
};
const base_title_action_active_style = PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 245, .g = 245, .b = 245 }),
    .bg = ui.cell.packColor(.{ .r = 45, .g = 75, .b = 105 }),
    .attrs = ui.cell.Attr.bold,
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

fn badgeWidth(tab: TabInfo) usize {
    if (iconFor(tab).len == 0) return 0;
    return iconFor(tab).len + 1;
}

fn iconFor(tab: TabInfo) []const u8 {
    if (tab.language.len == 0) return "";
    return languageBadge(tab.language);
}

fn closeWidth(tab: TabInfo) usize {
    return if (tab.closeable) 2 else 0;
}

fn tabWidth(tab: TabInfo, cols: usize) usize {
    const width = textWidth(tab.label) + 2 + badgeWidth(tab) + closeWidth(tab);
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

fn drawLabel(grid: *CellGrid, label: []const u8, start: usize, row: usize, max_cells: usize, paint: PaintStyle) usize {
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
    return col - start;
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
    options: DrawOptions,
    palette: ?*const theme_colors_mod.ThemeColors,
) !?TitleActionHit {
    hits.clearRetainingCapacity();
    if (row >= grid.rows) return null;
    if (x >= grid.cols) return null;

    const cols = @min(width, grid.cols - x);
    if (cols == 0) return null;
    var strip_background = base_strip_background;
    var active_style = base_active_style;
    var inactive_group_active_style = base_inactive_group_active_style;
    var inactive_style = base_inactive_style;
    var separator_style = base_separator_style;
    var dirty_style = base_dirty_style;
    var title_action_style = base_title_action_style;
    var title_action_hover_style = base_title_action_hover_style;
    var title_action_active_style = base_title_action_active_style;
    if (palette) |colors| {
        strip_background = .{
            .fg = ui.cell.packColor(colors.color("tab.inactiveForeground", .{ 190, 190, 190 })),
            .bg = ui.cell.packColor(colors.color("editorGroupHeader.tabsBackground", .{ 37, 37, 38 })),
        };
        active_style = .{
            .fg = ui.cell.packColor(colors.color("tab.activeForeground", .{ 245, 245, 245 })),
            .bg = ui.cell.packColor(colors.color("tab.activeBackground", .{ 30, 30, 30 })),
            .attrs = ui.cell.Attr.bold,
        };
        inactive_group_active_style = .{
            .fg = ui.cell.packColor(colors.color("tab.unfocusedActiveForeground", .{ 205, 205, 205 })),
            .bg = ui.cell.packColor(colors.color("tab.unfocusedActiveBackground", .{ 45, 45, 45 })),
        };
        inactive_style = .{
            .fg = ui.cell.packColor(colors.color("tab.inactiveForeground", .{ 150, 150, 150 })),
            .bg = ui.cell.packColor(colors.color("tab.inactiveBackground", .{ 37, 37, 38 })),
        };
        separator_style = .{
            .fg = ui.cell.packColor(colors.color("editorGroup.border", .{ 70, 70, 70 })),
            .bg = ui.cell.packColor(colors.color("editorGroupHeader.tabsBackground", .{ 37, 37, 38 })),
        };
        dirty_style = .{
            .fg = ui.cell.packColor(colors.color("gitDecoration.modifiedResourceForeground", .{ 230, 170, 70 })),
            .attrs = ui.cell.Attr.bold,
        };
        title_action_style = .{
            .fg = ui.cell.packColor(colors.color("tab.inactiveForeground", .{ 150, 150, 150 })),
            .bg = ui.cell.packColor(colors.color("editorGroupHeader.tabsBackground", .{ 37, 37, 38 })),
        };
        title_action_hover_style = .{
            .fg = ui.cell.packColor(colors.color("tab.activeForeground", .{ 235, 235, 235 })),
            .bg = ui.cell.packColor(colors.color("toolbar.hoverBackground", .{ 55, 55, 58 })),
        };
        title_action_active_style = .{
            .fg = ui.cell.packColor(colors.color("tab.activeForeground", .{ 255, 255, 255 })),
            .bg = ui.cell.packColor(colors.color("toolbar.activeBackground", .{ 75, 75, 78 })),
        };
    }
    grid.fillRect(@floatFromInt(x), @floatFromInt(row), @floatFromInt(cols), 1, strip_background);
    if (tabs.len == 0) return null;

    const action_width: usize = if (options.title_action != null and cols >= 16) 3 else 0;
    const layout_cols = cols -| action_width;
    const widths = try grid.allocator.alloc(usize, tabs.len);
    defer grid.allocator.free(widths);
    for (tabs, 0..) |tab, index| {
        widths[index] = tabWidth(tab, layout_cols);
    }

    // Find the first tab to paint. Start at zero unless the active tab would
    // be clipped, in which case walk backwards until it fits.
    var first: usize = 0;
    if (active < tabs.len) {
        first = revealFirst(tabs.len, widths, active, layout_cols);
    }
    if (first > 0) {
        // Reserve the leading ellipsis and re-walk with the reduced width.
        const reduced = layout_cols -| 2;
        if (active < tabs.len) first = revealFirst(tabs.len, widths, active, reduced);
        grid.putCodepoint(x, row, 0x2026, 1, separator_style);
    }

    var col: usize = if (first > 0) 2 else 0;
    var index = first;
    while (index < tabs.len and col < layout_cols) : (index += 1) {
        if (index > first) {
            if (col >= layout_cols) break;
            grid.putCodepoint(x + col, row, ' ', 1, separator_style);
            col += 1;
            if (col >= layout_cols) break;
        }

        const tab = tabs[index];
        const tab_width = @min(widths[index], layout_cols - col);
        if (tab_width < 2) break;

        const is_active = index == active;
        const paint = if (is_active)
            (if (options.group_active) active_style else inactive_group_active_style)
        else
            inactive_style;
        const screen_col = x + col;
        grid.fillRect(@floatFromInt(screen_col), @floatFromInt(row), @floatFromInt(tab_width), 1, paint);

        var cursor = screen_col + 1;

        // Language badge, then a gap.
        const icon = iconFor(tab);
        if (icon.len > 0 and cursor + 2 <= screen_col + tab_width -| closeWidth(tab)) {
            const badge_paint = PaintStyle{
                .fg = if (is_active) ui.cell.packColor(.{ .r = 210, .g = 190, .b = 120 }) else ui.cell.packColor(.{ .r = 160, .g = 160, .b = 160 }),
                .bg = paint.bg,
            };
            _ = drawBadge(grid, cursor, row, icon, 2, badge_paint);
            cursor += 2;
            grid.putCodepoint(cursor, row, ' ', 1, paint);
            cursor += 1;
        }

        const reserved_close = closeWidth(tab);
        const label_end = screen_col + tab_width -| reserved_close -| 1;
        const label_cells = label_end -| cursor;
        var label_paint = paint;
        if (!tab.pinned) label_paint.attrs |= ui.cell.Attr.italic;
        const drawn = drawLabel(grid, tab.label, cursor, row, label_cells, label_paint);
        if (drawn < textWidth(tab.label) and cursor + drawn < label_end) {
            grid.putCodepoint(cursor + drawn, row, 0x2026, 1, label_paint);
        }

        if (reserved_close == 2 and tab_width >= 4) {
            const close_cell = screen_col + tab_width - 2;
            const hovered = options.hovered == index;
            const show_close = tab.closeable and (is_active or hovered or tab.dirty);
            if (show_close) {
                const glyph: u21 = if (tab.dirty and !hovered) 0x25CF else 0x00D7;
                const close_paint = if (tab.dirty and !hovered)
                    PaintStyle{ .fg = dirty_style.fg, .bg = paint.bg, .attrs = dirty_style.attrs }
                else
                    PaintStyle{ .fg = paint.fg, .bg = paint.bg };
                grid.putCodepoint(close_cell, row, glyph, 1, close_paint);
                try hits.append(.{
                    .start = screen_col,
                    .end = screen_col + tab_width,
                    .index = index,
                    .close_start = close_cell,
                    .close_end = close_cell + 1,
                });
                col += tab_width;
                continue;
            }
        }

        try hits.append(.{ .start = screen_col, .end = screen_col + tab_width, .index = index });
        col += tab_width;
    }

    if (options.title_action) |action| {
        const start = x + cols - 2;
        const paint = if (action.active)
            title_action_active_style
        else if (action.hovered)
            title_action_hover_style
        else
            title_action_style;
        grid.putCodepoint(start - 1, row, ' ', 1, paint);
        var offset: usize = 0;
        var cell = start;
        while (offset < action.glyphs.len and cell < x + cols) {
            const decoded = ui.dom.decodeAt(action.glyphs, offset);
            if (decoded.len == 0) break;
            grid.putCodepoint(cell, row, decoded.cp, 1, paint);
            cell += 1;
            offset += decoded.len;
        }
        return .{ .start = start, .end = cell };
    }
    return null;
}

fn revealFirst(count: usize, widths: []const usize, active: usize, cols: usize) usize {
    // Keep the active tab visible even when it is wider than the available
    // cells; otherwise the leading tabs would win and the active one would be
    // clipped away.
    var first: usize = active;
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
    _ = count;
    return first;
}

/// Returns the tab index at `col` in the strip painted by `draw`.
pub fn hitAt(hits: []const Hit, col: usize) ?usize {
    for (hits) |hit| {
        if (col >= hit.start and col < hit.end) return hit.index;
    }
    return null;
}

/// Returns the tab index whose close cell contains `col`.
pub fn closeHitAt(hits: []const Hit, col: usize) ?usize {
    for (hits) |hit| {
        const start = hit.close_start orelse continue;
        const end = hit.close_end orelse continue;
        if (col >= start and col < end) return hit.index;
    }
    return null;
}

test "tabBar draws labels, active state and hits" {
    const allocator = std.testing.allocator;
    var grid = try CellGrid.init(allocator, 32, 1);
    defer grid.deinit();

    var hits = std.array_list.Managed(Hit).init(allocator);
    defer hits.deinit();

    const tabs = [_]TabInfo{
        .{ .label = "a.txt", .language = "plaintext" },
        .{ .label = "b.txt", .language = "typescript", .dirty = true },
        .{ .label = "c.txt", .language = "plaintext" },
    };
    _ = try draw(&grid, &tabs, 1, 0, 0, grid.cols, &hits, .{}, null);

    try std.testing.expectEqual(@as(usize, 3), hits.items.len);
    try std.testing.expectEqual(@as(usize, 1), hitAt(hits.items, hits.items[1].start).?);
    try std.testing.expectEqual(@as(?usize, null), hitAt(hits.items, hits.items[0].end));

    const text = try grid.rowText(allocator, 0);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "a.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "b.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "TS") != null);
    // The dirty tab paints its dot in the close cell.
    try std.testing.expect(std.mem.indexOf(u8, text, "\u{25CF}") != null);
}

test "tabBar close hits and hovered close" {
    const allocator = std.testing.allocator;
    var grid = try CellGrid.init(allocator, 32, 1);
    defer grid.deinit();

    var hits = std.array_list.Managed(Hit).init(allocator);
    defer hits.deinit();

    const tabs = [_]TabInfo{
        .{ .label = "a.txt", .language = "plaintext" },
        .{ .label = "b.txt", .language = "plaintext" },
    };
    _ = try draw(&grid, &tabs, 0, 0, 0, grid.cols, &hits, .{ .hovered = 1 }, null);
    try std.testing.expectEqual(@as(usize, 2), hits.items.len);
    // Inactive tab has no close glyph unless hovered/active.
    try std.testing.expect(hits.items[0].close_start != null);
    try std.testing.expect(hits.items[1].close_start != null);
    try std.testing.expectEqual(@as(?usize, 1), closeHitAt(hits.items, hits.items[1].close_start.?));
}

test "tabBar scrolls to keep the active tab visible" {
    const allocator = std.testing.allocator;
    var grid = try CellGrid.init(allocator, 10, 1);
    defer grid.deinit();

    var hits = std.array_list.Managed(Hit).init(allocator);
    defer hits.deinit();

    const tabs = [_]TabInfo{
        .{ .label = "first.txt", .language = "plaintext" },
        .{ .label = "second.txt", .language = "plaintext" },
        .{ .label = "third.txt", .language = "plaintext" },
    };
    _ = try draw(&grid, &tabs, 2, 0, 0, grid.cols, &hits, .{}, null);

    try std.testing.expect(hits.items.len >= 1);
    try std.testing.expectEqual(@as(usize, 2), hits.items[hits.items.len - 1].index);
    try std.testing.expectEqual(@as(?usize, 2), hitAt(hits.items, hits.items[hits.items.len - 1].start));
}

test "tabBar italicizes preview tabs" {
    const allocator = std.testing.allocator;
    var grid = try CellGrid.init(allocator, 24, 1);
    defer grid.deinit();

    var hits = std.array_list.Managed(Hit).init(allocator);
    defer hits.deinit();

    const tabs = [_]TabInfo{
        .{ .label = "p.ts", .language = "typescript", .pinned = false },
    };
    _ = try draw(&grid, &tabs, 0, 0, 0, grid.cols, &hits, .{}, null);
    var col = hits.items[0].start;
    var found_italic = false;
    while (col < hits.items[0].end) : (col += 1) {
        if (grid.attrs[col] & ui.cell.Attr.italic != 0) found_italic = true;
    }
    try std.testing.expect(found_italic);
}

/// Returns the badge text for a language id. The result is at most two cells
/// and is a static string owned by this module.
pub fn languageBadge(language_id: []const u8) []const u8 {
    const table = .{
        .{ "javascript", "JS" },
        .{ "typescript", "TS" },
        .{ "javascriptreact", "JX" },
        .{ "typescriptreact", "TX" },
        .{ "zig", "ZG" },
        .{ "python", "PY" },
        .{ "rust", "RS" },
        .{ "go", "GO" },
        .{ "c", "C" },
        .{ "cpp", "C+" },
        .{ "java", "JV" },
        .{ "html", "HT" },
        .{ "css", "CS" },
        .{ "scss", "SC" },
        .{ "markdown", "MD" },
        .{ "yaml", "YM" },
        .{ "toml", "TM" },
        .{ "shellscript", "SH" },
        .{ "json", "{}" },
        .{ "jsonc", "{}" },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, entry[0], language_id)) return entry[1];
    }
    if (std.mem.eql(u8, language_id, "plaintext") or language_id.len == 0) return "";
    return "??";
}

/// Width of a badge in cells. Badges are ASCII, so this is the byte length.
/// Paints a badge's text, returning the number of cells written.
pub fn drawBadge(grid: *ui.CellGrid, x: usize, row: usize, text: []const u8, max_cells: usize, style: ui.cell.PaintStyle) usize {
    const visible = @min(text.len, max_cells);
    var col: usize = 0;
    while (col < visible) : (col += 1) {
        grid.putCodepoint(x + col, row, text[col], 1, style);
    }
    return visible;
}

test "tabBar: title action reserves the right corner and reports its hit" {
    const allocator = std.testing.allocator;
    var grid = try CellGrid.init(allocator, 30, 1);
    defer grid.deinit();
    var hits = std.array_list.Managed(Hit).init(allocator);
    defer hits.deinit();

    const tabs = [_]TabInfo{
        .{ .label = "a.md", .language = "markdown" },
        .{ .label = "b.md", .language = "markdown" },
    };
    const action_hit = (try draw(&grid, &tabs, 0, 0, 0, grid.cols, &hits, .{
        .title_action = .{ .active = true },
    }, null)).?;
    try std.testing.expectEqual(@as(usize, 28), action_hit.start);
    try std.testing.expectEqual(@as(usize, 30), action_hit.end);
    try std.testing.expectEqual(@as(u32, 0x25EB), grid.cluster[grid.index(28, 0)]);
    try std.testing.expectEqual(@as(u32, 0x2315), grid.cluster[grid.index(29, 0)]);
    for (hits.items) |hit| try std.testing.expect(hit.end <= 27);
}

test "tabBar: language badges" {
    try std.testing.expectEqualStrings("JS", languageBadge("javascript"));
    try std.testing.expectEqualStrings("TS", languageBadge("typescript"));
    try std.testing.expectEqualStrings("ZG", languageBadge("zig"));
    try std.testing.expectEqualStrings("{}", languageBadge("json"));
    try std.testing.expectEqualStrings("", languageBadge("plaintext"));
    try std.testing.expectEqualStrings("??", languageBadge("a-b?"));
    try std.testing.expectEqual(@as(usize, 2), languageBadge("javascript").len);
}
