//! Terminal Explorer view over the ported list/tree layer.
//!
//! This replaces the ad-hoc visible-row painting with a `CompressibleObjectTree`
//! backed by `CompressedObjectTreeModel(*ExplorerItem)`: virtualization,
//! selection, focus, keyboard/mouse scrolling, collapse state and
//! `explorer.compactFolders` come from the ported base tree views. The portable
//! Explorer model, ignore filtering and lazy directory resolution are shared
//! with the upstream-shaped `FilesFilter` in
//! `vs/workbench/contrib/files/browser/views/explorerViewer.zig`.
//!
//! Sticky scroll comes from the tree view: ancestor folders pin above the list
//! and `workbench.tree.enableStickyScroll` / `stickyScrollMaxItemCount` are
//! read at construction. The sticky rows reuse the Explorer row renderer, so
//! they keep twisties, Nerd Font icons, compressed labels and indentation.

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
const abstract_tree = @import("../../../../../base/browser/ui/tree/abstractTree.zig");
const file_icon = @import("../../../../browser/fileIcon.zig");

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

/// Background shared by the Explorer container and its rows. Upstream rows have
/// a transparent background and inherit the list background through CSS; the
/// terminal paints rows directly, so they must carry it explicitly. A row paint
/// that leaves `bg` unset resets those cells to the terminal default and reads
/// as a different rectangle behind the labels.
fn sidebarBackground(palette: ?*const theme_colors_mod.ThemeColors) PaintStyle {
    return if (palette) |theme|
        .{ .bg = ui.cell.packColor(theme.color("sideBar.background", .{ 30, 30, 33 })) }
    else
        .{};
}

/// Background for pinned sticky rows. Upstream's `sideBarStickyScroll
/// .background` defaults to the side bar background, so fall back to the
/// section-header tint (and finally a derived shade) when the theme does not
/// separate the two. This keeps the pinned rows visible on terminals without
/// cell-border support, where the bottom border cannot be drawn.
fn stickyRowBackground(palette: ?*const theme_colors_mod.ThemeColors) ui.Color {
    const theme = palette orelse return .{ .r = 42, .g = 45, .b = 46 };
    const side_bar = theme.color("sideBar.background", .{ 30, 30, 33 });
    const sticky = theme.colorOr("sideBarStickyScroll.background", side_bar);
    if (!colorsEqual(sticky, side_bar)) return sticky;
    const section_header = theme.colorOr("sideBarSectionHeader.background", .{ .r = 38, .g = 38, .b = 42 });
    if (!colorsEqual(section_header, side_bar)) return section_header;
    return shiftColor(side_bar, 12);
}

fn stickyScrollBorderColor(palette: ?*const theme_colors_mod.ThemeColors) ui.Color {
    const theme = palette orelse return .{ .r = 70, .g = 70, .b = 70 };
    return theme.color("sideBarStickyScroll.border", .{ 70, 70, 70 });
}

fn colorsEqual(a: ui.Color, b: ui.Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b;
}

/// Lightens dark colors and darkens light colors so the derived sticky
/// background always differs from the side bar background.
fn shiftColor(color: ui.Color, amount: i16) ui.Color {
    const luminance = @divTrunc(@as(i32, color.r) * 299 + @as(i32, color.g) * 587 + @as(i32, color.b) * 114, 1000);
    const delta: i32 = if (luminance < 128) amount else -amount;
    return .{
        .r = @intCast(std.math.clamp(@as(i32, color.r) + delta, 0, 255)),
        .g = @intCast(std.math.clamp(@as(i32, color.g) + delta, 0, 255)),
        .b = @intCast(std.math.clamp(@as(i32, color.b) + delta, 0, 255)),
    };
}

pub const Action = union(enum) {
    none,
    handled,
    open: []const u8,
};

/// Terminal view options. The side bar part owns the title area, so the
/// workbench renders the content without the view's own section header.
pub const RenderOptions = struct {
    show_header: bool = true,
    /// The terminal accepted the cell-border protocol. Sticky rows then get a
    /// bottom border as a cell attribute (no extra row); otherwise the row
    /// background alone distinguishes them.
    cell_borders: bool = false,
};

/// One async directory listing. It owns only the raw entry data; the tree item
/// is mutated when the result is applied on the TUI thread.
const ExplorerEntry = struct {
    name: []u8,
    /// Resolved `FileType` bits, mirroring upstream `readdir`.
    file_type: u8,
};

const ExplorerLoadResult = union(enum) {
    entries: []ExplorerEntry,
    err: anyerror,
};

const ExplorerLoadJob = struct {
    sidebar: *Sidebar,
    future: Io.Future(ExplorerLoadResult),
    done: std.atomic.Value(bool) = .init(false),
    item: *ExplorerItem,
    path: []u8,
    io: Io,

    fn deinit(self: *ExplorerLoadJob, allocator: Allocator) void {
        allocator.free(self.path);
        allocator.destroy(self);
    }
};

fn runExplorerLoad(job: *ExplorerLoadJob) ExplorerLoadResult {
    defer job.done.store(true, .release);
    const allocator = job.sidebar.allocator;
    const io = job.sidebar.async_io orelse return .{ .err = error.AsyncIoUnavailable };
    var dir = Io.Dir.cwd().openDir(io, job.path, .{ .iterate = true }) catch |err| return .{ .err = err };
    defer dir.close(io);

    var entries = std.array_list.Managed(ExplorerEntry).init(allocator);
    var iterator = dir.iterate();
    while (iterator.next(io) catch |err| {
        freeExplorerEntryList(allocator, &entries);
        return .{ .err = err };
    }) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        const name = allocator.dupe(u8, entry.name) catch |err| {
            freeExplorerEntryList(allocator, &entries);
            return .{ .err = err };
        };
        entries.append(.{
            .name = name,
            .file_type = explorer.entryFileType(io, allocator, job.path, entry),
        }) catch |err| {
            allocator.free(name);
            freeExplorerEntryList(allocator, &entries);
            return .{ .err = err };
        };
    }
    return .{ .entries = entries.toOwnedSlice() catch |err| {
        freeExplorerEntryList(allocator, &entries);
        return .{ .err = err };
    } };
}

fn freeExplorerEntryList(allocator: Allocator, entries: *std.array_list.Managed(ExplorerEntry)) void {
    for (entries.items) |entry| allocator.free(entry.name);
    entries.deinit();
}

fn freeExplorerEntries(allocator: Allocator, entries: []ExplorerEntry) void {
    for (entries) |entry| allocator.free(entry.name);
    allocator.free(entries);
}

pub const Sidebar = struct {
    allocator: Allocator,
    io: Io,
    /// Io handed over by the workbench for interactive directory expansion.
    /// Null keeps the synchronous startup/test path.
    async_io: ?Io = null,
    load_job: ?*ExplorerLoadJob = null,
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
    /// Cells per tree depth. Terminal unit for upstream's `workbench.tree.indent`
    /// pixels setting.
    indent_cells: usize = 2,
    render_indent_guides: abstract_tree.RenderIndentGuides = .on_hover,
    /// Set from `RenderOptions` for the current frame; controls whether sticky
    /// rows use terminal cell borders or the underline fallback.
    cell_borders: bool = false,

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
        self.indent_cells = readIndentCells(configuration);
        self.render_indent_guides = readRenderIndentGuides(configuration);
        self.tree = try CompressibleTree.init(allocator, "explorer", compression_enabled, .{
            .context = @ptrCast(self),
            .render = renderRow,
        }, .{
            .indent = self.indent_cells,
            .render_indent_guides = self.render_indent_guides,
            .enable_sticky_scroll = readEnableStickyScroll(configuration),
            .sticky_scroll_max_item_count = readStickyScrollMaxItemCount(configuration),
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
        self.cancelLoad();
        self.tree.deinit();
        self.force_expanded.deinit();
        self.files_filter.deinit();
        self.model.deinit();
        self.allocator.destroy(self);
    }

    /// Enables async interactive expansion. Startup/root loads stay sync.
    pub fn setAsyncIo(self: *Sidebar, io: Io) void {
        self.async_io = io;
    }

    pub fn hasPendingLoad(self: *const Sidebar) bool {
        return self.load_job != null;
    }

    fn requestLoad(self: *Sidebar, item: *ExplorerItem) !void {
        const async_io = self.async_io orelse return;
        if (self.load_job) |job| {
            if (job.item == item) return;
            self.cancelLoad();
        }
        const path = try self.allocator.dupe(u8, item.resource);
        errdefer self.allocator.free(path);
        const job = try self.allocator.create(ExplorerLoadJob);
        errdefer self.allocator.destroy(job);
        job.* = .{
            .sidebar = self,
            .future = undefined,
            .item = item,
            .path = path,
            .io = async_io,
        };
        job.future = async_io.async(runExplorerLoad, .{job});
        self.load_job = job;
    }

    /// Drains a completed directory listing on the TUI thread.
    pub fn pollLoad(self: *Sidebar) bool {
        const job = self.load_job orelse return false;
        if (!job.done.load(.acquire)) return false;
        const result = job.future.await(job.io);
        self.load_job = null;
        const item = job.item;
        job.deinit(self.allocator);

        var changed = false;
        switch (result) {
            .entries => |entries| {
                defer freeExplorerEntries(self.allocator, entries);
                if (item.is_directory_resolved or !self.isAttached(item)) return false;
                for (entries) |entry| {
                    const path = std.fs.path.join(self.allocator, &.{ item.resource, entry.name }) catch continue;
                    defer self.allocator.free(path);
                    const child = ExplorerItem.createWithFileType(
                        self.allocator,
                        path,
                        entry.name,
                        item,
                        entry.file_type,
                    ) catch continue;
                    item.children.append(child) catch {
                        child.destroy();
                        continue;
                    };
                }
                item.sortChildren(self.sort_order);
                item.is_directory_resolved = true;
                self.files_filter.prepare(item) catch {};
                self.setChildren(item, item.children.items) catch {};
                _ = self.tree.setCollapsed(item, false, false) catch {};
                self.selectElement(item);
                changed = true;
            },
            .err => {},
        }
        return changed;
    }

    pub fn cancelLoad(self: *Sidebar) void {
        const job = self.load_job orelse return;
        self.load_job = null;
        const result = job.future.cancel(job.io);
        if (result == .entries) freeExplorerEntries(self.allocator, result.entries);
        job.deinit(self.allocator);
    }

    fn isAttached(self: *Sidebar, item: *ExplorerItem) bool {
        const root = item.root();
        for (self.model.roots.items) |candidate| {
            if (candidate == root) return true;
        }
        return false;
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
        // Child updates must not scroll the viewport; upstream splices keep
        // the scroll position and restore the selected element in place.
        if (selected) |item| self.tree.setSelectionElementNoReveal(item);
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
            if (!item.is_directory_resolved and self.async_io != null) {
                try self.requestLoad(item);
                self.selectElement(item);
                return null;
            }
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
        // While the sticky widget owns the focus, upstream's
        // `list.stickyScroll*` commands take priority over the Explorer's own
        // Enter/Space handling. Tab enters the widget (the terminal analogue of
        // DOM tab order) and Escape leaves it.
        if (self.tree.stickyScrollFocused()) {
            if (event.key == .escape or event.key == .backtab) {
                self.tree.clearStickyScrollFocus();
                return .handled;
            }
            if (self.tree.handleKey(event)) return .handled;
            return .none;
        }
        if (event.key == .tab and self.tree.focusStickyScroll()) return .handled;

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

    pub fn clearHover(self: *Sidebar) void {
        self.tree.clearHover();
    }

    /// True while the pointer is over a file row (or a sticky pinned row);
    /// the workbench maps it to the hand pointer.
    pub fn hasHoveredRow(self: *const Sidebar) bool {
        return self.tree.hasHoveredRow();
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

        const sticky_hit = self.tree.stickyRowAt(x, y) != null;
        const event = ui.MouseEvent{
            .kind = .down,
            .x = x,
            .y = y,
            .button = .left,
        };
        if (!self.tree.handleMouse(&event)) return null;
        if (sticky_hit) {
            // Upstream's sticky click selects/reveals the node; a click on its
            // twistie additionally toggles the folder.
            const node = self.tree.selectionNode() orelse return null;
            const item = CompressibleTree.elementOfNode(node) orelse return null;
            if (item.is_directory) {
                const twistie_x = left + 2 + (node.depth -| 1) * self.indent_cells;
                if (x == twistie_x) return self.toggle(item);
            }
            return null;
        }

        // Ignore clicks below the last rendered row.
        const list_y = y - top - self.header_rows;
        const position = self.tree.view.widget.view.scroll_top + @as(f64, @floatFromInt(list_y));
        const index = self.tree.view.widget.view.range_map.indexAt(position);
        if (index < 0 or index >= @as(i64, @intCast(self.tree.count()))) return null;

        const node = self.tree.selectionNode() orelse return null;
        const item = CompressibleTree.elementOfNode(node) orelse return null;
        if (item.is_directory) {
            const visual_depth = node.depth -| 1;
            const twistie_x = left + 2 + visual_depth * self.indent_cells;
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
            const was_resolved = current.is_directory_resolved;
            if (!was_resolved) try self.loadChildren(current);

            var next: ?*ExplorerItem = null;
            for (current.children.items) |child| {
                if (std.mem.eql(u8, child.name, name)) {
                    next = child;
                    break;
                }
            }
            const item = next orelse return;

            // The single-folder root is the tree input and has no visible row;
            // its children were already installed by init(). Resolved folders
            // are already installed too, so re-splicing them would rebuild the
            // tree (and move the selection/scroll) for no change.
            if (!(current == root_item and !self.show_roots)) {
                if (!was_resolved or !self.tree.has(current)) {
                    try self.setChildren(current, current.children.items);
                }
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

        const background = sidebarBackground(self.theme);
        grid.fillRect(@floatFromInt(x), @floatFromInt(y), @floatFromInt(width), @floatFromInt(height), background);

        // Upstream the Explorer view pane container has no section header: the
        // side bar title area shows `EXPLORER` and its actions. The header
        // remains for standalone preview/test rendering.
        self.header_rows = if (options.show_header) 1 else 0;
        self.cell_borders = options.cell_borders;
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
        if (options.cell_borders) {
            renderStickyScrollBorder(self, grid, x, y + self.header_rows, list_width, rows);
        }

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

/// Port of upstream's `treeStickyScrollBorder` list style: the sticky
/// container's bottom border. The terminal draws it as a cell-border attribute
/// on the last pinned row, so it costs no row. Terminals without the protocol
/// fall back to the sticky row background.
fn renderStickyScrollBorder(
    self: *Sidebar,
    grid: *CellGrid,
    list_x: usize,
    list_y: usize,
    list_width: usize,
    rows: usize,
) void {
    const sticky_nodes = self.tree.stickyScrollNodes();
    if (sticky_nodes.len == 0 or list_width == 0 or rows == 0) return;

    var visible_bottom: f64 = 0;
    for (sticky_nodes) |sticky| {
        if (sticky.position >= @as(f64, @floatFromInt(rows))) continue;
        visible_bottom = @max(visible_bottom, @floor(sticky.position + sticky.height));
    }
    if (visible_bottom <= 0) return;

    const row_offset: usize = @min(@as(usize, @intFromFloat(visible_bottom)) - 1, rows - 1);
    const stroke = ui.cell_border.Stroke{
        .width = 16,
        .color = .{ .rgb = stickyScrollBorderColor(self.theme) },
        .placement = .centered,
        .layer = .below_text,
    };
    var col = list_x;
    while (col < list_x + list_width) : (col += 1) {
        grid.addBorder(col, list_y + row_offset, ui.cell_border.Segment.bottom, stroke);
    }
}

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

/// `workbench.tree.enableStickyScroll` defaults to true, like upstream's
/// workbench tree service. The Explorer reads it at construction time, the
/// same lifecycle as `workbench.tree.indent`.
fn readEnableStickyScroll(configuration: *ConfigurationService) bool {
    const value = configuration.getValue("workbench.tree.enableStickyScroll", .{}) orelse return true;
    return switch (value.*) {
        .bool => |inner| inner,
        else => true,
    };
}

/// `workbench.tree.stickyScrollMaxItemCount`, clamped to at least one, like
/// `validateStickySettings` in upstream's sticky controller.
fn readStickyScrollMaxItemCount(configuration: *ConfigurationService) usize {
    const value = configuration.getValue("workbench.tree.stickyScrollMaxItemCount", .{}) orelse return 7;
    const count: i64 = switch (value.*) {
        .integer => |inner| inner,
        .float => |inner| if (std.math.isFinite(inner) and inner >= 1 and inner <= 1_000_000)
            @intFromFloat(inner)
        else
            return 7,
        else => return 7,
    };
    if (count < 1) return 1;
    return @intCast(count);
}

fn readIndentCells(configuration: *ConfigurationService) usize {
    const value = configuration.getValue("workbench.tree.indent", .{}) orelse return 2;
    const cells: usize = switch (value.*) {
        .integer => |inner| if (inner > 0) @intCast(inner) else 2,
        else => 2,
    };
    return std.math.clamp(cells, 1, 6);
}

fn readRenderIndentGuides(configuration: *ConfigurationService) abstract_tree.RenderIndentGuides {
    const value = configuration.getValue("workbench.tree.renderIndentGuides", .{}) orelse return .on_hover;
    return switch (value.*) {
        .string => |inner| abstract_tree.RenderIndentGuides.fromString(inner),
        else => .on_hover,
    };
}

fn renderRow(context: *anyopaque, row: *const list.Row, node: *const CompressibleTree.Node) void {
    const sidebar: *Sidebar = @ptrCast(@alignCast(context));
    const compressed = node.element orelse return;
    if (compressed.elements.len == 0) return;
    const item = compressed.elements[compressed.elements.len - 1];
    const selected = row.selected;
    const sticky_highlight = row.sticky and (row.sticky_hovered or row.sticky_focused);
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
        // Unselected rows must repeat the side bar background on every painted
        // cell; the row is otherwise transparent over the container fill.
        const row_background = sidebarBackground(sidebar.theme).bg;
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
            .bg = row_background,
        } else .{
            .fg = ui.cell.packColor(palette.color("sideBar.foreground", .{ 190, 190, 190 })),
            .bg = row_background,
        };
    }

    if (row.sticky and !sticky_highlight) {
        paint.bg = ui.cell.packColor(stickyRowBackground(sidebar.theme));
    }
    if (row.sticky_last and !sidebar.cell_borders) {
        // Fallback for terminals without the cell-border protocol: underline
        // the whole bottom pinned row, which draws the separator on the
        // existing row instead of reserving one.
        paint.attrs |= ui.cell.Attr.underline;
    }

    if (sticky_highlight) {
        // Upstream sticky rows use `list.hoverBackground` on `:hover` and a
        // focus outline when the sticky widget has focus. The terminal paints
        // the hover background for both and bolds the focused row, the same
        // adaptation the editor sticky-scroll widget uses.
        const color = if (sidebar.theme) |palette|
            palette.color("list.hoverBackground", .{ 42, 45, 46 })
        else
            ui.Color{ .r = 42, .g = 45, .b = 46 };
        paint = .{
            .fg = paint.fg,
            .bg = ui.cell.packColor(color),
            .attrs = (if (row.sticky_focused) ui.cell.Attr.bold else 0) | (paint.attrs & ui.cell.Attr.underline),
        };
    }

    // Sticky rows overlay list rows, so they must cover the whole row; a
    // partial paint would leave the row underneath visible past the label.
    if (selected or sticky_highlight or row.sticky) {
        row.grid.fillRect(
            @floatFromInt(row.x),
            @floatFromInt(row.y),
            @floatFromInt(row.width),
            1,
            paint,
        );
    }

    var col = row.x + 2;
    const indent_width = (node.depth -| 1) * row.indent;
    var indent: usize = 0;
    while (indent < indent_width and col < row.x + row.width) : (indent += 1) {
        // One guide per ancestor level, painted at the first cell of its
        // indent slot. The terminal has no CSS borders, so the vertical
        // `│` is the same one-cell adaptation the pane borders use.
        if (row.render_indent_guides and indent % row.indent == 0) {
            const guide_color = if (sidebar.theme) |palette|
                palette.color("tree.indentGuidesStroke", .{ 80, 80, 80 })
            else
                ui.Color{ .r = 80, .g = 80, .b = 80 };
            const guide_paint = PaintStyle{ .fg = ui.cell.packColor(guide_color), .bg = paint.bg, .attrs = paint.attrs };
            row.grid.putCodepoint(col, row.y, '│', 1, guide_paint);
        } else {
            row.grid.putSpace(col, row.y, paint);
        }
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

    // Nerd Font file/folder icon, after the twistie and its gap, matching the
    // Explorer row order (twistie, file icon, label).
    {
        const icon = if (item.is_directory)
            file_icon.folder(!node.collapsed)
        else
            file_icon.file(item.name);
        if (col < row.x + row.width) {
            var icon_paint = PaintStyle{
                .fg = ui.cell.packColor(icon.color),
                .bg = paint.bg,
            };
            icon_paint.attrs = paint.attrs;
            row.grid.putCodepoint(col, row.y, icon.glyph, 1, icon_paint);
            col += 1;
        }
        if (col < row.x + row.width) {
            row.grid.putSpace(col, row.y, paint);
            col += 1;
        }
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

test "explorer tree sidebar: nerd font icons and hover indent guides" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "alpha");
    var nested = try tmp.dir.createFile(io, "alpha/beta.txt", .{});
    try nested.writeStreamingAll(io, "b");
    nested.close(io);
    var root_file = try tmp.dir.createFile(io, "z.txt", .{});
    try root_file.writeStreamingAll(io, "z");
    root_file.close(io);

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    const configuration = try ConfigurationService.init(allocator, io, context, .{});
    defer configuration.deinit();
    const sidebar = try Sidebar.init(allocator, io, context, configuration);
    defer sidebar.deinit();

    var grid = try ui.CellGrid.init(allocator, 24, 8);
    defer grid.deinit();
    try sidebar.render(&grid, .{ .x = 0, .y = 0, .w = 24, .h = 8 }, true, .{ .show_header = false });
    const closed = try grid.rowText(allocator, 0);
    defer allocator.free(closed);
    try std.testing.expect(std.mem.indexOf(u8, closed, "\u{f07b}") != null);

    var home = ui.KeyEvent{ .key = .home };
    _ = try sidebar.handleKey(&home);
    var right = ui.KeyEvent{ .key = .right };
    _ = try sidebar.handleKey(&right);
    var expanded_grid = try ui.CellGrid.init(allocator, 24, 8);
    defer expanded_grid.deinit();
    try sidebar.render(&expanded_grid, .{ .x = 0, .y = 0, .w = 24, .h = 8 }, true, .{ .show_header = false });
    const open_folder = try expanded_grid.rowText(allocator, 0);
    defer allocator.free(open_folder);
    try std.testing.expect(std.mem.indexOf(u8, open_folder, "\u{f07c}") != null);
    const child = try expanded_grid.rowText(allocator, 1);
    defer allocator.free(child);
    try std.testing.expect(std.mem.indexOf(u8, child, "beta.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, child, "\u{f15b}") != null);
    // Default `onHover`: no guide until the pointer is inside the list.
    try std.testing.expect(std.mem.indexOf(u8, child, "│") == null);

    const move = ui.MouseEvent{ .kind = .move, .x = 2, .y = 1, .button = .left };
    try std.testing.expect(sidebar.handleMouse(&move));
    try sidebar.render(&expanded_grid, .{ .x = 0, .y = 0, .w = 24, .h = 8 }, true, .{ .show_header = false });
    const hovered_child = try expanded_grid.rowText(allocator, 1);
    defer allocator.free(hovered_child);
    try std.testing.expect(std.mem.indexOf(u8, hovered_child, "│") != null);
}

test "explorer tree sidebar: row text keeps the theme side bar background" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const color_theme = @import("../../../../services/themes/common/colorThemeData.zig");
    const color_utils = @import("../../../../../platform/theme/common/colorUtils.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "alpha");
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

    var registry = color_utils.ColorRegistry.init(allocator);
    defer registry.deinit();
    const theme = try color_theme.ColorThemeData.createUnloadedTheme(allocator, &registry, "test", &.{
        .{ "sideBar.background", "#123456" },
    });
    defer theme.deinit();
    const palette = theme_colors_mod.ThemeColors.init(theme);
    sidebar.setThemeColors(&palette);

    var grid = try ui.CellGrid.init(allocator, 24, 6);
    defer grid.deinit();
    var home = ui.KeyEvent{ .key = .home };
    _ = try sidebar.handleKey(&home);
    try sidebar.render(&grid, .{ .x = 0, .y = 0, .w = 24, .h = 6 }, true, .{ .show_header = false });

    const file_row = try grid.rowText(allocator, 1);
    defer allocator.free(file_row);
    try std.testing.expect(std.mem.indexOf(u8, file_row, "z.txt") != null);

    // Every cell of the unselected file row keeps the side bar background.
    // Painting the label with an unset background resets those cells to the
    // terminal default and shows a differently colored rectangle behind it.
    const side_bar_bg = ui.cell.packColor(palette.color("sideBar.background", .{ 0, 0, 0 }));
    for (0..24) |col| {
        try std.testing.expectEqual(side_bar_bg, grid.bg[grid.index(col, 1)]);
    }

    // The selected first row keeps the active selection background.
    const selection_bg = ui.cell.packColor(palette.color("list.activeSelectionBackground", .{ 55, 65, 80 }));
    try std.testing.expectEqual(selection_bg, grid.bg[grid.index(0, 0)]);
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

test "explorer tree sidebar: expansion reads directories on the async Io" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "alpha");
    var nested = try tmp.dir.createFile(io, "alpha/beta.txt", .{});
    try nested.writeStreamingAll(io, "b");
    nested.close(io);

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    const configuration = try ConfigurationService.init(allocator, io, context, .{});
    defer configuration.deinit();

    var async_state = Io.Threaded.init(allocator, .{});
    defer async_state.deinit();

    const sidebar = try Sidebar.init(allocator, io, context, configuration);
    defer sidebar.deinit();
    sidebar.setAsyncIo(async_state.io());

    var home = ui.KeyEvent{ .key = .home };
    _ = try sidebar.handleKey(&home);
    const alpha = sidebar.selectedNode().?;
    try std.testing.expect(!sidebar.isExpanded(alpha));

    var right = ui.KeyEvent{ .key = .right };
    _ = try sidebar.handleKey(&right);
    try std.testing.expect(sidebar.hasPendingLoad());
    try std.testing.expect(!sidebar.isExpanded(alpha));

    var waited: usize = 0;
    while (!sidebar.pollLoad() and waited < 2000) : (waited += 1) {
        sidebar.async_io.?.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(!sidebar.hasPendingLoad());
    try std.testing.expect(sidebar.isExpanded(alpha));
    try std.testing.expect(alpha.is_directory_resolved);
    try std.testing.expect(alpha.getChild("beta.txt") != null);
}

test "explorer tree sidebar: async expansion resolves a symbolic link directory" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "real");
    var inner = try tmp.dir.createFile(io, "real/inner.txt", .{});
    try inner.writeStreamingAll(io, "inside");
    inner.close(io);
    try tmp.dir.symLink(io, "real", "link", .{ .is_directory = true });

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    const configuration = try ConfigurationService.init(allocator, io, context, .{});
    defer configuration.deinit();

    var async_state = Io.Threaded.init(allocator, .{});
    defer async_state.deinit();

    const sidebar = try Sidebar.init(allocator, io, context, configuration);
    defer sidebar.deinit();
    sidebar.setAsyncIo(async_state.io());

    const link = sidebar.model.roots.items[0].getChild("link").?;
    try std.testing.expect(link.is_directory);
    sidebar.tree.setSelectionElement(link);

    _ = try sidebar.handleKey(&.{ .key = .right });
    try std.testing.expect(sidebar.hasPendingLoad());

    var waited: usize = 0;
    while (!sidebar.pollLoad() and waited < 2000) : (waited += 1) {
        sidebar.async_io.?.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(!sidebar.hasPendingLoad());
    try std.testing.expect(sidebar.isExpanded(link));
    try std.testing.expect(link.is_directory_resolved);
    const inner_child = link.getChild("inner.txt").?;
    try std.testing.expect(!inner_child.is_directory);
    try std.testing.expect(!inner_child.is_symbolic_link);
}

test "explorer tree sidebar: symbolic link directories render and expand" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "real");
    var inner = try tmp.dir.createFile(io, "real/inner.txt", .{});
    try inner.writeStreamingAll(io, "inside");
    inner.close(io);
    try tmp.dir.symLink(io, "real", "link", .{ .is_directory = true });

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    const configuration = try ConfigurationService.init(allocator, io, context, .{});
    defer configuration.deinit();
    const sidebar = try Sidebar.init(allocator, io, context, configuration);
    defer sidebar.deinit();

    const link = sidebar.model.roots.items[0].getChild("link").?;
    try std.testing.expect(link.is_directory);
    try std.testing.expect(link.is_symbolic_link);

    // The link row paints the folder twistie and the folder glyph instead of
    // the generic file icon it used before resolving the target type.
    var grid = try ui.CellGrid.init(allocator, 24, 8);
    defer grid.deinit();
    try sidebar.render(&grid, .{ .x = 0, .y = 0, .w = 24, .h = 8 }, true, .{ .show_header = false });
    const link_row = try grid.rowText(allocator, 0);
    defer allocator.free(link_row);
    try std.testing.expect(std.mem.indexOf(u8, link_row, "link") != null);
    try std.testing.expect(std.mem.indexOf(u8, link_row, "▸") != null);
    try std.testing.expect(std.mem.indexOf(u8, link_row, "\u{f07b}") != null);

    sidebar.tree.setSelectionElement(link);
    _ = try sidebar.handleKey(&.{ .key = .right });
    try std.testing.expect(sidebar.isExpanded(link));
    try std.testing.expect(link.getChild("inner.txt") != null);

    var expanded_grid = try ui.CellGrid.init(allocator, 24, 8);
    defer expanded_grid.deinit();
    try sidebar.render(&expanded_grid, .{ .x = 0, .y = 0, .w = 24, .h = 8 }, true, .{ .show_header = false });
    const link_expanded_row = try expanded_grid.rowText(allocator, 0);
    defer allocator.free(link_expanded_row);
    try std.testing.expect(std.mem.indexOf(u8, link_expanded_row, "▾") != null);
    try std.testing.expect(std.mem.indexOf(u8, link_expanded_row, "\u{f07c}") != null);
    const inner_row = try expanded_grid.rowText(allocator, 1);
    defer allocator.free(inner_row);
    try std.testing.expect(std.mem.indexOf(u8, inner_row, "inner.txt") != null);

    // Files under the link keep the link path, so the editor reads the target
    // through it like any other file.
    sidebar.tree.setSelectionElement(link.getChild("inner.txt").?);
    switch (try sidebar.handleKey(&.{ .key = .enter })) {
        .open => |path| {
            const expected = try std.fs.path.join(allocator, &.{ root, "link", "inner.txt" });
            defer allocator.free(expected);
            try std.testing.expectEqualStrings(expected, path);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "explorer tree sidebar: sticky headers pin folder ancestors" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Three folder levels with a sibling in each folder so `compactFolders`
    // keeps them as separate rows instead of compressing the chain.
    try tmp.dir.createDirPath(io, "aaa/bbb/ccc");
    var file_a = try tmp.dir.createFile(io, "aaa/a.txt", .{});
    try file_a.writeStreamingAll(io, "a");
    file_a.close(io);
    var file_b = try tmp.dir.createFile(io, "aaa/bbb/b.txt", .{});
    try file_b.writeStreamingAll(io, "b");
    file_b.close(io);
    for (0..12) |i| {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "aaa/bbb/ccc/f{d:0>2}.txt", .{i});
        var file = try tmp.dir.createFile(io, name, .{});
        try file.writeStreamingAll(io, "x");
        file.close(io);
    }

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    const configuration = try ConfigurationService.init(allocator, io, context, .{});
    defer configuration.deinit();
    const sidebar = try Sidebar.init(allocator, io, context, configuration);
    defer sidebar.deinit();

    var grid = try ui.CellGrid.init(allocator, 32, 8);
    defer grid.deinit();
    // Lay the tree out once so the selection reveal knows the viewport height,
    // like the workbench's render-before-reveal ordering.
    try sidebar.render(&grid, .{ .x = 0, .y = 0, .w = 32, .h = 8 }, true, .{ .show_header = false });

    const deep = try std.fs.path.join(allocator, &.{ root, "aaa", "bbb", "ccc", "f11.txt" });
    defer allocator.free(deep);
    try sidebar.revealPath(deep);
    try sidebar.render(&grid, .{ .x = 0, .y = 0, .w = 32, .h = 8 }, true, .{ .show_header = false });

    try std.testing.expectEqual(@as(usize, 3), sidebar.tree.stickyScrollNodes().len);
    const row0 = try grid.rowText(allocator, 0);
    defer allocator.free(row0);
    const row1 = try grid.rowText(allocator, 1);
    defer allocator.free(row1);
    const row2 = try grid.rowText(allocator, 2);
    defer allocator.free(row2);
    const row3 = try grid.rowText(allocator, 3);
    defer allocator.free(row3);
    try std.testing.expect(std.mem.indexOf(u8, row0, "aaa") != null);
    try std.testing.expect(std.mem.indexOf(u8, row1, "bbb") != null);
    try std.testing.expect(std.mem.indexOf(u8, row2, "ccc") != null);
    // Row 0-2 are sticky copies of the ancestors; the list starts at f04.
    try std.testing.expect(std.mem.indexOf(u8, row3, "f07.txt") != null);

    // Focus enters the sticky widget with Tab and Enter reveals the sticky
    // folder in the tree instead of opening a file (`list.stickyScrollselect`).
    var tab = ui.KeyEvent{ .key = .tab };
    switch (try sidebar.handleKey(&tab)) {
        .handled => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(sidebar.tree.stickyScrollFocused());
    var enter = ui.KeyEvent{ .key = .enter };
    switch (try sidebar.handleKey(&enter)) {
        .handled => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(!sidebar.tree.stickyScrollFocused());
    try std.testing.expectEqualStrings("aaa", sidebar.selectedNode().?.name);

    // Selecting a row that is already visible must not move the viewport, and
    // the auto-reveal that follows opening it must not move it either.
    try sidebar.revealPath(deep);
    try sidebar.render(&grid, .{ .x = 0, .y = 0, .w = 32, .h = 8 }, true, .{ .show_header = false });
    const scroll_before_file_click = sidebar.tree.view.widget.view.scroll_top;
    const clicked = try sidebar.handleClick(10, 3);
    try std.testing.expect(clicked != null);
    try std.testing.expectEqual(scroll_before_file_click, sidebar.tree.view.widget.view.scroll_top);
    try sidebar.revealPath(clicked.?);
    try std.testing.expectEqual(scroll_before_file_click, sidebar.tree.view.widget.view.scroll_top);

    // Clicking a sticky row jumps to the node and selects it in the list,
    // matching upstream `handleStickyScrollMouseEvent`.
    try sidebar.revealPath(deep);
    try sidebar.render(&grid, .{ .x = 0, .y = 0, .w = 32, .h = 8 }, true, .{ .show_header = false });
    const down = ui.MouseEvent{ .kind = .down, .x = 10, .y = 1, .button = .left };
    try std.testing.expect(sidebar.handleMouse(&down));
    try std.testing.expect(!sidebar.tree.stickyScrollFocused());
    try std.testing.expectEqualStrings("bbb", sidebar.selectedNode().?.name);
    try std.testing.expect(sidebar.isExpanded(sidebar.selectedNode().?));
    const click = try sidebar.handleClick(10, 1);
    try std.testing.expect(click == null);

    // Clicking the sticky row's twistie also toggles the folder.
    try sidebar.revealPath(deep);
    try sidebar.render(&grid, .{ .x = 0, .y = 0, .w = 32, .h = 8 }, true, .{ .show_header = false });
    const ccc = sidebar.selectedNode().?.parent.?;
    try std.testing.expectEqualStrings("ccc", ccc.name);
    try std.testing.expect(sidebar.isExpanded(ccc));
    _ = try sidebar.handleClick(6, 2);
    try std.testing.expect(!sidebar.isExpanded(ccc));
}

test "explorer tree sidebar: sticky headers honor the tree settings" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var settings = try tmp.dir.createFile(io, "settings.json", .{});
    try settings.writeStreamingAll(io, "{\"workbench.tree.stickyScrollMaxItemCount\": 1}");
    settings.close(io);
    try tmp.dir.createDirPath(io, "aaa/bbb/ccc");
    var file_a = try tmp.dir.createFile(io, "aaa/a.txt", .{});
    try file_a.writeStreamingAll(io, "a");
    file_a.close(io);
    var file_b = try tmp.dir.createFile(io, "aaa/bbb/b.txt", .{});
    try file_b.writeStreamingAll(io, "b");
    file_b.close(io);
    for (0..12) |i| {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "aaa/bbb/ccc/f{d:0>2}.txt", .{i});
        var file = try tmp.dir.createFile(io, name, .{});
        try file.writeStreamingAll(io, "x");
        file.close(io);
    }

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    const settings_path = try std.fs.path.join(allocator, &.{ root, "settings.json" });
    defer allocator.free(settings_path);
    const configuration = try ConfigurationService.init(allocator, io, context, .{
        .user_settings_paths = &.{settings_path},
    });
    defer configuration.deinit();
    const sidebar = try Sidebar.init(allocator, io, context, configuration);
    defer sidebar.deinit();

    var grid = try ui.CellGrid.init(allocator, 32, 8);
    defer grid.deinit();
    try sidebar.render(&grid, .{ .x = 0, .y = 0, .w = 32, .h = 8 }, true, .{ .show_header = false });

    const deep = try std.fs.path.join(allocator, &.{ root, "aaa", "bbb", "ccc", "f11.txt" });
    defer allocator.free(deep);
    try sidebar.revealPath(deep);
    try sidebar.render(&grid, .{ .x = 0, .y = 0, .w = 32, .h = 8 }, true, .{ .show_header = false });
    try std.testing.expectEqual(@as(usize, 1), sidebar.tree.stickyScrollNodes().len);
    const row0 = try grid.rowText(allocator, 0);
    defer allocator.free(row0);
    // The overflow chain renders as one compressed sticky row.
    try std.testing.expect(std.mem.indexOf(u8, row0, "aaa/bbb/ccc") != null);

    // `workbench.tree.enableStickyScroll: false` removes the widget entirely.
    var disabled_settings = try tmp.dir.createFile(io, "settings_off.json", .{});
    try disabled_settings.writeStreamingAll(io, "{\"workbench.tree.enableStickyScroll\": false}");
    disabled_settings.close(io);
    const disabled_path = try std.fs.path.join(allocator, &.{ root, "settings_off.json" });
    defer allocator.free(disabled_path);
    const disabled_configuration = try ConfigurationService.init(allocator, io, context, .{
        .user_settings_paths = &.{disabled_path},
    });
    defer disabled_configuration.deinit();
    const disabled_sidebar = try Sidebar.init(allocator, io, context, disabled_configuration);
    defer disabled_sidebar.deinit();
    var disabled_grid = try ui.CellGrid.init(allocator, 32, 8);
    defer disabled_grid.deinit();
    try disabled_sidebar.render(&disabled_grid, .{ .x = 0, .y = 0, .w = 32, .h = 8 }, true, .{ .show_header = false });
    try disabled_sidebar.revealPath(deep);
    try disabled_sidebar.render(&disabled_grid, .{ .x = 0, .y = 0, .w = 32, .h = 8 }, true, .{ .show_header = false });
    try std.testing.expectEqual(@as(usize, 0), disabled_sidebar.tree.stickyScrollNodes().len);
}

test "explorer tree sidebar: sticky rows use a header tint and bottom cell border" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const color_theme = @import("../../../../services/themes/common/colorThemeData.zig");
    const color_utils = @import("../../../../../platform/theme/common/colorUtils.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "aaa/bbb/ccc");
    var file_a = try tmp.dir.createFile(io, "aaa/a.txt", .{});
    try file_a.writeStreamingAll(io, "a");
    file_a.close(io);
    var file_b = try tmp.dir.createFile(io, "aaa/bbb/b.txt", .{});
    try file_b.writeStreamingAll(io, "b");
    file_b.close(io);
    for (0..12) |i| {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "aaa/bbb/ccc/f{d:0>2}.txt", .{i});
        var file = try tmp.dir.createFile(io, name, .{});
        try file.writeStreamingAll(io, "x");
        file.close(io);
    }

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    const configuration = try ConfigurationService.init(allocator, io, context, .{});
    defer configuration.deinit();
    const sidebar = try Sidebar.init(allocator, io, context, configuration);
    defer sidebar.deinit();

    var registry = color_utils.ColorRegistry.init(allocator);
    defer registry.deinit();
    const theme = try color_theme.ColorThemeData.createUnloadedTheme(allocator, &registry, "test", &.{
        .{ "sideBar.background", "#101010" },
        .{ "sideBarSectionHeader.background", "#202020" },
        .{ "sideBarStickyScroll.border", "#abcdef" },
    });
    defer theme.deinit();
    const palette = theme_colors_mod.ThemeColors.init(theme);
    sidebar.setThemeColors(&palette);

    var grid = try ui.CellGrid.init(allocator, 32, 8);
    defer grid.deinit();
    try sidebar.render(&grid, .{ .x = 0, .y = 0, .w = 32, .h = 8 }, true, .{ .show_header = false });

    const deep = try std.fs.path.join(allocator, &.{ root, "aaa", "bbb", "ccc", "f11.txt" });
    defer allocator.free(deep);
    try sidebar.revealPath(deep);
    try sidebar.render(&grid, .{ .x = 0, .y = 0, .w = 32, .h = 8 }, true, .{ .show_header = false });
    try std.testing.expectEqual(@as(usize, 3), sidebar.tree.stickyScrollNodes().len);

    // Pinned rows use the section-header tint, while a normal row keeps the
    // side bar background.
    const sticky_bg = ui.cell.packColor(palette.color("sideBarSectionHeader.background", .{ 0, 0, 0 }));
    const side_bar_bg = ui.cell.packColor(palette.color("sideBar.background", .{ 0, 0, 0 }));
    try std.testing.expectEqual(sticky_bg, grid.bg[grid.index(0, 0)]);
    try std.testing.expectEqual(sticky_bg, grid.bg[grid.index(0, 2)]);
    try std.testing.expectEqual(side_bar_bg, grid.bg[grid.index(0, 3)]);

    // Without the cell-border protocol there is no border attribute; the
    // fallback underlines the bottom pinned row so the separator still draws
    // on an existing row. Rows above it and the list rows below are untouched.
    try std.testing.expectEqual(@as(u16, 0), grid.borderIdAt(0, 2));
    try std.testing.expect(grid.attrs[grid.index(0, 2)] & ui.cell.Attr.underline != 0);
    try std.testing.expectEqual(@as(u16, 0), grid.attrs[grid.index(0, 1)] & ui.cell.Attr.underline);
    try std.testing.expectEqual(@as(u16, 0), grid.attrs[grid.index(0, 3)] & ui.cell.Attr.underline);
    try sidebar.render(&grid, .{ .x = 0, .y = 0, .w = 32, .h = 8 }, true, .{
        .show_header = false,
        .cell_borders = true,
    });
    const border = grid.borderSetAt(0, 2);
    try std.testing.expect(border.count > 0);
    var has_bottom = false;
    for (border.groups[0..border.count]) |group| {
        if (group.mask & ui.cell_border.Segment.bottom != 0) has_bottom = true;
    }
    try std.testing.expect(has_bottom);
    try std.testing.expectEqual(@as(u16, 0), grid.borderIdAt(0, 3));
    // The cell-border path replaces the underline fallback.
    try std.testing.expectEqual(@as(u16, 0), grid.attrs[grid.index(0, 2)] & ui.cell.Attr.underline);
}
