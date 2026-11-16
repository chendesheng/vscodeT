//! Terminal Explorer view over the ported list/tree layer.
//!
//! This replaces the ad-hoc visible-row painting with an `AbstractTree` backed
//! by `ObjectTreeModel(*ExplorerItem)`: virtualization, selection, focus,
//! keyboard/mouse scrolling and collapse state come from the ported base tree
//! view. The portable Explorer model, ignore filtering and lazy directory
//! resolution are shared with `sidebar.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ui = @import("ui");
const explorer = @import("../vs/workbench/contrib/files/common/explorerModel.zig");
const workspace_context = @import("../vs/workbench/services/workspaces/common/workspaceContextService.zig");
const configuration_mod = @import("../vs/workbench/services/configuration/browser/configurationService.zig");
const sidebar_mod = @import("./sidebar.zig");
const object_tree = @import("../vs/base/browser/ui/tree/objectTreeModel.zig");
const abstract_tree = @import("../vs/base/browser/ui/tree/abstractTree.zig");
const list = @import("../vs/base/browser/ui/list/list.zig");

const ExplorerItem = explorer.ExplorerItem;
const ExplorerModel = explorer.ExplorerModel;
const FilesFilter = sidebar_mod.FilesFilter;
const WorkspaceContextService = workspace_context.WorkspaceContextService;
const ConfigurationService = configuration_mod.ConfigurationService;
const TreeModel = object_tree.ObjectTreeModel(*ExplorerItem);
const TreeView = abstract_tree.AbstractTree(*ExplorerItem);
const ObjectElement = object_tree.ObjectTreeElement(*ExplorerItem);

const CellGrid = ui.CellGrid;
const PaintStyle = ui.cell.PaintStyle;

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

pub const Action = sidebar_mod.Action;

pub const Sidebar = struct {
    allocator: Allocator,
    io: Io,
    model: *ExplorerModel,
    files_filter: FilesFilter,
    tree_model: TreeModel,
    tree_view: *TreeView,
    show_roots: bool = false,
    last_rect: ui.Rect = .{},

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

        var tree_model = try TreeModel.init(allocator, "explorer", false);
        errdefer tree_model.deinit();

        self.* = .{
            .allocator = allocator,
            .io = io,
            .model = explorer_model,
            .files_filter = FilesFilter.init(allocator, io, configuration),
            .tree_model = tree_model,
            .tree_view = undefined,
        };
        errdefer self.files_filter.deinit();

        self.show_roots = context.getWorkbenchState() != .FOLDER or self.model.roots.items.len != 1;
        self.tree_view = try TreeView.init(allocator, &self.tree_model, .{
            .context = @ptrCast(self),
            .render = renderRow,
        });
        errdefer self.tree_view.deinit();

        if (!self.show_roots and self.model.roots.items.len == 1) {
            const root = self.model.roots.items[0];
            try self.loadChildren(root);
            try self.setChildren(null, root.children.items, false);
        } else {
            try self.setChildren(null, self.model.roots.items, false);
            const expand_count = @min(self.model.roots.items.len, 5);
            for (self.model.roots.items[0..expand_count]) |root| {
                try self.loadChildren(root);
                try self.setChildren(root, root.children.items, false);
                _ = try self.tree_model.setCollapsed(root, false, false);
                try self.tree_view.refresh();
            }
        }
        return self;
    }

    pub fn deinit(self: *Sidebar) void {
        self.tree_view.deinit();
        self.tree_model.deinit();
        self.files_filter.deinit();
        self.model.deinit();
        self.allocator.destroy(self);
    }

    fn loadChildren(self: *Sidebar, item: *ExplorerItem) !void {
        item.fetchChildren(self.io, .FilesFirst) catch {};
        try self.files_filter.prepare(item);
        var index: usize = 0;
        while (index < item.children.items.len) {
            const child = item.children.items[index];
            if (self.files_filter.isVisible(child)) {
                index += 1;
                continue;
            }
            item.removeChild(child);
            child.destroy();
        }
    }

    fn setChildren(self: *Sidebar, parent: ?*ExplorerItem, items: []*ExplorerItem, expand: bool) !void {
        const selected = self.selectedNode();
        var elements = try self.allocator.alloc(ObjectElement, items.len);
        defer self.allocator.free(elements);
        for (items, 0..) |item, i| {
            elements[i] = .{
                .element = item,
                .collapsible = item.is_directory,
                .collapsed = item.is_directory and !expand,
            };
        }
        try self.tree_model.setChildren(parent, elements);
        try self.tree_view.refresh();
        if (selected) |item| self.selectElement(item);
    }

    fn selectElement(self: *Sidebar, item: *ExplorerItem) void {
        const node = self.tree_model.getNode(item) catch return;
        self.tree_view.setSelectionNode(node);
    }

    fn toggle(self: *Sidebar, item: *ExplorerItem) !?[]const u8 {
        if (!item.is_directory) return item.resource;
        if (self.tree_model.isCollapsed(item)) {
            try self.loadChildren(item);
            try self.setChildren(item, item.children.items, false);
            _ = try self.tree_model.setCollapsed(item, false, false);
            try self.tree_view.refresh();
            self.selectElement(item);
        } else {
            _ = try self.tree_model.setCollapsed(item, true, false);
            try self.tree_view.refresh();
            self.selectElement(item);
        }
        return null;
    }

    fn expandSelected(self: *Sidebar) !void {
        const node = self.tree_view.selection() orelse return;
        const item = node.element orelse return;
        if (!item.is_directory) return;
        if (self.tree_model.isCollapsed(item)) {
            _ = try self.toggle(item);
        } else if (node.children.items.len > 0) {
            self.tree_view.setSelectionNode(node.children.items[0]);
        }
    }

    pub fn handleKey(self: *Sidebar, event: *const ui.KeyEvent) !Action {
        switch (event.key) {
            .right => {
                try self.expandSelected();
                return .handled;
            },
            .enter => {
                const node = self.tree_view.selection() orelse return .handled;
                const item = node.element orelse return .handled;
                if (try self.toggle(item)) |path| return .{ .open = path };
                return .handled;
            },
            .char => |ch| {
                if (ch == ' ') {
                    const node = self.tree_view.selection() orelse return .handled;
                    const item = node.element orelse return .handled;
                    if (try self.toggle(item)) |path| return .{ .open = path };
                    return .handled;
                }
            },
            else => {
                if (self.tree_view.handleKey(event)) return .handled;
                return .none;
            },
        }
        return .none;
    }

    /// Routes wheel and other pointer events to the ported tree viewport.
    pub fn handleMouse(self: *Sidebar, event: *const ui.MouseEvent) bool {
        return self.tree_view.handleMouse(event);
    }

    pub fn handleClick(self: *Sidebar, x: usize, y: usize) !?[]const u8 {
        const rect = self.last_rect;
        const left = ui.cell.snap(rect.x);
        const top = ui.cell.snap(rect.y);
        const width = ui.cell.snap(rect.w);
        const height = ui.cell.snap(rect.h);
        if (x < left or x >= left + width or y <= top or y >= top + height) return null;

        const event = ui.MouseEvent{
            .kind = .down,
            .x = x,
            .y = y,
            .button = .left,
        };
        if (!self.tree_view.handleMouse(&event)) return null;

        // Ignore clicks below the last rendered row.
        const list_y = y - top - 1;
        const position = self.tree_view.widget.view.scroll_top + @as(f64, @floatFromInt(list_y));
        const index = self.tree_view.widget.view.range_map.indexAt(position);
        if (index < 0 or index >= @as(i64, @intCast(self.tree_view.count()))) return null;

        const node = self.tree_view.selection() orelse return null;
        const item = node.element orelse return null;
        if (item.is_directory) {
            const visual_depth = node.depth -| 1;
            const twistie_x = left + 2 + visual_depth * 2;
            if (x != twistie_x) return null;
        }
        return self.toggle(item);
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
                try self.setChildren(current, current.children.items, false);
                _ = try self.tree_model.setCollapsed(current, false, false);
                try self.tree_view.refresh();
            }
            current = item;
        }
        self.selectElement(current);
    }

    pub fn selectedNode(self: *Sidebar) ?*ExplorerItem {
        const node = self.tree_view.selection() orelse return null;
        return node.element;
    }

    pub fn count(self: *const Sidebar) usize {
        return self.tree_view.count();
    }

    pub fn isExpanded(self: *Sidebar, item: *ExplorerItem) bool {
        return !self.tree_model.isCollapsed(item);
    }

    pub fn render(self: *Sidebar, grid: *CellGrid, rect: ui.Rect, focused: bool) !void {
        self.last_rect = rect;
        const x = ui.cell.snap(rect.x);
        const y = ui.cell.snap(rect.y);
        const width = ui.cell.snap(rect.w);
        const height = ui.cell.snap(rect.h);
        if (width == 0 or height == 0) return;

        grid.fillRect(@floatFromInt(x), @floatFromInt(y), @floatFromInt(width), @floatFromInt(height), .{});

        const header = if (focused) " EXPLORER " else " Explorer ";
        grid.fillRect(@floatFromInt(x), @floatFromInt(y), @floatFromInt(width), 1, header_style);
        drawText(grid, x + 1, y, width - 2, header, header_style);

        if (height <= 1) return;
        const rows = height - 1;
        const content_rows = self.tree_view.count();
        const show_scrollbar = width > 1 and content_rows > rows;
        const list_width = if (show_scrollbar) width - 1 else width;
        self.tree_view.setFocus(focused);
        self.tree_view.render(grid, .{
            .x = @floatFromInt(x),
            .y = @floatFromInt(y + 1),
            .w = @floatFromInt(list_width),
            .h = @floatFromInt(rows),
        });

        if (show_scrollbar) {
            const scrollbar_x = x + width - 1;
            grid.fillRect(
                @floatFromInt(scrollbar_x),
                @floatFromInt(y + 1),
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
                        self.tree_view.widget.view.scroll_top / max_scroll,
                )));
            grid.fillRect(
                @floatFromInt(scrollbar_x),
                @floatFromInt(y + 1 + thumb_top),
                1,
                @floatFromInt(thumb_height),
                scrollbar_thumb_style,
            );
        }
    }
};

fn renderRow(context: *anyopaque, row: *const list.Row, node: *const TreeModel.Node) void {
    const self: *Sidebar = @ptrCast(@alignCast(context));
    const item = node.element orelse return;
    const selected = row.selected;
    const paint = if (selected)
        (if (item.is_directory)
            (if (row.focused) selected_dir_style else unfocused_dir_selection_style)
        else
            (if (row.focused) selected_style else unfocused_selection_style))
    else if (item.is_directory)
        dir_style
    else
        text_style;

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
            (if (self.tree_model.isCollapsed(item)) '▸' else '▾')
        else
            ' ';
        row.grid.putCodepoint(col, row.y, glyph, 1, paint);
        col += 1;
    }
    if (col < row.x + row.width) {
        row.grid.putSpace(col, row.y, paint);
        col += 1;
    }
    drawText(row.grid, col, row.y, (row.x + row.width) -| col, item.name, paint);
}

fn drawText(grid: *CellGrid, x: usize, y: usize, max_width: usize, text: []const u8, paint: PaintStyle) void {
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
    try sidebar.render(&grid, .{ .x = 0, .y = 0, .w = 24, .h = 8 }, true);
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
    try sidebar.render(&expanded_grid, .{ .x = 0, .y = 0, .w = 24, .h = 8 }, true);
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
    try sidebar.render(&grid, .{ .x = 0, .y = 0, .w = 24, .h = 6 }, true);
    try std.testing.expect(grid.bg[grid.index(23, 1)] != 0);
    const before = sidebar.tree_view.widget.view.scroll_top;

    const wheel = ui.MouseEvent{ .kind = .wheel, .x = 1, .y = 2, .delta_y = 1 };
    try std.testing.expect(sidebar.handleMouse(&wheel));
    try std.testing.expect(sidebar.tree_view.widget.view.scroll_top > before);
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
    try sidebar.render(&grid, .{ .x = 0, .y = 0, .w = 24, .h = 6 }, true);

    const alpha = sidebar.selectedNode().?;
    try std.testing.expectEqualStrings("alpha", alpha.name);
    _ = try sidebar.handleClick(5, 1);
    try std.testing.expect(!sidebar.isExpanded(alpha));
    _ = try sidebar.handleClick(2, 1);
    try std.testing.expect(sidebar.isExpanded(alpha));
}
