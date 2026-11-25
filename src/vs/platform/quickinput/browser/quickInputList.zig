// Terminal quick-pick widget: the TUI view for
// `src/vs/platform/quickinput/browser/quickInput.ts` +
// `quickInputList.ts`.
//
// The input row is a real `ui.InputBox` rendered into a one-row `ui.Surface`;
// the cell list mirrors the upstream inline separators, action bar and
// keybinding labels. Native cell borders or box-drawing glyphs frame it.
//
// The picker is an overlay of the workbench, not an editor overlay: it is
// blitted after every pane and the tab strip.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const theme_colors_mod = @import("../../../workbench/browser/themeColors.zig");
const QuickPick = @import("./quickInput.zig").QuickPick;

const model = @import("../common/quickInput.zig");
pub const ItemAction = model.ItemAction;
const ScrollbarState = @import("../../../base/browser/ui/scrollbar/scrollbarState.zig").ScrollbarState;
const clock = @import("../../../base/common/timeCompat.zig");
const busy_delay_ms = 800;
const progress_frame_ms = 50;
const scrollbar_hide_ms = 500;
const file_icons = @import("../../../workbench/services/themes/browser/fileIconThemeData.zig");

const base_background = ui.Color{ .r = 31, .g = 31, .b = 31 };
const base_foreground = ui.Color{ .r = 230, .g = 230, .b = 230 };
const base_dim_foreground = ui.Color{ .r = 145, .g = 145, .b = 158 };
const base_active_background = ui.Color{ .r = 4, .g = 57, .b = 94 };
const base_hover_background = ui.Color{ .r = 52, .g = 58, .b = 74 };

pub const Layout = struct {
    x: usize = 0,
    y: usize = 0,
    width: usize = 0,
    height: usize = 0,
    list_rows: usize = 0,
    inset: usize = 0,

    fn content(self: Layout) Layout {
        return .{ .x = self.x + self.inset, .y = self.y + self.inset, .width = self.width - 2 * self.inset, .height = self.height - 2 * self.inset, .list_rows = self.list_rows };
    }
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
    caps: ui.cell_border.Capabilities = .{},
    open_to_bottom: bool = false,
    focused_action: ?usize = null,
    progress_frame: ?usize = null,
    scrollbar: ?ScrollbarState = null,
    scrollbar_visible: bool = false,
    scrollbar_hide_at: i64 = 0,
    over_list: bool = false,
    over_thumb: bool = false,
    drag: ?struct { state: ScrollbarState, start_y: usize } = null,
    action_context: ?*anyopaque = null,
    on_action: ?*const fn (*anyopaque, *QuickPick, usize, model.ItemAction) void = null,
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

        const inset: usize = if (width >= 3 and rows >= 3) 1 else 0;
        const list_rows: usize = @min(picker.rows.items.len, 15, rows -| (1 + 2 * inset));
        const height = @min(rows, 1 + list_rows + 2 * inset);
        self.layout = .{
            .inset = inset,
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
        return self.renderAt(picker, grid, clock.milliTimestamp());
    }

    fn renderAt(self: *QuickPickWidget, picker: *QuickPick, grid: *ui.CellGrid, now: i64) !Layout {
        self.active_picker = picker;
        self.colors = self.resolveColors();
        const layout = self.computeLayout(picker, grid.cols, grid.rows);
        if (layout.width == 0 or layout.height == 0) return layout;

        // The picker is an overlay: it must not inherit a split divider's cell
        // border on cells it covers.
        const rect = ui.Rect{ .x = @floatFromInt(layout.x), .y = @floatFromInt(layout.y), .w = @floatFromInt(layout.width), .h = @floatFromInt(layout.height) };
        const native = if (layout.inset != 0 and self.caps.has(.round)) ui.cell.RoundedCellFrame.capture(grid, rect) else null;
        grid.clearBordersRect(rect.x, rect.y, rect.w, rect.h);
        const border = self.themeColor("widget.border", .{ .r = 69, .g = 69, .b = 69 });
        grid.fillRect(rect.x, rect.y, rect.w, rect.h, .{ .bg = ui.cell.packColor(self.colors.background) });
        if (native) |frame| {
            frame.paint(grid, self.caps, .{ .rgb = border });
        } else if (layout.inset != 0) {
            grid.paintRoundedFrame(rect, .{ .fg = ui.cell.packColor(border), .bg = ui.cell.packColor(self.colors.background) });
        }

        const inner = layout.content();
        self.syncInput(picker);
        try self.renderInput(grid, inner);
        if (self.caps.has(.round)) {
            const input_rect = ui.Rect{ .x = @floatFromInt(inner.x), .y = @floatFromInt(inner.y), .w = @floatFromInt(inner.width), .h = 1 };
            if (ui.cell.RoundedCellFrame.capture(grid, input_rect)) |frame| frame.paint(grid, self.caps, .{ .rgb = self.themeColor("focusBorder", .{ .r = 0, .g = 122, .b = 204 }) });
        }
        self.renderList(picker, grid, inner);
        self.renderScrollbar(grid, picker, inner, now);
        self.progress_frame = progressFrame(picker, now);
        if (self.progress_frame) |step| self.paintProgress(grid, inner, step);
        return layout;
    }

    // quickInput.ts delays ProgressBar.infinite() for 800 ms. Quantize the
    // four-second CSS animation to cells along the bottom of the input.
    fn progressFrame(picker: *const QuickPick, now: i64) ?usize {
        if (!picker.busy) return null;
        const elapsed = now - picker.busy_since_ms - busy_delay_ms;
        if (elapsed < 0) return null;
        return @intCast(@divTrunc(@mod(elapsed, 4000), progress_frame_ms));
    }

    fn paintProgress(self: *QuickPickWidget, grid: *ui.CellGrid, inner: Layout, step: usize) void {
        const frames = 4000 / progress_frame_ms;
        const bit = @max(1, inner.width / 50);
        const width = @min(inner.width, bit + 4 * bit * @min(step, frames - step) / frames);
        const start = inner.x + (inner.width - width) * step / (frames - 1);
        const color = self.themeColor("progressBar.background", .{ .r = 14, .g = 112, .b = 192 });
        for (start..start + width) |col| {
            if (self.caps.has(.pen)) {
                grid.addBorder(col, inner.y, ui.cell_border.Segment.bottom, .{ .width = 48, .color = .{ .rgb = color }, .placement = .inside, .priority = 3 });
            } else {
                const i = grid.index(col, inner.y);
                grid.attrs[i] |= ui.cell.Attr.underline;
                grid.fg[i] = ui.cell.packColor(color);
            }
        }
    }

    pub fn needsAnimationFrame(self: *const QuickPickWidget, picker: *const QuickPick, now: i64) bool {
        return self.progress_frame != progressFrame(picker, now) or self.scrollbar_visible != self.showScrollbar(now);
    }

    pub fn animationTimeout(self: *const QuickPickWidget, picker: *const QuickPick, now: i64, maximum: i32) i32 {
        var timeout: i64 = maximum;
        if (picker.busy) {
            const elapsed = now - picker.busy_since_ms - busy_delay_ms;
            timeout = @min(timeout, if (elapsed < 0) -elapsed else progress_frame_ms - @mod(elapsed, progress_frame_ms));
        }
        if (self.scrollbar_visible and !self.over_list and self.drag == null)
            timeout = @min(timeout, @max(0, self.scrollbar_hide_at - now));
        return @intCast(timeout);
    }

    fn showScrollbar(self: *const QuickPickWidget, now: i64) bool {
        return self.scrollbar != null and (self.over_list or self.drag != null or now < self.scrollbar_hide_at);
    }

    fn renderScrollbar(self: *QuickPickWidget, grid: *ui.CellGrid, picker: *QuickPick, inner: Layout, now: i64) void {
        const state = ScrollbarState.initWithMinimumSliderSize(0, 1, 0, @floatFromInt(inner.list_rows), @floatFromInt(picker.rows.items.len), @floatFromInt(picker.scroll_top), 1);
        if (inner.width < 2 or inner.list_rows == 0 or !state.isNeeded()) {
            self.scrollbar = null;
            self.scrollbar_visible = false;
            self.drag = null;
            return;
        }
        if (self.scrollbar == null or self.scrollbar.?._visibleSize != state._visibleSize or
            self.scrollbar.?._scrollSize != state._scrollSize or self.scrollbar.?.getScrollPosition() != state.getScrollPosition())
            self.scrollbar_hide_at = now + scrollbar_hide_ms;
        self.scrollbar = state;
        self.scrollbar_visible = self.showScrollbar(now);
        if (!self.scrollbar_visible) return;
        const color = if (self.drag != null)
            self.themeColor("scrollbarSlider.activeBackground", .{ .r = 165, .g = 165, .b = 165 })
        else if (self.over_thumb)
            self.themeColor("scrollbarSlider.hoverBackground", .{ .r = 130, .g = 130, .b = 130 })
        else
            self.themeColor("scrollbarSlider.background", .{ .r = 90, .g = 90, .b = 90 });
        grid.fillRect(@floatFromInt(inner.x + inner.width - 1), @as(f64, @floatFromInt(inner.y + 1)) + state.getSliderPosition(), 1, state.getSliderSize(), .{ .bg = ui.cell.packColor(color) });
    }

    pub fn resetInteraction(self: *QuickPickWidget) void {
        self.leaveList();
        self.drag = null;
        self.scrollbar = null;
        self.scrollbar_visible = false;
        self.focused_action = null;
        self.progress_frame = null;
    }

    pub fn leaveList(self: *QuickPickWidget) void {
        self.over_list = false;
        self.over_thumb = false;
        self.hover_index = null;
        self.scrollbar_hide_at = 0;
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
        self.input.focused = self.focused_action == null;
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
            .background = self.themeColor("input.background", self.colors.background),
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

        const top = @min(picker.scroll_top, picker.rows.items.len - layout.list_rows);
        picker.scroll_top = top;
        for (picker.rows.items[top..][0..layout.list_rows], 0..) |index, visible| {
            const row = layout.y + 1 + visible;
            const entry = picker.items.items[index].item;
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

            var right = layout.x + layout.width - 1;
            var left = @min(layout.x + 1, right);
            const buttons = actionCount(entry, is_active or is_hover, layout.width);
            right -= buttons * 3;
            for (entry.actions[0..buttons], 0..) |action, i| {
                const glyph: u21 = switch (action) {
                    .open_side => if (self.open_to_bottom) '⊟' else '◫',
                    .configure_keybinding => '⚙',
                    .remove_history => '×',
                };
                var button_style = row_style;
                if (is_active and self.focused_action == i) button_style.attrs |= ui.cell.Attr.inverse;
                grid.putCodepoint(right + i * 3 + 1, row, glyph, 1, button_style);
            }

            const detail_style = ui.cell.PaintStyle{ .fg = ui.cell.packColor(if (is_active) self.colors.foreground else self.colors.dim_foreground), .bg = row_style.bg };
            if (index > 0 and picker.items.items[index - 1] == .separator) {
                if (index != picker.rows.items[0] and self.caps.has(.pen)) {
                    const stroke = ui.cell_border.Stroke{ .color = .{ .rgb = self.themeColor("pickerGroup.border", self.colors.dim_foreground) }, .width = 16, .placement = .inside };
                    for (layout.x..layout.x + layout.width) |col| grid.addBorder(col, row, ui.cell_border.Segment.top, stroke);
                }
                const group = picker.items.items[index - 1].separator.label;
                const width = textWidth(group);
                if (width + 2 < right - left) {
                    right -= width;
                    _ = drawText(grid, right, row, width, group, detail_style, &.{});
                    right -= 1;
                }
            }
            var keys_width: usize = 0;
            for (entry.keycaps) |key| keys_width += textWidth(key) + 3;
            if (keys_width < right - left) {
                right -= keys_width;
                var x = right + 1;
                const key_style = ui.cell.PaintStyle{
                    .fg = ui.cell.packColor(self.themeColor("keybindingLabel.foreground", self.colors.foreground)),
                    .bg = ui.cell.packColor(self.themeColor("keybindingLabel.background", .{ .r = 55, .g = 55, .b = 55 })),
                };
                for (entry.keycaps) |key| {
                    const width = textWidth(key);
                    grid.fillRect(@floatFromInt(x), @floatFromInt(row), @floatFromInt(width + 2), 1, key_style);
                    _ = drawText(grid, x + 1, row, width, key, key_style, &.{});
                    x += width + 3;
                }
            }
            if (entry.file_icon and right - left > 2) {
                const icon = file_icons.file(entry.label);
                grid.putCodepoint(left, row, icon.glyph, 1, .{ .fg = ui.cell.packColor(icon.color), .bg = row_style.bg });
                left += 2;
            }
            left += drawText(grid, left, row, right - left, entry.label, .{ .fg = ui.cell.packColor(self.colors.foreground), .bg = row_style.bg }, entry.highlights.label);
            if (left < right) _ = drawText(grid, left + 1, row, right - left - 1, entry.description, detail_style, entry.highlights.description);
        }
    }

    fn actionCount(entry: model.Item, show: bool, width: usize) usize {
        return if (show) @min(entry.actions.len, (width -| 3) / 3) else 0;
    }

    fn themeColor(self: *QuickPickWidget, id: []const u8, fallback: ui.Color) ui.Color {
        return if (self.theme) |palette| palette.colorOr(id, fallback) else fallback;
    }

    /// Handles one key. Returns true when the picker consumed it.
    pub fn handleKey(self: *QuickPickWidget, picker: *QuickPick, event: *ui.KeyEvent) bool {
        self.active_picker = picker;
        self.syncInput(picker);
        if (event.key == .tab) {
            const entry = picker.activeItem() orelse return true;
            const count = actionCount(entry.*, true, self.layout.content().width);
            if (count == 0) return true;
            self.focused_action = if (self.focused_action) |i| blk: {
                if (event.mods.shift) break :blk if (i == 0) null else i - 1;
                break :blk if (i + 1 >= count) null else i + 1;
            } else if (event.mods.shift) count - 1 else 0;
            return true;
        }
        const focused = self.focused_action;
        self.focused_action = null;
        switch (event.key) {
            .escape => {
                picker.hide();
                return true;
            },
            .enter => {
                if (focused) |i| {
                    const entry = picker.activeItem() orelse return true;
                    if (i < entry.actions.len) {
                        if (self.on_action) |callback| callback(self.action_context.?, picker, picker.active_index.?, entry.actions[i]);
                    }
                    return true;
                }
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
        const inner = self.layout.content();
        if (self.drag) |drag| {
            if (event.kind == .move or event.kind == .up) {
                const delta = @as(f64, @floatFromInt(event.y)) - @as(f64, @floatFromInt(drag.start_y));
                const desired = drag.state.getDesiredScrollPositionFromDelta(delta);
                picker.scroll_top = @min(picker.rows.items.len -| inner.list_rows, ui.cell.snap(@max(0, desired)));
                if (event.kind == .up) self.drag = null;
                self.over_list = event.x >= inner.x and event.x < inner.x + inner.width and event.y > inner.y and event.y < inner.y + inner.height;
                return true;
            }
        }
        if (event.x < inner.x or event.x >= inner.x + inner.width or event.y < inner.y or event.y >= inner.y + inner.height) {
            self.leaveList();
            return true;
        }
        const x = event.x - inner.x;
        const y = event.y - inner.y;
        if (y == 0) {
            self.leaveList();
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
        self.over_list = true;
        self.over_thumb = false;
        if (self.scrollbar) |state| {
            if (x == inner.width - 1 and event.kind != .wheel) {
                const offset: f64 = @floatFromInt(row);
                self.over_thumb = offset >= state.getSliderPosition() and offset < state.getSliderPosition() + state.getSliderSize();
                self.hover_index = null;
                if ((event.kind == .down or event.kind == .click) and event.button == .left) {
                    var initial = state;
                    if (!self.over_thumb) {
                        const desired = state.getDesiredScrollPositionFromOffset(offset);
                        picker.scroll_top = @min(picker.rows.items.len -| inner.list_rows, ui.cell.snap(@max(0, desired)));
                        _ = initial.setScrollPosition(@floatFromInt(picker.scroll_top));
                    }
                    if (event.kind == .down) self.drag = .{ .state = initial, .start_y = event.y };
                }
                return true;
            }
        }
        const index = self.layoutIndex(picker, row);
        if (event.kind == .move) {
            self.hover_index = index;
            return true;
        }
        if (event.kind == .click or event.kind == .down) {
            if (index) |value| {
                self.focused_action = null;
                switch (picker.items.items[value]) {
                    .item => |entry| {
                        if (event.button != .left) return true;
                        const buttons = actionCount(entry, self.hover_index == value or picker.active_index == value, inner.width);
                        const start = inner.width - 1 - buttons * 3;
                        if (x >= start and x < inner.width - 1) {
                            if (self.on_action) |callback| callback(self.action_context.?, picker, value, entry.actions[(x - start) / 3]);
                            return true;
                        }
                        picker.setActiveIndex(value);
                        picker.accept();
                    },
                    .separator => {},
                }
            }
            return true;
        }
        if (event.kind == .wheel) {
            const max_scroll = picker.rows.items.len -| self.layout.list_rows;
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
        if (index >= picker.rows.items.len) return null;
        return picker.rows.items[index];
    }

    /// The pointer shape at a screen cell: the input row is text, item rows are
    /// clickable, separators and the area outside the picker are not.
    pub fn pointerAt(self: *const QuickPickWidget, picker: *const QuickPick, x: usize, y: usize) ui.Pointer {
        const layout = self.layout.content();
        if (x < layout.x or x >= layout.x + layout.width or
            y < layout.y or y >= layout.y + layout.height)
        {
            return .default;
        }
        if (y == layout.y) return .text;
        if (self.scrollbar != null and x == layout.x + layout.width - 1) return .default;
        const row = y - layout.y - 1;
        const index = self.layoutIndex(picker, row) orelse return .default;
        return switch (picker.items.items[index]) {
            .item => .pointer,
            .separator => .default,
        };
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

test "QuickPickWidget: a full results page leaves room for the input and frame" {
    var picker = QuickPick.init(std.testing.allocator);
    defer picker.deinit();
    const items: [16]model.QuickPickItem = @splat(.{ .item = .{ .label = "file" } });
    try picker.setItems(&items);
    const widget = try QuickPickWidget.init(std.testing.allocator);
    defer widget.deinit();

    for (0..25) |rows| {
        const layout = widget.computeLayout(&picker, 80, rows);
        try std.testing.expectEqual(@min(rows, 18), layout.height);
        try std.testing.expectEqual(@min(rows -| (1 + 2 * layout.inset), 15), layout.list_rows);
    }
}

test "QuickPickWidget: a busy picker keeps the input row clear around the placeholder and caret" {
    const allocator = std.testing.allocator;
    var picker = QuickPick.init(allocator);
    defer picker.deinit();
    picker.setPlaceholder("Type a file");
    picker.setBusy(true);

    const widget = try QuickPickWidget.init(allocator);
    defer widget.deinit();

    var frame = try ui.Frame.init(allocator, 40, 10);
    defer frame.deinit();
    frame.begin();
    const layout = try widget.render(&picker, &frame.next);
    try std.testing.expectEqual(@as(usize, 3), layout.height);

    const row = try frame.next.rowText(allocator, layout.content().y);
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "Type a file") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "…") == null);
    const grid = frame.next;
    try std.testing.expectEqual(@as(u21, '│'), grid.cluster[grid.index(layout.content().x, layout.content().y)]);
    try std.testing.expectEqual(
        @as(u16, 0),
        grid.attrs[grid.index(layout.content().x + 1, layout.content().y)] & ui.cell.Attr.inverse,
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
    try std.testing.expectEqual(@as(usize, 5), layout.height);

    const row = try frame.next.rowText(allocator, 2);
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "file results") != null);

    const name = std.mem.indexOf(u8, row, "alpha.txt") orelse return error.MissingLabel;
    try std.testing.expect(name < std.mem.indexOf(u8, row, "file results").?);
    const grid = frame.next;
    const right = layout.x + layout.width - 1;
    const bottom = layout.y + layout.height - 1;
    try std.testing.expectEqual(@as(u32, '╭'), grid.cluster[grid.index(layout.x, layout.y)]);
    try std.testing.expectEqual(@as(u32, '╮'), grid.cluster[grid.index(right, layout.y)]);
    try std.testing.expectEqual(@as(u32, '╰'), grid.cluster[grid.index(layout.x, bottom)]);
    try std.testing.expectEqual(@as(u32, '╯'), grid.cluster[grid.index(right, bottom)]);
    try std.testing.expectEqual(ui.Pointer.default, widget.pointerAt(&picker, layout.x + 1, layout.y));
    try std.testing.expectEqual(ui.Pointer.text, widget.pointerAt(&picker, layout.x + 1, layout.y + 1));
    try std.testing.expectEqual(ui.Pointer.pointer, widget.pointerAt(&picker, layout.x + 1, layout.y + 2));
    try std.testing.expectEqual(ui.Pointer.default, widget.pointerAt(&picker, 0, 0));

    widget.caps = ui.cell_border.parseReply("\x1bP1+bcell-border;ok;1;pen,rect,round,outside,radius\x1b\\").?;
    frame.begin();
    _ = try widget.render(&picker, &frame.next);
    const joint = ui.cell_border.Joint;
    try std.testing.expect(frame.next.borderSetAt(layout.x, layout.y).joints & joint.top_left != 0);
    try std.testing.expect(frame.next.borderSetAt(right, layout.y).joints & joint.top_right != 0);
    try std.testing.expect(frame.next.borderSetAt(layout.x, bottom).joints & joint.bottom_left != 0);
    try std.testing.expect(frame.next.borderSetAt(right, bottom).joints & joint.bottom_right != 0);
}

test "QuickPickWidget: progress starts at 800 ms, advances and clears on completion" {
    const allocator = std.testing.allocator;
    const widget = try QuickPickWidget.init(allocator);
    defer widget.deinit();
    var picker = QuickPick.init(allocator);
    defer picker.deinit();
    var frame = try ui.Frame.init(allocator, 80, 20);
    defer frame.deinit();

    picker.setBusy(true);
    const start = picker.busy_since_ms;
    frame.begin();
    const inner = (try widget.renderAt(&picker, &frame.next, start + 799)).content();
    const first = frame.next.index(inner.x, inner.y);
    try std.testing.expectEqual(@as(?usize, null), widget.progress_frame);
    try std.testing.expectEqual(@as(i32, 1), widget.animationTimeout(&picker, start + 799, 250));
    try std.testing.expect(widget.needsAnimationFrame(&picker, start + 800));
    _ = try widget.renderAt(&picker, &frame.next, start + 800);
    try std.testing.expect(frame.next.attrs[first] & ui.cell.Attr.underline != 0);
    _ = try widget.renderAt(&picker, &frame.next, start + 2800);
    try std.testing.expect(frame.next.attrs[first] & ui.cell.Attr.underline == 0);
    const middle = frame.next.index(inner.x + inner.width / 2, inner.y);
    try std.testing.expect(frame.next.attrs[middle] & ui.cell.Attr.underline != 0);
    picker.setBusy(false);
    _ = try widget.renderAt(&picker, &frame.next, start + 2801);
    try std.testing.expect(frame.next.attrs[middle] & ui.cell.Attr.underline == 0);
    try std.testing.expect(!widget.needsAnimationFrame(&picker, start + 4000));
}

test "QuickPickWidget: overflow scrollbar reveals on hover, pages by track and drags past the list" {
    const allocator = std.testing.allocator;
    const widget = try QuickPickWidget.init(allocator);
    defer widget.deinit();
    var picker = QuickPick.init(allocator);
    defer picker.deinit();
    const items: [60]model.QuickPickItem = @splat(.{ .item = .{ .label = "file" } });
    try picker.setItems(&items);
    picker.show();
    var frame = try ui.Frame.init(allocator, 80, 26);
    defer frame.deinit();
    frame.begin();
    const inner = (try widget.renderAt(&picker, &frame.next, 0)).content();
    const x = inner.x + inner.width - 1;
    const y = inner.y + 1;
    const i = frame.next.index(x, y);
    const thumb_color = frame.next.bg[i];
    try std.testing.expect(widget.scrollbar_visible);
    _ = try widget.renderAt(&picker, &frame.next, 500);
    try std.testing.expect(!widget.scrollbar_visible);
    try std.testing.expect(thumb_color != frame.next.bg[i]);
    var event = ui.MouseEvent{ .kind = .move, .x = x, .y = y };
    _ = widget.handleMouse(&picker, &event);
    _ = try widget.renderAt(&picker, &frame.next, 900);
    try std.testing.expect(widget.scrollbar_visible);
    try std.testing.expect(widget.over_thumb);
    try std.testing.expect(frame.next.bg[i] != thumb_color);
    event.kind = .down;
    event.button = .left;
    _ = widget.handleMouse(&picker, &event);
    event.kind = .move;
    event.x = 0;
    event.y = inner.y + inner.height + 4;
    _ = widget.handleMouse(&picker, &event);
    try std.testing.expectEqual(items.len - inner.list_rows, picker.scroll_top);
    event.kind = .up;
    _ = widget.handleMouse(&picker, &event);
    try std.testing.expect(widget.drag == null);
    _ = try widget.renderAt(&picker, &frame.next, 1000);
    event = .{ .kind = .click, .x = x, .y = y, .button = .left };
    _ = widget.handleMouse(&picker, &event);
    try std.testing.expectEqual(@as(usize, 0), picker.scroll_top);
    try std.testing.expect(picker.visible);
    try std.testing.expect(picker.selected_index == null);
    try picker.setItems(items[0..2]);
    _ = try widget.renderAt(&picker, &frame.next, 1100);
    try std.testing.expect(widget.scrollbar == null);
}
