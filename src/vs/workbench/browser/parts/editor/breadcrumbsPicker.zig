// Port of the portable file-picker decisions of
// `src/vs/workbench/browser/parts/editor/breadcrumbsPicker.ts`.
//
// Upstream `BreadcrumbsFilePicker` and `BreadcrumbsOutlinePicker` are trees in
// an anchored context view. This file ports both tree pipelines: the file
// picker uses `AsyncDataTree` with an `IAsyncDataSource` over directory
// children, and the outline picker uses `AsyncDataTree` over the outline tree
// snapshot. Expansion, selection, navigation and activation come from the
// ported tree, not a parallel row list.
//
// Terminal adaptations: `IFileService.resolve` becomes direct `Io.Dir`
// iteration with synchronous children; the browser context view is replaced by
// an anchored cell overlay because the terminal has no DOM/CSS context view.
// The tree behavior and data flow stay upstream-shaped.

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
const theme_colors_mod = @import("../../themeColors.zig");
const file_icon_mod = @import("../../fileIcon.zig");

// ---------------------------------------------------------------------------
// Terminal breadcrumb pickers
//
// Port of `BreadcrumbsFilePicker` and `BreadcrumbsOutlinePicker` from
// `breadcrumbsPicker.ts`. Both upstream classes use a workbench data tree in an
// anchored context view. The terminal replaces the DOM context view with an
// anchored cell overlay, but keeps the tree pipeline: `AsyncDataTree` for the
// file picker (lazy directory children) and `AsyncDataTree` over the outline
// tree snapshot for symbols. Expansion, selection, keyboard navigation and
// activation are the ported tree's behavior, not a parallel flat-list model.
// ---------------------------------------------------------------------------

const async_tree_mod = @import("../../../../base/browser/ui/tree/asyncDataTree.zig");
const outline_mod = @import("../../../services/outline/browser/outline.zig");
const goto_symbol = @import("../../../contrib/codeEditor/browser/quickaccess/gotoSymbolQuickAccess.zig");
const markerSeverity = @import("../../../../platform/markers/common/markers.zig").MarkerSeverity;

pub const FileNode = struct {
    path: []const u8,
    name: []const u8,
    is_dir: bool,
};

pub const FileInput = union(enum) {
    workspace: void,
    directory: []const u8,
};

pub const FolderRef = struct {
    path: []const u8,
    name: []const u8,
};

/// Port of upstream's `event.node` plus `event.payload.posx`: the picker is
/// anchored to the breadcrumb item rectangle, not to the mouse cursor. The
/// arrow offset still follows the cursor for mouse activation.
pub const Anchor = struct {
    start: usize,
    end: usize,
    cursor: ?usize = null,
};

pub const FileHost = struct {
    context: *anyopaque,
    io: Io,
    /// Strings/nodes created by the data source live in this arena, which the
    /// workbench resets when a new picker opens.
    arena: Allocator,
    open_file: *const fn (context: *anyopaque, path: []const u8) anyerror!void,
    file_icon: *const fn (context: *anyopaque, path: []const u8) file_icon_mod.Icon,
    request_render: *const fn (context: *anyopaque) void,
};

pub const OutlineHost = struct {
    context: *anyopaque,
    arena: Allocator,
    reveal: *const fn (context: *anyopaque, outline: *outline_mod.IOutline, element: *anyopaque) anyerror!void,
    request_render: *const fn (context: *anyopaque) void,
};

const FileTree = async_tree_mod.AsyncDataTree(FileInput, *const FileNode);
const OutlineTree = async_tree_mod.AsyncDataTree(*outline_mod.IOutline, *const outline_mod.TreeElement);

pub const FilePicker = struct {
    allocator: Allocator,
    host: FileHost,
    tree: *FileTree,
    folders: []const FolderRef = &.{},
    anchor: Anchor = .{ .start = 0, .end = 0 },
    anchor_y: usize = 0,
    arrow_offset: usize = 0,
    rect: ui.Rect = .{},
    visible: bool = false,
    theme: ?*const theme_colors_mod.ThemeColors = null,

    pub fn init(allocator: Allocator, host: FileHost) !*FilePicker {
        const self = try allocator.create(FilePicker);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .host = host,
            .tree = undefined,
        };
        self.tree = try FileTree.init(allocator, "BreadcrumbsFilePicker", .{
            .context = @ptrCast(self),
            .has_children = fileHasChildren,
            .get_children = fileGetChildren,
        }, .{
            .context = @ptrCast(self),
            .render = renderFileRow,
        }, .{
            .compression_enabled = false,
            .indent = 2,
        });
        self.tree.setActivateHandler(self, fileActivate);
        return self;
    }

    pub fn deinit(self: *FilePicker) void {
        self.tree.deinit();
        self.allocator.destroy(self);
    }

    pub fn setThemeColors(self: *FilePicker, palette: ?*const theme_colors_mod.ThemeColors) void {
        self.theme = palette;
    }

    pub fn isVisible(self: *const FilePicker) bool {
        return self.visible;
    }

    pub fn showWorkspace(self: *FilePicker, folders: []const FolderRef, focus_path: ?[]const u8) !void {
        self.folders = folders;
        _ = try self.tree.setInput(.{ .workspace = {} });
        self.finishShow(focus_path);
    }

    pub fn showDirectory(self: *FilePicker, directory: []const u8, focus_path: ?[]const u8) !void {
        self.folders = &.{};
        _ = try self.tree.setInput(.{ .directory = directory });
        self.finishShow(focus_path);
    }

    fn finishShow(self: *FilePicker, focus_path: ?[]const u8) void {
        self.tree.setFocus(true);
        if (focus_path) |path| self.selectPath(path);
        self.visible = true;
    }

    pub fn close(self: *FilePicker) void {
        if (!self.visible) return;
        self.visible = false;
        self.tree.setFocus(false);
        self.tree.clearHover();
    }

    pub fn count(self: *const FilePicker) usize {
        return self.tree.count();
    }

    pub fn selectedPath(self: *const FilePicker) ?[]const u8 {
        const element = self.tree.selectionElement() orelse return null;
        return element.path;
    }

    fn selectPath(self: *FilePicker, path: []const u8) void {
        for (0..self.tree.count()) |index| {
            const element = self.tree.renderedItem(index) orelse continue;
            if (std.mem.eql(u8, element.path, path)) {
                self.tree.setSelectionElement(element);
                return;
            }
        }
    }

    pub fn render(self: *FilePicker, grid: *ui.CellGrid) !void {
        if (!self.visible) return;
        const layout = overlayLayout(self.anchor, self.anchor_y, grid.cols, grid.rows);
        self.rect = layout.rect;
        self.arrow_offset = layout.arrow_offset;
        if (ui.cell.snap(self.rect.w) < 3 or ui.cell.snap(self.rect.h) < 3) return;
        renderOverlayFrame(grid, self.rect, self.theme, self.arrow_offset);
        self.tree.render(grid, innerRect(self.rect));
    }

    pub fn handleKey(self: *FilePicker, event: *const ui.KeyEvent) bool {
        if (!self.visible) return false;
        if (event.key == .escape) {
            self.close();
            return true;
        }
        return self.tree.handleKey(event);
    }

    pub fn handleMouse(self: *FilePicker, event: *const ui.MouseEvent) bool {
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
        const handled = self.tree.handleMouse(event);
        if ((event.kind == .down or event.kind == .click) and handled) {
            if (self.tree.selectionElement()) |node| {
                if (node.is_dir) {
                    const depth = self.tree.selectionDepth() orelse 0;
                    const twistie_x = x + 1 + depth * 2;
                    if (event.x == twistie_x) _ = self.tree.toggleCollapsed(node, false);
                }
            }
        }
        return true;
    }
};

pub const OutlinePicker = struct {
    allocator: Allocator,
    host: OutlineHost,
    tree: *OutlineTree,
    outline: ?*outline_mod.IOutline = null,
    anchor: Anchor = .{ .start = 0, .end = 0 },
    anchor_y: usize = 0,
    arrow_offset: usize = 0,
    rect: ui.Rect = .{},
    visible: bool = false,
    theme: ?*const theme_colors_mod.ThemeColors = null,

    pub fn init(allocator: Allocator, host: OutlineHost) !*OutlinePicker {
        const self = try allocator.create(OutlinePicker);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .host = host,
            .tree = undefined,
        };
        self.tree = try OutlineTree.init(allocator, "BreadcrumbsOutlinePicker", .{
            .context = @ptrCast(self),
            .has_children = outlineHasChildren,
            .get_children = outlineGetChildren,
        }, .{
            .context = @ptrCast(self),
            .render = renderOutlineRow,
        }, .{
            .compression_enabled = false,
            .indent = 2,
        });
        self.tree.setActivateHandler(self, outlineActivate);
        return self;
    }

    pub fn deinit(self: *OutlinePicker) void {
        self.tree.deinit();
        self.allocator.destroy(self);
    }

    pub fn setThemeColors(self: *OutlinePicker, palette: ?*const theme_colors_mod.ThemeColors) void {
        self.theme = palette;
    }

    pub fn isVisible(self: *const OutlinePicker) bool {
        return self.visible;
    }

    pub fn show(self: *OutlinePicker, outline: *outline_mod.IOutline, element: *anyopaque) !void {
        self.outline = outline;
        _ = try self.tree.setInput(outline);
        const source = outline.config.tree_data_source orelse {
            self.tree.setFocus(true);
            self.visible = true;
            return;
        };
        const roots = source.get_roots(source.context);
        const target = findElementInTree(roots, element) orelse {
            self.tree.setFocus(true);
            self.visible = true;
            return;
        };
        const target_element = findTreeElementById(roots, target.id) orelse {
            self.tree.setFocus(true);
            self.visible = true;
            return;
        };
        const path = try outlinePath(self.allocator, roots, target.id);
        defer self.allocator.free(path);
        for (path[0..path.len -| 1]) |ancestor| {
            _ = self.tree.expand(ancestor, false);
        }
        self.tree.setSelectionElement(target_element);
        self.tree.setFocus(true);
        self.visible = true;
    }

    pub fn close(self: *OutlinePicker) void {
        if (!self.visible) return;
        self.visible = false;
        self.tree.setFocus(false);
        self.tree.clearHover();
        self.outline = null;
    }

    pub fn count(self: *const OutlinePicker) usize {
        return self.tree.count();
    }

    pub fn selectedLabel(self: *const OutlinePicker) ?[]const u8 {
        const element = self.tree.selectionElement() orelse return null;
        return element.label;
    }

    pub fn render(self: *OutlinePicker, grid: *ui.CellGrid) !void {
        if (!self.visible) return;
        const layout = overlayLayout(self.anchor, self.anchor_y, grid.cols, grid.rows);
        self.rect = layout.rect;
        self.arrow_offset = layout.arrow_offset;
        if (ui.cell.snap(self.rect.w) < 3 or ui.cell.snap(self.rect.h) < 3) return;
        renderOverlayFrame(grid, self.rect, self.theme, self.arrow_offset);
        self.tree.render(grid, innerRect(self.rect));
    }

    pub fn handleKey(self: *OutlinePicker, event: *const ui.KeyEvent) bool {
        if (!self.visible) return false;
        if (event.key == .escape) {
            self.close();
            return true;
        }
        return self.tree.handleKey(event);
    }

    pub fn handleMouse(self: *OutlinePicker, event: *const ui.MouseEvent) bool {
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
        const handled = self.tree.handleMouse(event);
        if ((event.kind == .down or event.kind == .click) and handled) {
            if (self.tree.selectionElement()) |node| {
                if (node.children.len > 0) {
                    const depth = self.tree.selectionDepth() orelse 0;
                    const twistie_x = x + 1 + depth * 2;
                    if (event.x == twistie_x) _ = self.tree.toggleCollapsed(node, false);
                }
            }
        }
        return true;
    }
};

/// Terminal shell around the two upstream picker classes. It owns one tree at a
/// time; the workbench routes keys, mouse and rendering through it.
pub const Picker = struct {
    allocator: Allocator,
    file: ?*FilePicker = null,
    outline: ?*OutlinePicker = null,
    file_host: FileHost,
    outline_host: OutlineHost,
    theme: ?*const theme_colors_mod.ThemeColors = null,

    pub fn init(allocator: Allocator, file_host: FileHost, outline_host: OutlineHost) !*Picker {
        const self = try allocator.create(Picker);
        self.* = .{
            .allocator = allocator,
            .file_host = file_host,
            .outline_host = outline_host,
        };
        return self;
    }

    pub fn deinit(self: *Picker) void {
        if (self.file) |picker| picker.deinit();
        if (self.outline) |picker| picker.deinit();
        self.file = null;
        self.outline = null;
        self.allocator.destroy(self);
    }

    pub fn setThemeColors(self: *Picker, palette: ?*const theme_colors_mod.ThemeColors) void {
        self.theme = palette;
        if (self.file) |picker| picker.setThemeColors(palette);
        if (self.outline) |picker| picker.setThemeColors(palette);
    }

    pub fn showFileWorkspace(self: *Picker, folders: []const FolderRef, focus_path: ?[]const u8, anchor: Anchor, anchor_y: usize) !void {
        self.closeOutline();
        if (self.file == null) {
            self.file = try FilePicker.init(self.allocator, self.file_host);
            self.file.?.setThemeColors(self.theme);
        }
        self.file.?.anchor = anchor;
        self.file.?.anchor_y = anchor_y;
        try self.file.?.showWorkspace(folders, focus_path);
    }

    pub fn showFileDirectory(self: *Picker, directory: []const u8, focus_path: ?[]const u8, anchor: Anchor, anchor_y: usize) !void {
        self.closeOutline();
        if (self.file == null) {
            self.file = try FilePicker.init(self.allocator, self.file_host);
            self.file.?.setThemeColors(self.theme);
        }
        self.file.?.anchor = anchor;
        self.file.?.anchor_y = anchor_y;
        try self.file.?.showDirectory(directory, focus_path);
    }

    pub fn showOutline(self: *Picker, outline: *outline_mod.IOutline, element: *anyopaque, anchor: Anchor, anchor_y: usize) !void {
        self.closeFile();
        if (self.outline == null) {
            self.outline = try OutlinePicker.init(self.allocator, self.outline_host);
            self.outline.?.setThemeColors(self.theme);
        }
        self.outline.?.anchor = anchor;
        self.outline.?.anchor_y = anchor_y;
        try self.outline.?.show(outline, element);
    }

    pub fn isVisible(self: *const Picker) bool {
        if (self.file) |picker| if (picker.isVisible()) return true;
        if (self.outline) |picker| if (picker.isVisible()) return true;
        return false;
    }

    pub fn close(self: *Picker) void {
        self.closeFile();
        self.closeOutline();
    }

    fn closeFile(self: *Picker) void {
        if (self.file) |picker| picker.close();
    }

    fn closeOutline(self: *Picker) void {
        if (self.outline) |picker| picker.close();
    }

    pub fn render(self: *Picker, grid: *ui.CellGrid) !void {
        if (self.file) |picker| if (picker.isVisible()) return picker.render(grid);
        if (self.outline) |picker| if (picker.isVisible()) return picker.render(grid);
    }

    pub fn handleKey(self: *Picker, event: *const ui.KeyEvent) bool {
        if (self.file) |picker| if (picker.isVisible()) return picker.handleKey(event);
        if (self.outline) |picker| if (picker.isVisible()) return picker.handleKey(event);
        return false;
    }

    pub fn handleMouse(self: *Picker, event: *const ui.MouseEvent) bool {
        if (self.file) |picker| if (picker.isVisible()) return picker.handleMouse(event);
        if (self.outline) |picker| if (picker.isVisible()) return picker.handleMouse(event);
        return false;
    }
};

fn fileHasChildren(_: *anyopaque, node: *const FileNode) bool {
    return node.is_dir;
}

fn fileGetChildren(context: *anyopaque, element: async_tree_mod.DataElement(FileInput, *const FileNode)) async_tree_mod.Children(*const FileNode) {
    const self: *FilePicker = @ptrCast(@alignCast(context));
    var result = std.array_list.Managed(*const FileNode).init(self.host.arena);
    switch (element) {
        .input => |input| switch (input) {
            .workspace => {
                for (self.folders) |folder| {
                    const node = self.host.arena.create(FileNode) catch continue;
                    node.* = .{ .path = folder.path, .name = folder.name, .is_dir = true };
                    result.append(node) catch continue;
                }
            },
            .directory => |directory| appendDirectory(self, &result, directory),
        },
        .item => |node| appendDirectory(self, &result, node.path),
    }
    return .{ .items = result.toOwnedSlice() catch &.{} };
}

fn appendDirectory(self: *FilePicker, result: *std.array_list.Managed(*const FileNode), directory: []const u8) void {
    const entries = list(self.allocator, self.host.io, directory) catch return;
    defer freeEntries(self.allocator, entries);
    const arena = self.host.arena;
    for (entries) |entry| {
        const path = arena.dupe(u8, entry.path) catch continue;
        const name = arena.dupe(u8, entry.name) catch continue;
        const node = arena.create(FileNode) catch continue;
        node.* = .{ .path = path, .name = name, .is_dir = entry.is_dir };
        result.append(node) catch continue;
    }
}

fn renderFileRow(context: *anyopaque, row: *const list_mod.Row, node: *const FileTree.Node, elements: []const *FileTree.Node) void {
    _ = elements;
    const self: *FilePicker = @ptrCast(@alignCast(context));
    const item = node.element orelse return;
    const base = rowPaint(self.theme, row);
    row.grid.fillRect(@floatFromInt(row.x), @floatFromInt(row.y), @floatFromInt(row.width), 1, base);
    var col = row.x + @min(2, row.width);
    const indent_width = (node.depth -| 1) * 2;
    var indent: usize = 0;
    while (indent < indent_width and col < row.x + row.width) : (indent += 1) {
        if (row.render_indent_guides and indent % 2 == 0) {
            const guide_color = if (self.theme) |theme|
                theme.color("tree.indentGuidesStroke", .{ 80, 80, 80 })
            else
                ui.Color{ .r = 80, .g = 80, .b = 80 };
            row.grid.putCodepoint(col, row.y, 0x2502, 1, .{
                .fg = ui.cell.packColor(guide_color),
                .bg = base.bg,
            });
        } else {
            row.grid.putSpace(col, row.y, base);
        }
        col += 1;
    }
    if (col < row.x + row.width) {
        if (node.has_children) {
            row.grid.putCodepoint(col, row.y, if (node.collapsed) 0x25B8 else 0x25BE, 1, base);
        } else {
            row.grid.putCodepoint(col, row.y, ' ', 1, base);
        }
        col += 1;
        if (col < row.x + row.width) {
            row.grid.putCodepoint(col, row.y, ' ', 1, base);
            col += 1;
        }
    }
    const icon = self.host.file_icon(self.host.context, item.path);
    if (col < row.x + row.width) {
        row.grid.putCodepoint(col, row.y, icon.glyph, 1, .{
            .fg = ui.cell.packColor(icon.color),
            .bg = base.bg,
        });
        col += 1;
        if (col < row.x + row.width) {
            row.grid.putCodepoint(col, row.y, ' ', 1, base);
            col += 1;
        }
    }
    _ = drawTextClipped(row.grid, col, row.y, row.x + row.width -| col, item.name, base);
}

fn fileActivate(context: ?*anyopaque, element: *const FileNode) void {
    const self: *FilePicker = @ptrCast(@alignCast(context orelse return));
    if (element.is_dir) {
        _ = self.tree.toggleCollapsed(element, false);
        return;
    }
    self.close();
    self.host.open_file(self.host.context, element.path) catch {};
}

fn outlineHasChildren(_: *anyopaque, node: *const outline_mod.TreeElement) bool {
    return node.children.len > 0;
}

fn outlineGetChildren(context: *anyopaque, element: async_tree_mod.DataElement(*outline_mod.IOutline, *const outline_mod.TreeElement)) async_tree_mod.Children(*const outline_mod.TreeElement) {
    const self: *OutlinePicker = @ptrCast(@alignCast(context));
    const children = switch (element) {
        .input => |outline| blk: {
            const source = outline.config.tree_data_source orelse break :blk &.{};
            break :blk source.get_roots(source.context);
        },
        .item => |node| node.children,
    };
    const result = self.host.arena.alloc(*const outline_mod.TreeElement, children.len) catch return .{ .items = &.{} };
    for (children, 0..) |_, index| result[index] = &children[index];
    return .{ .items = result };
}

fn renderOutlineRow(context: *anyopaque, row: *const list_mod.Row, node: *const OutlineTree.Node, elements: []const *OutlineTree.Node) void {
    _ = elements;
    const self: *OutlinePicker = @ptrCast(@alignCast(context));
    const item = node.element orelse return;
    const base = rowPaint(self.theme, row);
    row.grid.fillRect(@floatFromInt(row.x), @floatFromInt(row.y), @floatFromInt(row.width), 1, base);
    var col = row.x + @min(2, row.width);
    const indent_width = (node.depth -| 1) * 2;
    var indent: usize = 0;
    while (indent < indent_width and col < row.x + row.width) : (indent += 1) {
        if (row.render_indent_guides and indent % 2 == 0) {
            const guide_color = if (self.theme) |theme|
                theme.color("tree.indentGuidesStroke", .{ 80, 80, 80 })
            else
                ui.Color{ .r = 80, .g = 80, .b = 80 };
            row.grid.putCodepoint(col, row.y, 0x2502, 1, .{
                .fg = ui.cell.packColor(guide_color),
                .bg = base.bg,
            });
        } else {
            row.grid.putSpace(col, row.y, base);
        }
        col += 1;
    }
    if (col < row.x + row.width) {
        if (node.has_children) {
            row.grid.putCodepoint(col, row.y, if (node.collapsed) 0x25B8 else 0x25BE, 1, base);
        } else {
            row.grid.putCodepoint(col, row.y, ' ', 1, base);
        }
        col += 1;
        if (col < row.x + row.width) {
            row.grid.putCodepoint(col, row.y, ' ', 1, base);
            col += 1;
        }
    }
    if (col < row.x + row.width) {
        const glyph = goto_symbol.glyph(item.symbol_kind orelse 0);
        col += drawTextClipped(row.grid, col, row.y, row.x + row.width -| col, glyph, base);
        if (col < row.x + row.width) {
            row.grid.putCodepoint(col, row.y, ' ', 1, base);
            col += 1;
        }
    }
    col += drawTextClipped(row.grid, col, row.y, row.x + row.width -| col, item.label, base);
    if (item.marker_severity) |severity| {
        var buf: [8]u8 = undefined;
        const badge = if (item.marker_count > 0)
            std.fmt.bufPrint(&buf, "{d}", .{@min(item.marker_count, 9)}) catch "+"
        else
            "\u{25CF}";
        const badge_width = textWidth(badge);
        if (row.x + row.width > badge_width + 1) {
            const badge_col = row.x + row.width -| badge_width -| 1;
            const color = if (severity == markerSeverity.Error)
                if (self.theme) |theme| theme.color("list.errorForeground", .{ 244, 135, 113 }) else ui.Color{ .r = 244, .g = 135, .b = 113 }
            else if (self.theme) |theme| theme.color("list.warningForeground", .{ 204, 167, 0 }) else ui.Color{ .r = 204, .g = 167, .b = 0 };
            _ = drawTextClipped(row.grid, badge_col, row.y, row.width -| (badge_col - row.x), badge, .{
                .fg = ui.cell.packColor(color),
                .bg = base.bg,
            });
        }
    }
}

fn outlineActivate(context: ?*anyopaque, element: *const outline_mod.TreeElement) void {
    const self: *OutlinePicker = @ptrCast(@alignCast(context orelse return));
    const outline = self.outline orelse return;
    self.close();
    self.host.reveal(self.host.context, outline, element.element) catch {};
}

fn rowPaint(theme: ?*const theme_colors_mod.ThemeColors, row: *const list_mod.Row) ui.cell.PaintStyle {
    var bg = if (theme) |palette| palette.color("menu.background", .{ 37, 37, 38 }) else ui.Color{ .r = 37, .g = 37, .b = 38 };
    var fg = if (theme) |palette| palette.color("menu.foreground", .{ 204, 204, 204 }) else ui.Color{ .r = 204, .g = 204, .b = 204 };
    if (row.selected) {
        bg = if (theme) |palette| palette.color("list.activeSelectionBackground", .{ 4, 57, 94 }) else ui.Color{ .r = 4, .g = 57, .b = 94 };
        fg = .{ .r = 255, .g = 255, .b = 255 };
    } else if (row.hovered) {
        bg = if (theme) |palette| palette.color("list.hoverBackground", .{ 42, 45, 46 }) else ui.Color{ .r = 42, .g = 45, .b = 46 };
    }
    return .{ .fg = ui.cell.packColor(fg), .bg = ui.cell.packColor(bg) };
}

const OverlayLayout = struct {
    rect: ui.Rect,
    arrow_offset: usize,
};

/// Port of the context-view anchor math: left edge from the breadcrumb item,
/// arrow from the mouse cursor (or 30% into the item for keyboard activation).
fn overlayLayout(anchor: Anchor, anchor_y: usize, cols: usize, rows: usize) OverlayLayout {
    const width = @min(@max(cols -| 4, 20), 64);
    const height = @min(@max(rows -| 3, 4), 14);
    var x = anchor.start;
    if (x + width > cols) x = cols -| width;
    var arrow_offset = if (anchor.cursor) |cursor| cursor -| x else blk: {
        const item_width = anchor.end -| anchor.start;
        break :blk (anchor.start + item_width * 3 / 10) -| x;
    };
    const max_arrow = width -| 2;
    if (arrow_offset > max_arrow) {
        x = @min(cols -| width, x + arrow_offset - max_arrow);
        arrow_offset = max_arrow;
    }
    var y = anchor_y + 1;
    if (y + height > rows) y = anchor_y -| height;
    if (y + height > rows) y = rows -| height;
    return .{
        .rect = .{
            .x = @floatFromInt(x),
            .y = @floatFromInt(y),
            .w = @floatFromInt(width),
            .h = @floatFromInt(height),
        },
        .arrow_offset = arrow_offset,
    };
}

fn innerRect(rect: ui.Rect) ui.Rect {
    return .{
        .x = rect.x + 1,
        .y = rect.y + 1,
        .w = @max(rect.w - 2, 1),
        .h = @max(rect.h - 2, 1),
    };
}

fn renderOverlayFrame(grid: *ui.CellGrid, rect: ui.Rect, theme: ?*const theme_colors_mod.ThemeColors, arrow_offset: usize) void {
    const x = ui.cell.snap(rect.x);
    const y = ui.cell.snap(rect.y);
    const width = ui.cell.snap(rect.w);
    const height = ui.cell.snap(rect.h);
    if (width < 3 or height < 3) return;
    const bg = if (theme) |palette| palette.color("menu.background", .{ 37, 37, 38 }) else ui.Color{ .r = 37, .g = 37, .b = 38 };
    const fg = if (theme) |palette| palette.color("menu.foreground", .{ 204, 204, 204 }) else ui.Color{ .r = 204, .g = 204, .b = 204 };
    const border = if (theme) |palette| palette.color("widget.border", .{ 69, 69, 69 }) else ui.Color{ .r = 69, .g = 69, .b = 69 };
    const background = ui.cell.PaintStyle{ .bg = ui.cell.packColor(bg), .fg = ui.cell.packColor(fg) };
    const border_style = ui.cell.PaintStyle{ .bg = ui.cell.packColor(bg), .fg = ui.cell.packColor(border) };
    grid.fillRect(rect.x, rect.y, rect.w, rect.h, background);
    grid.clearBordersRect(rect.x, rect.y, rect.w, rect.h);
    grid.putCodepoint(x, y, 0x250C, 1, border_style);
    grid.putCodepoint(x + width - 1, y, 0x2510, 1, border_style);
    grid.putCodepoint(x, y + height - 1, 0x2514, 1, border_style);
    grid.putCodepoint(x + width - 1, y + height - 1, 0x2518, 1, border_style);
    var col: usize = 1;
    while (col + 1 < width) : (col += 1) {
        grid.putCodepoint(x + col, y, 0x2500, 1, border_style);
        grid.putCodepoint(x + col, y + height - 1, 0x2500, 1, border_style);
    }
    var row: usize = 1;
    while (row + 1 < height) : (row += 1) {
        grid.putCodepoint(x, y + row, 0x2502, 1, border_style);
        grid.putCodepoint(x + width - 1, y + row, 0x2502, 1, border_style);
    }
    const arrow = x + @min(arrow_offset, width -| 2);
    grid.putCodepoint(arrow, y, 0x25B2, 1, border_style);
}

fn findElementInTree(roots: []const outline_mod.TreeElement, element: *anyopaque) ?outline_mod.TreeElement {
    for (roots) |root| {
        if (root.element == element) return root;
        if (findElementInTree(root.children, element)) |found| return found;
    }
    return null;
}

fn findTreeElementById(roots: []const outline_mod.TreeElement, id: []const u8) ?*const outline_mod.TreeElement {
    for (roots) |*root| {
        if (std.mem.eql(u8, root.id, id)) return root;
        if (findTreeElementById(root.children, id)) |found| return found;
    }
    return null;
}

fn outlinePath(allocator: Allocator, roots: []const outline_mod.TreeElement, id: []const u8) ![]const *const outline_mod.TreeElement {
    var path = std.array_list.Managed(*const outline_mod.TreeElement).init(allocator);
    errdefer path.deinit();
    for (roots) |*root| {
        if (try appendPath(&path, root, id)) return path.toOwnedSlice();
    }
    return path.toOwnedSlice();
}

fn appendPath(path: *std.array_list.Managed(*const outline_mod.TreeElement), element: *const outline_mod.TreeElement, id: []const u8) !bool {
    try path.append(element);
    if (std.mem.eql(u8, element.id, id)) return true;
    for (element.children) |*child| {
        if (try appendPath(path, child, id)) return true;
    }
    _ = path.pop();
    return false;
}

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
