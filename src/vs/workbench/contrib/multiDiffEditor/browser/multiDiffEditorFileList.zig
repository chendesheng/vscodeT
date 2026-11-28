// Port of `src/vs/workbench/contrib/multiDiffEditor/browser/multiDiffEditorFileList.ts`.
// The terminal uses the existing CompressibleObjectTree/List delegate and
// row renderer instead of DOM templates. Model and viewport events drive
// contents and selection; no render-time model scan is needed.
const std = @import("std");
const ui = @import("ui");
const Allocator = std.mem.Allocator;
const common = @import("../common/multiDiffEditor.zig");
const css = @import("media/multiDiffEditorWithFileList_css.zig");
const widget_mod = @import("../../../../editor/browser/widget/multiDiffEditor/multiDiffEditorWidget.zig");
const model = @import("../../../../editor/browser/widget/multiDiffEditor/multiDiffEditorViewModel.zig");
const std_uri = @import("../../../../base/common/stdUri.zig");
const ResourceTree = @import("../../../../base/common/resourceTree.zig").ResourceTree;
const object_tree = @import("../../../../base/browser/ui/tree/compressibleObjectTree.zig");
const list_mod = @import("../../../../base/browser/ui/list/list.zig");
const list_service = @import("../../../../platform/list/browser/listService.zig");
const event = @import("../../../../base/common/event.zig");
const Workspace = @import("../../../services/workspaces/common/workspaceContextService.zig").WorkspaceContextService;
const ThemeColors = @import("../../../browser/themeColors.zig").ThemeColors;
const file_icon = @import("../../../services/themes/browser/fileIconThemeData.zig");

pub const MultiDiffFileStatus = enum {
    added,
    deleted,
    modified,
    renamed,
    pub fn letter(self: MultiDiffFileStatus) u21 {
        return switch (self) {
            .added => 'A',
            .deleted => 'D',
            .modified => 'M',
            .renamed => 'R',
        };
    }
    pub fn label(self: MultiDiffFileStatus) []const u8 {
        return switch (self) {
            .added => "Added",
            .deleted => "Deleted",
            .modified => "Modified",
            .renamed => "Renamed",
        };
    }
};

pub fn getItemUri(item: *model.DocumentDiffItemViewModel) std.Uri {
    const doc = item.documentDiffItem;
    return (doc.modified orelse doc.original.?).uri;
}

pub fn getFileStatus(item: *model.DocumentDiffItemViewModel, arena: Allocator) !MultiDiffFileStatus {
    const doc = item.documentDiffItem;
    const original = doc.original orelse return .added;
    const modified = doc.modified orelse return .deleted;
    return if (std.mem.eql(u8, try std_uri.path(original.uri, arena), try std_uri.path(modified.uri, arena))) .modified else .renamed;
}

fn parentPath(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "/";
    return if (slash == 0) "/" else path[0..slash];
}
fn basename(path: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| path[slash + 1 ..] else path;
}
fn isParent(parent: []const u8, path: []const u8) bool {
    if (parent.len == 1 and parent[0] == '/') return true;
    if (path.len < parent.len) return false;
    const equal = if (@import("builtin").os.tag == .windows) std.ascii.eqlIgnoreCase(parent, path[0..parent.len]) else std.mem.eql(u8, parent, path[0..parent.len]);
    return equal and (path.len == parent.len or path[parent.len] == '/');
}

pub fn getCommonFolderPath(paths: []const []const u8) []const u8 {
    if (paths.len == 0) return "/";
    var common_path = parentPath(paths[0]);
    for (paths[1..]) |path| {
        const parent = parentPath(path);
        while (!isParent(common_path, parent)) {
            if (std.mem.eql(u8, common_path, "/")) break;
            common_path = parentPath(common_path);
        }
    }
    return common_path;
}

pub fn MultiDiffEditorFileList(comptime View: type) type {
    return struct {
        const Self = @This();
        const Widget = widget_mod.MultiDiffEditorWidget(View);
        pub const FileRow = struct {
            item: *model.DocumentDiffItemViewModel,
            path: []const u8,
            name: []const u8,
            description: []const u8,
            status: MultiDiffFileStatus,
            element: ElementData,
        };
        pub const FolderRow = struct { path: []const u8, name: []const u8, element: ElementData };
        pub const ElementData = union(enum) { file: *FileRow, folder: *FolderRow };
        pub const Element = *const ElementData;
        pub const Tree = object_tree.CompressibleObjectTree(Element);
        const PathTree = ResourceTree(std.ArrayList(*FileRow), void);
        pub const Host = struct { context: *anyopaque, focus_diff: *const fn (*anyopaque) void };

        allocator: Allocator,
        widget: *Widget,
        workspace: ?*Workspace,
        host: Host,
        tree: *Tree,
        list_focus: list_service.ListFocus,
        arena: std.heap.ArenaAllocator,
        files: []*FileRow = &.{},
        folders: []*FolderRow = &.{},
        model_value: ?*model.MultiDiffEditorViewModel = null,
        model_listener: ?event.SignalSubscription = null,
        layout_listener: ?event.SignalSubscription = null,
        workspace_listener: ?event.SignalSubscription = null,
        mode: common.MultiDiffEditorFileListViewMode,
        theme: ?*const ThemeColors = null,
        last_error: ?anyerror = null,
        last_clicked_item: ?*model.DocumentDiffItemViewModel = null,
        last_click_time: i64 = 0,

        pub fn create(allocator: Allocator, widget: *Widget, workspace: ?*Workspace, lists: ?*list_service.ListService, host: Host, mode: common.MultiDiffEditorFileListViewMode) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            const tree = try Tree.init(allocator, "MultiDiffEditorFileList", true, .{ .context = self, .render = renderRow }, .{});
            errdefer tree.deinit();
            self.* = .{
                .allocator = allocator,
                .widget = widget,
                .workspace = workspace,
                .host = host,
                .tree = tree,
                .list_focus = .init(allocator),
                .arena = std.heap.ArenaAllocator.init(allocator),
                .mode = mode,
            };
            errdefer {
                self.detachListeners();
                self.list_focus.deinit();
                self.arena.deinit();
            }
            tree.setActivateHandler(self, onActivate);
            self.layout_listener = try widget.on_did_change_layout.listenDisposable(self, onLayout);
            if (workspace) |service| self.workspace_listener = try service.on_did_add_folder.listenDisposable(self, onWorkspaceFolder);
            if (lists) |service| try service.register(.{ .context = self, .focus = &self.list_focus, .run = runListCommand });
            try self.setModel(widget.getViewModel());
            return self;
        }
        fn detachListeners(self: *Self) void {
            if (self.model_listener) |listener| listener.dispose();
            if (self.layout_listener) |listener| listener.dispose();
            if (self.workspace_listener) |listener| listener.dispose();
            self.model_listener = null;
            self.layout_listener = null;
            self.workspace_listener = null;
        }
        pub fn destroy(self: *Self) void {
            self.detachListeners();
            self.list_focus.deinit();
            self.tree.deinit();
            self.arena.deinit();
            self.allocator.destroy(self);
        }
        pub fn setWorkspace(self: *Self, workspace: ?*Workspace) !void {
            if (self.workspace == workspace) return;
            if (self.workspace_listener) |listener| listener.dispose();
            self.workspace_listener = null;
            self.workspace = workspace;
            if (workspace) |service| self.workspace_listener = try service.on_did_add_folder.listenDisposable(self, onWorkspaceFolder);
            try self.rebuild();
        }
        pub fn setModel(self: *Self, value: ?*model.MultiDiffEditorViewModel) !void {
            if (self.model_value == value) return;
            if (self.model_listener) |listener| listener.dispose();
            self.model_listener = null;
            self.model_value = value;
            if (value) |vm| self.model_listener = try vm.on_did_change_items.listenDisposable(self, onItems);
            try self.rebuild();
        }
        fn onItems(_: void, self: *Self) !void {
            try self.rebuild();
        }
        fn onLayout(_: void, self: *Self) !void {
            if (self.model_value != self.widget.getViewModel()) {
                // The pane explicitly calls setModel when attaching; variant
                // replacement preserves that model and does not rebuild rows.
                return;
            }
            self.syncSelection();
        }
        fn onWorkspaceFolder(_: []const u8, self: *Self) !void {
            try self.rebuild();
        }
        pub fn setMode(self: *Self, mode: common.MultiDiffEditorFileListViewMode) !void {
            if (self.mode == mode) return;
            self.mode = mode;
            try self.rebuild();
        }
        fn workspaceRoot(self: *Self, arena: Allocator, common_path: []const u8) ![]const u8 {
            const workspace = self.workspace orelse return common_path;
            const URI = @import("../../../../base/common/uri.zig").URI;
            for (workspace.getWorkspace().folders.items) |folder| {
                var uri = try URI.file(arena, folder.resource);
                defer uri.deinit();
                if (isParent(uri.path, common_path)) return common_path[0..uri.path.len];
            }
            return common_path;
        }
        fn fileDescription(self: *Self, arena: Allocator, path: []const u8) ![]const u8 {
            const dirname = parentPath(path);
            const root = try self.workspaceRoot(arena, dirname);
            if (self.workspace != null and !std.mem.eql(u8, root, dirname)) return std.mem.trimStart(u8, dirname[root.len..], "/");
            // For files directly in a workspace folder show no description.
            if (self.workspace) |workspace| for (workspace.getWorkspace().folders.items) |folder| {
                var uri = try @import("../../../../base/common/uri.zig").URI.file(arena, folder.resource);
                defer uri.deinit();
                if (std.mem.eql(u8, uri.path, dirname)) return "";
            };
            return dirname;
        }
        fn rebuild(self: *Self) !void {
            var next = std.heap.ArenaAllocator.init(self.allocator);
            errdefer next.deinit();
            const a = next.allocator();
            var collapsed: std.StringHashMap(bool) = .init(a);
            for (self.folders) |folder| try collapsed.put(folder.path, self.tree.isCollapsed(&folder.element));
            const items = if (self.model_value) |vm| vm.items else &.{};
            const sorted = try common.sortMultiDiffEditorFileListItems(*model.DocumentDiffItemViewModel, a, items, getItemUri, self.mode);
            const files = try a.alloc(*FileRow, sorted.len);
            const paths = try a.alloc([]const u8, sorted.len);
            for (sorted, files, paths) |item, *file, *path| {
                path.* = try a.dupe(u8, try std_uri.path(getItemUri(item), a));
                file.* = try a.create(FileRow);
                file.*.* = .{ .item = item, .path = path.*, .name = basename(path.*), .description = try self.fileDescription(a, path.*), .status = try getFileStatus(item, a), .element = .{ .file = file.* } };
            }
            var folders: std.ArrayList(*FolderRow) = .empty;
            var elements: std.ArrayList(Tree.Element) = .empty;
            if (self.mode == .list or files.len == 0) {
                for (files) |file| try elements.append(a, .{ .element = &file.element, .incompressible = true });
            } else {
                const root = try self.workspaceRoot(a, getCommonFolderPath(paths));
                var path_tree = try PathTree.init(a, {}, root);
                defer path_tree.deinit();
                for (files) |file| {
                    if (path_tree.getNode(file.path)) |node| {
                        if (node.element) |*bucket| {
                            try bucket.append(a, file);
                            continue;
                        }
                    }
                    var bucket: std.ArrayList(*FileRow) = .empty;
                    try bucket.append(a, file);
                    _ = try path_tree.add(file.path, bucket);
                }
                try appendTreeElements(a, path_tree.root, &elements, &folders, &collapsed);
            }
            self.tree.setChildren(null, elements.items) catch |err| {
                self.tree.setChildren(null, &.{}) catch {};
                return err;
            };
            var previous = self.arena;
            self.arena = next;
            self.files = files;
            self.folders = folders.items;
            self.last_clicked_item = null;
            previous.deinit();
            self.syncSelection();
        }
        fn appendTreeElements(a: Allocator, node: *PathTree.NodeType, out: *std.ArrayList(Tree.Element), folders: *std.ArrayList(*FolderRow), collapsed: *const std.StringHashMap(bool)) !void {
            for (node.childNodes()) |child| {
                if (child.element) |bucket| for (bucket.items) |file| try out.append(a, .{ .element = &file.element, .incompressible = true });
                if (child.childrenCount() == 0) continue;
                const folder = try a.create(FolderRow);
                folder.* = .{ .path = try a.dupe(u8, child.path), .name = try a.dupe(u8, child.name), .element = .{ .folder = folder } };
                try folders.append(a, folder);
                var children: std.ArrayList(Tree.Element) = .empty;
                try appendTreeElements(a, child, &children, folders, collapsed);
                try out.append(a, .{ .element = &folder.element, .children = children.items, .collapsible = true, .collapsed = collapsed.get(folder.path) orelse false });
            }
        }
        pub fn currentSelection(self: *Self) ?*model.DocumentDiffItemViewModel {
            const selected = self.tree.selectionElement() orelse return null;
            return switch (selected.*) {
                .file => |file| file.item,
                .folder => null,
            };
        }
        fn syncSelection(self: *Self) void {
            const item = self.widget.impl.currentVisibleItem() orelse {
                self.tree.setSelectionElement(null);
                return;
            };
            if (self.currentSelection() == item) return;
            for (self.files) |file| if (file.item == item) {
                // Expand ancestors of a newly revealed resource, like the
                // tree's reveal operation, while preserving other folders.
                const element: Element = &file.element;
                var node = self.tree.model.getNode(element) catch null;
                while (node) |current| : (node = current.parent) {
                    if (current.parent) |ancestor| if (Tree.elementOfNode(ancestor)) |parent| {
                        _ = self.tree.setCollapsed(parent, false, false) catch {};
                    };
                }
                self.tree.setSelectionElement(element);
                return;
            };
            self.tree.setSelectionElement(null);
        }
        pub fn focus(self: *Self, value: bool) void {
            if (value and self.tree.selectionElement() == null and self.tree.count() != 0) self.tree.setSelectionNode(self.tree.renderedNode(0));
            self.tree.setFocus(value);
            self.list_focus.setFocused(value);
        }
        pub fn isFocused(self: *const Self) bool {
            return self.list_focus.focused;
        }
        pub fn render(self: *Self, grid: *ui.CellGrid, rect: ui.Rect) void {
            const background = self.color(css.background, .{ .r = 30, .g = 30, .b = 30 });
            grid.fillRect(rect.x, rect.y, rect.w, rect.h, .{ .bg = ui.cell.packColor(background) });
            self.tree.render(grid, rect);
        }
        pub fn handleKey(self: *Self, input: *const ui.KeyEvent) bool {
            return self.tree.handleKey(input);
        }
        pub fn handleMouse(self: *Self, input: *const ui.MouseEvent) bool {
            const handled = self.tree.handleMouse(input);
            if (handled and input.kind == .down and input.button == .left) {
                if (self.tree.selectionElement()) |element| switch (element.*) {
                    .file => |file| {
                        const now = @import("../../../../base/common/timeCompat.zig").milliTimestamp(self.widget.impl.queue.io);
                        const double_click = self.last_clicked_item == file.item and now - self.last_click_time <= 300;
                        self.last_clicked_item = if (double_click) null else file.item;
                        self.last_click_time = now;
                        self.open(file.item, !double_click) catch |err| {
                            self.last_error = err;
                        };
                    },
                    .folder => {
                        _ = self.tree.setCollapsed(element, !self.tree.isCollapsed(element), false) catch {};
                    },
                };
            }
            return handled;
        }
        fn runListCommand(context: *anyopaque, operation: list_service.Navigation) !void {
            const self: *Self = @ptrCast(@alignCast(context));
            _ = self.handleKey(&.{ .key = operation.key() });
        }
        fn onActivate(context: ?*anyopaque, element: Element) void {
            const self: *Self = @ptrCast(@alignCast(context orelse return));
            switch (element.*) {
                .file => |file| self.open(file.item, false) catch |err| {
                    self.last_error = err;
                },
                .folder => {
                    _ = self.tree.setCollapsed(element, !self.tree.isCollapsed(element), false) catch {};
                },
            }
        }
        pub fn open(self: *Self, item: *model.DocumentDiffItemViewModel, preserve_focus: bool) !void {
            const vm = self.model_value orelse return;
            if (std.mem.indexOfScalar(*model.DocumentDiffItemViewModel, vm.items, item) == null) return;
            if (!preserve_focus and item.collapsed) try item.setCollapsed(false);
            const doc = item.documentDiffItem;
            try self.widget.reveal(.{ .original = if (doc.original) |side| side.uri else null, .modified = if (doc.modified) |side| side.uri else null }, null);
            if (!preserve_focus) self.host.focus_diff(self.host.context);
        }
        pub fn widgetAriaLabel(allocator: Allocator, screen_reader_optimized: bool, verbosity: bool, help_keybinding: ?[]const u8) ![]u8 {
            if (!screen_reader_optimized or !verbosity) return allocator.dupe(u8, "Changed Files");
            if (help_keybinding) |binding| return std.fmt.allocPrint(allocator, "Changed Files, use {s} for accessibility help", .{binding});
            return allocator.dupe(u8, "Changed Files, run the Open Accessibility Help command for more information");
        }
        pub fn getAriaLabel(self: *Self, allocator: Allocator, element: Element) ![]u8 {
            _ = self;
            return switch (element.*) {
                .folder => |folder| allocator.dupe(u8, std.mem.trimStart(u8, folder.path, "/")),
                .file => |file| std.fmt.allocPrint(allocator, "{s}, {s}, {s}", .{ file.name, file.status.label(), file.description }),
            };
        }
        fn color(self: *Self, name: []const u8, fallback: ui.Color) ui.Color {
            return if (self.theme) |palette| palette.color(name, .{ fallback.r, fallback.g, fallback.b }) else fallback;
        }
        fn renderRow(context: *anyopaque, row: *const list_mod.Row, node: *const Tree.Node) void {
            const self: *Self = @ptrCast(@alignCast(context));
            const actual = node.element orelse return;
            if (actual.elements.len == 0) return;
            const element = actual.elements[actual.elements.len - 1];
            var bg = self.color(css.background, .{ .r = 30, .g = 30, .b = 30 });
            var fg = self.color("editor.foreground", .{ .r = 204, .g = 204, .b = 204 });
            if (row.selected) {
                bg = self.color(if (row.focused_selection) "list.activeSelectionBackground" else "list.inactiveSelectionBackground", if (row.focused_selection) .{ .r = 4, .g = 57, .b = 94 } else .{ .r = 55, .g = 55, .b = 61 });
                if (row.focused_selection) fg = self.color("list.activeSelectionForeground", .{ .r = 255, .g = 255, .b = 255 });
            } else if (row.hovered) {
                bg = self.color("list.hoverBackground", .{ .r = 42, .g = 45, .b = 46 });
                fg = self.color("list.hoverForeground", .{ .r = 255, .g = 255, .b = 255 });
            }
            const paint: ui.cell.PaintStyle = .{ .bg = ui.cell.packColor(bg), .fg = ui.cell.packColor(fg) };
            row.grid.fillRect(@floatFromInt(row.x), @floatFromInt(row.y), @floatFromInt(row.width), 1, paint);
            const right = row.x + row.width -| css.padding;
            var x = row.x + css.padding + (node.depth -| 1) * 2;
            if (x >= right) return;
            if (node.collapsible) row.grid.putCodepoint(x, row.y, if (node.collapsed) '▸' else '▾', 1, paint);
            x += 2;
            if (x >= right) return;
            switch (element.*) {
                .file => |file| {
                    const icon = file_icon.file(file.name);
                    row.grid.putCodepoint(x, row.y, icon.glyph, 1, .{ .fg = ui.cell.packColor(icon.color), .bg = paint.bg });
                    x += 2;
                    const status_x = right -| 1;
                    if (x < status_x -| css.status_gap) {
                        var label_paint = paint;
                        if (file.status == .deleted) label_paint.attrs |= ui.cell.Attr.strikethrough;
                        x += drawText(row.grid, x, row.y, status_x - css.status_gap - x, file.name, label_paint);
                        if (self.mode == .list and file.description.len != 0 and x + 1 < status_x) {
                            x += 1;
                            _ = drawText(row.grid, x, row.y, status_x - x, file.description, .{ .fg = ui.cell.packColor(self.color("descriptionForeground", .{ .r = 145, .g = 145, .b = 145 })), .bg = paint.bg });
                        }
                    }
                    const status_color = switch (file.status) {
                        .added => self.color(css.added_foreground, .{ .r = 129, .g = 184, .b = 139 }),
                        .deleted => self.color(css.deleted_foreground, .{ .r = 241, .g = 76, .b = 76 }),
                        .modified, .renamed => self.color(css.modified_foreground, .{ .r = 226, .g = 192, .b = 141 }),
                    };
                    if (status_x >= row.x) row.grid.putCodepoint(status_x, row.y, file.status.letter(), 1, .{ .fg = ui.cell.packColor(status_color), .bg = paint.bg, .attrs = ui.cell.Attr.bold });
                },
                .folder => {
                    const icon = file_icon.folder(!node.collapsed);
                    row.grid.putCodepoint(x, row.y, icon.glyph, 1, .{ .fg = ui.cell.packColor(icon.color), .bg = paint.bg });
                    x += 2;
                    for (actual.elements, 0..) |part, index| {
                        if (x >= right) break;
                        if (index != 0) {
                            row.grid.putCodepoint(x, row.y, '/', 1, paint);
                            x += 1;
                        }
                        if (part.* == .folder) x += drawText(row.grid, x, row.y, right -| x, part.folder.name, paint);
                    }
                },
            }
        }
    };
}

fn drawText(grid: *ui.CellGrid, x: usize, y: usize, width: usize, text: []const u8, style: ui.cell.PaintStyle) usize {
    var offset: usize = 0;
    var column: usize = 0;
    while (offset < text.len and column < width) {
        const decoded = ui.dom.decodeAt(text, offset);
        const size = ui.dom.defaultMeasureWidth(decoded.cp);
        if (column + size > width) break;
        grid.putCodepoint(x + column, y, decoded.cp, size, style);
        column += size;
        offset += decoded.len;
    }
    if (offset < text.len and column < width) {
        grid.putCodepoint(x + column, y, '…', 1, style);
        column += 1;
    }
    return column;
}
