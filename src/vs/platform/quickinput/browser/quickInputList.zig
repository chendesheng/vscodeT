// Terminal quick-pick widget: the TUI view for
// `src/vs/platform/quickinput/browser/quickInput.ts` +
// `quickInputList.ts`.
//
// The input row is a real `ui.InputBox` rendered into a one-row `ui.Surface`;
// the list is painted directly into the workbench cell grid (the same
// approach the sidebar and tab bar use). The terminal has no CSS, icons,
// buttons, keybinding labels or virtualized tree, so a separator is a dim
// row and an item is label + description with matched characters in bold.
//
// The picker is an overlay of the workbench, not an editor overlay: it is
// blitted after every pane and the tab strip.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const theme_colors_mod = @import("../../../workbench/browser/themeColors.zig");
const QuickPick = @import("./quickInput.zig").QuickPick;

const base_background = ui.Color{ .r = 45, .g = 45, .b = 55 };
const base_foreground = ui.Color{ .r = 230, .g = 230, .b = 230 };
const base_dim_foreground = ui.Color{ .r = 145, .g = 145, .b = 158 };
const base_active_background = ui.Color{ .r = 60, .g = 70, .b = 95 };
const base_hover_background = ui.Color{ .r = 52, .g = 58, .b = 74 };

pub const Layout = struct {
    x: usize = 0,
    y: usize = 0,
    width: usize = 0,
    height: usize = 0,
    list_rows: usize = 0,
};

pub const QuickPickWidget = struct {
    pub const Colors = struct {
        background: ui.Color = base_background,
        foreground: ui.Color = base_foreground,
        dim_foreground: ui.Color = base_dim_foreground,
        active_background: ui.Color = base_active_background,
        hover_background: ui.Color = base_hover_background,
    };

    allocator: Allocator,
    theme: ?*const theme_colors_mod.ThemeColors = null,
    colors: Colors = .{},
    input: ui.InputBox,
    input_surface: ?ui.Surface = null,
    input_surface_width: usize = 0,
    layout: Layout = .{},
    hover_index: ?usize = null,
    syncing: bool = false,
    active_picker: ?*QuickPick = null,

    pub fn init(allocator: Allocator) !*QuickPickWidget {
        const self = try allocator.create(QuickPickWidget);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .input = ui.InputBox.init(allocator),
        };
        self.input.placeholder_when_focused = true;
        self.input.callback_context = self;
        self.input.on_change = onInputChanged;
        return self;
    }

    pub fn setThemeColors(self: *QuickPickWidget, palette: ?*const theme_colors_mod.ThemeColors) void {
        self.theme = palette;
    }

    fn resolveColors(self: *const QuickPickWidget) Colors {
        const palette = self.theme orelse return .{};
        return .{
            .background = palette.colorOr("quickInput.background", base_background),
            .foreground = palette.colorOr("quickInput.foreground", base_foreground),
            .dim_foreground = palette.colorOr("descriptionForeground", base_dim_foreground),
            .active_background = palette.colorOr("quickInputList.focusBackground", base_active_background),
            .hover_background = palette.colorOr("list.hoverBackground", base_hover_background),
        };
    }

    pub fn deinit(self: *QuickPickWidget) void {
        if (self.input_surface) |*surface| surface.deinit();
        self.input.deinit();
        self.allocator.destroy(self);
    }

    /// Computes the overlay geometry for a viewport and the current items.
    pub fn computeLayout(
        self: *QuickPickWidget,
        picker: *QuickPick,
        cols: usize,
        rows: usize,
    ) Layout {
        var width: usize = @min(cols -| 2, 80);
        width = @max(width, @min(cols, 20));
        if (width > cols) width = cols;

        const wanted_items = picker.items.items.len;
        var list_rows: usize = @min(wanted_items, 10);
        if (rows <= 1) list_rows = 0;
        if (list_rows > rows -| 1) list_rows = rows -| 1;

        const height = 1 + list_rows;
        self.layout = .{
            .x = (cols -| width) / 2,
            .y = 0,
            .width = width,
            .height = height,
            .list_rows = list_rows,
        };
        picker.page_size = @max(list_rows, 1);
        return self.layout;
    }

    /// Draws the picker and returns its overlay rectangle.
    pub fn render(
        self: *QuickPickWidget,
        picker: *QuickPick,
        grid: *ui.CellGrid,
    ) !Layout {
        self.active_picker = picker;
        self.colors = self.resolveColors();
        const layout = self.computeLayout(picker, grid.cols, grid.rows);
        if (layout.width == 0 or layout.height == 0) return layout;

        // The picker is an overlay: it must not inherit a split divider's cell
        // border on cells it covers.
        grid.clearBordersRect(
            @floatFromInt(layout.x),
            @floatFromInt(layout.y),
            @floatFromInt(layout.width),
            @floatFromInt(layout.height),
        );

        self.syncInput(picker);
        try self.renderInput(grid, layout);
        self.renderList(picker, grid, layout);

        if (picker.busy and layout.width > 3) {
            grid.putCodepoint(layout.x + layout.width - 2, layout.y, 0x2026, 1, .{
                .fg = ui.cell.packColor(self.colors.dim_foreground),
                .bg = ui.cell.packColor(self.colors.background),
            });
        }
        return layout;
    }

    fn syncInput(self: *QuickPickWidget, picker: *QuickPick) void {
        if (!std.mem.eql(u8, self.input.getValue(), picker.value.items)) {
            self.syncing = true;
            self.input.setValue(picker.value.items) catch {};
            self.syncing = false;
        }
        self.input.placeholder = picker.placeholder;
        self.input.color = self.colors.foreground;
        self.input.placeholder_color = self.colors.dim_foreground;
        self.input.focused = true;
    }

    fn renderInput(
        self: *QuickPickWidget,
        grid: *ui.CellGrid,
        layout: Layout,
    ) !void {
        if (self.input_surface == null or self.input_surface_width != layout.width) {
            if (self.input_surface) |*surface| surface.deinit();
            self.input_surface = try ui.Surface.init(self.allocator, .{
                .cols = layout.width,
                .rows = 1,
            });
            self.input_surface_width = layout.width;
        }

        const surface = &self.input_surface.?;
        const doc = surface.document();
        doc.clear();
        const root = try doc.createElement(.div);
        root.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = 0 },
            .top = .{ .cells = 0 },
            .width = .{ .percent = 100 },
            .height = .{ .cells = 1 },
            .white_space = .pre,
            .overflow = .hidden,
            .background = self.colors.background,
            .color = self.colors.foreground,
        });
        const input_node = try self.input.build(doc, layout.width);
        _ = try root.appendChild(input_node);
        doc.setRoot(root);
        _ = doc.focus(input_node);
        try surface.paintFrame();
        try grid.blit(surface.grid(), layout.x, layout.y, layout.width, 1);
    }

    fn renderList(
        self: *QuickPickWidget,
        picker: *QuickPick,
        grid: *ui.CellGrid,
        layout: Layout,
    ) void {
        if (layout.list_rows == 0) return;

        const top = @min(picker.scroll_top, picker.items.items.len);
        var visible: usize = 0;
        while (visible < layout.list_rows and top + visible < picker.items.items.len) : (visible += 1) {
            const index = top + visible;
            const row = layout.y + 1 + visible;
            const item = picker.items.items[index];
            const is_active = picker.active_index == index;
            const is_hover = self.hover_index == index and !is_active;
            const row_bg = if (is_active)
                self.colors.active_background
            else if (is_hover)
                self.colors.hover_background
            else
                self.colors.background;
            const row_style = ui.cell.PaintStyle{
                .fg = ui.cell.packColor(if (is_active) self.colors.foreground else self.colors.dim_foreground),
                .bg = ui.cell.packColor(row_bg),
            };
            grid.fillRect(
                @floatFromInt(layout.x),
                @floatFromInt(row),
                @floatFromInt(layout.width),
                1,
                row_style,
            );

            switch (item) {
                .separator => |separator| {
                    if (separator.label.len > 0) {
                        _ = drawText(
                            grid,
                            layout.x + 1,
                            row,
                            layout.width -| 2,
                            separator.label,
                            .{ .fg = ui.cell.packColor(self.colors.dim_foreground), .bg = ui.cell.packColor(row_bg) },
                            &.{},
                        );
                    }
                },
                .item => |entry| {
                    const label_style = ui.cell.PaintStyle{
                        .fg = ui.cell.packColor(self.colors.foreground),
                        .bg = ui.cell.packColor(row_bg),
                        .attrs = if (is_active) ui.cell.Attr.bold else 0,
                    };
                    const label_range = layout.width -| 2;
                    const label_width = drawText(
                        grid,
                        layout.x + 1,
                        row,
                        label_range,
                        entry.label,
                        label_style,
                        entry.highlights.label,
                    );
                    if (entry.description.len > 0 and label_width < label_range) {
                        _ = drawText(
                            grid,
                            layout.x + 1 + label_width + 1,
                            row,
                            label_range -| (label_width + 1),
                            entry.description,
                            .{ .fg = ui.cell.packColor(self.colors.dim_foreground), .bg = ui.cell.packColor(row_bg) },
                            entry.highlights.description,
                        );
                    }
                },
            }
        }
    }

    /// Handles one key. Returns true when the picker consumed it.
    pub fn handleKey(self: *QuickPickWidget, picker: *QuickPick, event: *ui.KeyEvent) bool {
        self.active_picker = picker;
        self.syncInput(picker);
        switch (event.key) {
            .escape => {
                picker.hide();
                return true;
            },
            .enter => {
                picker.accept();
                return true;
            },
            .up => {
                picker.focusPrevious();
                return true;
            },
            .down => {
                picker.focusNext();
                return true;
            },
            .page_up => {
                picker.focusPreviousPage();
                return true;
            },
            .page_down => {
                picker.focusNextPage();
                return true;
            },
            .home => {
                if (event.mods.ctrl) {
                    picker.focusFirst();
                    return true;
                }
            },
            .end => {
                if (event.mods.ctrl) {
                    picker.focusLast();
                    return true;
                }
            },
            .char => |ch| {
                // Upstream binds select-next/select-previous in quick open to
                // Ctrl+N/Ctrl+P on macOS (`KeyMod.WinCtrl`). A terminal only
                // delivers Ctrl, so these are the reachable variants of
                // `workbench.action.quickOpenSelectNext`/`SelectPrevious`.
                // They must run before the input box, which consumes every
                // Ctrl chord without moving the list.
                if (event.mods.ctrl and !event.mods.alt) {
                    switch (ch) {
                        'n', 'N' => {
                            picker.focusNext();
                            return true;
                        },
                        'p', 'P' => {
                            picker.focusPrevious();
                            return true;
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }

        return self.input.handleKey(event);
    }

    /// Handles one absolute workbench mouse event while the picker is open.
    pub fn handleMouse(
        self: *QuickPickWidget,
        picker: *QuickPick,
        event: *ui.MouseEvent,
    ) bool {
        self.active_picker = picker;
        const x = event.x -| self.layout.x;
        const y = event.y -| self.layout.y;

        if (event.y >= self.layout.y + self.layout.height) return true;

        if (y == 0) {
            self.syncInput(picker);
            if (self.input_surface) |*surface| {
                const doc = surface.document();
                const target = (surface.elementFromPoint(x, 0) catch null) orelse doc.root orelse return true;
                var local = event.*;
                local.x = x;
                local.y = 0;
                doc.dispatchMouse(target, &local);
            }
            return true;
        }

        const row = y - 1;
        if (row >= self.layout.list_rows) return true;
        const index = self.layoutIndex(picker, row);
        if (event.kind == .move) {
            self.hover_index = index;
            return true;
        }
        if (event.kind == .click or event.kind == .down) {
            if (index) |value| {
                switch (picker.items.items[value]) {
                    .item => {
                        picker.setActiveIndex(value);
                        picker.accept();
                    },
                    .separator => {},
                }
            }
            return true;
        }
        if (event.kind == .wheel) {
            const max_scroll = picker.items.items.len -| self.layout.list_rows;
            if (event.delta_y > 0) {
                picker.scroll_top = @min(max_scroll, picker.scroll_top + 3);
            } else if (event.delta_y < 0) {
                picker.scroll_top = picker.scroll_top -| 3;
            }
            return true;
        }
        return true;
    }

    fn layoutIndex(self: *const QuickPickWidget, picker: *const QuickPick, row: usize) ?usize {
        _ = self;
        const index = picker.scroll_top + row;
        if (index >= picker.items.items.len) return null;
        return index;
    }

    /// The pointer shape at a screen cell: the input row is text, item rows are
    /// clickable, separators and the area outside the picker are not.
    pub fn pointerAt(self: *const QuickPickWidget, picker: *const QuickPick, x: usize, y: usize) ui.Pointer {
        const layout = self.layout;
        if (x < layout.x or x >= layout.x + layout.width or
            y < layout.y or y >= layout.y + layout.height)
        {
            return .default;
        }
        if (y == layout.y) return .text;
        const row = y - layout.y - 1;
        const index = self.layoutIndex(picker, row) orelse return .default;
        return switch (picker.items.items[index]) {
            .item => .pointer,
            .separator => .default,
        };
    }

    pub fn setHover(self: *QuickPickWidget, index: ?usize) void {
        self.hover_index = index;
    }

    fn pickerChanged(self: *QuickPickWidget, value: []const u8) void {
        const picker = self.active_picker orelse return;
        picker.setValue(value) catch {};
    }
};

fn onInputChanged(context: ?*anyopaque, value: []const u8) void {
    const self: *QuickPickWidget = @ptrCast(@alignCast(context orelse return));
    if (self.syncing) return;
    self.pickerChanged(value);
}

fn drawText(
    grid: *ui.CellGrid,
    x: usize,
    y: usize,
    max_width: usize,
    text: []const u8,
    style: ui.cell.PaintStyle,
    matches: []const @import("../../../base/common/filters.zig").Match,
) usize {
    var col = x;
    var offset: usize = 0;
    while (offset < text.len and col < x + max_width) {
        const decoded = ui.dom.decodeAt(text, offset);
        if (decoded.len == 0) break;
        const width = ui.dom.defaultMeasureWidth(decoded.cp);
        if (col + width > x + max_width) break;
        var paint = style;
        if (isMatched(matches, offset)) paint.attrs |= ui.cell.Attr.bold;
        grid.putCodepoint(col, y, decoded.cp, width, paint);
        col += width;
        offset += decoded.len;
    }
    return col - x;
}

fn isMatched(matches: []const @import("../../../base/common/filters.zig").Match, offset: usize) bool {
    for (matches) |match| {
        if (offset >= match.start and offset < match.end) return true;
    }
    return false;
}

test "QuickPickWidget: focused empty input shows a caret with its placeholder" {
    const allocator = std.testing.allocator;
    var picker = QuickPick.init(allocator);
    defer picker.deinit();
    picker.setPlaceholder("Type a file");

    const widget = try QuickPickWidget.init(allocator);
    defer widget.deinit();

    var frame = try ui.Frame.init(allocator, 40, 10);
    defer frame.deinit();
    frame.begin();
    const layout = try widget.render(&picker, &frame.next);
    try std.testing.expectEqual(@as(usize, 1), layout.height);

    const row = try frame.next.rowText(allocator, layout.y);
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "Type a file") != null);
    const grid = frame.next;
    try std.testing.expectEqual(@as(u21, '│'), grid.cluster[grid.index(layout.x, layout.y)]);
    try std.testing.expectEqual(
        @as(u16, 0),
        grid.attrs[grid.index(layout.x + 1, layout.y)] & ui.cell.Attr.inverse,
    );
}

test "QuickPickWidget: renders input, items, separators and active row" {
    const allocator = std.testing.allocator;
    var picker = QuickPick.init(allocator);
    defer picker.deinit();

    try picker.setItems(&.{
        .{ .separator = .{ .label = "file results" } },
        .{ .item = .{ .id = "a", .label = "alpha.txt", .description = "src" } },
        .{ .item = .{ .id = "b", .label = "beta.txt", .description = "src" } },
    });
    try picker.setValue("a");

    const widget = try QuickPickWidget.init(allocator);
    defer widget.deinit();

    var frame = try ui.Frame.init(allocator, 40, 10);
    defer frame.deinit();
    frame.begin();
    const layout = try widget.render(&picker, &frame.next);
    try std.testing.expectEqual(@as(usize, 4), layout.height);

    const row = try frame.next.rowText(allocator, 1);
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "file results") != null);

    const active_row = try frame.next.rowText(allocator, 2);
    defer allocator.free(active_row);
    try std.testing.expect(std.mem.indexOf(u8, active_row, "alpha.txt") != null);

    // The input row is text, separators are not clickable, item rows are.
    try std.testing.expectEqual(ui.Pointer.text, widget.pointerAt(&picker, layout.x + 1, layout.y));
    try std.testing.expectEqual(ui.Pointer.default, widget.pointerAt(&picker, layout.x + 1, layout.y + 1));
    try std.testing.expectEqual(ui.Pointer.pointer, widget.pointerAt(&picker, layout.x + 1, layout.y + 2));
    try std.testing.expectEqual(ui.Pointer.default, widget.pointerAt(&picker, 0, 0));
}
