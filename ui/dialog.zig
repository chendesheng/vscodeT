// Reusable modal message dialog for terminal hosts.
//
// A host supplies a message, a detail line and up to three button labels. The
// dialog owns focus, layout, painting and hit testing; it is composited into
// the host's `CellGrid` after the underlying content. The interaction rules
// follow the modal save-confirmation pattern used by VS Code's browser dialog:
//
// - the primary (first) button is focused when the dialog opens;
// - Tab / Shift-Tab / Left / Right / Up / Down wrap through the buttons;
// - Enter (or Space) activates the focused button, Escape cancels with the
//   cancel action (the host maps it to the last button);
// - a mouse press focuses a button and the matching release activates it; a
//   click elsewhere is consumed, not replayed to the host underneath.
//
// Layout uses the native macOS save-sheet shape: a centered warning dialog with
// the warning icon above the bold message, a detail line, and full-width
// buttons stacked vertically. On a terminal too short for that shape the buttons
// become one row and the icon/blank separators are dropped so the message,
// detail and actions still fit. The dialog dims every cell outside its
// rectangle; there is no shadow, border image or 1px styling.

const std = @import("std");
const Allocator = std.mem.Allocator;
const cell = @import("cell.zig");
const dom = @import("dom.zig");
const events = @import("event.zig");
const style = @import("style.zig");

const CellGrid = cell.CellGrid;
const PaintStyle = cell.PaintStyle;

pub const max_buttons = 3;

const dialog_max_width: usize = 50;
const border_width: usize = 1;
const cell_border = @import("cell_border.zig");
const horizontal_padding: usize = 2;
const vertical_padding: usize = 1;
const warning_glyph: u21 = 0x26A0; // ⚠
const ellipsis: u21 = 0x2026;

const dialog_background = style.Color{ .r = 0x25, .g = 0x25, .b = 0x26 };
const dialog_border = style.Color{ .r = 0x58, .g = 0x58, .b = 0x5a };
const text_color = style.Color{ .r = 0xeb, .g = 0xeb, .b = 0xeb };
const detail_color = style.Color{ .r = 0xc4, .g = 0xc4, .b = 0xc4 };
const warning_color = style.Color{ .r = 0xe8, .g = 0xc2, .b = 0x5a };
const primary_background = style.Color{ .r = 0x00, .g = 0x7a, .b = 0xff };
const primary_focused_background = style.Color{ .r = 0x3d, .g = 0x9b, .b = 0xff };
const primary_foreground = style.Color{ .r = 0xff, .g = 0xff, .b = 0xff };
const secondary_background = style.Color{ .r = 0x3a, .g = 0x3a, .b = 0x3c };
const secondary_focused_background = style.Color{ .r = 0x5a, .g = 0x5a, .b = 0x5c };
const secondary_foreground = style.Color{ .r = 0xed, .g = 0xed, .b = 0xed };

pub const Theme = struct {
    background: style.Color = dialog_background,
    border: style.Color = dialog_border,
    text: style.Color = text_color,
    detail: style.Color = detail_color,
    warning: style.Color = warning_color,
    primary_background: style.Color = primary_background,
    primary_focused_background: style.Color = primary_focused_background,
    primary_foreground: style.Color = primary_foreground,
    secondary_background: style.Color = secondary_background,
    secondary_focused_background: style.Color = secondary_focused_background,
    secondary_foreground: style.Color = secondary_foreground,
};

const background_paint = PaintStyle{
    .fg = cell.packColor(text_color),
    .bg = cell.packColor(dialog_background),
};
const message_paint = PaintStyle{
    .fg = cell.packColor(text_color),
    .bg = cell.packColor(dialog_background),
    .attrs = cell.Attr.bold,
};
const detail_paint = PaintStyle{
    .fg = cell.packColor(detail_color),
    .bg = cell.packColor(dialog_background),
};
const warning_paint = PaintStyle{
    .fg = cell.packColor(warning_color),
    .bg = cell.packColor(dialog_background),
    .attrs = cell.Attr.bold,
};

pub const ButtonRect = struct {
    x: usize = 0,
    y: usize = 0,
    width: usize = 0,
    height: usize = 0,
};

pub const Layout = struct {
    x: usize = 0,
    y: usize = 0,
    width: usize = 0,
    height: usize = 0,
    content_width: usize = 0,
    frame_cells: usize = border_width,
    message_rows: usize = 0,
    detail_rows: usize = 0,
    compact: bool = false,
};

pub const Action = union(enum) {
    none,
    activate: usize,
    cancel,
};

pub const Dialog = struct {
    allocator: Allocator,
    message: []u8,
    detail: []u8,
    buttons: [max_buttons][]u8 = undefined,
    button_count: usize = 0,
    focused: usize = 0,
    hovered: ?usize = null,
    pressed: ?usize = null,
    layout: Layout = .{},
    button_rects: [max_buttons]ButtonRect = [_]ButtonRect{ .{}, .{}, .{} },
    theme: Theme = .{},

    fn backgroundPaint(self: *const Dialog) PaintStyle {
        return .{ .fg = cell.packColor(self.theme.text), .bg = cell.packColor(self.theme.background) };
    }
    fn messagePaint(self: *const Dialog) PaintStyle {
        return .{ .fg = cell.packColor(self.theme.text), .bg = cell.packColor(self.theme.background), .attrs = cell.Attr.bold };
    }
    fn detailPaint(self: *const Dialog) PaintStyle {
        return .{ .fg = cell.packColor(self.theme.detail), .bg = cell.packColor(self.theme.background) };
    }
    fn warningPaint(self: *const Dialog) PaintStyle {
        return .{ .fg = cell.packColor(self.theme.warning), .bg = cell.packColor(self.theme.background), .attrs = cell.Attr.bold };
    }

    pub fn init(
        allocator: Allocator,
        message: []const u8,
        detail: []const u8,
        labels: []const []const u8,
    ) !*Dialog {
        if (labels.len == 0) return error.NoDialogButtons;
        if (labels.len > max_buttons) return error.TooManyDialogButtons;

        const message_copy = try allocator.dupe(u8, message);
        errdefer allocator.free(message_copy);
        const detail_copy = try allocator.dupe(u8, detail);
        errdefer allocator.free(detail_copy);

        var label_copies: [max_buttons][]u8 = undefined;
        var copied: usize = 0;
        errdefer for (label_copies[0..copied]) |label| allocator.free(label);
        for (labels, 0..) |label, index| {
            label_copies[index] = try allocator.dupe(u8, label);
            copied += 1;
        }

        const self = try allocator.create(Dialog);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .message = message_copy,
            .detail = detail_copy,
            .buttons = label_copies,
            .button_count = labels.len,
            .focused = 0,
        };
        return self;
    }

    pub fn deinit(self: *Dialog) void {
        for (self.buttons[0..self.button_count]) |label| self.allocator.free(label);
        self.allocator.free(self.message);
        self.allocator.free(self.detail);
        self.allocator.destroy(self);
    }

    pub fn buttonLabel(self: *const Dialog, index: usize) ?[]const u8 {
        if (index >= self.button_count) return null;
        return self.buttons[index];
    }

    pub fn buttonRect(self: *const Dialog, index: usize) ?ButtonRect {
        if (index >= self.button_count) return null;
        const rect = self.button_rects[index];
        if (rect.width == 0 or rect.height == 0) return null;
        return rect;
    }

    /// The pointer shape the dialog asks for at a host cell: a hand over a
    /// button, the terminal default over the dimmed backdrop and padding.
    /// Valid after `render` has computed the button rectangles.
    pub fn pointerAt(self: *const Dialog, x: usize, y: usize) style.Pointer {
        return if (self.buttonAt(x, y) != null) .pointer else .default;
    }

    pub fn focusNext(self: *Dialog) void {
        if (self.button_count == 0) return;
        self.focused = (self.focused + 1) % self.button_count;
    }

    pub fn focusPrevious(self: *Dialog) void {
        if (self.button_count == 0) return;
        self.focused = if (self.focused == 0) self.button_count - 1 else self.focused - 1;
    }

    /// Portable dialog keyboard handling. The host consumes every key while
    /// the dialog is open; this method only reports an activation or cancel.
    pub fn handleKey(self: *Dialog, event: *const events.KeyEvent) Action {
        switch (event.key) {
            .escape => return .cancel,
            .enter => return .{ .activate = self.focused },
            .tab, .backtab => {
                if (event.key == .backtab or event.mods.shift) {
                    self.focusPrevious();
                } else {
                    self.focusNext();
                }
                return .none;
            },
            .left, .up => {
                self.focusPrevious();
                return .none;
            },
            .right, .down => {
                self.focusNext();
                return .none;
            },
            .char => |ch| {
                if (ch == ' ') return .{ .activate = self.focused };
                return .none;
            },
            .text => |text| {
                if (std.mem.eql(u8, text, " ")) return .{ .activate = self.focused };
                return .none;
            },
            else => return .none,
        }
    }

    /// Mouse handling for the whole workbench surface. A press focuses a
    /// button and remembers it; the release over the same button activates
    /// it. Returns the activated button index, or null when the event only
    /// changed focus/hover or was consumed outside the buttons.
    pub fn handleMouse(self: *Dialog, event: *const events.MouseEvent) ?usize {
        switch (event.kind) {
            .move => {
                self.hovered = self.buttonAt(event.x, event.y);
                return null;
            },
            .down => {
                self.pressed = if (event.button == .left) self.buttonAt(event.x, event.y) else null;
                if (self.pressed) |index| self.focused = index;
                return null;
            },
            .up => {
                const pressed = self.pressed;
                self.pressed = null;
                if (event.button != .left) return null;
                const index = pressed orelse return null;
                if (self.buttonAt(event.x, event.y) != index) return null;
                return index;
            },
            .click => {
                if (event.button != .left) return null;
                return self.buttonAt(event.x, event.y);
            },
            .wheel => return null,
        }
    }

    /// Lays out and paints the dialog. The previous frame is cleared by the
    /// host, so the modal dim outside the rectangle is recomputed each frame.
    pub fn render(self: *Dialog, grid: *CellGrid) void {
        self.renderWithBorderCapabilities(grid, .{});
    }

    pub fn renderWithBorderCapabilities(self: *Dialog, grid: *CellGrid, caps: cell_border.Capabilities) void {
        const frame_cells = if (caps.has(.round)) @as(usize, 0) else border_width;
        const layout = self.computeLayout(grid.cols, grid.rows, frame_cells);
        self.layout = layout;
        for (&self.button_rects) |*rect| rect.* = .{};
        if (layout.width == 0 or layout.height == 0) return;

        self.dimBackdrop(grid, layout);
        const rect: style.Rect = .{
            .x = @floatFromInt(layout.x),
            .y = @floatFromInt(layout.y),
            .w = @floatFromInt(layout.width),
            .h = @floatFromInt(layout.height),
        };
        const frame = if (frame_cells == 0) cell.RoundedCellFrame.capture(grid, rect) else null;
        grid.clearBordersRect(rect.x, rect.y, rect.w, rect.h);
        grid.fillRect(rect.x, rect.y, rect.w, rect.h, self.backgroundPaint());

        self.renderContent(grid, layout);
        if (frame) |native| {
            native.paint(grid, caps, .{ .rgb = self.theme.border });
        } else {
            grid.paintRoundedFrame(rect, .{ .fg = cell.packColor(self.theme.border), .bg = cell.packColor(self.theme.background) });
        }
    }

    fn computeLayout(self: *const Dialog, cols: usize, rows: usize, frame_cells: usize) Layout {
        if (cols == 0 or rows == 0) return .{};

        const width = dialogWidth(cols);
        const content_width = contentWidth(width, frame_cells);
        const message_rows = @max(countWrappedLines(self.message, content_width), 1);
        const detail_rows = countWrappedLines(self.detail, content_width);
        const details = if (detail_rows > 0) 1 + detail_rows else 0;
        const vertical_height = 2 * frame_cells + 2 * vertical_padding +
            1 + message_rows + details + 1 + self.button_count;
        const compact_height = 2 * frame_cells + 2 * vertical_padding +
            message_rows + detail_rows + 1;

        var compact = false;
        var height = vertical_height;
        if (vertical_height > rows) {
            compact = true;
            height = compact_height;
        }
        height = @min(height, rows);

        return .{
            .x = (cols -| width) / 2,
            .y = (rows -| height) / 2,
            .width = width,
            .height = height,
            .content_width = content_width,
            .frame_cells = frame_cells,
            .message_rows = message_rows,
            .detail_rows = detail_rows,
            .compact = compact,
        };
    }

    fn renderContent(self: *Dialog, grid: *CellGrid, layout: Layout) void {
        const inner_x = layout.x + layout.frame_cells + horizontal_padding;
        const content_bottom = layout.y + layout.height -| layout.frame_cells;
        var row = layout.y + layout.frame_cells + vertical_padding;

        if (!layout.compact) {
            if (row < content_bottom) {
                grid.putCodepoint(inner_x, row, warning_glyph, 1, self.warningPaint());
                row += 1;
            }
        }

        const message_start = row;
        const message_drawn = drawWrapped(
            grid,
            inner_x,
            row,
            layout.content_width,
            content_bottom -| row,
            self.message,
            self.messagePaint(),
        );
        row = message_start + message_drawn;
        if (message_drawn < layout.message_rows) return;

        if (layout.detail_rows > 0) {
            if (!layout.compact and row < content_bottom) row += 1;
            const detail_start = row;
            const detail_drawn = drawWrapped(
                grid,
                inner_x,
                row,
                layout.content_width,
                content_bottom -| row,
                self.detail,
                self.detailPaint(),
            );
            row = detail_start + detail_drawn;
            if (detail_drawn < layout.detail_rows) return;
        }

        if (!layout.compact and row < content_bottom) row += 1;
        self.renderButtons(grid, layout, row, content_bottom);
    }

    fn renderButtons(self: *Dialog, grid: *CellGrid, layout: Layout, row: usize, content_bottom: usize) void {
        if (row >= content_bottom) return;

        if (layout.compact) {
            var widths: [max_buttons]usize = @splat(0);
            horizontalButtonWidths(self, layout.content_width, &widths);

            var total: usize = 0;
            for (widths[0..self.button_count], 0..) |width, index| {
                total += width;
                if (index + 1 < self.button_count) total += 1;
            }
            const inner_x = layout.x + layout.frame_cells + horizontal_padding;
            var col = inner_x + (layout.content_width -| total) / 2;

            for (widths[0..self.button_count], 0..) |width, index| {
                if (width == 0) continue;
                const rect = ButtonRect{
                    .x = col,
                    .y = row,
                    .width = width,
                    .height = 1,
                };
                self.button_rects[index] = rect;
                self.paintButton(grid, rect, index);
                col += width + 1;
            }
            return;
        }

        const inner_x = layout.x + layout.frame_cells + horizontal_padding;
        for (0..self.button_count) |index| {
            const y = row + index;
            if (y >= content_bottom) break;
            const rect = ButtonRect{
                .x = inner_x,
                .y = y,
                .width = layout.content_width,
                .height = 1,
            };
            self.button_rects[index] = rect;
            self.paintButton(grid, rect, index);
        }
    }

    fn paintButton(self: *const Dialog, grid: *CellGrid, rect: ButtonRect, index: usize) void {
        const primary = index == 0;
        const focused = index == self.focused;
        const hovered = self.hovered != null and self.hovered.? == index;

        var background = if (primary) self.theme.primary_background else self.theme.secondary_background;
        if (hovered or focused) {
            background = if (primary) self.theme.primary_focused_background else self.theme.secondary_focused_background;
        }
        const paint = PaintStyle{
            .fg = cell.packColor(if (primary) self.theme.primary_foreground else self.theme.secondary_foreground),
            .bg = cell.packColor(background),
            .attrs = if (focused) cell.Attr.bold else 0,
        };

        grid.fillRect(
            @floatFromInt(rect.x),
            @floatFromInt(rect.y),
            @floatFromInt(rect.width),
            1,
            paint,
        );
        drawButtonLabel(grid, rect, self.buttons[index], paint);
    }

    fn dimBackdrop(self: *const Dialog, grid: *CellGrid, layout: Layout) void {
        _ = self;
        var row: usize = 0;
        while (row < grid.rows) : (row += 1) {
            if (row >= layout.y and row < layout.y + layout.height) {
                if (layout.x > 0) {
                    const start = row * grid.cols;
                    for (grid.attrs[start .. start + layout.x]) |*attr| attr.* |= cell.Attr.dim;
                }
                const after = layout.x + layout.width;
                if (after < grid.cols) {
                    const start = row * grid.cols + after;
                    for (grid.attrs[start .. (row + 1) * grid.cols]) |*attr| attr.* |= cell.Attr.dim;
                }
                continue;
            }
            const start = row * grid.cols;
            for (grid.attrs[start .. (row + 1) * grid.cols]) |*attr| attr.* |= cell.Attr.dim;
        }
    }

    fn buttonAt(self: *const Dialog, x: usize, y: usize) ?usize {
        for (self.button_rects[0..self.button_count], 0..) |rect, index| {
            if (rect.width == 0 or rect.height == 0) continue;
            if (x >= rect.x and x < rect.x + rect.width and y == rect.y) return index;
        }
        return null;
    }
};

fn dialogWidth(cols: usize) usize {
    var width = @min(dialog_max_width, cols);
    if (cols > 4) width = @min(width, cols - 2);
    width = @max(width, @min(cols, 12));
    return width;
}

fn contentWidth(width: usize, frame_cells: usize) usize {
    return @max(width -| (2 * frame_cells) -| (2 * horizontal_padding), 1);
}

fn horizontalButtonWidths(dialog: *const Dialog, content_width: usize, widths: *[max_buttons]usize) void {
    const count = dialog.button_count;
    const gaps = count -| 1;

    var natural_total = gaps;
    for (dialog.buttons[0..count]) |label| natural_total += textWidth(label) + 2;
    if (natural_total <= content_width) {
        for (dialog.buttons[0..count], 0..) |label, index| {
            widths[index] = textWidth(label) + 2;
        }
        return;
    }

    const usable = content_width -| gaps;
    const base = usable / count;
    var extra = usable % count;
    for (0..count) |index| {
        widths[index] = base + @as(usize, if (extra > 0) 1 else 0);
        if (extra > 0) extra -= 1;
    }
}

fn drawButtonLabel(grid: *CellGrid, rect: ButtonRect, label: []const u8, paint: PaintStyle) void {
    const available = rect.width -| 2;
    if (available == 0) return;

    var visible = label;
    var truncated = false;
    if (textWidth(label) > available) {
        if (available <= 1) {
            visible = label[0..0];
        } else {
            visible = truncateLabel(label, available - 1);
        }
        truncated = true;
    }

    const label_width = textWidth(visible) + if (truncated) @as(usize, 1) else 0;
    const start = rect.x + (rect.width -| label_width) / 2;
    drawText(grid, start, rect.y, available, visible, paint);
    if (truncated) {
        grid.putCodepoint(start + textWidth(visible), rect.y, ellipsis, 1, paint);
    }
}

fn drawWrapped(
    grid: *CellGrid,
    x: usize,
    y: usize,
    width: usize,
    max_rows: usize,
    text: []const u8,
    paint: PaintStyle,
) usize {
    var rows: usize = 0;
    var start: usize = 0;
    while (start < text.len and rows < max_rows) {
        const line = wrapLine(text, start, width);
        if (line.next <= start) break;
        drawText(grid, x, y + rows, width, line.text, paint);
        rows += 1;
        start = line.next;
    }
    return rows;
}

fn countWrappedLines(text: []const u8, width: usize) usize {
    var lines: usize = 0;
    var start: usize = 0;
    while (start < text.len) {
        const line = wrapLine(text, start, width);
        if (line.next <= start) break;
        lines += 1;
        start = line.next;
    }
    return lines;
}

const WrappedLine = struct {
    text: []const u8,
    next: usize,
};

fn wrapLine(text: []const u8, start: usize, width: usize) WrappedLine {
    const line_width = @max(width, 1);

    // Skip leading whitespace so a break at a space does not produce an empty
    // line on the next row. A newline still produces its own (empty) row.
    var line_start = start;
    while (line_start < text.len) {
        const decoded = dom.decodeAt(text, line_start);
        if (decoded.len == 0) break;
        if (decoded.cp == '\n') break;
        if (isWhitespace(decoded.cp)) {
            line_start += decoded.len;
            continue;
        }
        break;
    }

    var offset = line_start;
    var cells: usize = 0;
    var last_break: ?usize = null;
    while (offset < text.len) {
        const decoded = dom.decodeAt(text, offset);
        if (decoded.len == 0) break;
        if (decoded.cp == '\n') {
            return .{
                .text = trimRight(text[line_start..offset]),
                .next = offset + decoded.len,
            };
        }

        const char_width = dom.defaultMeasureWidth(decoded.cp);
        if (cells + char_width > line_width) {
            if (last_break) |break_at| {
                if (break_at > line_start) {
                    return .{
                        .text = trimRight(text[line_start..break_at]),
                        .next = skipWhitespace(text, break_at),
                    };
                }
            }
            if (cells == 0) {
                // A cell wider than the content area still has to advance or
                // the renderer would loop on the same character forever.
                return .{
                    .text = text[line_start .. offset + decoded.len],
                    .next = offset + decoded.len,
                };
            }
            return .{
                .text = trimRight(text[line_start..offset]),
                .next = offset,
            };
        }

        if (isWhitespace(decoded.cp)) last_break = offset;
        cells += char_width;
        offset += decoded.len;
    }

    return .{
        .text = trimRight(text[line_start..text.len]),
        .next = text.len,
    };
}

fn skipWhitespace(text: []const u8, start: usize) usize {
    var offset = start;
    while (offset < text.len) {
        const decoded = dom.decodeAt(text, offset);
        if (decoded.len == 0 or decoded.cp == '\n' or !isWhitespace(decoded.cp)) break;
        offset += decoded.len;
    }
    return offset;
}

fn trimRight(text: []const u8) []const u8 {
    var end = text.len;
    while (end > 0) {
        const ch = text[end - 1];
        if (ch != ' ' and ch != '\t' and ch != '\r') break;
        end -= 1;
    }
    return text[0..end];
}

fn isWhitespace(cp: u21) bool {
    return cp == ' ' or cp == '\t' or cp == '\r';
}

fn textWidth(text: []const u8) usize {
    var width: usize = 0;
    var offset: usize = 0;
    while (offset < text.len) {
        const decoded = dom.decodeAt(text, offset);
        if (decoded.len == 0) break;
        width += dom.defaultMeasureWidth(decoded.cp);
        offset += decoded.len;
    }
    return width;
}

fn truncateLabel(label: []const u8, max_cells: usize) []const u8 {
    var width: usize = 0;
    var offset: usize = 0;
    while (offset < label.len) {
        const decoded = dom.decodeAt(label, offset);
        if (decoded.len == 0) break;
        const char_width = dom.defaultMeasureWidth(decoded.cp);
        if (width + char_width > max_cells) break;
        width += char_width;
        offset += decoded.len;
    }
    return label[0..offset];
}

fn drawText(
    grid: *CellGrid,
    x: usize,
    y: usize,
    cell_width: usize,
    text: []const u8,
    paint: PaintStyle,
) void {
    var col = x;
    var offset: usize = 0;
    while (offset < text.len and col < x + cell_width) {
        const decoded = dom.decodeAt(text, offset);
        if (decoded.len == 0) break;
        const char_width = dom.defaultMeasureWidth(decoded.cp);
        if (col + char_width > x + cell_width) break;
        grid.putCodepoint(col, y, decoded.cp, char_width, paint);
        col += char_width;
        offset += decoded.len;
    }
}

test "Dialog: rounded corners use glyphs or zero-cell strokes" {
    const allocator = std.testing.allocator;
    const dialog = try Dialog.init(allocator, "Save changes?", "Changes are unsaved.", &.{ "Save", "Cancel" });
    defer dialog.deinit();
    var grid = try CellGrid.init(allocator, 60, 20);
    defer grid.deinit();
    dialog.render(&grid);
    const fallback = dialog.layout;
    try std.testing.expectEqual(@as(u32, '╭'), grid.cluster[grid.index(fallback.x, fallback.y)]);
    try std.testing.expectEqual(@as(u32, '╯'), grid.cluster[grid.index(fallback.x + fallback.width - 1, fallback.y + fallback.height - 1)]);

    grid.clear();
    const caps = cell_border.parseReply("\x1bP1+bcell-border;ok;1;pen,rect,round,radius,outside\x1b\\").?;
    dialog.renderWithBorderCapabilities(&grid, caps);
    const native = dialog.layout;
    try std.testing.expectEqual(fallback.height - 2, native.height);
    try std.testing.expectEqual(cell_border.Joint.top_left, grid.borderSetAt(native.x, native.y).joints);
    try std.testing.expectEqual(@as(?u9, 128), grid.borderSetAt(native.x, native.y).round_style.radius);
    try std.testing.expect(dialog.buttonRect(0) != null);
}

test "Dialog: renders warning, message, detail and vertical buttons" {
    const allocator = std.testing.allocator;
    const dialog = try Dialog.init(
        allocator,
        "Do you want to save the changes you made to http-proxy.js?",
        "Your changes will be lost if you don't save them.",
        &.{ "Save", "Don't Save", "Cancel" },
    );
    defer dialog.deinit();

    var grid = try CellGrid.init(allocator, 60, 20);
    defer grid.deinit();
    dialog.render(&grid);
    try std.testing.expect(!dialog.layout.compact);
    try std.testing.expect(dialog.layout.height > 0);
    try std.testing.expect(dialog.buttonRect(0) != null);
    try std.testing.expect(dialog.buttonRect(2) != null);
    try std.testing.expect(dialog.buttonRect(0).?.y < dialog.buttonRect(2).?.y);
    try std.testing.expect(grid.attrs[grid.index(0, 0)] & cell.Attr.dim != 0);

    const rows = try allRows(allocator, &grid);
    defer allocator.free(rows);
    try std.testing.expect(std.mem.indexOf(u8, rows, "Do you want to save the changes") != null);
    try std.testing.expect(std.mem.indexOf(u8, rows, "Your changes will be lost") != null);
    try std.testing.expect(std.mem.indexOf(u8, rows, "Save") != null);
    try std.testing.expect(std.mem.indexOf(u8, rows, "Don't Save") != null);
    try std.testing.expect(std.mem.indexOf(u8, rows, "Cancel") != null);
    try std.testing.expect(std.mem.indexOf(u8, rows, "\u{26A0}") != null);
}

test "Dialog: custom theme colors" {
    const allocator = std.testing.allocator;
    const dialog = try Dialog.init(allocator, "Message", "Detail", &.{"OK"});
    defer dialog.deinit();
    dialog.theme = .{
        .background = .{ .r = 10, .g = 20, .b = 30 },
        .text = .{ .r = 200, .g = 210, .b = 220 },
    };
    var grid = try CellGrid.init(allocator, 40, 10);
    defer grid.deinit();
    dialog.render(&grid);
    try std.testing.expectEqual(
        cell.packColor(.{ .r = 10, .g = 20, .b = 30 }),
        grid.bg[grid.index(dialog.layout.x + 1, dialog.layout.y + 1)],
    );
}

test "Dialog: compact layout keeps the actions on a short terminal" {
    const allocator = std.testing.allocator;
    const dialog = try Dialog.init(
        allocator,
        "Do you want to save the changes you made to close.txt?",
        "Your changes will be lost if you don't save them.",
        &.{ "Save", "Don't Save", "Cancel" },
    );
    defer dialog.deinit();

    var grid = try CellGrid.init(allocator, 40, 9);
    defer grid.deinit();
    dialog.render(&grid);
    try std.testing.expect(dialog.layout.compact);
    try std.testing.expectEqual(@as(usize, 9), dialog.layout.height);
    try std.testing.expect(dialog.buttonRect(0) != null);
    try std.testing.expect(dialog.buttonRect(1) != null);
    try std.testing.expect(dialog.buttonRect(2) != null);
    try std.testing.expectEqual(dialog.buttonRect(0).?.y, dialog.buttonRect(2).?.y);

    const rows = try allRows(allocator, &grid);
    defer allocator.free(rows);
    try std.testing.expect(std.mem.indexOf(u8, rows, "Don't Save") != null);
    try std.testing.expect(std.mem.indexOf(u8, rows, "Cancel") != null);
}

test "Dialog: keyboard wraps focus, activates and cancels" {
    const allocator = std.testing.allocator;
    const dialog = try Dialog.init(
        allocator,
        "message",
        "detail",
        &.{ "Save", "Don't Save", "Cancel" },
    );
    defer dialog.deinit();

    try std.testing.expectEqual(@as(usize, 0), dialog.focused);
    var right = events.KeyEvent{ .key = .right };
    try std.testing.expectEqual(Action.none, dialog.handleKey(&right));
    try std.testing.expectEqual(@as(usize, 1), dialog.focused);
    var down = events.KeyEvent{ .key = .down };
    try std.testing.expectEqual(Action.none, dialog.handleKey(&down));
    try std.testing.expectEqual(@as(usize, 2), dialog.focused);
    try std.testing.expectEqual(Action.none, dialog.handleKey(&right));
    try std.testing.expectEqual(@as(usize, 0), dialog.focused);

    var enter = events.KeyEvent{ .key = .enter };
    try std.testing.expectEqual(Action{ .activate = 0 }, dialog.handleKey(&enter));

    var escape = events.KeyEvent{ .key = .escape };
    try std.testing.expectEqual(Action.cancel, dialog.handleKey(&escape));

    var shift_tab = events.KeyEvent{ .key = .tab, .mods = .{ .shift = true } };
    try std.testing.expectEqual(Action.none, dialog.handleKey(&shift_tab));
    try std.testing.expectEqual(@as(usize, 2), dialog.focused);

    var keys = try @import("input.zig").decodeKeys(allocator, " ");
    defer keys.deinit(allocator);
    try std.testing.expectEqual(Action{ .activate = 2 }, dialog.handleKey(&keys.items[0]));
}

test "Dialog: mouse press and release activate a button" {
    const allocator = std.testing.allocator;
    const dialog = try Dialog.init(
        allocator,
        "message",
        "detail",
        &.{ "Save", "Don't Save", "Cancel" },
    );
    defer dialog.deinit();

    var grid = try CellGrid.init(allocator, 60, 20);
    defer grid.deinit();
    dialog.render(&grid);

    const rect = dialog.buttonRect(1).?;
    var move = events.MouseEvent{ .kind = .move, .x = rect.x + 1, .y = rect.y };
    try std.testing.expectEqual(@as(?usize, null), dialog.handleMouse(&move));
    try std.testing.expectEqual(@as(?usize, 1), dialog.hovered);

    var down = events.MouseEvent{ .kind = .down, .x = rect.x + 1, .y = rect.y, .button = .left };
    try std.testing.expectEqual(@as(?usize, null), dialog.handleMouse(&down));
    var up = events.MouseEvent{ .kind = .up, .x = rect.x + 1, .y = rect.y, .button = .left };
    try std.testing.expectEqual(@as(?usize, 1), dialog.handleMouse(&up));

    var outside = events.MouseEvent{ .kind = .down, .x = 0, .y = 0, .button = .left };
    try std.testing.expectEqual(@as(?usize, null), dialog.handleMouse(&outside));

    try std.testing.expectEqual(style.Pointer.pointer, dialog.pointerAt(rect.x + 1, rect.y));
    try std.testing.expectEqual(style.Pointer.default, dialog.pointerAt(0, 0));
}

fn allRows(allocator: Allocator, grid: *const CellGrid) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    var row: usize = 0;
    while (row < grid.rows) : (row += 1) {
        const text = try grid.rowText(allocator, row);
        defer allocator.free(text);
        try out.appendSlice(text);
        try out.append('\n');
    }
    return out.toOwnedSlice();
}
