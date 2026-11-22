// Port of the portable file-picker decisions of
// `src/vs/workbench/browser/parts/editor/breadcrumbsPicker.ts`.
//
// Upstream `BreadcrumbsFilePicker` is a tree inside a context view: selecting
// a breadcrumb opens the tree at the clicked element's parent directory and
// focuses the clicked element. This file keeps those decisions and the
// immediate-children/sort rules; the terminal workbench maps the entries to the
// existing quick pick. The outline picker's tree/quick-pick sources are not
// ported because the TUI ships no document-symbol provider yet.
//
// Terminal adaptations: `IFileService.resolve` becomes a direct `Io.Dir`
// iteration; a folder selection drills into the folder by reopening the picker
// instead of expanding a tree row.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const model_mod = @import("breadcrumbsModel.zig");
const FileElement = model_mod.FileElement;

pub const Entry = struct {
    path: []u8,
    name: []u8,
    is_dir: bool,

    pub fn deinit(self: *Entry, allocator: Allocator) void {
        allocator.free(self.path);
        allocator.free(self.name);
    }
};

/// The directory whose immediate children the picker shows for `file`.
/// Upstream shows the workspace for a root folder and the parent directory for
/// every other element. The TUI has no workspace tree in the picker, so a root
/// folder lists its own children.
pub fn inputDirectory(file: *const FileElement) []const u8 {
    if (file.kind == .ROOT_FOLDER) return file.path;
    return dirnamePath(file.path);
}

/// Lists the immediate children of `directory`, directories first and then
/// case-insensitive by name. The caller frees the returned entries.
pub fn list(allocator: Allocator, io: Io, directory: []const u8) ![]Entry {
    var dir = try Io.Dir.cwd().openDir(io, directory, .{ .iterate = true });
    defer dir.close(io);

    var entries = std.array_list.Managed(Entry).init(allocator);
    errdefer {
        for (entries.items) |*entry| entry.deinit(allocator);
        entries.deinit();
    }

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        if (entry.kind != .file and entry.kind != .directory) continue;
        const path = try std.fs.path.join(allocator, &.{ directory, entry.name });
        errdefer allocator.free(path);
        const name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);
        try entries.append(.{
            .path = path,
            .name = name,
            .is_dir = entry.kind == .directory,
        });
    }

    std.mem.sort(Entry, entries.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            if (a.is_dir != b.is_dir) return a.is_dir;
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        }
    }.lessThan);

    return try entries.toOwnedSlice();
}

/// Parent directory of a picker directory, or the same path at a filesystem
/// root. Used for the picker's leading `..` entry.
pub fn parentDirectory(directory: []const u8) []const u8 {
    return dirnamePath(directory);
}

pub fn freeEntries(allocator: Allocator, entries: []Entry) void {
    for (entries) |*entry| entry.deinit(allocator);
    allocator.free(entries);
}

fn isSeparator(ch: u8) bool {
    return ch == '/' or ch == '\\';
}

fn dirnamePath(path: []const u8) []const u8 {
    var end = path.len;
    if (end == 0) return path;
    while (end > 0 and isSeparator(path[end - 1])) end -= 1;
    var index = end;
    while (index > 0) : (index -= 1) {
        if (isSeparator(path[index - 1])) {
            const parent = index - 1;
            if (parent == 0) return path[0..1];
            if (parent == 2 and path[1] == ':') return path[0..3];
            return path[0..parent];
        }
    }
    return path;
}

test "breadcrumb picker: parent directory stops at the root" {
    try std.testing.expectEqualStrings("/a/b", parentDirectory("/a/b/c"));
    try std.testing.expectEqualStrings("/", parentDirectory("/a"));
    try std.testing.expectEqualStrings("/", parentDirectory("/"));
}

// ---------------------------------------------------------------------------
// Terminal breadcrumb picker
//
// Upstream `BreadcrumbsPicker` is a tree anchored under the clicked breadcrumb
// in a context view. The terminal equivalent is a cell popup anchored under
// the item: a bordered list of the directory's children (or an outline
// element's siblings), navigated with the list widget. It replaces the
// quick-pick fallback used by earlier terminal ports; selecting a file,
// folder or symbol is still reported through the workbench callback.
// ---------------------------------------------------------------------------

const ui = @import("ui");
const list_mod = @import("../../../../base/browser/ui/list/list.zig");
const list_widget_mod = @import("../../../../base/browser/ui/list/listWidget.zig");
const ListWidget = list_widget_mod.ListWidget;
const theme_colors_mod = @import("../../themeColors.zig");
const file_icon_mod = @import("../../fileIcon.zig");

pub const PopupItemKind = enum { file, folder, symbol, parent, group };

pub const PopupItem = struct {
    /// Stable action id; the workbench owns the string behind it.
    id: []const u8,
    label: []const u8,
    description: []const u8 = "",
    kind: PopupItemKind = .file,
    icon: ?file_icon_mod.Icon = null,
};

pub const Popup = struct {
    allocator: Allocator,
    items: std.array_list.Managed(PopupItem),
    list: ListWidget,
    visible: bool = false,
    anchor_x: usize = 0,
    anchor_y: usize = 0,
    rect: ui.Rect = .{},
    theme: ?*const theme_colors_mod.ThemeColors = null,
    on_accept_context: ?*anyopaque = null,
    on_accept: ?*const fn (context: *anyopaque, item: *const PopupItem) anyerror!void = null,
    on_close_context: ?*anyopaque = null,
    on_close: ?*const fn (context: *anyopaque) void = null,

    pub fn init(allocator: Allocator) !*Popup {
        const self = try allocator.create(Popup);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .items = std.array_list.Managed(PopupItem).init(allocator),
            .list = ListWidget.init(allocator, .{
                .context = @ptrCast(self),
                .get_height = rowHeight,
                .get_template_id = rowTemplate,
            }, .{
                .context = @ptrCast(self),
                .render = renderRow,
            }),
        };
        self.list.on_activate = activate;
        self.list.activation_context = self;
        self.list.on_selection = selectionChanged;
        self.list.selection_context = self;
        return self;
    }

    pub fn deinit(self: *Popup) void {
        self.list.deinit();
        self.items.deinit();
        self.allocator.destroy(self);
    }

    pub fn setThemeColors(self: *Popup, palette: ?*const theme_colors_mod.ThemeColors) void {
        self.theme = palette;
    }

    pub fn isVisible(self: *const Popup) bool {
        return self.visible;
    }

    /// Replaces the items and anchors the popup under `(anchor_x, anchor_y)`
    /// (the clicked breadcrumb cell). `active_id` focuses the clicked element.
    pub fn open(
        self: *Popup,
        items: []const PopupItem,
        anchor_x: usize,
        anchor_y: usize,
        active_id: ?[]const u8,
    ) !void {
        self.items.clearRetainingCapacity();
        try self.items.appendSlice(items);
        var elements = std.array_list.Managed(list_mod.Element).init(self.allocator);
        defer elements.deinit();
        for (self.items.items) |*item| try elements.append(@ptrCast(item));
        try self.list.replaceAll(elements.items);
        self.list.setSelection(null);
        if (active_id) |id| {
            for (self.items.items, 0..) |item, index| {
                if (std.mem.eql(u8, item.id, id)) {
                    self.list.setSelection(index);
                    break;
                }
            }
        }
        if (self.list.selection() == null and self.items.items.len > 0) self.list.setSelection(0);
        self.list.setFocus(true);
        self.anchor_x = anchor_x;
        self.anchor_y = anchor_y;
        self.visible = true;
    }

    pub fn close(self: *Popup) void {
        if (!self.visible) return;
        self.visible = false;
        self.list.clearHover();
        if (self.on_close) |callback| callback(self.on_close_context orelse return);
    }

    pub fn selectedItem(self: *const Popup) ?*const PopupItem {
        const index = self.list.selection() orelse return null;
        if (index >= self.items.items.len) return null;
        return &self.items.items[index];
    }

    pub fn itemCount(self: *const Popup) usize {
        return self.items.items.len;
    }

    pub fn selectedIndex(self: *const Popup) ?usize {
        return self.list.selection();
    }

    fn colors(self: *const Popup) struct {
        background: ui.Color,
        foreground: ui.Color,
        dim: ui.Color,
        selection_background: ui.Color,
        hover_background: ui.Color,
        border: ui.Color,
    } {
        const palette = self.theme orelse return .{
            .background = .{ .r = 37, .g = 37, .b = 38 },
            .foreground = .{ .r = 204, .g = 204, .b = 204 },
            .dim = .{ .r = 150, .g = 150, .b = 150 },
            .selection_background = .{ .r = 4, .g = 57, .b = 94 },
            .hover_background = .{ .r = 42, .g = 45, .b = 46 },
            .border = .{ .r = 69, .g = 69, .b = 69 },
        };
        return .{
            .background = palette.colorOr("breadcrumbsPicker.background", palette.color("menu.background", .{ 37, 37, 38 })),
            .foreground = palette.color("menu.foreground", .{ 204, 204, 204 }),
            .dim = palette.color("descriptionForeground", .{ 150, 150, 150 }),
            .selection_background = palette.color("list.activeSelectionBackground", .{ 4, 57, 94 }),
            .hover_background = palette.color("list.hoverBackground", .{ 42, 45, 46 }),
            .border = palette.color("widget.border", .{ 69, 69, 69 }),
        };
    }

    fn computeLayout(self: *Popup, cols: usize, rows: usize) ui.Rect {
        var content_width: usize = 24;
        for (self.items.items) |item| {
            const label_width = textWidth(item.label);
            const desc_width = if (item.description.len > 0) textWidth(item.description) + 2 else 0;
            const icon_width: usize = if (item.icon != null) 2 else 0;
            content_width = @max(content_width, label_width + desc_width + icon_width + 4);
        }
        const width = @min(@max(content_width, 20), cols);
        const max_height = @max(@min(rows -| 2, 12), 1);
        const content_height = @min(self.items.items.len, max_height);
        const height = @min(content_height + 2, rows);
        var x = self.anchor_x;
        if (x + width > cols) x = cols -| width;
        var y = self.anchor_y + 1;
        if (y + height > rows) y = self.anchor_y -| height;
        if (y + height > rows) y = rows -| height;
        self.rect = .{
            .x = @floatFromInt(x),
            .y = @floatFromInt(y),
            .w = @floatFromInt(width),
            .h = @floatFromInt(height),
        };
        return self.rect;
    }

    pub fn render(self: *Popup, grid: *ui.CellGrid) !void {
        if (!self.visible) return;
        const rect = self.computeLayout(grid.cols, grid.rows);
        const x = ui.cell.snap(rect.x);
        const y = ui.cell.snap(rect.y);
        const width = ui.cell.snap(rect.w);
        const height = ui.cell.snap(rect.h);
        if (width < 3 or height < 3) return;
        const palette = self.colors();
        const background = ui.cell.PaintStyle{ .bg = ui.cell.packColor(palette.background), .fg = ui.cell.packColor(palette.foreground) };
        const border = ui.cell.PaintStyle{ .bg = ui.cell.packColor(palette.background), .fg = ui.cell.packColor(palette.border) };
        grid.fillRect(rect.x, rect.y, rect.w, rect.h, background);
        grid.clearBordersRect(rect.x, rect.y, rect.w, rect.h);
        // Box border. The arrow cell points back to the breadcrumb row.
        grid.putCodepoint(x, y, 0x250C, 1, border);
        grid.putCodepoint(x + width - 1, y, 0x2510, 1, border);
        grid.putCodepoint(x, y + height - 1, 0x2514, 1, border);
        grid.putCodepoint(x + width - 1, y + height - 1, 0x2518, 1, border);
        var col: usize = 1;
        while (col + 1 < width) : (col += 1) {
            grid.putCodepoint(x + col, y, 0x2500, 1, border);
            grid.putCodepoint(x + col, y + height - 1, 0x2500, 1, border);
        }
        var row: usize = 1;
        while (row + 1 < height) : (row += 1) {
            grid.putCodepoint(x, y + row, 0x2502, 1, border);
            grid.putCodepoint(x + width - 1, y + row, 0x2502, 1, border);
        }
        var arrow_offset = self.anchor_x -| x;
        arrow_offset = @min(arrow_offset, width - 2);
        grid.putCodepoint(x + arrow_offset, y, 0x25B2, 1, border);

        const inner = ui.Rect{
            .x = @floatFromInt(x + 1),
            .y = @floatFromInt(y + 1),
            .w = @floatFromInt(width - 2),
            .h = @floatFromInt(height - 2),
        };
        self.list.render(grid, inner);
    }

    pub fn handleKey(self: *Popup, event: *const ui.KeyEvent) bool {
        if (!self.visible) return false;
        switch (event.key) {
            .escape => {
                self.close();
                return true;
            },
            .enter => {
                if (self.selectedItem()) |item| {
                    if (self.on_accept) |callback| callback(self.on_accept_context orelse return true, item) catch {};
                }
                return true;
            },
            else => {
                _ = self.list.handleKey(event);
                return true;
            },
        }
    }

    pub fn handleMouse(self: *Popup, event: *const ui.MouseEvent) bool {
        if (!self.visible) return false;
        const x = ui.cell.snap(self.rect.x);
        const y = ui.cell.snap(self.rect.y);
        const width = ui.cell.snap(self.rect.w);
        const height = ui.cell.snap(self.rect.h);
        const inside = event.x >= x and event.x < x + width and event.y >= y and event.y < y + height;
        if (!inside) {
            if (event.kind == .down or event.kind == .click) self.close();
            return true;
        }
        if (event.kind == .move) {
            _ = self.list.handleMouse(event);
            return true;
        }
        if (event.kind == .wheel) {
            _ = self.list.handleMouse(event);
            return true;
        }
        if (event.kind == .down or event.kind == .click) {
            const handled = self.list.handleMouse(event);
            if (handled) {
                if (self.selectedItem()) |item| {
                    if (self.on_accept) |callback| callback(self.on_accept_context orelse return true, item) catch {};
                }
            }
            return true;
        }
        return self.list.handleMouse(event);
    }

    fn rowHeight(_: *anyopaque, _: list_mod.Element) f64 {
        return 1;
    }

    fn rowTemplate(_: *anyopaque, _: list_mod.Element) usize {
        return 0;
    }

    fn renderRow(context: *anyopaque, row: *const list_mod.Row, element: list_mod.Element) void {
        const self: *Popup = @ptrCast(@alignCast(context));
        const item: *const PopupItem = @ptrCast(@alignCast(element));
        const palette = self.colors();
        var bg = palette.background;
        var fg = palette.foreground;
        if (row.selected) {
            bg = palette.selection_background;
            fg = .{ .r = 255, .g = 255, .b = 255 };
        } else if (row.hovered) {
            bg = palette.hover_background;
        }
        const base = ui.cell.PaintStyle{ .fg = ui.cell.packColor(fg), .bg = ui.cell.packColor(bg) };
        row.grid.fillRect(@floatFromInt(row.x), @floatFromInt(row.y), @floatFromInt(row.width), 1, base);
        var col = row.x;
        const limit = row.x + row.width;
        if (col < limit) {
            const icon = item.icon orelse if (item.kind == .folder)
                file_icon_mod.folder(false)
            else if (item.kind == .parent)
                file_icon_mod.folder(false)
            else
                null;
            if (icon) |value| {
                row.grid.putCodepoint(col, row.y, value.glyph, 1, .{
                    .fg = ui.cell.packColor(value.color),
                    .bg = ui.cell.packColor(bg),
                });
                col += 1;
                if (col < limit) {
                    row.grid.putCodepoint(col, row.y, ' ', 1, base);
                    col += 1;
                }
            } else if (item.kind == .symbol) {
                row.grid.putCodepoint(col, row.y, 0x25C7, 1, base);
                col += 1;
                if (col < limit) {
                    row.grid.putCodepoint(col, row.y, ' ', 1, base);
                    col += 1;
                }
            }
        }
        const label_width = drawTextClipped(row.grid, col, row.y, limit -| col, item.label, base);
        col += label_width;
        if (item.description.len > 0 and col + 1 < limit) {
            col += 1;
            _ = drawTextClipped(row.grid, col, row.y, limit -| col, item.description, .{
                .fg = ui.cell.packColor(palette.dim),
                .bg = ui.cell.packColor(bg),
            });
        }
    }

    fn activate(context: ?*anyopaque, index: usize) void {
        const self: *Popup = @ptrCast(@alignCast(context orelse return));
        if (index >= self.items.items.len) return;
        if (self.on_accept) |callback| callback(self.on_accept_context orelse return, &self.items.items[index]) catch {};
    }

    fn selectionChanged(_: ?*anyopaque, _: ?usize) void {}
};

fn drawTextClipped(grid: *ui.CellGrid, x: usize, y: usize, max_width: usize, text: []const u8, style: ui.cell.PaintStyle) usize {
    var col: usize = 0;
    var offset: usize = 0;
    while (offset < text.len and col < max_width) {
        const decoded = ui.dom.decodeAt(text, offset);
        const width = ui.dom.defaultMeasureWidth(decoded.cp);
        if (col + width > max_width) break;
        grid.putCodepoint(x + col, y, decoded.cp, width, style);
        col += width;
        offset += decoded.len;
    }
    if (offset < text.len and col < max_width) {
        grid.putCodepoint(x + col, y, 0x2026, 1, style);
        col += 1;
    }
    return col;
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
