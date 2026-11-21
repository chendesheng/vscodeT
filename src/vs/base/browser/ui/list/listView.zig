// Port of the virtualized core of `src/vs/base/browser/ui/list/listView.ts`.
//
// Terminal adaptation: there is no DOM scroll element and no template cache.
// The `RangeMap` still owns row geometry, `scrollTop` is the viewport offset,
// and each visible row is handed to the terminal renderer as a `Row` clipped to
// the list rectangle. Mouse/keyboard selection lives in `listWidget.zig`.

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

    /// Port of `ListView.splice`.
    pub fn splice(
        self: *ListView,
        index: usize,
        delete_count: usize,
        elements: []const Element,
    ) !void {
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
        self.selected = index;
        if (index) |value| self.reveal(value);
    }

    pub fn selection(self: *const ListView) ?usize {
        return self.selected;
    }

    fn reveal(self: *ListView, index: usize) void {
        if (index >= self.items.items.len) return;
        const top = self.range_map.positionAt(@intCast(index));
        const height = self.delegate.height(self.items.items[index]);
        if (top < self.scroll_top) {
            self.setScrollTop(top);
        } else if (top + height > self.scroll_top + self.viewport_height) {
            self.setScrollTop(top + height - self.viewport_height);
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
