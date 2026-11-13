//! Terminal Explorer sidebar over the ported `ExplorerModel`.
//!
//! This is the TUI view for the Explorer. It keeps the portable model behavior
//! (directory-first sorting, lazy resolution, find/move/rename) in
//! `src/vs/workbench/contrib/files/common/explorerModel.zig`, and paints the
//! visible rows directly into the workbench cell grid. Expansion state and the
//! visible-row projection are view state, as they are in the browser tree.
//!
//! The file service, file watching, activity bar and view-container system are
//! not ported yet; the sidebar root is the current working directory.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ui = @import("ui");
const explorer = @import("../vs/workbench/contrib/files/common/explorerModel.zig");
const workspace_context = @import("../vs/workbench/services/workspaces/common/workspaceContextService.zig");
const WorkspaceContextService = workspace_context.WorkspaceContextService;
const ExplorerModel = explorer.ExplorerModel;
const ExplorerItem = explorer.ExplorerItem;

const CellGrid = ui.CellGrid;
const PaintStyle = ui.cell.PaintStyle;

const Visible = struct {
    item: *ExplorerItem,
    depth: usize,
};

const header_style = PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 200, .g = 200, .b = 200 }),
    .bg = ui.cell.packColor(.{ .r = 38, .g = 38, .b = 42 }),
};
const text_style = PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 190, .g = 190, .b = 190 }),
};
const dir_style = PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 170, .g = 190, .b = 210 }),
};
const selected_style = PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 245, .g = 245, .b = 245 }),
    .bg = ui.cell.packColor(.{ .r = 55, .g = 65, .b = 80 }),
};
const selected_dir_style = PaintStyle{
    .fg = ui.cell.packColor(.{ .r = 220, .g = 235, .b = 255 }),
    .bg = selected_style.bg,
};

pub const Action = union(enum) {
    none,
    handled,
    open: []const u8,
};

pub const Sidebar = struct {
    allocator: Allocator,
    io: Io,
    model: *ExplorerModel,
    visible: std.array_list.Managed(Visible),
    expanded: std.AutoHashMap(*ExplorerItem, void),
    /// Upstream the Explorer uses the single root itself as the tree input in
    /// a folder workspace, so the root row is hidden and its children are the
    /// top-level rows. Multi-root workspaces show the root rows.
    show_roots: bool = false,
    selected: usize = 0,
    scroll: usize = 0,
    last_rect: ui.Rect = .{},

    pub fn init(allocator: Allocator, io: Io, context: *WorkspaceContextService) !*Sidebar {
        const self = try allocator.create(Sidebar);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .model = try ExplorerModel.init(allocator, io, context),
            .visible = std.array_list.Managed(Visible).init(allocator),
            .expanded = std.AutoHashMap(*ExplorerItem, void).init(allocator),
        };
        errdefer self.model.deinit();

        self.show_roots = context.getWorkbenchState() != .FOLDER or self.model.roots.items.len != 1;
        if (!self.show_roots and self.model.roots.items.len == 1) {
            // The root is the tree input and starts expanded; its direct
            // children are the top-level rows.
            try self.loadChildren(self.model.roots.items[0]);
            try self.setExpanded(self.model.roots.items[0], true);
        } else {
            // Upstream expands up to five roots when there is no stored view
            // state; deeper directories remain lazy.
            const expand_count = @min(self.model.roots.items.len, 5);
            for (self.model.roots.items[0..expand_count]) |root| {
                try self.loadChildren(root);
                try self.setExpanded(root, true);
            }
        }
        try self.rebuildVisible();
        return self;
    }

    pub fn deinit(self: *Sidebar) void {
        self.expanded.deinit();
        self.visible.deinit();
        self.model.deinit();
        self.allocator.destroy(self);
    }

    fn loadChildren(self: *Sidebar, item: *ExplorerItem) !void {
        item.fetchChildren(self.io, .FilesFirst) catch {};
    }

    pub fn isExpanded(self: *const Sidebar, item: *ExplorerItem) bool {
        return self.expanded.contains(item);
    }

    fn setExpanded(self: *Sidebar, item: *ExplorerItem, expanded: bool) !void {
        if (expanded) {
            try self.expanded.put(item, {});
        } else {
            _ = self.expanded.remove(item);
        }
    }

    fn rebuildVisible(self: *Sidebar) !void {
        self.visible.clearRetainingCapacity();
        if (!self.show_roots and self.model.roots.items.len == 1) {
            const root = self.model.roots.items[0];
            for (root.children.items) |child| {
                try self.visible.append(.{ .item = child, .depth = 0 });
                if (child.is_directory and self.isExpanded(child)) {
                    try self.appendVisible(child, 1);
                }
            }
        } else {
            for (self.model.roots.items) |root| {
                try self.visible.append(.{ .item = root, .depth = 0 });
                if (self.isExpanded(root)) try self.appendVisible(root, 1);
            }
        }
        if (self.visible.items.len == 0) {
            self.selected = 0;
            self.scroll = 0;
        } else if (self.selected >= self.visible.items.len) {
            self.selected = self.visible.items.len - 1;
        }
    }

    fn appendVisible(self: *Sidebar, parent: *ExplorerItem, depth: usize) !void {
        for (parent.children.items) |child| {
            try self.visible.append(.{ .item = child, .depth = depth });
            if (child.is_directory and self.isExpanded(child)) {
                try self.appendVisible(child, depth + 1);
            }
        }
    }

    pub fn selectedNode(self: *const Sidebar) ?*ExplorerItem {
        if (self.selected >= self.visible.items.len) return null;
        return self.visible.items[self.selected].item;
    }

    pub fn count(self: *const Sidebar) usize {
        return self.visible.items.len;
    }

    fn moveSelection(self: *Sidebar, delta: isize) void {
        if (self.visible.items.len == 0) return;
        const total: isize = @intCast(self.visible.items.len);
        const current: isize = @intCast(self.selected);
        self.selected = @intCast(@mod(current + delta, total));
    }

    fn parentOfSelected(self: *Sidebar) ?*ExplorerItem {
        const item = self.selectedNode() orelse return null;
        return item.parent;
    }

    fn expandSelected(self: *Sidebar) !void {
        const item = self.selectedNode() orelse return;
        if (!item.is_directory) return;
        if (!self.isExpanded(item)) {
            try self.loadChildren(item);
            try self.setExpanded(item, true);
            try self.rebuildVisible();
        } else if (item.children.items.len > 0) {
            self.selected += 1;
        }
    }

    fn collapseSelected(self: *Sidebar) !void {
        const item = self.selectedNode() orelse return;
        if (item.is_directory and self.isExpanded(item)) {
            try self.setExpanded(item, false);
            try self.rebuildVisible();
            return;
        }
        if (self.parentOfSelected()) |parent| {
            for (self.visible.items, 0..) |candidate, index| {
                if (candidate.item == parent) {
                    self.selected = index;
                    return;
                }
            }
        }
    }

    fn toggleSelected(self: *Sidebar) !?[]const u8 {
        const item = self.selectedNode() orelse return null;
        if (item.is_directory) {
            try self.loadChildren(item);
            try self.setExpanded(item, !self.isExpanded(item));
            try self.rebuildVisible();
            return null;
        }
        return item.resource;
    }

    pub fn handleKey(self: *Sidebar, event: *const ui.KeyEvent) !Action {
        switch (event.key) {
            .up => {
                self.moveSelection(-1);
                return .handled;
            },
            .down => {
                self.moveSelection(1);
                return .handled;
            },
            .left => {
                try self.collapseSelected();
                return .handled;
            },
            .right => {
                try self.expandSelected();
                return .handled;
            },
            .home => {
                self.selected = 0;
                return .handled;
            },
            .end => {
                if (self.visible.items.len > 0) self.selected = self.visible.items.len - 1;
                return .handled;
            },
            .enter => {
                if (try self.toggleSelected()) |path| return .{ .open = path };
                return .handled;
            },
            .char => |ch| {
                if (ch == ' ') {
                    if (try self.toggleSelected()) |path| return .{ .open = path };
                    return .handled;
                }
            },
            else => {},
        }
        return .none;
    }

    /// Selects the row under a cell. A directory toggles on click; a file
    /// returns its path so the workbench can open it.
    pub fn handleClick(self: *Sidebar, x: usize, y: usize) !?[]const u8 {
        const rect = self.last_rect;
        if (x < ui.cell.snap(rect.x) or x >= ui.cell.snap(rect.right())) return null;
        const top = ui.cell.snap(rect.y);
        if (y <= top) return null;

        const row = y - top - 1 + self.scroll;
        if (row >= self.visible.items.len) return null;
        self.selected = row;
        return self.toggleSelected();
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

        const rows = height -| 1;
        if (rows == 0) return;
        if (self.selected >= self.visible.items.len and self.visible.items.len > 0) {
            self.selected = self.visible.items.len - 1;
        }
        if (self.selected < self.scroll) self.scroll = self.selected;
        if (self.selected >= self.scroll + rows) self.scroll = self.selected - rows + 1;

        var row: usize = 0;
        while (row < rows) : (row += 1) {
            const index = self.scroll + row;
            if (index >= self.visible.items.len) break;
            const entry = self.visible.items[index];
            const item = entry.item;
            const selected = index == self.selected;
            const paint = if (selected)
                (if (item.is_directory) selected_dir_style else selected_style)
            else if (item.is_directory)
                dir_style
            else
                text_style;
            if (selected) {
                grid.fillRect(
                    @floatFromInt(x),
                    @floatFromInt(y + 1 + row),
                    @floatFromInt(width),
                    1,
                    paint,
                );
            }

            var col: usize = 2;
            var indent: usize = 0;
            const indent_width = entry.depth * 2;
            while (indent < indent_width and col < width) : (indent += 1) {
                grid.putSpace(x + col, y + 1 + row, paint);
                col += 1;
            }

            const glyph: u21 = if (item.is_directory)
                (if (self.isExpanded(item)) '▾' else '▸')
            else
                ' ';
            if (col < width) {
                grid.putCodepoint(x + col, y + 1 + row, glyph, 1, paint);
                col += 1;
            }
            if (col < width) {
                grid.putSpace(x + col, y + 1 + row, paint);
                col += 1;
            }
            drawText(grid, x + col, y + 1 + row, width -| col, item.name, paint);
        }
    }
};

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

test "sidebar: lists directories first and toggles" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "alpha");
    try tmp.dir.createDirPath(io, "beta");
    var file = try tmp.dir.createFile(io, "z.txt", .{});
    try file.writeStreamingAll(io, "z");
    file.close(io);
    var file2 = try tmp.dir.createFile(io, "a.txt", .{});
    try file2.writeStreamingAll(io, "a");
    file2.close(io);

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    const sidebar = try Sidebar.init(allocator, io, context);
    defer sidebar.deinit();

    try std.testing.expectEqual(@as(usize, 4), sidebar.count());
    try std.testing.expectEqualStrings("alpha", sidebar.visible.items[0].item.name);
    try std.testing.expectEqualStrings("beta", sidebar.visible.items[1].item.name);
    try std.testing.expectEqualStrings("a.txt", sidebar.visible.items[2].item.name);
    try std.testing.expectEqualStrings("z.txt", sidebar.visible.items[3].item.name);

    try std.testing.expectEqual(Action.handled, try sidebar.handleKey(&.{ .key = .right }));
    try std.testing.expect(sidebar.isExpanded(sidebar.visible.items[0].item));
}

test "sidebar: enter on a file returns its path" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "open.txt", .{});
    try file.writeStreamingAll(io, "x");
    file.close(io);

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    const sidebar = try Sidebar.init(allocator, io, context);
    defer sidebar.deinit();

    const action = try sidebar.handleKey(&.{ .key = .enter });
    switch (action) {
        .open => |path| try std.testing.expect(std.mem.endsWith(u8, path, "open.txt")),
        else => return error.TestUnexpectedResult,
    }
}

test "sidebar: renders rows and handles clicks" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "click.txt", .{});
    try file.writeStreamingAll(io, "x");
    file.close(io);

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    const sidebar = try Sidebar.init(allocator, io, context);
    defer sidebar.deinit();

    var grid = try CellGrid.init(allocator, 24, 5);
    defer grid.deinit();
    try sidebar.render(&grid, .{ .x = 0, .y = 0, .w = 24, .h = 5 }, true);

    const header = try grid.rowText(allocator, 0);
    defer allocator.free(header);
    try std.testing.expect(std.mem.indexOf(u8, header, "EXPLORER") != null);
    const row = try grid.rowText(allocator, 1);
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "click.txt") != null);
    try std.testing.expect(std.mem.startsWith(u8, row, "  "));

    const opened = try sidebar.handleClick(4, 1);
    try std.testing.expect(opened != null);
    try std.testing.expect(std.mem.endsWith(u8, opened.?, "click.txt"));
}

test "sidebar: multi-root workspace shows root rows" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp_a = std.testing.tmpDir(.{});
    defer tmp_a.cleanup();
    var tmp_b = std.testing.tmpDir(.{});
    defer tmp_b.cleanup();

    var file = try tmp_a.dir.createFile(io, "root_file.txt", .{});
    try file.writeStreamingAll(io, "x");
    file.close(io);

    const root_a = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_a.sub_path});
    defer allocator.free(root_a);
    const root_b = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_b.sub_path});
    defer allocator.free(root_b);

    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{ root_a, root_b });
    defer context.deinit();
    const sidebar = try Sidebar.init(allocator, io, context);
    defer sidebar.deinit();

    try std.testing.expectEqual(@as(usize, 3), sidebar.count());
    try std.testing.expectEqualStrings(std.fs.path.basename(root_a), sidebar.visible.items[0].item.name);
    try std.testing.expectEqualStrings("root_file.txt", sidebar.visible.items[1].item.name);

    var grid = try CellGrid.init(allocator, 30, 7);
    defer grid.deinit();
    try sidebar.render(&grid, .{ .x = 0, .y = 0, .w = 30, .h = 7 }, true);
    const row = try grid.rowText(allocator, 2);
    defer allocator.free(row);
    try std.testing.expect(std.mem.startsWith(u8, row, "  "));
}
