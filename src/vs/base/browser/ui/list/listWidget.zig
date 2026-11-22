// Port of the core of `src/vs/base/browser/ui/list/listWidget.ts`.
//
// Terminal adaptation: focus, selection, keyboard and wheel/click routing are
// host-side; rendering is delegated to `ListView`/the terminal `Renderer`.
// Drag/drop, context menus and DOM focus are not part of this terminal subset.

const std = @import("std");
const ui = @import("ui");
const list = @import("./list.zig");
const list_view_mod = @import("./listView.zig");

pub const Element = list.Element;
pub const VirtualDelegate = list.VirtualDelegate;
pub const Renderer = list.Renderer;
pub const ListView = list_view_mod.ListView;

pub const ListWidget = struct {
    view: ListView,
    focused: bool = false,
    last_rect: ui.Rect = .{},
    selection_context: ?*anyopaque = null,
    on_selection: ?*const fn (context: ?*anyopaque, selection: ?usize) void = null,
    activation_context: ?*anyopaque = null,
    on_activate: ?*const fn (context: ?*anyopaque, index: usize) void = null,

    pub fn init(
        allocator: std.mem.Allocator,
        delegate: VirtualDelegate,
        renderer: Renderer,
    ) ListWidget {
        return .{ .view = ListView.init(allocator, delegate, renderer) };
    }

    pub fn deinit(self: *ListWidget) void {
        self.view.deinit();
    }

    pub fn count(self: *const ListWidget) usize {
        return self.view.count();
    }

    pub fn splice(self: *ListWidget, index: usize, delete_count: usize, elements: []const Element) !void {
        try self.view.splice(index, delete_count, elements);
        if (self.view.selected) |selected| {
            if (selected >= self.view.count()) self.setSelection(if (self.view.count() == 0) null else self.view.count() - 1);
        }
    }

    pub fn setFocus(self: *ListWidget, focused: bool) void {
        self.focused = focused;
        self.view.focused = focused;
    }

    pub fn selection(self: *const ListWidget) ?usize {
        return self.view.selection();
    }

    pub fn setSelection(self: *ListWidget, index: ?usize) void {
        self.setSelectionWithPadding(index, 0);
    }

    /// Selection reveal with the sticky-scroll widget height reserved at the
    /// top of the viewport, like upstream `reveal(index, top, paddingTop)`.
    pub fn setSelectionWithPadding(self: *ListWidget, index: ?usize, padding_top: f64) void {
        self.view.setSelectionWithPadding(index, padding_top);
        if (self.on_selection) |callback| callback(self.selection_context, index);
    }

    /// Restores a selection without scrolling the viewport, like the
    /// selection rewrite a list splice performs upstream.
    pub fn selectOnly(self: *ListWidget, index: ?usize) void {
        self.view.selectOnly(index);
    }

    pub fn clearHover(self: *ListWidget) void {
        self.view.clearHover();
    }

    pub fn render(self: *ListWidget, grid: *ui.CellGrid, rect: ui.Rect) void {
        self.last_rect = rect;
        self.view.focused = self.focused;
        self.view.render(grid, rect);
    }

    /// Keyboard navigation follows the list widget's focus/selection model.
    pub fn handleKey(self: *ListWidget, event: *const ui.KeyEvent) bool {
        return self.handleKeyWithPadding(event, 0);
    }

    /// `padding_top` is the sticky widget height. Upstream passes it to the
    /// previous-page navigation so the new selection stays below the pinned
    /// rows (`focusPreviousPage(..., () => stickyScrollController?.height)`).
    pub fn handleKeyWithPadding(self: *ListWidget, event: *const ui.KeyEvent, padding_top: f64) bool {
        if (!self.focused or self.view.count() == 0) return false;
        const item_count = self.view.count();
        const page = @max(1, @as(usize, @intFromFloat(@floor(self.view.viewport_height))));
        const current = self.view.selection() orelse 0;
        switch (event.key) {
            .up => {
                self.setSelection(if (current == 0) 0 else current - 1);
                return true;
            },
            .down => {
                self.setSelection(@min(current + 1, item_count - 1));
                return true;
            },
            .home => {
                self.setSelection(0);
                return true;
            },
            .end => {
                self.setSelection(item_count - 1);
                return true;
            },
            .page_up => {
                self.setSelectionWithPadding(current -| page, padding_top);
                return true;
            },
            .page_down => {
                self.setSelection(@min(current + page, item_count - 1));
                return true;
            },
            .enter => {
                if (self.on_activate) |callback| callback(self.activation_context, current);
                return true;
            },
            else => return false,
        }
    }

    /// Wheel scrolls the viewport independently of selection. A left click
    /// selects the row under the pointer. Coordinates are viewport cells.
    pub fn handleMouse(self: *ListWidget, event: *const ui.MouseEvent) bool {
        const rect = self.last_rect;
        const x = ui.cell.snap(rect.x);
        const y = ui.cell.snap(rect.y);
        const width = ui.cell.snap(rect.w);
        const height = ui.cell.snap(rect.h);
        const inside = event.x >= x and event.x < x + width and
            event.y >= y and event.y < y + height;
        self.view.mouse_inside = inside;
        if (!inside) {
            self.view.hovered = null;
            return false;
        }

        if (event.kind == .move) {
            const position = self.view.scroll_top +
                @as(f64, @floatFromInt(event.y - y));
            const index = self.view.range_map.indexAt(position);
            self.view.hovered = if (index >= 0 and index < @as(i64, @intCast(self.view.count())))
                @intCast(index)
            else
                null;
            return true;
        }

        switch (event.kind) {
            .wheel => {
                if (event.delta_y == 0) return false;
                self.view.scrollBy(@as(f64, @floatFromInt(event.delta_y)) * 3);
                return true;
            },
            .down => {
                if (event.button != .left) return false;
                const position = self.view.scroll_top +
                    @as(f64, @floatFromInt(event.y - y));
                const index = self.view.range_map.indexAt(position);
                if (index < 0 or index >= @as(i64, @intCast(self.view.count()))) return true;
                self.setSelection(@intCast(index));
                return true;
            },
            else => return false,
        }
    }
};
