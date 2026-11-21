// Port of `src/vs/base/browser/ui/breadcrumbs/breadcrumbsWidget.ts`.
//
// The browser widget is a horizontally scrollable flex row of item elements,
// each ending in a chevron separator; it tracks focus/selection and delegates
// rendering to `BreadcrumbsItem.render`. The terminal widget keeps the same
// state machine (items, focused index, selected index, minimal reveal) and
// replaces DOM nodes with one painted cell row.
//
// Terminal adaptations, documented in `docs/terminal-ui.md`:
// - No horizontal scrollbar: overflow drops leading items behind a leading
//   ellipsis and truncates the final label with a trailing ellipsis.
// - The separator is the cell glyph `>` instead of the codicon chevron.
// - Hover/focus colors and the underline come from direct `PaintStyle`s. An
//   item's icon is either one Nerd Font file glyph with its own colour (the
//   Explorer's table, supplied by the control) or pre-rendered symbol text.
//
// Item labels and icons are borrowed from the breadcrumbs control/model and
// must stay valid until the next `setItems` call.

const std = @import("std");
const ui = @import("ui");

const CellGrid = ui.CellGrid;
const PaintStyle = ui.cell.PaintStyle;

pub const ItemKind = enum { file, folder, symbol, placeholder };

pub const Icon = union(enum) {
    none,
    /// One Nerd Font file glyph painted with the Explorer's icon colour.
    glyph: struct {
        codepoint: u21,
        color: ui.Color,
    },
    /// Pre-rendered icon text (0-2 cells) painted with `Style.icon`.
    text: []const u8,

    fn width(self: Icon) usize {
        return switch (self) {
            .none => 0,
            .glyph => 1,
            .text => |text| textWidth(text),
        };
    }
};

pub const Item = struct {
    label: []const u8,
    kind: ItemKind = .file,
    icon: Icon = .none,
};

pub const Hit = struct {
    start: usize,
    end: usize,
    index: usize,
};

pub const Style = struct {
    background: PaintStyle,
    item: PaintStyle,
    focused: PaintStyle,
    hovered: PaintStyle,
    separator: PaintStyle,
    icon: PaintStyle,
};

pub const separator_width: usize = 3;
pub const leading_ellipsis_width: usize = 2;

pub const BreadcrumbsWidget = struct {
    allocator: std.mem.Allocator,
    items: std.array_list.Managed(Item),
    hits: std.array_list.Managed(Hit),
    focused: ?usize = null,
    selected: ?usize = null,
    hovered: ?usize = null,
    first_visible: usize = 0,
    enabled: bool = true,

    pub fn init(allocator: std.mem.Allocator) BreadcrumbsWidget {
        return .{
            .allocator = allocator,
            .items = std.array_list.Managed(Item).init(allocator),
            .hits = std.array_list.Managed(Hit).init(allocator),
        };
    }

    pub fn deinit(self: *BreadcrumbsWidget) void {
        self.items.deinit();
        self.hits.deinit();
    }

    pub fn setItems(self: *BreadcrumbsWidget, items: []const Item) !void {
        self.items.clearRetainingCapacity();
        try self.items.appendSlice(items);
        self.hits.clearRetainingCapacity();
        self.focused = null;
        self.selected = null;
        self.hovered = null;
        self.first_visible = 0;
    }

    pub fn itemCount(self: *const BreadcrumbsWidget) usize {
        return self.items.items.len;
    }

    pub fn setEnabled(self: *BreadcrumbsWidget, enabled: bool) void {
        self.enabled = enabled;
    }

    pub fn setFocused(self: *BreadcrumbsWidget, index: ?usize) void {
        if (index) |value| {
            if (value < self.items.items.len) self.focused = value;
        } else {
            self.focused = null;
        }
    }

    pub fn setSelection(self: *BreadcrumbsWidget, index: ?usize) void {
        if (index) |value| {
            if (value < self.items.items.len) self.selected = value;
        } else {
            self.selected = null;
        }
    }

    pub fn getFocused(self: *const BreadcrumbsWidget) ?usize {
        return self.focused;
    }

    pub fn getSelection(self: *const BreadcrumbsWidget) ?usize {
        return self.selected;
    }

    pub fn focusNext(self: *BreadcrumbsWidget) void {
        if (self.items.items.len == 0) return;
        const current = self.focused orelse return;
        if (current + 1 < self.items.items.len) self.focused = current + 1;
        self.reveal(self.focused.?);
    }

    pub fn focusPrev(self: *BreadcrumbsWidget) void {
        if (self.items.items.len == 0) return;
        const current = self.focused orelse return;
        if (current > 0) self.focused = current - 1;
        self.reveal(self.focused.?);
    }

    /// Minimal reveal: scroll just enough for `index` to be visible.
    pub fn reveal(self: *BreadcrumbsWidget, index: usize) void {
        if (index >= self.items.items.len) return;
        if (index < self.first_visible) self.first_visible = index;
    }

    pub fn revealLast(self: *BreadcrumbsWidget) void {
        if (self.items.items.len == 0) {
            self.first_visible = 0;
            return;
        }
        self.reveal(self.items.items.len - 1);
    }

    pub fn hitAt(self: *const BreadcrumbsWidget, x: usize) ?usize {
        for (self.hits.items) |hit| {
            if (x >= hit.start and x < hit.end) return hit.index;
        }
        return null;
    }

    /// Paints the widget. `row_style` is the base row background/foreground;
    /// `focus`/`hover` styling is applied per item.
    pub fn draw(
        self: *BreadcrumbsWidget,
        grid: *CellGrid,
        x: usize,
        row: usize,
        width: usize,
        style: Style,
        focused_widget: bool,
    ) !void {
        self.hits.clearRetainingCapacity();
        if (row >= grid.rows or x >= grid.cols or width == 0) return;
        const cols = @min(width, grid.cols - x);
        if (cols == 0) return;

        grid.fillRect(@floatFromInt(x), @floatFromInt(row), @floatFromInt(cols), 1, style.background);
        if (self.items.items.len == 0) return;

        const widths = try self.allocator.alloc(usize, self.items.items.len);
        defer self.allocator.free(widths);
        for (self.items.items, 0..) |item, index| widths[index] = itemWidth(item);

        const last = self.focused orelse self.items.items.len - 1;
        var first = @min(self.first_visible, self.items.items.len - 1);
        if (first > last) first = last;

        // Drop leading items until the wanted tail fits.
        while (first < last) {
            var used: usize = if (first > 0) leading_ellipsis_width else 0;
            var index = first;
            while (index < self.items.items.len) : (index += 1) {
                const separator: usize = if (index > first) separator_width else 0;
                used += widths[index] + separator;
            }
            if (used <= cols) break;
            first += 1;
        }
        self.first_visible = first;

        var col: usize = 0;
        if (first > 0) {
            if (cols < leading_ellipsis_width) return;
            grid.putCodepoint(x, row, 0x2026, 1, style.separator);
            col = leading_ellipsis_width;
        }

        var index = first;
        while (index < self.items.items.len and col < cols) : (index += 1) {
            if (index > first) {
                if (col + separator_width > cols) break;
                grid.putCodepoint(x + col, row, ' ', 1, style.separator);
                grid.putCodepoint(x + col + 1, row, '>', 1, style.separator);
                grid.putCodepoint(x + col + 2, row, ' ', 1, style.separator);
                col += separator_width;
            }

            const item = self.items.items[index];
            var paint = style.item;
            if (focused_widget and self.focused == index) {
                paint = style.focused;
            } else if (self.hovered == index) {
                paint = style.hovered;
            } else if (focused_widget and self.selected == index) {
                paint = style.focused;
            }

            const start = col;
            var icon_width: usize = 0;
            switch (item.icon) {
                .none => {},
                .glyph => |icon| {
                    if (cols -| col >= 1) {
                        grid.putCodepoint(x + col, row, icon.codepoint, 1, .{
                            .fg = ui.cell.packColor(icon.color),
                            .bg = style.icon.bg,
                            .attrs = style.icon.attrs,
                        });
                        icon_width = 1;
                    }
                },
                .text => |text| {
                    if (text.len > 0) {
                        icon_width = drawIcon(grid, x + col, row, text, cols -| col, style.icon);
                    }
                },
            }
            col += icon_width;
            if (icon_width > 0 and col < cols) {
                grid.putCodepoint(x + col, row, ' ', 1, style.background);
                col += 1;
            }

            const available = cols -| col;
            if (available == 0) break;
            const label = truncateText(item.label, available);
            const label_width = drawText(grid, x + col, row, label, paint);
            col += label_width;
            if (label_width < textWidth(item.label)) {
                // Trailing ellipsis when the label was truncated and a cell is
                // still available; otherwise the clip itself is the ellipsis.
                if (col < cols) {
                    grid.putCodepoint(x + col, row, 0x2026, 1, paint);
                    col += 1;
                }
            }
            try self.hits.append(.{ .start = x + start, .end = x + col, .index = index });
        }
    }
};

fn drawIcon(grid: *CellGrid, x: usize, row: usize, icon: []const u8, max_cells: usize, style: PaintStyle) usize {
    var col: usize = 0;
    var offset: usize = 0;
    while (offset < icon.len and col < max_cells) {
        const decoded = ui.dom.decodeAt(icon, offset);
        const width = ui.dom.defaultMeasureWidth(decoded.cp);
        if (col + width > max_cells) break;
        grid.putCodepoint(x + col, row, decoded.cp, width, style);
        col += width;
        offset += decoded.len;
    }
    return col;
}

fn iconWidth(icon: Icon) usize {
    return icon.width();
}

pub fn textWidth(text: []const u8) usize {
    var width: usize = 0;
    var offset: usize = 0;
    while (offset < text.len) {
        const decoded = ui.dom.decodeAt(text, offset);
        width += ui.dom.defaultMeasureWidth(decoded.cp);
        offset += decoded.len;
    }
    return width;
}

pub fn itemWidth(item: Item) usize {
    const width = iconWidth(item.icon);
    return width + @as(usize, if (width > 0) 1 else 0) + textWidth(item.label);
}

fn truncateText(text: []const u8, max_cells: usize) []const u8 {
    var width: usize = 0;
    var offset: usize = 0;
    while (offset < text.len) {
        const decoded = ui.dom.decodeAt(text, offset);
        const next = width + ui.dom.defaultMeasureWidth(decoded.cp);
        if (next > max_cells) break;
        width = next;
        offset += decoded.len;
    }
    return text[0..offset];
}

fn drawText(grid: *CellGrid, x: usize, row: usize, text: []const u8, paint: PaintStyle) usize {
    var col: usize = 0;
    var offset: usize = 0;
    while (offset < text.len) {
        const decoded = ui.dom.decodeAt(text, offset);
        const width = ui.dom.defaultMeasureWidth(decoded.cp);
        grid.putCodepoint(x + col, row, decoded.cp, width, paint);
        col += width;
        offset += decoded.len;
    }
    return col;
}
