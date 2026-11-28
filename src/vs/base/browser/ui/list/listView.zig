// Port of the virtualized core of `src/vs/base/browser/ui/list/listView.ts`.
//
// Terminal adaptation: there is no DOM scroll element and no template cache.
// The `RangeMap` still owns row geometry, `scrollTop` is the viewport offset,
// and each visible row is handed to the terminal renderer as a `Row` clipped to
// the list rectangle. Terminal tree splices use the unit-row fast path; other
// lists keep the general range-map splice. Mouse/keyboard selection lives in
// `listWidget.zig`.

const std = @import("std");
const ui = @import("ui");
const list = @import("./list.zig");
const range_map_mod = @import("./rangeMap.zig");

pub const Element = list.Element;
pub const Row = list.Row;
pub const VirtualDelegate = list.VirtualDelegate;
pub const Renderer = list.Renderer;
pub const RangeMap = range_map_mod.RangeMap;
pub const Item = range_map_mod.Item;

pub const ListView = struct {
    allocator: std.mem.Allocator,
    delegate: VirtualDelegate,
    renderer: Renderer,
    items: std.array_list.Managed(Element),
    range_map: RangeMap,
    scroll_top: f64 = 0,
    viewport_height: f64 = 0,
    selected: ?usize = null,
    focused: bool = false,
    hovered: ?usize = null,
    mouse_inside: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        delegate: VirtualDelegate,
        renderer: Renderer,
    ) ListView {
        return .{
            .allocator = allocator,
            .delegate = delegate,
            .renderer = renderer,
            .items = std.array_list.Managed(Element).init(allocator),
            .range_map = RangeMap.init(allocator, 0),
        };
    }

    pub fn deinit(self: *ListView) void {
        self.range_map.deinit();
        self.items.deinit();
    }

    pub fn count(self: *const ListView) usize {
        return self.items.items.len;
    }

    /// Clears row/list hover state when the pointer leaves the viewport.
    pub fn clearHover(self: *ListView) void {
        self.hovered = null;
        self.mouse_inside = false;
    }

    /// Replaces every element without rebuilding the list when the row count
    /// is unchanged. Unit-height lists (the terminal trees) do not touch the
    /// range map at all; other lists fall back to a size splice.
    pub fn replaceAll(self: *ListView, elements: []const Element) !void {
        if (elements.len != self.items.items.len) {
            try self.splice(0, self.items.items.len, elements);
            return;
        }
        try self.items.ensureTotalCapacity(elements.len);
        for (elements, 0..) |element, index| self.items.items[index] = element;
        self.items.items.len = elements.len;
        if (self.range_map.count() != elements.len or self.range_map.size() != @as(f64, @floatFromInt(elements.len))) {
            var sizes = try self.allocator.alloc(Item, elements.len);
            defer self.allocator.free(sizes);
            for (elements, 0..) |element, index| sizes[index] = .{ .size = self.delegate.height(element) };
            try self.range_map.splice(0, elements.len, sizes);
        }
        self.clampScroll();
    }

    /// Port of `ListView.splice`.
    pub fn splice(
        self: *ListView,
        index: usize,
        delete_count: usize,
        elements: []const Element,
    ) !void {
        // The terminal tree delegate reports unit rows. Keep the item array and
        // a single range group in place instead of rebuilding both structures.
        if (self.range_map.paddingTop() == 0 and
            self.range_map.count() == self.items.items.len and
            self.range_map.size() == @as(f64, @floatFromInt(self.items.items.len)))
        {
            var unit = true;
            for (elements) |element| {
                if (self.delegate.height(element) != 1) {
                    unit = false;
                    break;
                }
            }
            if (unit) {
                try self.items.replaceRange(index, delete_count, elements);
                self.range_map.setUniformCount(self.items.items.len);
                self.clampScroll();
                return;
            }
        }

        var sizes = try self.allocator.alloc(Item, elements.len);
        defer self.allocator.free(sizes);
        for (elements, 0..) |element, i| {
            sizes[i] = .{ .size = self.delegate.height(element) };
        }

        var next: std.array_list.Managed(Element) = .init(self.allocator);
        errdefer next.deinit();
        try next.appendSlice(self.items.items[0..@min(index, self.items.items.len)]);
        try next.appendSlice(elements);
        const after = @min(index + delete_count, self.items.items.len);
        try next.appendSlice(self.items.items[after..]);

        try self.range_map.splice(index, delete_count, sizes);
        self.items.deinit();
        self.items = next;
        self.clampScroll();
    }

    pub fn setViewportHeight(self: *ListView, height: f64) void {
        self.viewport_height = @max(0, height);
        self.clampScroll();
    }

    pub fn maxScroll(self: *const ListView) f64 {
        return @max(0, self.range_map.size() - self.viewport_height);
    }

    pub fn clampScroll(self: *ListView) void {
        self.scroll_top = std.math.clamp(self.scroll_top, 0, self.maxScroll());
    }

    pub fn setScrollTop(self: *ListView, value: f64) void {
        self.scroll_top = std.math.clamp(value, 0, self.maxScroll());
    }

    pub fn scrollBy(self: *ListView, delta: f64) void {
        self.setScrollTop(self.scroll_top + delta);
    }

    /// The index whose row contains `position` in list coordinates.
    pub fn indexAt(self: *const ListView, position: f64) i64 {
        return self.range_map.indexAt(position);
    }

    pub fn elementAt(self: *const ListView, index: usize) ?Element {
        if (index >= self.items.items.len) return null;
        return self.items.items[index];
    }

    pub fn setSelection(self: *ListView, index: ?usize) void {
        self.setSelectionWithPadding(index, 0);
    }

    /// Port of `ListWidget.reveal(index, undefined, paddingTop)`: selection
    /// revealing honors the sticky-scroll widget height so the selected row is
    /// not pinned underneath it.
    pub fn setSelectionWithPadding(self: *ListView, index: ?usize, padding_top: f64) void {
        self.selected = index;
        if (index) |value| self.revealAt(value, padding_top);
    }

    pub fn selection(self: *const ListView) ?usize {
        return self.selected;
    }

    /// Sets the selected row without revealing it. Model splices preserve the
    /// viewport in upstream; only explicit selection/reveal calls scroll.
    pub fn selectOnly(self: *ListView, index: ?usize) void {
        self.selected = index;
    }

    /// Port of the `relativeTop === undefined` branch of
    /// `ListWidget.reveal`.
    pub fn revealAt(self: *ListView, index: usize, padding_top: f64) void {
        if (index >= self.items.items.len) return;
        const element_top = self.range_map.positionAt(@intCast(index));
        const element_height = self.delegate.height(self.items.items[index]);
        const view_item_bottom = element_top + element_height;
        const scroll_bottom = self.scroll_top + self.viewport_height;

        if (element_top < self.scroll_top + padding_top and view_item_bottom >= scroll_bottom) {
            // The element already overflows the padded viewport; no-op.
        } else if (element_top < self.scroll_top + padding_top or
            (view_item_bottom >= scroll_bottom and element_height >= self.viewport_height))
        {
            self.setScrollTop(element_top - padding_top);
        } else if (view_item_bottom >= scroll_bottom) {
            self.setScrollTop(view_item_bottom - self.viewport_height);
        }
    }

    /// Paints every row intersecting the viewport rectangle.
    pub fn render(self: *ListView, grid: *ui.CellGrid, rect: ui.Rect) void {
        const x = ui.cell.snap(rect.x);
        const y = ui.cell.snap(rect.y);
        const width = ui.cell.snap(rect.w);
        const height = ui.cell.snap(rect.h);
        if (width == 0 or height == 0) return;

        self.setViewportHeight(@floatFromInt(height));
        const start: usize = @intCast(@max(0, self.range_map.indexAt(self.scroll_top)));
        var index = start;
        while (index < self.items.items.len) : (index += 1) {
            const element = self.items.items[index];
            const row_height = self.delegate.height(element);
            const top = self.range_map.positionAt(@intCast(index)) - self.scroll_top;
            const bottom = top + row_height;
            if (bottom <= 0) continue;
            if (top >= @as(f64, @floatFromInt(height))) break;

            const visible_top: usize = @intFromFloat(@max(0, @ceil(top)));
            const visible_bottom: usize = @intFromFloat(@min(
                @as(f64, @floatFromInt(height)),
                @floor(bottom),
            ));
            if (visible_bottom <= visible_top) continue;

            const row = Row{
                .grid = grid,
                .x = x,
                .y = y + visible_top,
                .width = width,
                .height = visible_bottom - visible_top,
                .offset_y = @intFromFloat(@max(0, @as(f64, @floatFromInt(visible_top)) - top)),
                .index = index,
                .selected = self.selected != null and self.selected.? == index,
                .focused_selection = self.focused and self.selected != null and self.selected.? == index,
                .focused = self.focused,
                .hovered = self.hovered != null and self.hovered.? == index,
                .list_hovered = self.mouse_inside,
            };
            self.renderer.renderRow(&row, element);
        }
    }
};
