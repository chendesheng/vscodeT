// Port of `src/vs/workbench/contrib/outline/browser/outlinePane.ts` to the
// terminal list layer.
//
// Faithful pieces: the pane follows the active editor, creates an outline
// through the ported `IOutlineService`, shows the provider's tree with
// expand/collapse, selection, marker rollups, follow-cursor reveal, sort by
// position/name/kind, filter-on-type and the Collapse All / Expand All /
// Follow Cursor / Filter on Type / Sort By title actions. The pane listens to
// the editor's view events for cursor and content changes, matching upstream's
// `onDidChangeCursorPosition` / `onDidChangeModelContent` flow (the terminal
// editor has no separate model events; `ViewCursorStateChanged` and
// `ViewLinesChanged` are its event surface).
//
// Terminal adaptations (documented in README/docs/terminal-ui.md): the browser
// workbench data tree and its DOM renderers are replaced by the ported
// `ListWidget` plus the outline tree snapshot from `DocumentSymbolsOutline`.
// Tree state is not persisted (no workspace storage), and `Loading document
// symbols...` is not shown because outline creation is synchronous. The
// filter input is typed directly in the pane like the browser tree's find
// widget, but rendered without a separate input row.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const views = @import("../../../common/views.zig");
const outline_mod = @import("../../../services/outline/browser/outline.zig");
const outline_service_mod = @import("../../../services/outline/browser/outlineService.zig");
const OutlineService = outline_service_mod.OutlineService;
const OutlineEditor = outline_mod.OutlineEditor;
const IOutline = outline_mod.IOutline;
const TreeElement = outline_mod.TreeElement;
const theme_colors_mod = @import("../../../browser/themeColors.zig");
const list_mod = @import("../../../../base/browser/ui/list/list.zig");
const list_widget_mod = @import("../../../../base/browser/ui/list/listWidget.zig");
const ListWidget = list_widget_mod.ListWidget;
const view_state_mod = @import("./outline.zig");
const OutlineViewState = view_state_mod.OutlineViewState;
const OutlineSortOrder = view_state_mod.OutlineSortOrder;
const goto_symbol = @import("../../codeEditor/browser/quickaccess/gotoSymbolQuickAccess.zig");
const Editor = @import("../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const view_events = @import("../../../../editor/common/viewEvents.zig");
const view_handler_mod = @import("../../../../editor/common/viewEventHandler.zig");
const ViewEventHandler = view_handler_mod.ViewEventHandler;
const time_compat = @import("../../../../base/common/timeCompat.zig");
const markerSeverity = @import("../../../../platform/markers/common/markers.zig").MarkerSeverity;

pub const Host = struct {
    context: *anyopaque,
    active_editor: *const fn (context: *anyopaque) ?OutlineEditor,
    active_resource: *const fn (context: *anyopaque) ?[]const u8,
    current_position: *const fn (context: *anyopaque) ?@import("../../../../editor/common/core/position.zig").Position,
    request_render: *const fn (context: *anyopaque) void,
    focus_editor: *const fn (context: *anyopaque) void,
    is_symbol_visible: *const fn (context: *anyopaque, kind: u32) bool,
};

const Row = struct {
    element: *anyopaque,
    id: []const u8,
    label: []const u8,
    kind: ?u32,
    depth: usize,
    collapsible: bool,
    collapsed: bool,
    marker_count: usize,
    marker_severity: ?u32,
    deprecated: bool,
    is_group: bool,
};

const SortContext = struct {
    pane: *OutlinePane,
    order: OutlineSortOrder,
};

pub const OutlinePane = struct {
    allocator: Allocator,
    host: Host,
    outline_service: *OutlineService,
    view_state: OutlineViewState,
    outline: ?*IOutline = null,
    rows: std.array_list.Managed(*Row),
    row_arena: std.heap.ArenaAllocator,
    list: ListWidget,
    collapsed_ids: std.StringHashMap(void),
    editor: ?*Editor = null,
    view_handler: ViewEventHandler = .{},
    handler_attached: bool = false,
    selected_element: ?*anyopaque = null,
    filter_text: std.array_list.Managed(u8),
    message: ?[]const u8 = null,
    theme: ?*const theme_colors_mod.ThemeColors = null,
    focused: bool = false,
    pending_rebuild_at: ?i64 = null,
    border: bool = false,
    action_buf: [6]views.TitleAction = undefined,

    pub fn init(
        allocator: Allocator,
        host: Host,
        outline_service: *OutlineService,
    ) !*OutlinePane {
        const self = try allocator.create(OutlinePane);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .host = host,
            .outline_service = outline_service,
            .view_state = OutlineViewState.init(allocator),
            .rows = std.array_list.Managed(*Row).init(allocator),
            .row_arena = std.heap.ArenaAllocator.init(allocator),
            .list = ListWidget.init(allocator, .{
                .context = @ptrCast(self),
                .get_height = rowHeight,
                .get_template_id = rowTemplate,
            }, .{
                .context = @ptrCast(self),
                .render = renderRow,
            }),
            .collapsed_ids = std.StringHashMap(void).init(allocator),
            .view_handler = ViewEventHandler.init(self, .{
                .onCursorStateChanged = onCursorStateChanged,
                .onLinesChanged = onLinesChanged,
                .onLinesInserted = onLinesInserted,
                .onLinesDeleted = onLinesDeleted,
                .onFlushed = onFlushed,
            }),
            .filter_text = std.array_list.Managed(u8).init(allocator),
        };
        self.list.on_activate = activate;
        self.list.activation_context = self;
        self.list.on_selection = selectionChanged;
        self.list.selection_context = self;
        return self;
    }

    pub fn deinit(self: *OutlinePane) void {
        self.detachEditor();
        self.disposeOutline();
        self.view_state.deinit();
        for (self.rows.items) |row| self.allocator.destroy(row);
        self.rows.deinit();
        self.row_arena.deinit();
        self.collapsed_ids.deinit();
        self.filter_text.deinit();
        self.list.deinit();
        self.allocator.destroy(self);
    }

    pub fn titleActions(self: *OutlinePane) []const views.TitleAction {
        const all_collapsed = self.isAllCollapsed();
        const follow = self.view_state.follow_cursor;
        var count: usize = 0;
        self.action_buf[count] = .{
            .id = if (all_collapsed) "outline.expand" else "outline.collapse",
            .label = if (all_collapsed) "Expand All" else "Collapse All",
            .glyph = if (all_collapsed) 0x229E else 0x229F,
        };
        count += 1;
        self.action_buf[count] = .{
            .id = "outline.followCursor",
            .label = "Follow Cursor",
            .glyph = if (follow) 0x25C9 else 0x25CB,
        };
        count += 1;
        self.action_buf[count] = .{
            .id = "outline.filterOnType",
            .label = "Filter on Type",
            .glyph = if (self.view_state.filter_on_type) 'F' else 'f',
        };
        count += 1;
        self.action_buf[count] = .{
            .id = "outline.sortByPosition",
            .label = "Sort By: Position",
            .glyph = 0x21C5,
            .enabled = self.view_state.sort_by != .ByPosition,
        };
        count += 1;
        self.action_buf[count] = .{
            .id = "outline.sortByName",
            .label = "Sort By: Name",
            .glyph = 'A',
            .enabled = self.view_state.sort_by != .ByName,
        };
        count += 1;
        self.action_buf[count] = .{
            .id = "outline.sortByKind",
            .label = "Sort By: Category",
            .glyph = 'T',
            .enabled = self.view_state.sort_by != .ByKind,
        };
        count += 1;
        return self.action_buf[0..count];
    }

    pub fn setThemeColors(self: *OutlinePane, palette: ?*const theme_colors_mod.ThemeColors) void {
        self.theme = palette;
    }

    pub fn setBorderRendering(self: *OutlinePane, enabled: bool) void {
        self.border = enabled;
    }

    pub fn isFocused(self: *const OutlinePane) bool {
        return self.focused;
    }

    /// Updates the view's selection/focus state without changing the editor.
    pub fn setFocused(self: *OutlinePane, focused: bool) void {
        self.focused = focused;
        self.list.setFocus(focused);
        if (!focused) self.list.clearHover();
    }

    /// Rebinds the pane to the active editor. Called by the workbench when the
    /// active tab or group changes; the editor's view events then drive cursor
    /// following and debounced content rebuilds.
    pub fn setEditor(self: *OutlinePane, editor: ?*Editor) !void {
        if (self.editor == editor) return;
        self.detachEditor();
        self.editor = editor;
        if (editor) |value| {
            value.addViewEventHandler(&self.view_handler);
            self.handler_attached = true;
        }
        self.selected_element = null;
        try self.refresh();
    }

    fn detachEditor(self: *OutlinePane) void {
        if (self.handler_attached) {
            if (self.editor) |editor| editor.removeViewEventHandler(&self.view_handler);
        }
        self.handler_attached = false;
        self.editor = null;
    }

    /// Recreates the outline for the current editor, matching upstream's
    /// `createOutline` hand-off. The terminal service is synchronous.
    pub fn refresh(self: *OutlinePane) !void {
        self.pending_rebuild_at = null;
        self.disposeOutline();
        self.list.setSelection(null);
        self.selected_element = null;
        self.message = null;

        const editor = self.host.active_editor(self.host.context);
        if (editor == null or self.editor == null) {
            self.message = "The active editor cannot provide outline information.";
            self.rows.clearRetainingCapacity();
            try self.replaceList();
            return;
        }
        if (!self.outline_service.canCreateOutline(editor.?)) {
            self.message = "The active editor cannot provide outline information.";
            self.rows.clearRetainingCapacity();
            try self.replaceList();
            return;
        }

        const outline = self.outline_service.createOutline(editor.?, .OutlinePane) catch null;
        if (outline == null) {
            self.message = "The active editor cannot provide outline information.";
            self.rows.clearRetainingCapacity();
            try self.replaceList();
            return;
        }
        self.outline = outline;
        if (outline.?.config.collapse_by_default) self.initCollapsed();
        try self.rebuildRows();
        if (outline.?.is_empty) {
            self.message = "No symbols found in the active document.";
        } else if (self.view_state.follow_cursor) {
            _ = self.revealActiveElement();
        }
    }

    fn disposeOutline(self: *OutlinePane) void {
        if (self.outline) |outline| {
            outline.dispose();
            self.outline = null;
        }
    }

    pub fn poll(self: *OutlinePane, now_ms: i64) bool {
        const due = self.pending_rebuild_at orelse return false;
        if (now_ms < due) return false;
        self.pending_rebuild_at = null;
        self.refresh() catch {
            self.message = "The outline could not be created.";
            self.rows.clearRetainingCapacity();
            self.replaceList() catch {};
        };
        self.host.request_render(self.host.context);
        return true;
    }

    pub fn wantsTick(self: *const OutlinePane) bool {
        return self.pending_rebuild_at != null;
    }

    pub fn timeout(self: *const OutlinePane, now_ms: i64) ?i64 {
        const due = self.pending_rebuild_at orelse return null;
        return @max(due - now_ms, 0);
    }

    fn onCursorStateChanged(context: *anyopaque, _: *const view_events.ViewCursorStateChangedEvent) bool {
        const self: *OutlinePane = @ptrCast(@alignCast(context));
        if (!self.view_state.follow_cursor) return false;
        const changed = self.revealActiveElement();
        if (changed) self.host.request_render(self.host.context);
        return changed;
    }

    fn onLinesChanged(context: *anyopaque, _: *const view_events.ViewLinesChangedEvent) bool {
        return scheduleRebuild(context);
    }

    fn onLinesInserted(context: *anyopaque, _: *const view_events.ViewLinesInsertedEvent) bool {
        return scheduleRebuild(context);
    }

    fn onLinesDeleted(context: *anyopaque, _: *const view_events.ViewLinesDeletedEvent) bool {
        return scheduleRebuild(context);
    }

    fn onFlushed(context: *anyopaque, _: *const view_events.ViewFlushedEvent) bool {
        return scheduleRebuild(context);
    }

    fn scheduleRebuild(context: *anyopaque) bool {
        const self: *OutlinePane = @ptrCast(@alignCast(context));
        self.pending_rebuild_at = time_compat.milliTimestamp() + 200;
        return false;
    }

    pub fn setFollowCursor(self: *OutlinePane, value: bool) !void {
        try self.view_state.setFollowCursor(value);
        if (value) _ = self.revealActiveElement();
        self.host.request_render(self.host.context);
    }

    pub fn setFilterOnType(self: *OutlinePane, value: bool) !void {
        try self.view_state.setFilterOnType(value);
        if (!value) {
            self.filter_text.clearRetainingCapacity();
            try self.rebuildRows();
        }
        self.host.request_render(self.host.context);
    }

    pub fn setSortBy(self: *OutlinePane, order: OutlineSortOrder) !void {
        try self.view_state.setSortBy(order);
        try self.rebuildRows();
        self.host.request_render(self.host.context);
    }

    pub fn collapseAll(self: *OutlinePane) void {
        self.collapsed_ids.clearRetainingCapacity();
        if (self.outline) |outline| {
            if (outline.config.tree_data_source) |source| {
                for (source.get_roots(source.context)) |root| collectCollapsible(self, root);
            }
        }
        self.rebuildRows() catch {};
        self.host.request_render(self.host.context);
    }

    fn initCollapsed(self: *OutlinePane) void {
        self.collapsed_ids.clearRetainingCapacity();
        if (self.outline) |outline| {
            if (outline.config.tree_data_source) |source| {
                for (source.get_roots(source.context)) |root| collectCollapsible(self, root);
            }
        }
    }

    pub fn expandAll(self: *OutlinePane) void {
        self.collapsed_ids.clearRetainingCapacity();
        self.rebuildRows() catch {};
        self.host.request_render(self.host.context);
    }

    pub fn isAllCollapsed(self: *const OutlinePane) bool {
        var found = false;
        if (self.outline) |outline| {
            if (outline.config.tree_data_source) |source| {
                for (source.get_roots(source.context)) |root| {
                    if (hasCollapsible(root)) {
                        found = true;
                        if (!self.isCollapsed(root)) return false;
                    }
                }
            }
        }
        return found;
    }

    pub fn hasHoveredRow(self: *const OutlinePane) bool {
        return self.list.hasHoveredRow();
    }

    pub fn clearHover(self: *OutlinePane) void {
        self.list.clearHover();
    }

    fn collectCollapsible(self: *OutlinePane, element: TreeElement) void {
        if (element.collapsible) self.collapsed_ids.put(element.id, {}) catch {};
        for (element.children) |child| self.collectCollapsible(child);
    }

    fn hasCollapsible(element: TreeElement) bool {
        if (element.collapsible) return true;
        for (element.children) |child| {
            if (hasCollapsible(child)) return true;
        }
        return false;
    }

    fn isCollapsed(self: *const OutlinePane, element: TreeElement) bool {
        return element.collapsible and self.collapsed_ids.contains(element.id);
    }

    fn rebuildRows(self: *OutlinePane) !void {
        const selected = self.selected_element;
        for (self.rows.items) |row| self.allocator.destroy(row);
        self.rows.clearRetainingCapacity();
        _ = self.row_arena.reset(.retain_capacity);

        if (self.outline) |outline| {
            if (outline.config.tree_data_source) |source| {
                const roots = source.get_roots(source.context);
                const sorted = try self.sortedElements(roots);
                defer self.allocator.free(sorted);
                for (sorted) |element| try self.appendElement(element, 0);
            }
        }
        try self.replaceList();
        if (selected) |element| {
            for (self.rows.items, 0..) |row, index| {
                if (row.element == element) {
                    self.list.selectOnly(index);
                    break;
                }
            }
        }
    }

    fn appendElement(self: *OutlinePane, element: TreeElement, depth: usize) !void {
        if (self.outline) |outline| {
            if (outline.config.filter) |filter| {
                if (!filter.is_visible(filter.context, element.element)) return;
            }
        }
        if (self.filter_text.items.len > 0 and !self.subtreeMatches(element)) return;

        const row = try self.allocator.create(Row);
        errdefer self.allocator.destroy(row);
        row.* = .{
            .element = element.element,
            .id = element.id,
            .label = element.label,
            .kind = element.symbol_kind,
            .depth = depth,
            .collapsible = element.collapsible,
            .collapsed = self.isCollapsed(element),
            .marker_count = element.marker_count,
            .marker_severity = element.marker_severity,
            .deprecated = element.deprecated,
            .is_group = element.is_group,
        };
        try self.rows.append(row);

        if (element.collapsible and row.collapsed and self.filter_text.items.len == 0) return;
        const sorted = try self.sortedElements(element.children);
        defer self.allocator.free(sorted);
        for (sorted) |child| try self.appendElement(child, depth + 1);
    }

    fn subtreeMatches(self: *OutlinePane, element: TreeElement) bool {
        if (matchesFilter(self.filter_text.items, element.label)) return true;
        for (element.children) |child| {
            if (self.subtreeMatches(child)) return true;
        }
        return false;
    }

    fn sortedElements(self: *OutlinePane, elements: []const TreeElement) ![]TreeElement {
        const copy = try self.allocator.dupe(TreeElement, elements);
        if (self.outline) |outline| {
            if (outline.config.comparator != null) {
                const context = SortContext{ .pane = self, .order = self.view_state.sort_by };
                std.mem.sort(TreeElement, copy, context, struct {
                    fn lessThan(ctx: SortContext, a: TreeElement, b: TreeElement) bool {
                        const compare = ctx.pane.outline.?.config.comparator.?;
                        const order = switch (ctx.order) {
                            .ByPosition => compare.compare_by_position(compare.context, a.element, b.element),
                            .ByName => compare.compare_by_name(compare.context, a.element, b.element),
                            .ByKind => compare.compare_by_type(compare.context, a.element, b.element),
                        };
                        return order == .lt;
                    }
                }.lessThan);
            }
        }
        return copy;
    }

    fn replaceList(self: *OutlinePane) !void {
        var elements = std.array_list.Managed(list_mod.Element).init(self.row_arena.allocator());
        defer elements.deinit();
        for (self.rows.items) |row| try elements.append(@ptrCast(row));
        try self.list.replaceAll(elements.items);
        if (self.selected_element) |selected| {
            for (self.rows.items, 0..) |row, index| {
                if (row.element == selected) {
                    self.list.selectOnly(index);
                    return;
                }
            }
            self.list.selectOnly(null);
        }
    }

    fn revealActiveElement(self: *OutlinePane) bool {
        const outline = self.outline orelse return false;
        var candidate = outline.activeElement() orelse return false;
        while (true) {
            for (self.rows.items, 0..) |row, index| {
                if (row.element == candidate) {
                    if (self.list.selection() == index) return false;
                    self.list.setSelection(index);
                    self.selected_element = candidate;
                    return true;
                }
            }
            candidate = outline.getParent(candidate) orelse return false;
        }
    }

    fn rowHeight(_: *anyopaque, _: list_mod.Element) f64 {
        return 1;
    }

    fn rowTemplate(_: *anyopaque, _: list_mod.Element) usize {
        return 0;
    }

    fn renderRow(context: *anyopaque, row: *const list_mod.Row, element: list_mod.Element) void {
        const self: *OutlinePane = @ptrCast(@alignCast(context));
        const item: *const Row = @ptrCast(@alignCast(element));
        drawRow(self, row, item);
    }

    fn selectionChanged(context: ?*anyopaque, selection: ?usize) void {
        const self: *OutlinePane = @ptrCast(@alignCast(context orelse return));
        if (selection) |index| {
            if (index < self.rows.items.len) self.selected_element = self.rows.items[index].element;
        }
        self.host.request_render(self.host.context);
    }

    fn activate(context: ?*anyopaque, index: usize) void {
        const self: *OutlinePane = @ptrCast(@alignCast(context orelse return));
        if (index >= self.rows.items.len) return;
        const outline = self.outline orelse return;
        outline.reveal(self.rows.items[index].element, .{ .select = false }) catch {};
        self.host.focus_editor(self.host.context);
    }

    pub fn render(self: *OutlinePane, grid: *ui.CellGrid, rect: ui.Rect, focused: bool) !void {
        self.setFocused(focused);
        const x = ui.cell.snap(rect.x);
        const y = ui.cell.snap(rect.y);
        const width = ui.cell.snap(rect.w);
        const height = ui.cell.snap(rect.h);
        if (width == 0 or height == 0) return;
        grid.fillRect(rect.x, rect.y, rect.w, rect.h, .{
            .bg = ui.cell.packColor(self.background()),
        });
        if (self.message) |message| {
            const style = ui.cell.PaintStyle{
                .fg = ui.cell.packColor(self.foreground()),
                .bg = ui.cell.packColor(self.background()),
                .attrs = ui.cell.Attr.dim,
            };
            _ = drawTextClipped(grid, x + 1, y, width -| 1, message, style);
            return;
        }
        if (self.rows.items.len == 0) {
            const style = ui.cell.PaintStyle{
                .fg = ui.cell.packColor(self.foreground()),
                .bg = ui.cell.packColor(self.background()),
                .attrs = ui.cell.Attr.dim,
            };
            _ = drawTextClipped(grid, x + 1, y, width -| 1, "No symbols found in the active document.", style);
            return;
        }
        self.list.render(grid, rect);
    }

    pub fn handleKey(self: *OutlinePane, event: *const ui.KeyEvent) !bool {
        if (self.message != null) {
            if (event.key == .escape) {
                self.host.focus_editor(self.host.context);
                return true;
            }
            return true;
        }
        if (self.list.handleKey(event)) return true;

        switch (event.key) {
            .left => {
                try self.collapseOrParent();
                return true;
            },
            .right => {
                try self.expandOrChild();
                return true;
            },
            .escape => {
                if (self.filter_text.items.len > 0) {
                    self.filter_text.clearRetainingCapacity();
                    try self.rebuildRows();
                } else {
                    self.host.focus_editor(self.host.context);
                }
                return true;
            },
            .backspace => {
                if (self.filter_text.items.len > 0) {
                    _ = self.filter_text.pop();
                    try self.rebuildRows();
                }
                return true;
            },
            .char => |ch| {
                if (self.view_state.filter_on_type and !event.mods.ctrl and !event.mods.alt and ch >= 0x20 and ch != 0x7f) {
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(ch, &buf) catch 0;
                    if (len > 0) {
                        try self.filter_text.appendSlice(buf[0..len]);
                        try self.rebuildRows();
                    }
                    return true;
                }
                return false;
            },
            else => return false,
        }
    }

    fn collapseOrParent(self: *OutlinePane) !void {
        const index = self.list.selection() orelse return;
        if (index >= self.rows.items.len) return;
        const row = self.rows.items[index];
        if (row.collapsible and !row.collapsed) {
            try self.collapsed_ids.put(row.id, {});
            try self.rebuildRows();
            return;
        }
        if (row.depth == 0) return;
        var parent_id: ?[]const u8 = null;
        for (self.rows.items[0..index]) |candidate| {
            if (candidate.depth +% 1 == row.depth) parent_id = candidate.id;
        }
        if (parent_id) |id| {
            for (self.rows.items, 0..) |candidate, candidate_index| {
                if (std.mem.eql(u8, candidate.id, id)) {
                    self.list.setSelection(candidate_index);
                    self.selected_element = candidate.element;
                    return;
                }
            }
        }
    }

    fn expandOrChild(self: *OutlinePane) !void {
        const index = self.list.selection() orelse {
            if (self.rows.items.len > 0) self.list.setSelection(0);
            return;
        };
        if (index >= self.rows.items.len) return;
        const row = self.rows.items[index];
        if (row.collapsible and row.collapsed) {
            _ = self.collapsed_ids.remove(row.id);
            try self.rebuildRows();
            return;
        }
        if (index + 1 < self.rows.items.len and self.rows.items[index + 1].depth > row.depth) {
            self.list.setSelection(index + 1);
            self.selected_element = self.rows.items[index + 1].element;
        }
    }

    pub fn handleMouse(self: *OutlinePane, event: *const ui.MouseEvent, rect: ui.Rect) bool {
        const inside = event.x >= ui.cell.snap(rect.x) and event.x < ui.cell.snap(rect.right()) and
            event.y >= ui.cell.snap(rect.y) and event.y < ui.cell.snap(rect.bottom());
        if (!inside) {
            self.list.clearHover();
            return false;
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
            if (!handled) return false;
            const index = self.list.selection() orelse return true;
            if (index >= self.rows.items.len) return true;
            const row = self.rows.items[index];
            const local_x = event.x -| ui.cell.snap(rect.x);
            const twistie_col = row.depth * 2;
            if (row.collapsible and local_x == twistie_col) {
                if (row.collapsed) {
                    _ = self.collapsed_ids.remove(row.id);
                } else {
                    self.collapsed_ids.put(row.id, {}) catch {};
                }
                self.rebuildRows() catch {};
                return true;
            }
            if (self.outline) |outline| {
                outline.reveal(row.element, .{ .select = false }) catch {};
                self.host.focus_editor(self.host.context);
            }
            return true;
        }
        return self.list.handleMouse(event);
    }

    pub fn selectedIndex(self: *const OutlinePane) ?usize {
        return self.list.selection();
    }

    pub fn rowCount(self: *const OutlinePane) usize {
        return self.rows.items.len;
    }

    pub fn rowLabel(self: *const OutlinePane, index: usize) ?[]const u8 {
        if (index >= self.rows.items.len) return null;
        return self.rows.items[index].label;
    }

    pub fn rowDepth(self: *const OutlinePane, index: usize) ?usize {
        if (index >= self.rows.items.len) return null;
        return self.rows.items[index].depth;
    }

    pub fn rowCollapsed(self: *const OutlinePane, index: usize) ?bool {
        if (index >= self.rows.items.len) return null;
        return self.rows.items[index].collapsed;
    }

    pub fn selectRow(self: *OutlinePane, index: usize) void {
        if (index >= self.rows.items.len) return;
        self.list.setSelection(index);
        self.selected_element = self.rows.items[index].element;
    }

    pub fn toggleRow(self: *OutlinePane, index: usize) !void {
        if (index >= self.rows.items.len) return;
        const row = self.rows.items[index];
        if (!row.collapsible) return;
        if (row.collapsed) {
            _ = self.collapsed_ids.remove(row.id);
        } else {
            try self.collapsed_ids.put(row.id, {});
        }
        try self.rebuildRows();
    }

    fn background(self: *const OutlinePane) ui.Color {
        const palette = self.theme orelse return .{ .r = 30, .g = 30, .b = 33 };
        return palette.color("sideBar.background", .{ 30, 30, 33 });
    }

    fn foreground(self: *const OutlinePane) ui.Color {
        const palette = self.theme orelse return .{ .r = 204, .g = 204, .b = 204 };
        return palette.color("sideBar.foreground", .{ 204, 204, 204 });
    }
};

fn drawRow(self: *OutlinePane, row: *const list_mod.Row, item: *const Row) void {
    const palette = self.theme;
    const base_bg = if (palette) |theme| theme.color("sideBar.background", .{ 30, 30, 33 }) else ui.Color{ .r = 30, .g = 30, .b = 33 };
    const default_fg = if (palette) |theme| theme.color("sideBar.foreground", .{ 204, 204, 204 }) else ui.Color{ .r = 204, .g = 204, .b = 204 };
    var bg = base_bg;
    var fg = default_fg;
    if (row.hovered and !row.selected) {
        bg = if (palette) |theme| theme.color("list.hoverBackground", .{ 42, 45, 46 }) else ui.Color{ .r = 42, .g = 45, .b = 46 };
        fg = if (palette) |theme| theme.color("list.hoverForeground", .{ 255, 255, 255 }) else ui.Color{ .r = 255, .g = 255, .b = 255 };
    }
    if (row.selected) {
        if (row.focused_selection) {
            bg = if (palette) |theme| theme.color("list.activeSelectionBackground", .{ 4, 57, 94 }) else ui.Color{ .r = 4, .g = 57, .b = 94 };
            fg = if (palette) |theme| theme.color("list.activeSelectionForeground", .{ 255, 255, 255 }) else ui.Color{ .r = 255, .g = 255, .b = 255 };
        } else {
            bg = if (palette) |theme| theme.color("list.inactiveSelectionBackground", .{ 55, 55, 61 }) else ui.Color{ .r = 55, .g = 55, .b = 61 };
            fg = if (palette) |theme| theme.color("list.inactiveSelectionForeground", .{ 204, 204, 204 }) else ui.Color{ .r = 204, .g = 204, .b = 204 };
        }
    }
    const base = ui.cell.PaintStyle{ .fg = ui.cell.packColor(fg), .bg = ui.cell.packColor(bg) };
    const x = row.x;
    const y = row.y;
    const width = row.width;
    if (width == 0) return;
    row.grid.fillRect(@floatFromInt(x), @floatFromInt(y), @floatFromInt(width), 1, base);

    const indent = item.depth * 2;
    var col = x + @min(indent, width -| 1);
    if (item.depth > 0 and x + indent < x + width) {
        row.grid.putCodepoint(x + indent - 1, y, 0x2502, 1, .{
            .fg = ui.cell.packColor(if (palette) |theme| theme.color("tree.indentGuidesStroke", .{ 88, 88, 88 }) else ui.Color{ .r = 88, .g = 88, .b = 88 }),
            .bg = ui.cell.packColor(bg),
            .attrs = ui.cell.Attr.dim,
        });
    }
    if (item.collapsible and col < x + width) {
        row.grid.putCodepoint(col, y, if (item.collapsed) 0x25B8 else 0x25BE, 1, base);
        col += 1;
    } else if (col < x + width) {
        col += 1;
    }
    if (col < x + width) col += 1;

    if (col < x + width) {
        const glyph = goto_symbol.glyph(item.kind orelse 0);
        const glyph_width = drawTextClipped(row.grid, col, y, x + width -| col, glyph, base);
        col += glyph_width;
        if (col < x + width) {
            row.grid.putCodepoint(col, y, ' ', 1, base);
            col += 1;
        }
    }

    var label_style = base;
    if (item.deprecated) {
        label_style.attrs |= ui.cell.Attr.strikethrough;
        label_style.attrs |= ui.cell.Attr.dim;
    }
    const label_width = drawTextClipped(row.grid, col, y, x + width -| col, item.label, label_style);
    col += label_width;

    // Marker rollup: the count badge when this element owns problems, or a
    // bubble when a descendant does, exactly like `_renderMarkerInfo`.
    if (item.marker_severity) |severity| {
        var badge_buf: [8]u8 = undefined;
        const badge = if (item.marker_count > 0)
            std.fmt.bufPrint(&badge_buf, "{d}", .{@min(item.marker_count, 9)}) catch "+"
        else
            "\u{25CF}";
        const badge_width = textWidth(badge);
        if (x + width > badge_width + 1 and col + badge_width < x + width) {
            const badge_col = x + width -| badge_width -| 1;
            const color = if (severity == markerSeverity.Error)
                if (palette) |theme| theme.color("list.errorForeground", .{ 244, 135, 113 }) else ui.Color{ .r = 244, .g = 135, .b = 113 }
            else if (palette) |theme| theme.color("list.warningForeground", .{ 204, 167, 0 }) else ui.Color{ .r = 204, .g = 167, .b = 0 };
            _ = drawTextClipped(row.grid, badge_col, y, x + width -| badge_col, badge, .{
                .fg = ui.cell.packColor(color),
                .bg = ui.cell.packColor(bg),
            });
        }
    }
}

fn matchesFilter(filter: []const u8, label: []const u8) bool {
    if (filter.len == 0) return true;
    if (filter.len > label.len) return false;
    var index: usize = 0;
    while (index + filter.len <= label.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(filter, label[index .. index + filter.len])) return true;
    }
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

test "OutlinePane: tree rows, collapsing, filtering and sorting" {
    const allocator = std.testing.allocator;
    const Fixture = struct {
        const leaf_a = TreeElement{ .element = @ptrFromInt(0x10), .label = "zeta", .symbol_kind = 12, .id = "a" };
        const leaf_b = TreeElement{ .element = @ptrFromInt(0x20), .label = "alpha", .symbol_kind = 6, .id = "b" };
        const children = [_]TreeElement{ leaf_a, leaf_b };
        const root = TreeElement{
            .element = @ptrFromInt(0x30),
            .label = "Root",
            .symbol_kind = 5,
            .id = "root",
            .collapsible = true,
            .children = children[0..],
        };
        const roots = [_]TreeElement{root};

        fn getRoots(_: *anyopaque) []const TreeElement {
            return &roots;
        }
        fn comparePosition(_: *anyopaque, a: *anyopaque, b: *anyopaque) std.math.Order {
            return if (@intFromPtr(a) < @intFromPtr(b)) .lt else .gt;
        }
        fn compareType(_: *anyopaque, a: *anyopaque, b: *anyopaque) std.math.Order {
            _ = a;
            _ = b;
            return .eq;
        }
        fn compareName(_: *anyopaque, a: *anyopaque, b: *anyopaque) std.math.Order {
            const left = if (@intFromPtr(a) == 0x10) "zeta" else if (@intFromPtr(a) == 0x20) "alpha" else "Root";
            const right = if (@intFromPtr(b) == 0x10) "zeta" else if (@intFromPtr(b) == 0x20) "alpha" else "Root";
            return std.mem.order(u8, left, right);
        }
        fn reveal(_: *anyopaque, _: *anyopaque, _: outline_mod.RevealOptions) !void {}
        fn dispose(_: *anyopaque) void {}
    };
    var service = OutlineService.init(allocator);
    defer service.deinit();
    const pane = try OutlinePane.init(allocator, .{
        .context = @ptrCast(&service),
        .active_editor = fakeNoEditor,
        .active_resource = fakeNoResource,
        .current_position = fakeNoPosition,
        .request_render = fakeRequestRender,
        .focus_editor = fakeFocusEditor,
        .is_symbol_visible = fakeSymbolVisible,
    }, &service);
    defer pane.deinit();

    var fake_outline = IOutline{
        .context = @ptrCast(&service),
        .uri = null,
        .outline_kind = "test",
        .config = .{
            .breadcrumbs_data_source = .{ .context = @ptrCast(&service), .get_breadcrumb_elements = fakeBreadcrumbs },
            .tree_data_source = .{ .context = @ptrCast(&service), .get_roots = Fixture.getRoots },
            .comparator = .{
                .context = @ptrCast(&service),
                .compare_by_position = Fixture.comparePosition,
                .compare_by_type = Fixture.compareType,
                .compare_by_name = Fixture.compareName,
            },
        },
        .revealFn = Fixture.reveal,
        .disposeFn = Fixture.dispose,
    };
    pane.outline = &fake_outline;
    try pane.rebuildRows();
    try std.testing.expectEqual(@as(usize, 3), pane.rowCount());
    try std.testing.expectEqualStrings("Root", pane.rowLabel(0).?);
    try std.testing.expectEqual(@as(usize, 1), pane.rowDepth(1).?);
    try std.testing.expectEqualStrings("zeta", pane.rowLabel(1).?);

    try pane.toggleRow(0);
    try std.testing.expectEqual(@as(usize, 1), pane.rowCount());
    try std.testing.expect(pane.rowCollapsed(0).?);
    try std.testing.expect(pane.isAllCollapsed());
    pane.expandAll();
    try std.testing.expectEqual(@as(usize, 3), pane.rowCount());

    try pane.setSortBy(.ByName);
    try std.testing.expectEqualStrings("alpha", pane.rowLabel(1).?);
    try std.testing.expectEqualStrings("zeta", pane.rowLabel(2).?);

    try pane.filter_text.appendSlice("zet");
    try pane.rebuildRows();
    try std.testing.expectEqual(@as(usize, 2), pane.rowCount());
    try std.testing.expectEqualStrings("Root", pane.rowLabel(0).?);
    try std.testing.expectEqualStrings("zeta", pane.rowLabel(1).?);

    pane.outline = null;
}

fn fakeNoEditor(_: *anyopaque) ?OutlineEditor {
    return null;
}
fn fakeNoResource(_: *anyopaque) ?[]const u8 {
    return null;
}
fn fakeNoPosition(_: *anyopaque) ?@import("../../../../editor/common/core/position.zig").Position {
    return null;
}
fn fakeRequestRender(_: *anyopaque) void {}
fn fakeFocusEditor(_: *anyopaque) void {}
fn fakeSymbolVisible(_: *anyopaque, _: u32) bool {
    return true;
}
fn fakeBreadcrumbs(_: *anyopaque) []const outline_mod.BreadcrumbsOutlineElement {
    return &.{};
}
