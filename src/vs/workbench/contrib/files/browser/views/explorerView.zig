//! Terminal Explorer view over the ported list/tree layer.
//!
//! This replaces the ad-hoc visible-row painting with a `CompressibleObjectTree`
//! backed by `CompressedObjectTreeModel(*ExplorerItem)`: virtualization,
//! selection, focus, keyboard/mouse scrolling, collapse state and
//! `explorer.compactFolders` come from the ported base tree views. The portable
//! Explorer model, ignore filtering and lazy directory resolution are shared
//! with the upstream-shaped `FilesFilter` in
//! `vs/workbench/contrib/files/browser/views/explorerViewer.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ui = @import("ui");
const explorer = @import("../../common/explorerModel.zig");
const workspace_context = @import("../../../../services/workspaces/common/workspaceContextService.zig");
const configuration_mod = @import("../../../../services/configuration/browser/configurationService.zig");
const explorer_viewer = @import("./explorerViewer.zig");
const compressible_tree = @import("../../../../../base/browser/ui/tree/compressibleObjectTree.zig");
const list = @import("../../../../../base/browser/ui/list/list.zig");
const tree = @import("../../../../../base/browser/ui/tree/tree.zig");

const ExplorerItem = explorer.ExplorerItem;
const ExplorerModel = explorer.ExplorerModel;
const FilesFilter = explorer_viewer.FilesFilter;
const WorkspaceContextService = workspace_context.WorkspaceContextService;
const ConfigurationService = configuration_mod.ConfigurationService;
const CompressibleTree = compressible_tree.CompressibleObjectTree(*ExplorerItem);
const CompressedElement = CompressibleTree.Element;

const CellGrid = ui.CellGrid;
const PaintStyle = ui.cell.PaintStyle;
const theme_colors_mod = @import("../../../../browser/themeColors.zig");

const header_style = PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 200, .g = 200, .b = 200 }),
    .bg = ui.cell.packColor(.{ .r = 38, .g = 38, .b = 42 }),
};
const text_style = PaintStyle{ .fg = ui.cell.packColor(.{ .r = 190, .g = 190, .b = 190 }) };
const dir_style = PaintStyle{ .fg = ui.cell.packColor(.{ .r = 170, .g = 190, .b = 210 }) };
const selected_style = PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 245, .g = 245, .b = 245 }),
    .bg = ui.cell.packColor(.{ .r = 55, .g = 65, .b = 80 }),
};
const selected_dir_style = PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 220, .g = 235, .b = 255 }),
    .bg = selected_style.bg,
};
const unfocused_selection_style = PaintStyle{
    .fg = text_style.fg,
    .bg = ui.cell.packColor(.{ .r = 45, .g = 48, .b = 58 }),
};
const unfocused_dir_selection_style = PaintStyle{
    .fg = dir_style.fg,
    .bg = unfocused_selection_style.bg,
};
const scrollbar_track_style = PaintStyle{
    .bg = ui.cell.packColor(.{ .r = 30, .g = 32, .b = 40 }),
};
const scrollbar_thumb_style = PaintStyle{
    .bg = ui.cell.packColor(.{ .r = 105, .g = 108, .b = 122 }),
};

pub const Action = union(enum) {
    none,
    handled,
    open: []const u8,
};

/// Terminal view options. The side bar part owns the title area, so the
/// workbench renders the content without the view's own section header.
pub const RenderOptions = struct {
    show_header: bool = true,
};

pub const Sidebar = struct {
    allocator: Allocator,
    io: Io,
    model: *ExplorerModel,
    files_filter: FilesFilter,
    tree: *CompressibleTree,
    compression_enabled: bool = true,
    /// Directories force-expanded once by `autoExpandCompressedChildren`.
    force_expanded: std.AutoHashMap(*ExplorerItem, void),
    sort_order: explorer.SortOrder = .FilesFirst,
    show_roots: bool = false,
    last_rect: ui.Rect = .{},
    /// Rows above the tree: one while the view paints its own section header,
    /// zero when the side bar part paints the title.
    header_rows: usize = 1,
    theme: ?*const theme_colors_mod.ThemeColors = null,

    pub fn init(
        allocator: Allocator,
        io: Io,
        context: *WorkspaceContextService,
        configuration: *ConfigurationService,
    ) !*Sidebar {
        const self = try allocator.create(Sidebar);
        errdefer allocator.destroy(self);

        const explorer_model = try ExplorerModel.init(allocator, io, context);
        errdefer explorer_model.deinit();

        const compression_enabled = readCompactFolders(configuration, explorer_model);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .model = explorer_model,
            .files_filter = FilesFilter.init(allocator, io, configuration),
            .tree = undefined,
            .compression_enabled = compression_enabled,
            .force_expanded = std.AutoHashMap(*ExplorerItem, void).init(allocator),
            .sort_order = readSortOrder(configuration, explorer_model),
        };
        errdefer self.files_filter.deinit();
        errdefer self.force_expanded.deinit();

        self.show_roots = context.getWorkbenchState() != .FOLDER or self.model.roots.items.len != 1;
        self.tree = try CompressibleTree.init(allocator, "explorer", compression_enabled, .{
            .context = @ptrCast(self),
            .render = renderRow,
        });
        errdefer self.tree.deinit();
        try self.tree.setFilter(.{
            .context = &self.files_filter,
            .filter = filterItem,
        });

        if (!self.show_roots and self.model.roots.items.len == 1) {
            const root = self.model.roots.items[0];
            try self.loadChildren(root);
            try self.setChildren(null, root.children.items);
        } else {
            try self.setChildren(null, self.model.roots.items);
            const expand_count = @min(self.model.roots.items.len, 5);
            for (self.model.roots.items[0..expand_count]) |root| {
                try self.loadChildren(root);
                try self.setChildren(root, root.children.items);
                _ = try self.tree.setCollapsed(root, false, false);
            }
        }
        return self;
    }

    pub fn deinit(self: *Sidebar) void {
        self.tree.deinit();
        self.force_expanded.deinit();
        self.files_filter.deinit();
        self.model.deinit();
        self.allocator.destroy(self);
    }

    fn loadChildren(self: *Sidebar, item: *ExplorerItem) !void {
        const was_resolved = item.is_directory_resolved;
        item.fetchChildren(self.io, self.sort_order) catch {};
        try self.files_filter.prepare(item);
        if (was_resolved or !self.compression_enabled) return;

        // `autoExpandCompressedChildren`: a lone compressible child is rendered
        // together with its parent, so resolve its children as well to reveal
        // them when the compressed row is expanded.
        var current = item;
        while (current.children.items.len == 1) {
            const child = current.children.items[0];
            if (isIncompressible(child)) break;
            try self.force_expanded.put(child, {});
            if (!child.is_directory or child.is_directory_resolved) break;
            child.fetchChildren(self.io, self.sort_order) catch {};
            try self.files_filter.prepare(child);
            current = child;
        }
    }

    fn setChildren(self: *Sidebar, parent: ?*ExplorerItem, items: []*ExplorerItem) !void {
        const selected = self.tree.selectionElement();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const elements = try self.buildElements(arena.allocator(), items);
        self.force_expanded.clearRetainingCapacity();
        try self.tree.setChildren(parent, elements);
        if (selected) |item| self.selectElement(item);
    }

    /// Builds the loaded subtree as compressed tree elements. Children are only
    /// included for resolved directories, which mirrors the async data tree's
    /// `asTreeElement` including the children it has loaded.
    fn buildElements(
        self: *Sidebar,
        allocator: Allocator,
        items: []*ExplorerItem,
    ) ![]CompressedElement {
        var children_list = std.array_list.Managed(CompressedElement).init(allocator);
        for (items) |item| {
            var children: []const CompressedElement = &.{};
            if (item.is_directory and item.is_directory_resolved and item.children.items.len > 0) {
                children = try self.buildElements(allocator, item.children.items);
            }
            const collapsed: ?bool = if (!item.is_directory)
                null
            else if (self.force_expanded.contains(item))
                false
            else if (self.tree.has(item))
                null
            else
                true;
            try children_list.append(.{
                .element = item,
                .children = children,
                .collapsible = item.is_directory,
                .collapsed = collapsed,
                .incompressible = isIncompressible(item),
            });
        }
        return children_list.toOwnedSlice();
    }

    fn selectElement(self: *Sidebar, item: *ExplorerItem) void {
        self.tree.setSelectionElement(item);
    }

    fn toggle(self: *Sidebar, item: *ExplorerItem) !?[]const u8 {
        if (!item.is_directory) return item.resource;
        if (self.tree.isCollapsed(item)) {
            try self.loadChildren(item);
            try self.setChildren(item, item.children.items);
            _ = try self.tree.setCollapsed(item, false, false);
            self.selectElement(item);
        } else {
            _ = try self.tree.setCollapsed(item, true, false);
            self.selectElement(item);
        }
        return null;
    }

    fn expandSelected(self: *Sidebar) !void {
        const node = self.tree.selectionNode() orelse return;
        const item = CompressibleTree.elementOfNode(node) orelse return;
        if (!item.is_directory) return;
        if (self.tree.isCollapsed(item)) {
            _ = try self.toggle(item);
        } else if (node.children.items.len > 0) {
            self.tree.setSelectionNode(node.children.items[0]);
        }
    }

    pub fn handleKey(self: *Sidebar, event: *const ui.KeyEvent) !Action {
        switch (event.key) {
            .right => {
                try self.expandSelected();
                return .handled;
            },
            .enter => {
                const node = self.tree.selectionNode() orelse return .handled;
                const item = CompressibleTree.elementOfNode(node) orelse return .handled;
                if (try self.toggle(item)) |path| return .{ .open = path };
                return .handled;
            },
            .char => |ch| {
                if (ch == ' ') {
                    const node = self.tree.selectionNode() orelse return .handled;
                    const item = CompressibleTree.elementOfNode(node) orelse return .handled;
                    if (try self.toggle(item)) |path| return .{ .open = path };
                    return .handled;
                }
            },
            else => {
                if (self.tree.handleKey(event)) return .handled;
                return .none;
            },
        }
        return .none;
    }

    /// Routes wheel and other pointer events to the ported tree viewport.
    pub fn handleMouse(self: *Sidebar, event: *const ui.MouseEvent) bool {
        return self.tree.handleMouse(event);
    }

    pub fn handleClick(self: *Sidebar, x: usize, y: usize) !?[]const u8 {
        return self.handleClickInternal(x, y);
    }

    /// A single click in the Explorer opens a preview editor; Enter stays
    /// pinned. Tree toggling and selection behavior are unchanged.
    pub fn handleClickPreview(self: *Sidebar, x: usize, y: usize) !?[]const u8 {
        return self.handleClickInternal(x, y);
    }

    fn handleClickInternal(self: *Sidebar, x: usize, y: usize) !?[]const u8 {
        const rect = self.last_rect;
        const left = ui.cell.snap(rect.x);
        const top = ui.cell.snap(rect.y);
        const width = ui.cell.snap(rect.w);
        const height = ui.cell.snap(rect.h);
        if (x < left or x >= left + width or y < top + self.header_rows or y >= top + height) return null;

        const event = ui.MouseEvent{
            .kind = .down,
            .x = x,
            .y = y,
            .button = .left,
        };
        if (!self.tree.handleMouse(&event)) return null;

        // Ignore clicks below the last rendered row.
        const list_y = y - top - self.header_rows;
        const position = self.tree.view.widget.view.scroll_top + @as(f64, @floatFromInt(list_y));
        const index = self.tree.view.widget.view.range_map.indexAt(position);
        if (index < 0 or index >= @as(i64, @intCast(self.tree.count()))) return null;

        const node = self.tree.selectionNode() orelse return null;
        const item = CompressibleTree.elementOfNode(node) orelse return null;
        if (item.is_directory) {
            const visual_depth = node.depth -| 1;
            const twistie_x = left + 2 + visual_depth * 2;
            if (x != twistie_x) return null;
        }
        return self.toggle(item);
    }

    /// Supplies the open-editor query used by the ported `FilesFilter` to
    /// keep excluded open files and their parents visible.
    pub fn setOpenEditorQuery(self: *Sidebar, query: ?explorer_viewer.OpenEditorQuery) void {
        self.files_filter.setOpenEditorQuery(query);
    }

    /// Reveals a resource like VS Code's `explorer.autoReveal`: expands lazy
    /// ancestors, then selects and scrolls to the item without moving focus.
    pub fn revealPath(self: *Sidebar, path: []const u8) !void {
        const folder = self.model.context.getWorkspaceFolder(path) orelse return;
        var root: ?*ExplorerItem = null;
        for (self.model.roots.items) |candidate| {
            if (std.mem.eql(u8, candidate.resource, folder.resource)) {
                root = candidate;
                break;
            }
        }
        const root_item = root orelse return;
        const relative = std.mem.trimStart(u8, path[root_item.resource.len..], "/\\");
        if (relative.len == 0) {
            if (self.show_roots) self.selectElement(root_item);
            return;
        }

        var current = root_item;
        var parts = std.mem.tokenizeAny(u8, relative, "/\\");
        while (parts.next()) |name| {
            if (!current.is_directory) return;
            if (!current.is_directory_resolved) try self.loadChildren(current);

            var next: ?*ExplorerItem = null;
            for (current.children.items) |child| {
                if (std.mem.eql(u8, child.name, name)) {
                    next = child;
                    break;
                }
            }
            const item = next orelse return;

            // The single-folder root is the tree input and has no visible row;
            // its children were already installed by init().
            if (!(current == root_item and !self.show_roots)) {
                try self.setChildren(current, current.children.items);
                _ = try self.tree.setCollapsed(current, false, false);
            }
            current = item;
        }
        self.selectElement(current);
    }

    pub fn selectedNode(self: *Sidebar) ?*ExplorerItem {
        return self.tree.selectionElement();
    }

    pub fn renderedItem(self: *Sidebar, index: usize) ?*ExplorerItem {
        const node = self.tree.renderedNode(index) orelse return null;
        return CompressibleTree.elementOfNode(node);
    }

    pub fn count(self: *const Sidebar) usize {
        return self.tree.count();
    }

    pub fn isExpanded(self: *Sidebar, item: *ExplorerItem) bool {
        return !self.tree.isCollapsed(item);
    }

    pub fn setThemeColors(self: *Sidebar, palette: ?*const theme_colors_mod.ThemeColors) void {
        self.theme = palette;
    }

    pub fn render(self: *Sidebar, grid: *CellGrid, rect: ui.Rect, focused: bool, options: RenderOptions) !void {
        self.last_rect = rect;
        const x = ui.cell.snap(rect.x);
        const y = ui.cell.snap(rect.y);
        const width = ui.cell.snap(rect.w);
        const height = ui.cell.snap(rect.h);
        if (width == 0 or height == 0) return;

        const background = if (self.theme) |palette|
            ui.cell.PaintStyle{ .bg = ui.cell.packColor(palette.color("sideBar.background", .{ 30, 30, 33 })) }
        else
            ui.cell.PaintStyle{};
        grid.fillRect(@floatFromInt(x), @floatFromInt(y), @floatFromInt(width), @floatFromInt(height), background);

        // Upstream the Explorer view pane container has no section header: the
        // side bar title area shows `EXPLORER` and its actions. The header
        // remains for standalone preview/test rendering.
        self.header_rows = if (options.show_header) 1 else 0;
        if (options.show_header) {
            const header_style_local = if (self.theme) |palette| ui.cell.PaintStyle{
                .fg = ui.cell.packColor(palette.color("sideBarSectionHeader.foreground", .{ 200, 200, 200 })),
                .bg = ui.cell.packColor(palette.color("sideBarSectionHeader.background", .{ 38, 38, 42 })),
            } else header_style;
            const header = if (focused) " EXPLORER " else " Explorer ";
            grid.fillRect(@floatFromInt(x), @floatFromInt(y), @floatFromInt(width), 1, header_style_local);
            _ = drawText(grid, x + 1, y, width - 2, header, header_style_local);
        }

        if (height <= self.header_rows) return;
        const rows = height - self.header_rows;
        const content_rows = self.tree.count();
        const show_scrollbar = width > 1 and content_rows > rows;
        const list_width = if (show_scrollbar) width - 1 else width;
        self.tree.setFocus(focused);
        self.tree.render(grid, .{
            .x = @floatFromInt(x),
            .y = @floatFromInt(y + self.header_rows),
            .w = @floatFromInt(list_width),
            .h = @floatFromInt(rows),
        });

        if (show_scrollbar) {
            const scrollbar_x = x + width - 1;
            grid.fillRect(
                @floatFromInt(scrollbar_x),
                @floatFromInt(y + self.header_rows),
                1,
                @floatFromInt(rows),
                scrollbar_track_style,
            );
            const thumb_height = @max(1, @as(usize, @intFromFloat(@round(
                @as(f64, @floatFromInt(rows * rows)) / @as(f64, @floatFromInt(content_rows)),
            ))));
            const max_scroll = @as(f64, @floatFromInt(content_rows - rows));
            const thumb_top = if (max_scroll <= 0)
                0
            else
                @as(usize, @intFromFloat(@round(
                    @as(f64, @floatFromInt(rows - thumb_height)) *
                        self.tree.view.widget.view.scroll_top / max_scroll,
                )));
            grid.fillRect(
                @floatFromInt(scrollbar_x),
                @floatFromInt(y + self.header_rows + thumb_top),
                1,
                @floatFromInt(thumb_height),
                scrollbar_thumb_style,
            );
        }
    }
};

fn filterItem(context: *anyopaque, item: ?*ExplorerItem, parent_visibility: tree.TreeVisibility) tree.TreeVisibility {
    if (parent_visibility == .hidden) return .hidden;
    const files_filter: *FilesFilter = @ptrCast(@alignCast(context));
    const value = item orelse return .visible;
    return if (files_filter.filter(value, parent_visibility)) .visible else .hidden;
}

/// `explorer.compactFolders` defaults to true, like upstream. Screen-reader
/// mode has no terminal equivalent, so it does not disable compression.
fn readCompactFolders(configuration: *ConfigurationService, model: *ExplorerModel) bool {
    if (model.roots.items.len == 0) return true;
    const value = configuration.getValue("explorer.compactFolders", .{
        .resource = model.roots.items[0].resource,
    }) orelse return true;
    return switch (value.*) {
        .bool => |inner| inner,
        else => true,
    };
}

/// Port of `ExplorerCompressionDelegate.isIncompressible`: workspace roots,
/// files and the root's direct children never merge into their parent.
fn isIncompressible(item: *ExplorerItem) bool {
    if (item.parent == null) return true;
    if (!item.is_directory) return true;
    return item.parent.?.parent == null;
}

fn readSortOrder(configuration: *ConfigurationService, model: *ExplorerModel) explorer.SortOrder {
    if (model.roots.items.len == 0) return .FilesFirst;
    const value = configuration.getValue("explorer.sortOrder", .{
        .resource = model.roots.items[0].resource,
    }) orelse return .FilesFirst;
    const text = switch (value.*) {
        .string => |inner| inner,
        else => return .FilesFirst,
    };
    if (std.mem.eql(u8, text, "mixed")) return .Mixed;
    if (std.mem.eql(u8, text, "type")) return .Type;
    if (std.mem.eql(u8, text, "modified")) return .Modified;
    if (std.mem.eql(u8, text, "filesFirst")) return .FilesFirst;
    return .FilesFirst;
}

fn renderRow(context: *anyopaque, row: *const list.Row, node: *const CompressibleTree.Node) void {
    const sidebar: *Sidebar = @ptrCast(@alignCast(context));
    const compressed = node.element orelse return;
    if (compressed.elements.len == 0) return;
    const item = compressed.elements[compressed.elements.len - 1];
    const selected = row.selected;
    var paint = if (selected)
        (if (item.is_directory)
            (if (row.focused) selected_dir_style else unfocused_dir_selection_style)
        else
            (if (row.focused) selected_style else unfocused_selection_style))
    else if (item.is_directory)
        dir_style
    else
        text_style;
    if (sidebar.theme) |palette| {
        paint = if (selected) .{
            .fg = ui.cell.packColor(palette.color(
                if (row.focused) "list.activeSelectionForeground" else "list.inactiveSelectionForeground",
                .{ 245, 245, 245 },
            )),
            .bg = ui.cell.packColor(palette.color(
                if (row.focused) "list.activeSelectionBackground" else "list.inactiveSelectionBackground",
                .{ 55, 65, 80 },
            )),
        } else if (item.is_directory) .{
            .fg = ui.cell.packColor(palette.color("symbolIcon.folderForeground", .{ 170, 190, 210 })),
        } else .{
            .fg = ui.cell.packColor(palette.color("sideBar.foreground", .{ 190, 190, 190 })),
        };
    }

    if (selected) {
        row.grid.fillRect(
            @floatFromInt(row.x),
            @floatFromInt(row.y),
            @floatFromInt(row.width),
            1,
            paint,
        );
    }

    var col = row.x + 2;
    var indent: usize = 0;
    const indent_width = (node.depth -| 1) * 2;
    while (indent < indent_width and col < row.x + row.width) : (indent += 1) {
        row.grid.putSpace(col, row.y, paint);
        col += 1;
    }

    if (col < row.x + row.width) {
        const glyph: u21 = if (item.is_directory)
            (if (node.collapsed) '▸' else '▾')
        else
            ' ';
        row.grid.putCodepoint(col, row.y, glyph, 1, paint);
        col += 1;
    }
    if (col < row.x + row.width) {
        row.grid.putSpace(col, row.y, paint);
        col += 1;
    }

    // `renderCompressedElements`: join the compressed path with `/`. A single
    // element renders exactly like the uncompressed `renderElement` path.
    var remaining = (row.x + row.width) -| col;
    for (compressed.elements, 0..) |element, index| {
        if (index > 0) {
            if (remaining == 0) break;
            row.grid.putCodepoint(col, row.y, '/', 1, paint);
            col += 1;
            remaining -= 1;
        }
        const used = drawText(row.grid, col, row.y, remaining, element.name, paint);
        col += used;
        remaining -= used;
    }
}

fn drawText(grid: *CellGrid, x: usize, y: usize, max_width: usize, text: []const u8, paint: PaintStyle) usize {
    var col = x;
    var offset: usize = 0;
    while (offset < text.len and col < x + max_width) {
        const decoded = ui.dom.decodeAt(text, offset);
        const width = ui.dom.defaultMeasureWidth(decoded.cp);
        if (col + width > x + max_width) break;
        grid.putCodepoint(col, y, decoded.cp, width, paint);
        col += width;
        offset += decoded.len;
    }
    return col - x;
}

test "explorer tree sidebar: renders and uses the ported tree view" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "alpha");
    try tmp.dir.createDirPath(io, "beta");
    var file = try tmp.dir.createFile(io, "z.txt", .{});
    try file.writeStreamingAll(io, "z");
    file.close(io);

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    const configuration = try ConfigurationService.init(allocator, io, context, .{});
    defer configuration.deinit();
    const sidebar = try Sidebar.init(allocator, io, context, configuration);
    defer sidebar.deinit();

    try std.testing.expectEqual(@as(usize, 3), sidebar.count());

    var grid = try ui.CellGrid.init(allocator, 24, 8);
    defer grid.deinit();
    try sidebar.render(&grid, .{ .x = 0, .y = 0, .w = 24, .h = 8 }, true, .{});
    const first = try grid.rowText(allocator, 1);
    defer allocator.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "▸") != null);

    var home = ui.KeyEvent{ .key = .home };
    _ = try sidebar.handleKey(&home);
    const alpha = sidebar.selectedNode().?;
    var right = ui.KeyEvent{ .key = .right };
    _ = try sidebar.handleKey(&right);
    try std.testing.expect(sidebar.isExpanded(alpha));
    var expanded_grid = try ui.CellGrid.init(allocator, 24, 8);
    defer expanded_grid.deinit();
    try sidebar.render(&expanded_grid, .{ .x = 0, .y = 0, .w = 24, .h = 8 }, true, .{});
    const expanded_row = try expanded_grid.rowText(allocator, 1);
    defer allocator.free(expanded_row);
    try std.testing.expect(std.mem.indexOf(u8, expanded_row, "▾") != null);

    var end = ui.KeyEvent{ .key = .end };
    _ = try sidebar.handleKey(&end);
    var enter = ui.KeyEvent{ .key = .enter };
    switch (try sidebar.handleKey(&enter)) {
        .open => |path| try std.testing.expect(std.mem.endsWith(u8, path, "z.txt")),
        else => return error.TestUnexpectedResult,
    }
}

test "explorer tree sidebar: wheel scrolls the tree viewport" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    for (0..12) |i| {
        var name_buffer: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "f{d:0>2}.txt", .{i});
        var file = try tmp.dir.createFile(io, name, .{});
        try file.writeStreamingAll(io, "x");
        file.close(io);
    }

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    const configuration = try ConfigurationService.init(allocator, io, context, .{});
    defer configuration.deinit();
    const sidebar = try Sidebar.init(allocator, io, context, configuration);
    defer sidebar.deinit();

    try std.testing.expectEqual(@as(usize, 12), sidebar.count());
    var grid = try ui.CellGrid.init(allocator, 24, 6);
    defer grid.deinit();
    try sidebar.render(&grid, .{ .x = 0, .y = 0, .w = 24, .h = 6 }, true, .{});
    try std.testing.expect(grid.bg[grid.index(23, 1)] != 0);
    const before = sidebar.tree.view.widget.view.scroll_top;

    const wheel = ui.MouseEvent{ .kind = .wheel, .x = 1, .y = 2, .delta_y = 1 };
    try std.testing.expect(sidebar.handleMouse(&wheel));
    try std.testing.expect(sidebar.tree.view.widget.view.scroll_top > before);
}

test "explorer tree sidebar: revealPath expands ancestors and selects the file" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "alpha/beta");
    var file = try tmp.dir.createFile(io, "alpha/beta/deep.txt", .{});
    try file.writeStreamingAll(io, "deep");
    file.close(io);

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    const configuration = try ConfigurationService.init(allocator, io, context, .{});
    defer configuration.deinit();
    const sidebar = try Sidebar.init(allocator, io, context, configuration);
    defer sidebar.deinit();

    const path = try std.fmt.allocPrint(allocator, "{s}/alpha/beta/deep.txt", .{root});
    defer allocator.free(path);
    try sidebar.revealPath(path);

    const selected = sidebar.selectedNode().?;
    try std.testing.expectEqualStrings("deep.txt", selected.name);
    try std.testing.expect(sidebar.isExpanded(selected.parent.?));
    try std.testing.expect(sidebar.isExpanded(selected.parent.?.parent.?));
}

test "explorer tree sidebar: directory rows only toggle from the twistie" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "alpha");
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    const configuration = try ConfigurationService.init(allocator, io, context, .{});
    defer configuration.deinit();
    const sidebar = try Sidebar.init(allocator, io, context, configuration);
    defer sidebar.deinit();

    var grid = try ui.CellGrid.init(allocator, 24, 6);
    defer grid.deinit();
    try sidebar.render(&grid, .{ .x = 0, .y = 0, .w = 24, .h = 6 }, true, .{});

    const alpha = sidebar.selectedNode().?;
    try std.testing.expectEqualStrings("alpha", alpha.name);
    _ = try sidebar.handleClick(5, 1);
    try std.testing.expect(!sidebar.isExpanded(alpha));
    _ = try sidebar.handleClick(2, 1);
    try std.testing.expect(sidebar.isExpanded(alpha));
}

test "explorer tree sidebar: sort order comes from settings" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".vscode");
    var settings = try tmp.dir.createFile(io, ".vscode/settings.json", .{});
    try settings.writeStreamingAll(io, "{\"explorer.sortOrder\": \"type\"}");
    settings.close(io);
    var zig_file = try tmp.dir.createFile(io, "a.zig", .{});
    try zig_file.writeStreamingAll(io, "x");
    zig_file.close(io);
    var txt_file = try tmp.dir.createFile(io, "z.txt", .{});
    try txt_file.writeStreamingAll(io, "x");
    txt_file.close(io);

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    const configuration = try ConfigurationService.init(allocator, io, context, .{});
    defer configuration.deinit();
    const sidebar = try Sidebar.init(allocator, io, context, configuration);
    defer sidebar.deinit();

    try std.testing.expectEqual(explorer.SortOrder.Type, sidebar.sort_order);
    try std.testing.expectEqualStrings(".vscode", sidebar.renderedItem(0).?.name);
    try std.testing.expectEqualStrings("z.txt", sidebar.renderedItem(1).?.name);
    try std.testing.expectEqualStrings("a.zig", sidebar.renderedItem(2).?.name);
}

test "explorer tree sidebar: tree filter hides ignored children without dropping them" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var ignore = try tmp.dir.createFile(io, ".gitignore", .{});
    try ignore.writeStreamingAll(io, "ignored.txt\n");
    ignore.close(io);
    var ignored = try tmp.dir.createFile(io, "ignored.txt", .{});
    try ignored.writeStreamingAll(io, "x");
    ignored.close(io);
    var visible = try tmp.dir.createFile(io, "visible.txt", .{});
    try visible.writeStreamingAll(io, "x");
    visible.close(io);

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    const configuration = try ConfigurationService.init(allocator, io, context, .{});
    defer configuration.deinit();
    const sidebar = try Sidebar.init(allocator, io, context, configuration);
    defer sidebar.deinit();

    try std.testing.expectEqual(@as(usize, 2), sidebar.count());
    try std.testing.expectEqualStrings(".gitignore", sidebar.renderedItem(0).?.name);
    try std.testing.expectEqualStrings("visible.txt", sidebar.renderedItem(1).?.name);
}

test "explorer tree sidebar: compactFolders compresses single-child chains" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "a/b/c");
    var file = try tmp.dir.createFile(io, "a/b/c/deep.txt", .{});
    try file.writeStreamingAll(io, "deep");
    file.close(io);

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    const configuration = try ConfigurationService.init(allocator, io, context, .{});
    defer configuration.deinit();
    const sidebar = try Sidebar.init(allocator, io, context, configuration);
    defer sidebar.deinit();

    try std.testing.expect(sidebar.compression_enabled);
    try std.testing.expectEqual(@as(usize, 1), sidebar.count());
    try std.testing.expectEqualStrings("a", sidebar.selectedNode().?.name);

    var grid = try ui.CellGrid.init(allocator, 24, 8);
    defer grid.deinit();
    try sidebar.render(&grid, .{ .x = 0, .y = 0, .w = 24, .h = 8 }, true, .{});

    var right = ui.KeyEvent{ .key = .right };
    _ = try sidebar.handleKey(&right);
    try std.testing.expectEqual(@as(usize, 2), sidebar.count());
    try std.testing.expectEqualStrings("c", sidebar.renderedItem(0).?.name);
    try std.testing.expectEqualStrings("deep.txt", sidebar.renderedItem(1).?.name);

    try sidebar.render(&grid, .{ .x = 0, .y = 0, .w = 24, .h = 8 }, true, .{});
    const compressed_row = try grid.rowText(allocator, 1);
    defer allocator.free(compressed_row);
    try std.testing.expect(std.mem.indexOf(u8, compressed_row, "a/b/c") != null);
    try std.testing.expect(std.mem.indexOf(u8, compressed_row, "▾") != null);

    var left = ui.KeyEvent{ .key = .left };
    _ = try sidebar.handleKey(&left);
    try std.testing.expectEqual(@as(usize, 1), sidebar.count());
    try sidebar.render(&grid, .{ .x = 0, .y = 0, .w = 24, .h = 8 }, true, .{});
    const collapsed_row = try grid.rowText(allocator, 1);
    defer allocator.free(collapsed_row);
    try std.testing.expect(std.mem.indexOf(u8, collapsed_row, "a/b/c") != null);
    try std.testing.expect(std.mem.indexOf(u8, collapsed_row, "▸") != null);

    _ = try sidebar.handleKey(&right);
    try std.testing.expectEqual(@as(usize, 2), sidebar.count());
}

test "explorer tree sidebar: compactFolders false keeps folders separate" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".vscode");
    var settings = try tmp.dir.createFile(io, ".vscode/settings.json", .{});
    try settings.writeStreamingAll(io, "{\"explorer.compactFolders\": false}");
    settings.close(io);
    try tmp.dir.createDirPath(io, "a/b/c");
    var file = try tmp.dir.createFile(io, "a/b/c/deep.txt", .{});
    try file.writeStreamingAll(io, "deep");
    file.close(io);

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    const configuration = try ConfigurationService.init(allocator, io, context, .{});
    defer configuration.deinit();
    const sidebar = try Sidebar.init(allocator, io, context, configuration);
    defer sidebar.deinit();

    try std.testing.expect(!sidebar.compression_enabled);
    // `.vscode` (which holds the setting) and `a` are the top-level rows.
    try std.testing.expectEqual(@as(usize, 2), sidebar.count());

    var grid = try ui.CellGrid.init(allocator, 24, 8);
    defer grid.deinit();
    try sidebar.render(&grid, .{ .x = 0, .y = 0, .w = 24, .h = 8 }, true, .{});

    const a_item = sidebar.model.roots.items[0].getChild("a").?;
    sidebar.tree.setSelectionElement(a_item);

    var right = ui.KeyEvent{ .key = .right };
    _ = try sidebar.handleKey(&right);
    try std.testing.expectEqual(@as(usize, 3), sidebar.count());
    try std.testing.expectEqualStrings("a", sidebar.renderedItem(1).?.name);
    try std.testing.expectEqualStrings("b", sidebar.renderedItem(2).?.name);

    _ = try sidebar.handleKey(&right);
    _ = try sidebar.handleKey(&right);
    try std.testing.expectEqual(@as(usize, 4), sidebar.count());
    try std.testing.expectEqualStrings("c", sidebar.renderedItem(3).?.name);

    _ = try sidebar.handleKey(&right);
    _ = try sidebar.handleKey(&right);
    try std.testing.expectEqual(@as(usize, 5), sidebar.count());
    try std.testing.expectEqualStrings("deep.txt", sidebar.renderedItem(4).?.name);

    try sidebar.render(&grid, .{ .x = 0, .y = 0, .w = 24, .h = 8 }, true, .{});
    const second_row = try grid.rowText(allocator, 2);
    defer allocator.free(second_row);
    try std.testing.expect(std.mem.indexOf(u8, second_row, "a") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_row, "/") == null);
}

test "explorer tree sidebar: compressed paths keep the tree filter" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var ignore = try tmp.dir.createFile(io, ".gitignore", .{});
    try ignore.writeStreamingAll(io, "ignored.txt\n");
    ignore.close(io);
    try tmp.dir.createDirPath(io, "a/b/c");
    var hidden = try tmp.dir.createFile(io, "a/b/c/ignored.txt", .{});
    try hidden.writeStreamingAll(io, "hidden");
    hidden.close(io);
    var visible = try tmp.dir.createFile(io, "a/b/c/visible.txt", .{});
    try visible.writeStreamingAll(io, "visible");
    visible.close(io);

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    const configuration = try ConfigurationService.init(allocator, io, context, .{});
    defer configuration.deinit();
    const sidebar = try Sidebar.init(allocator, io, context, configuration);
    defer sidebar.deinit();

    try std.testing.expectEqual(@as(usize, 2), sidebar.count());
    sidebar.tree.setSelectionElement(sidebar.model.roots.items[0].getChild("a").?);

    var right = ui.KeyEvent{ .key = .right };
    _ = try sidebar.handleKey(&right);

    try std.testing.expectEqual(@as(usize, 3), sidebar.count());
    try std.testing.expectEqualStrings("c", sidebar.renderedItem(0).?.name);
    try std.testing.expectEqualStrings("visible.txt", sidebar.renderedItem(1).?.name);
    try std.testing.expectEqualStrings(".gitignore", sidebar.renderedItem(2).?.name);
}
