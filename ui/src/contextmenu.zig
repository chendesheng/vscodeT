//! Native-style terminal context menu.
//!
//! Terminal adaptation of VS Code's native context-menu API in
//! `src/vs/base/parts/contextmenu/common/contextmenu.ts` and the
//! `NativeContextMenuService` popup path:
//!
//! - `Item` mirrors `IContextMenuItem` (`label`, `type`, `accelerator`,
//!   `enabled`, `visible`, `checked`, `click`, `submenu`).
//! - `Event` mirrors `IContextMenuEvent` with Zig snake_case fields.
//! - `Options` keeps `x`, `y` and `positioning_item` from `IPopupOptions`.
//! - `popup(items, options, on_hide)` mirrors the native `popup` helper.
//!
//! There is no OS menu window here. Unlike the browser `Menu` widget, this
//! context menu is **not part of the DOM** and does not take part in
//! `Document` focus or event listeners. It paints into a host `CellGrid` like
//! `Dialog` and the host routes key/mouse events to it while it is open.
//!
//! JavaScript closures have no direct Zig equivalent, so `click` and `on_hide`
//! carry an explicit `context` pointer with the callback. The returned
//! `*ContextMenu` handle is also a terminal necessity: the host must render it
//! and feed it input because there is no native menu window.
//!
//! Browser/OS-only behavior is omitted: no shadows or animations, no OS
//! accessibility, no mnemonic/type-ahead handling, no submenu delay timer, and
//! accelerators are display-only. Checked items are rendered but never toggled
//! automatically.

const std = @import("std");
const cell = @import("cell.zig");
const cell_border = @import("cell_border.zig");
const dom = @import("dom.zig");
const event = @import("event.zig");
const style = @import("style.zig");

const Allocator = std.mem.Allocator;
const CellGrid = cell.CellGrid;
const PaintStyle = cell.PaintStyle;

/// The native `type` field of `IContextMenuItem`.
pub const ItemType = enum { normal, separator, submenu, checkbox, radio };

/// The native `IContextMenuEvent` modifier payload.
pub const Event = struct {
    shift_key: bool = false,
    ctrl_key: bool = false,
    alt_key: bool = false,
    /// Terminal input does not report Command; present for native parity.
    meta_key: bool = false,
};

/// Zig stand-in for a JavaScript click closure.
pub const ClickHandler = struct {
    context: ?*anyopaque = null,
    callback: *const fn (context: ?*anyopaque, event: Event) void,
};

/// The native `IContextMenuItem` shape.
pub const Item = struct {
    label: []const u8 = "",
    type: ItemType = .normal,
    accelerator: []const u8 = "",
    enabled: bool = true,
    visible: bool = true,
    checked: bool = false,
    click: ?ClickHandler = null,
    submenu: []const Item = &.{},
};

/// Zig stand-in for the native `onHide` closure.
pub const OnHide = struct {
    context: ?*anyopaque = null,
    callback: *const fn (context: ?*anyopaque) void,
};

pub const Theme = struct {
    background: style.Color = .{ .r = 37, .g = 37, .b = 38 },
    border: style.Color = .{ .r = 69, .g = 69, .b = 69 },
    foreground: style.Color = .{ .r = 204, .g = 204, .b = 204 },
    disabled: style.Color = .{ .r = 138, .g = 138, .b = 138 },
    separator: style.Color = .{ .r = 69, .g = 69, .b = 69 },
    accelerator: style.Color = .{ .r = 150, .g = 150, .b = 150 },
    selection_background: style.Color = .{ .r = 0, .g = 95, .b = 184 },
    selection_foreground: style.Color = .{ .r = 255, .g = 255, .b = 255 },
};

/// `IPopupOptions` plus terminal sizing/theming.
pub const Options = struct {
    /// `IPopupOptions.x`; null anchors at 0 because the terminal has no cursor
    /// position service.
    x: ?usize = null,
    /// `IPopupOptions.y`; null anchors at 0.
    y: ?usize = null,
    /// `IPopupOptions.positioningItem`, indexing the cleaned root rows.
    positioning_item: ?usize = null,
    min_width: usize = 20,
    max_width: usize = 60,
    theme: Theme = .{},
};

pub const Action = enum { none, closed };

const border_cells: usize = 1;
const left_padding: usize = 1;
const check_width: usize = 1;
const check_gap: usize = 1;
const label_offset: usize = left_padding + check_width + check_gap;
const right_padding: usize = 1;
const check_glyph: u21 = 0x2713; // ✓
const radio_glyph: u21 = 0x25CF; // ●
const submenu_glyph: u21 = 0x203A; // ›
const ellipsis: u21 = 0x2026;

const LayoutRect = struct {
    x: usize = 0,
    y: usize = 0,
    width: usize = 0,
    height: usize = 0,

    fn contains(self: LayoutRect, x: usize, y: usize) bool {
        return x >= self.x and x < self.x + self.width and
            y >= self.y and y < self.y + self.height;
    }
};

const Level = struct {
    items: []const Item,
    owner_index: ?usize = null,
    focused: ?usize = null,
    scroll_top: usize = 0,
    visible: usize = 0,
    inner_width: usize = 0,
    /// Keep the focused row in the window on the next layout. Wheel scrolling
    /// clears it so the window can move while the selection stays off-screen.
    reveal_focus: bool = true,
    rect: LayoutRect = .{},
};

const Press = union(enum) {
    none,
    outside,
    item: struct { level: usize, index: usize },
};

pub const ContextMenu = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    items: []const Item = &.{},
    options: Options,
    on_hide: ?OnHide = null,
    levels: std.ArrayListUnmanaged(Level) = .empty,
    open: bool = false,
    viewport_cols: usize = 0,
    viewport_rows: usize = 0,
    pressed: Press = .none,

    pub fn deinit(self: *ContextMenu) void {
        self.levels.deinit(self.allocator);
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    /// Paints the menu into a host grid. The caller composites this after its
    /// normal UI paint and before ANSI encoding.
    pub fn render(self: *ContextMenu, grid: *CellGrid) void {
        self.renderWithBorderCapabilities(grid, .{});
    }

    pub fn renderWithBorderCapabilities(
        self: *ContextMenu,
        grid: *CellGrid,
        caps: cell_border.Capabilities,
    ) void {
        if (!self.open or self.levels.items.len == 0) return;
        self.layout(grid.cols, grid.rows);
        for (self.levels.items) |*level| self.paintLevel(grid, level, caps);
    }

    /// Consumes one key while the menu is open. Returns `.closed` only when the
    /// root menu was dismissed; submenu collapses return `.none`.
    pub fn handleKey(self: *ContextMenu, key_event: *const event.KeyEvent) Action {
        if (!self.open) return .none;
        const deepest = self.levels.items.len - 1;
        const mods = eventFromMods(key_event.mods);

        switch (key_event.key) {
            .up => _ = self.moveFocus(deepest, false),
            .down => _ = self.moveFocus(deepest, true),
            .home => _ = self.focusEdge(deepest, false),
            .end => _ = self.focusEdge(deepest, true),
            .page_up => self.pageFocus(deepest, false),
            .page_down => self.pageFocus(deepest, true),
            .left => {
                if (deepest > 0) {
                    self.truncateLevels(deepest);
                    self.relayout();
                }
            },
            .right => {
                const level = &self.levels.items[deepest];
                if (level.focused) |index| _ = self.openSubmenu(deepest, index, true);
            },
            .enter => return self.activateFocused(deepest, mods),
            .char => |ch| {
                if (ch == ' ') return self.activateFocused(deepest, mods);
            },
            .text => |text| {
                if (std.mem.eql(u8, text, " ")) return self.activateFocused(deepest, mods);
            },
            .escape => {
                if (deepest > 0) {
                    self.truncateLevels(deepest);
                    self.relayout();
                } else {
                    self.close();
                    return .closed;
                }
            },
            else => {},
        }
        return .none;
    }

    /// Consumes one mouse event while the menu is open. The host must not
    /// forward the event to the UI underneath.
    pub fn handleMouse(self: *ContextMenu, mouse_event: *const event.MouseEvent) Action {
        if (!self.open) return .none;
        const mods = eventFromMods(mouse_event.mods);

        switch (mouse_event.kind) {
            .down => {
                if (self.hitItem(mouse_event.x, mouse_event.y)) |hit| {
                    if (self.isFocusable(hit.level, hit.index)) {
                        self.setFocus(hit.level, hit.index);
                        self.pressed = .{ .item = .{ .level = hit.level, .index = hit.index } };
                    } else {
                        self.pressed = .none;
                    }
                } else {
                    self.pressed = .outside;
                }
                return .none;
            },
            .move => {
                self.hover(mouse_event.x, mouse_event.y);
                return .none;
            },
            .up => return self.mouseRelease(mouse_event.x, mouse_event.y, mods),
            .click => return self.mouseClick(mouse_event.x, mouse_event.y, mods),
            .wheel => {
                self.wheel(mouse_event);
                return .none;
            },
        }
    }

    pub fn pointerAt(self: *ContextMenu, x: usize, y: usize) style.Pointer {
        if (!self.open) return .default;
        if (self.hitItem(x, y)) |hit| {
            if (self.isFocusable(hit.level, hit.index)) return .pointer;
        }
        return .default;
    }

    pub fn focusedItem(self: *const ContextMenu) ?*const Item {
        if (!self.open or self.levels.items.len == 0) return null;
        const level = &self.levels.items[self.levels.items.len - 1];
        const index = level.focused orelse return null;
        if (index >= level.items.len) return null;
        return &level.items[index];
    }

    pub fn isOpen(self: *const ContextMenu) bool {
        return self.open;
    }

    /// Closes the menu and fires `on_hide` once. The caller still owns the
    /// allocation and must call `deinit` when convenient.
    pub fn close(self: *ContextMenu) void {
        if (!self.open) return;
        self.open = false;
        self.pressed = .none;
        self.levels.clearRetainingCapacity();
        if (self.on_hide) |hook| hook.callback(hook.context);
    }

    fn layout(self: *ContextMenu, cols: usize, rows: usize) void {
        self.viewport_cols = cols;
        self.viewport_rows = rows;
        if (cols == 0 or rows == 0 or self.levels.items.len == 0) return;
        if (cols < 1 + 2 * border_cells or rows < 1 + 2 * border_cells) return;

        for (self.levels.items) |*level| self.measureLevel(level, cols, rows);

        const root = &self.levels.items[0];
        var x = self.options.x orelse 0;
        var y = self.options.y orelse 0;
        if (self.options.positioning_item) |index| {
            if (index < root.items.len and root.items.len > 0) {
                const offset = border_cells + index;
                y = y -| offset;
            }
        }
        x = @min(x, cols -| root.rect.width);
        y = @min(y, rows -| root.rect.height);
        root.rect.x = x;
        root.rect.y = y;

        var level_index: usize = 1;
        while (level_index < self.levels.items.len) : (level_index += 1) {
            const parent = &self.levels.items[level_index - 1];
            const child = &self.levels.items[level_index];
            const owner = child.owner_index orelse 0;
            const row = if (owner >= parent.scroll_top and owner < parent.scroll_top + parent.visible)
                owner - parent.scroll_top
            else
                0;

            var child_x = parent.rect.x + parent.rect.width;
            if (child_x + child.rect.width > cols) {
                child_x = if (parent.rect.x >= child.rect.width)
                    parent.rect.x - child.rect.width
                else
                    cols -| child.rect.width;
            }
            var child_y = parent.rect.y + border_cells + row;
            child_x = @min(child_x, cols -| child.rect.width);
            child_y = @min(child_y, rows -| child.rect.height);
            child.rect.x = child_x;
            child.rect.y = child_y;
        }
    }

    fn measureLevel(self: *ContextMenu, level: *Level, cols: usize, rows: usize) void {
        var natural_width: usize = 0;
        for (level.items) |*item| {
            if (item.type == .separator) continue;
            natural_width = @max(natural_width, itemNaturalWidth(item));
        }
        natural_width = @max(natural_width, self.options.min_width);

        const available_width = cols -| (2 * border_cells);
        var inner_width = @min(natural_width, self.options.max_width);
        inner_width = @max(inner_width, self.options.min_width);
        inner_width = @min(inner_width, available_width);
        level.inner_width = inner_width;
        level.rect.width = inner_width + 2 * border_cells;

        // A terminal row is already the item height, so there is no extra
        // vertical padding inside the border; one padded row would double the
        // gap VS Code draws in pixels.
        const available_rows = rows -| (2 * border_cells);
        const visible = @min(level.items.len, available_rows);
        level.visible = visible;
        level.rect.height = visible + 2 * border_cells;

        const max_top = level.items.len -| visible;
        level.scroll_top = @min(level.scroll_top, max_top);
        if (level.reveal_focus) {
            if (level.focused) |focused| {
                if (visible > 0) {
                    if (focused < level.scroll_top) {
                        level.scroll_top = focused;
                    } else if (focused >= level.scroll_top + visible) {
                        level.scroll_top = focused - visible + 1;
                    }
                }
            }
        }
    }

    fn relayout(self: *ContextMenu) void {
        if (self.viewport_cols == 0 or self.viewport_rows == 0) return;
        self.layout(self.viewport_cols, self.viewport_rows);
    }

    fn paintLevel(
        self: *ContextMenu,
        grid: *CellGrid,
        level: *const Level,
        caps: cell_border.Capabilities,
    ) void {
        const rect = level.rect;
        if (rect.width == 0 or rect.height == 0) return;
        if (rect.x >= grid.cols or rect.y >= grid.rows) return;
        if (rect.x + rect.width > grid.cols or rect.y + rect.height > grid.rows) return;

        const frame_rect: style.Rect = .{
            .x = @floatFromInt(rect.x),
            .y = @floatFromInt(rect.y),
            .w = @floatFromInt(rect.width),
            .h = @floatFromInt(rect.height),
        };
        const native_frame = if (caps.has(.round))
            cell.RoundedCellFrame.capture(grid, frame_rect)
        else
            null;

        const bg_paint = PaintStyle{
            .fg = cell.packColor(self.options.theme.foreground),
            .bg = cell.packColor(self.options.theme.background),
        };
        grid.clearBordersRect(frame_rect.x, frame_rect.y, frame_rect.w, frame_rect.h);
        grid.fillRect(
            frame_rect.x,
            frame_rect.y,
            frame_rect.w,
            frame_rect.h,
            bg_paint,
        );

        const inner_x = rect.x + border_cells;
        var row_index: usize = 0;
        while (row_index < level.visible) : (row_index += 1) {
            const index = level.scroll_top + row_index;
            if (index >= level.items.len) break;
            const y = rect.y + border_cells + row_index;
            const item = &level.items[index];
            self.paintItem(grid, level, item, index, inner_x, y);
        }

        const frame_paint = PaintStyle{
            .fg = cell.packColor(self.options.theme.border),
            .bg = cell.packColor(self.options.theme.background),
        };
        if (native_frame) |native| {
            native.paint(grid, caps, .{ .rgb = self.options.theme.border });
        } else {
            grid.paintRoundedFrame(frame_rect, frame_paint);
        }
    }

    fn paintItem(
        self: *ContextMenu,
        grid: *CellGrid,
        level: *const Level,
        item: *const Item,
        index: usize,
        inner_x: usize,
        y: usize,
    ) void {
        const selected = level.focused != null and level.focused.? == index;
        const theme = self.options.theme;
        const bg = if (selected) theme.selection_background else theme.background;

        if (item.type == .separator) {
            const width = level.inner_width -| 2;
            if (width == 0) return;
            const paint = PaintStyle{
                .fg = cell.packColor(theme.separator),
                .bg = cell.packColor(bg),
            };
            grid.fillGlyphSpan(
                grid.index(inner_x + 1, y),
                width,
                '─',
                1,
                paint,
                false,
            );
            return;
        }

        if (selected) {
            grid.fillRect(
                @floatFromInt(inner_x),
                @floatFromInt(y),
                @floatFromInt(level.inner_width),
                1,
                .{ .fg = 0, .bg = cell.packColor(bg) },
            );
        }

        const enabled = item.enabled;
        const fg = if (!enabled)
            theme.disabled
        else if (selected)
            theme.selection_foreground
        else
            theme.foreground;
        const text_paint = PaintStyle{
            .fg = cell.packColor(fg),
            .bg = cell.packColor(bg),
            .attrs = if (!enabled) cell.Attr.dim else 0,
        };

        if (item.checked) {
            const glyph: u21 = if (item.type == .radio) radio_glyph else check_glyph;
            grid.putCodepoint(inner_x + left_padding, y, glyph, 1, text_paint);
        }

        const submenu = item.submenu.len > 0;
        const accelerator_width = textWidth(item.accelerator);
        var content_end = inner_x + level.inner_width -| right_padding;
        var accelerator_x: ?usize = null;
        if (submenu) {
            const arrow_x = content_end -| 1;
            content_end -|= 2;
            const arrow_paint = PaintStyle{
                .fg = cell.packColor(fg),
                .bg = cell.packColor(bg),
                .attrs = text_paint.attrs | cell.Attr.dim,
            };
            grid.putCodepoint(arrow_x, y, submenu_glyph, 1, arrow_paint);
        }
        if (accelerator_width > 0) {
            const width = accelerator_width;
            if (content_end >= inner_x + label_offset + 1 + width) {
                const x = content_end - width;
                accelerator_x = x;
                content_end = x -| 1;
            }
        }

        const label_x = inner_x + label_offset;
        const label_width = content_end -| label_x;
        if (label_width > 0 and item.label.len > 0) {
            drawLabel(grid, label_x, y, label_width, item.label, text_paint);
        }
        if (accelerator_x) |x| {
            const accelerator_paint = PaintStyle{
                .fg = cell.packColor(if (!enabled)
                    theme.disabled
                else if (selected)
                    theme.selection_foreground
                else
                    theme.accelerator),
                .bg = cell.packColor(bg),
                .attrs = cell.Attr.dim,
            };
            drawText(grid, x, y, accelerator_width, item.accelerator, accelerator_paint);
        }
    }

    fn moveFocus(self: *ContextMenu, level_index: usize, forward: bool) bool {
        const level = &self.levels.items[level_index];
        if (level.items.len == 0) return false;

        const target = if (level.focused) |focused|
            nextFocusable(level.items, focused, forward)
        else if (forward)
            edgeFocusable(level.items, false)
        else
            edgeFocusable(level.items, true);
        const index = target orelse return false;
        self.setFocus(level_index, index);
        return true;
    }

    fn focusEdge(self: *ContextMenu, level_index: usize, last: bool) bool {
        const level = &self.levels.items[level_index];
        const index = edgeFocusable(level.items, last) orelse return false;
        self.setFocus(level_index, index);
        return true;
    }

    fn pageFocus(self: *ContextMenu, level_index: usize, forward: bool) void {
        const level = &self.levels.items[level_index];
        const step = @max(level.visible -| 1, 1);
        var count: usize = 0;
        while (count < step) : (count += 1) {
            if (!self.moveFocus(level_index, forward)) break;
        }
    }

    fn setFocus(self: *ContextMenu, level_index: usize, index: usize) void {
        if (level_index >= self.levels.items.len) return;
        const level = &self.levels.items[level_index];
        if (level.focused != null and level.focused.? == index) {
            level.reveal_focus = true;
            return;
        }
        level.focused = index;
        level.reveal_focus = true;
        if (self.levels.items.len > level_index + 1) {
            if (self.levels.items[level_index + 1].owner_index != index) {
                self.truncateLevels(level_index + 1);
            }
        }
        self.relayout();
    }

    fn openSubmenu(
        self: *ContextMenu,
        level_index: usize,
        owner_index: usize,
        select_first: bool,
    ) bool {
        if (level_index >= self.levels.items.len) return false;
        const level = &self.levels.items[level_index];
        if (owner_index >= level.items.len) return false;
        const owner = &level.items[owner_index];
        if (!owner.enabled or owner.type == .separator or owner.submenu.len == 0) return false;

        if (self.levels.items.len > level_index + 1) {
            if (self.levels.items[level_index + 1].owner_index == owner_index) {
                if (select_first) {
                    if (edgeFocusable(self.levels.items[level_index + 1].items, false)) |first| {
                        self.levels.items[level_index + 1].focused = first;
                        self.levels.items[level_index + 1].reveal_focus = true;
                    }
                }
                self.relayout();
                return true;
            }
            self.truncateLevels(level_index + 1);
        }

        const submenu = owner.submenu;
        var child = Level{ .items = submenu, .owner_index = owner_index };
        if (select_first) {
            child.focused = edgeFocusable(submenu, false);
            child.reveal_focus = true;
        } else {
            child.reveal_focus = false;
        }
        self.levels.append(self.allocator, child) catch return false;
        self.levels.items[level_index].focused = owner_index;
        self.levels.items[level_index].reveal_focus = true;
        self.relayout();
        return true;
    }

    fn truncateLevels(self: *ContextMenu, length: usize) void {
        if (self.levels.items.len > length) self.levels.items.len = length;
    }

    fn activateFocused(self: *ContextMenu, level_index: usize, mods: Event) Action {
        const level = &self.levels.items[level_index];
        const index = level.focused orelse return .none;
        if (index >= level.items.len) return .none;
        return self.activate(level_index, index, mods);
    }

    fn activate(self: *ContextMenu, level_index: usize, index: usize, mods: Event) Action {
        if (level_index >= self.levels.items.len) return .none;
        const item = &self.levels.items[level_index].items[index];
        if (!item.enabled or item.type == .separator) return .none;
        if (item.submenu.len > 0) {
            _ = self.openSubmenu(level_index, index, true);
            return .none;
        }

        const click = item.click;
        self.close();
        if (click) |handler| handler.callback(handler.context, mods);
        return .closed;
    }

    fn hover(self: *ContextMenu, x: usize, y: usize) void {
        const level_index = self.levelAt(x, y) orelse return;
        const index = self.itemAt(level_index, x, y) orelse return;
        if (!self.isFocusable(level_index, index)) return;
        self.setFocus(level_index, index);
        const item = &self.levels.items[level_index].items[index];
        if (item.submenu.len > 0) _ = self.openSubmenu(level_index, index, false);
    }

    fn mouseRelease(self: *ContextMenu, x: usize, y: usize, mods: Event) Action {
        const pressed = self.pressed;
        self.pressed = .none;

        if (pressed == .outside) {
            self.close();
            return .closed;
        }

        const hit = self.hitItem(x, y);
        switch (pressed) {
            .item => |press| {
                if (hit) |current| {
                    if (current.level == press.level and current.index == press.index) {
                        return self.activateOrOpen(current.level, current.index, mods);
                    }
                }
                return .none;
            },
            .outside => unreachable,
            .none => {
                if (hit) |current| {
                    return self.activateOrOpen(current.level, current.index, mods);
                }
                self.close();
                return .closed;
            },
        }
    }

    fn mouseClick(self: *ContextMenu, x: usize, y: usize, mods: Event) Action {
        const pressed = self.pressed;
        self.pressed = .none;
        if (pressed == .outside) {
            self.close();
            return .closed;
        }
        const hit = self.hitItem(x, y);
        switch (pressed) {
            .item => |press| {
                if (hit) |current| {
                    if (current.level == press.level and current.index == press.index) {
                        return self.activateOrOpen(current.level, current.index, mods);
                    }
                }
                return .none;
            },
            .outside => unreachable,
            .none => {
                if (hit) |current| {
                    return self.activateOrOpen(current.level, current.index, mods);
                }
                self.close();
                return .closed;
            },
        }
    }

    fn activateOrOpen(self: *ContextMenu, level_index: usize, index: usize, mods: Event) Action {
        if (level_index >= self.levels.items.len) return .none;
        const item = &self.levels.items[level_index].items[index];
        if (!item.enabled or item.type == .separator) return .none;
        if (item.submenu.len > 0) {
            _ = self.openSubmenu(level_index, index, true);
            return .none;
        }
        return self.activate(level_index, index, mods);
    }

    fn wheel(self: *ContextMenu, mouse_event: *const event.MouseEvent) void {
        const level_index = self.levelAt(mouse_event.x, mouse_event.y) orelse return;
        const level = &self.levels.items[level_index];
        if (level.visible == 0) return;
        const max_top = level.items.len -| level.visible;
        const delta: isize = @intCast(mouse_event.delta_y);
        var top: isize = @intCast(level.scroll_top);
        top += delta;
        level.reveal_focus = false;
        if (top < 0) {
            level.scroll_top = 0;
        } else {
            const value: usize = @intCast(top);
            level.scroll_top = @min(value, max_top);
        }
        self.relayout();
    }

    const Hit = struct { level: usize, index: usize };

    fn hitItem(self: *ContextMenu, x: usize, y: usize) ?Hit {
        const level_index = self.levelAt(x, y) orelse return null;
        const index = self.itemAt(level_index, x, y) orelse return null;
        return .{ .level = level_index, .index = index };
    }

    fn levelAt(self: *const ContextMenu, x: usize, y: usize) ?usize {
        var i = self.levels.items.len;
        while (i > 0) {
            i -= 1;
            if (self.levels.items[i].rect.contains(x, y)) return i;
        }
        return null;
    }

    fn itemAt(self: *const ContextMenu, level_index: usize, x: usize, y: usize) ?usize {
        const level = &self.levels.items[level_index];
        const inner_x = level.rect.x + border_cells;
        if (x < inner_x or x >= inner_x + level.inner_width) return null;
        const top = level.rect.y + border_cells;
        if (y < top) return null;
        const slot = y - top;
        if (slot >= level.visible) return null;
        const index = level.scroll_top + slot;
        if (index >= level.items.len) return null;
        return index;
    }

    fn isFocusable(self: *const ContextMenu, level_index: usize, index: usize) bool {
        if (level_index >= self.levels.items.len) return false;
        const level = &self.levels.items[level_index];
        if (index >= level.items.len) return false;
        const item = &level.items[index];
        return item.enabled and item.type != .separator;
    }
};

/// Mirrors the native `popup(items, options?, onHide?)` entry point. The
/// returned handle is the terminal host's menu window.
pub fn popup(
    allocator: Allocator,
    items: []const Item,
    options: Options,
    on_hide: ?OnHide,
) !*ContextMenu {
    const self = try allocator.create(ContextMenu);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .options = options,
        .on_hide = on_hide,
    };
    errdefer self.arena.deinit();

    self.items = try copyItems(self.arena.allocator(), items);
    if (self.items.len == 0) return error.EmptyContextMenu;

    try self.levels.append(allocator, .{ .items = self.items });
    self.open = true;
    return self;
}

fn copyItems(arena: Allocator, source: []const Item) ![]const Item {
    var out: std.ArrayListUnmanaged(Item) = .empty;
    errdefer out.deinit(arena);

    for (source) |source_item| {
        if (!source_item.visible) continue;

        if (source_item.type == .separator) {
            if (out.items.len == 0) continue;
            if (out.items[out.items.len - 1].type == .separator) continue;
            try out.append(arena, .{ .type = .separator });
            continue;
        }

        var item = source_item;
        item.label = try arena.dupe(u8, source_item.label);
        item.accelerator = try arena.dupe(u8, source_item.accelerator);
        item.click = source_item.click;

        if (source_item.submenu.len > 0) {
            item.submenu = try copyItems(arena, source_item.submenu);
            if (item.submenu.len == 0) continue;
            item.type = .submenu;
        } else {
            if (source_item.type == .submenu) continue;
            item.submenu = &.{};
        }

        if (item.type == .separator) continue;
        try out.append(arena, item);
    }

    while (out.items.len > 0 and out.items[out.items.len - 1].type == .separator) {
        out.items.len -= 1;
    }
    return out.toOwnedSlice(arena);
}

fn eventFromMods(mods: event.Modifiers) Event {
    return .{
        .shift_key = mods.shift,
        .ctrl_key = mods.ctrl,
        .alt_key = mods.alt,
        .meta_key = false,
    };
}

fn nextFocusable(items: []const Item, from: usize, forward: bool) ?usize {
    if (items.len == 0) return null;
    var index = from;
    var count: usize = 0;
    while (count < items.len) : (count += 1) {
        index = if (forward)
            (index + 1) % items.len
        else if (index == 0)
            items.len - 1
        else
            index - 1;
        if (focusable(items[index])) return index;
    }
    return null;
}

fn edgeFocusable(items: []const Item, last: bool) ?usize {
    if (items.len == 0) return null;
    if (!last) {
        for (items, 0..) |item, index| {
            if (focusable(item)) return index;
        }
    } else {
        var i = items.len;
        while (i > 0) {
            i -= 1;
            if (focusable(items[i])) return i;
        }
    }
    return null;
}

fn focusable(item: Item) bool {
    return item.enabled and item.type != .separator;
}

fn itemNaturalWidth(item: *const Item) usize {
    if (item.type == .separator) return 0;
    var width = label_offset + textWidth(item.label) + right_padding;
    if (textWidth(item.accelerator) > 0) width += 1 + textWidth(item.accelerator);
    if (item.submenu.len > 0) width += 2;
    return width;
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

fn drawText(
    grid: *CellGrid,
    x: usize,
    y: usize,
    max_width: usize,
    text: []const u8,
    paint: PaintStyle,
) void {
    var column = x;
    var offset: usize = 0;
    while (offset < text.len and column < x + max_width) {
        const decoded = dom.decodeAt(text, offset);
        if (decoded.len == 0) break;
        const width = dom.defaultMeasureWidth(decoded.cp);
        if (column + width > x + max_width) break;
        grid.putCodepoint(column, y, decoded.cp, width, paint);
        column += width;
        offset += decoded.len;
    }
}

fn drawLabel(
    grid: *CellGrid,
    x: usize,
    y: usize,
    max_width: usize,
    text: []const u8,
    paint: PaintStyle,
) void {
    if (max_width == 0) return;
    var column = x;
    var offset: usize = 0;
    var truncated = false;
    while (offset < text.len) {
        const decoded = dom.decodeAt(text, offset);
        if (decoded.len == 0) break;
        const width = dom.defaultMeasureWidth(decoded.cp);
        if (column + width > x + max_width) {
            truncated = true;
            break;
        }
        grid.putCodepoint(column, y, decoded.cp, width, paint);
        column += width;
        offset += decoded.len;
    }
    if (!truncated) return;
    if (column < x + max_width - 1) {
        grid.putCodepoint(column, y, ellipsis, 1, paint);
    } else if (max_width > 0) {
        grid.putCodepoint(x + max_width - 1, y, ellipsis, 1, paint);
    }
}
