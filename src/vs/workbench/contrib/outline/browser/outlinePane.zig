// Port of `src/vs/workbench/contrib/outline/browser/outlinePane.ts` on the
// ported workbench tree stack.
//
// The pane follows the active editor, creates an outline through the ported
// `IOutlineService`, and renders the provider tree through the ported
// `DataTree` (`WorkbenchDataTree` upstream), the same workbench tree component
// the Explorer uses. Expansion/collapse, selection,
// keyboard/mouse navigation, wheel scrolling and indent guides therefore come
// from the ported tree rather than a parallel row list. The pane listens to the
// editor's `ViewCursorStateChanged` / `ViewLinesChanged` view events for cursor
// following and content rebuilds, matching upstream's editor event flow.
//
// Terminal adaptations (documented in README/docs/terminal-ui.md): there is no
// workspace view-state storage, so tree state is not persisted; the find
// widget's separate input row is replaced by typed filter text in the pane; and
// `Loading document symbols...` is not shown because outline creation is
// synchronous. Filtering and sorting are applied by the ported tree's data
// source.

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
const data_tree_mod = @import("../../../../base/browser/ui/tree/dataTree.zig");
const abstract_tree_mod = @import("../../../../base/browser/ui/tree/abstractTree.zig");
const list_mod = @import("../../../../base/browser/ui/list/list.zig");
const view_state_mod = @import("./outline.zig");
const OutlineViewState = view_state_mod.OutlineViewState;
const OutlineSortOrder = view_state_mod.OutlineSortOrder;
const goto_symbol = @import("../../codeEditor/browser/quickaccess/gotoSymbolQuickAccess.zig");
const Editor = @import("../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const view_events = @import("../../../../editor/common/viewEvents.zig");
const view_handler_mod = @import("../../../../editor/common/viewEventHandler.zig");
const ViewEventHandler = view_handler_mod.ViewEventHandler;
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

const SortContext = struct {
    pane: *OutlinePane,
    order: OutlineSortOrder,
};

const OutlineTree = data_tree_mod.DataTree(*const TreeElement);

pub const OutlinePane = struct {
    allocator: Allocator,
    host: Host,
    outline_service: *OutlineService,
    view_state: OutlineViewState,
    outline: ?*IOutline = null,
    tree: *OutlineTree,
    /// Synthetic root passed to the data tree. The rendered tree starts at
    /// `root.children`, matching upstream's outline input.
    root: TreeElement = undefined,
    tree_arena: std.heap.ArenaAllocator,
    editor: ?*Editor = null,
    view_handler: ViewEventHandler = .{},
    handler_attached: bool = false,
    filter_text: std.array_list.Managed(u8),
    message: ?[]const u8 = null,
    theme: ?*const theme_colors_mod.ThemeColors = null,
    focused: bool = false,
    border: bool = false,
    action_buf: [2]views.TitleAction = undefined,

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
            .tree = undefined,
            .tree_arena = std.heap.ArenaAllocator.init(allocator),
            .view_handler = ViewEventHandler.init(self, .{
                .onCursorStateChanged = onCursorStateChanged,
                .onLinesChanged = onLinesChanged,
                .onLinesInserted = onLinesInserted,
                .onLinesDeleted = onLinesDeleted,
                .onFlushed = onFlushed,
            }),
            .filter_text = std.array_list.Managed(u8).init(allocator),
        };
        self.root = .{ .element = @ptrCast(self), .label = "" };
        self.tree = try OutlineTree.init(allocator, "OutlinePane", .{
            .context = @ptrCast(self),
            .render = renderRow,
        }, .{
            .context = @ptrCast(self),
            .get_children = outlineGetChildren,
            .has_children = outlineHasChildren,
        }, false, .{
            .indent = 2,
        });
        self.tree.tree.view.setActivateHandler(self, activate);
        return self;
    }

    pub fn deinit(self: *OutlinePane) void {
        self.detachEditor();
        self.disposeOutline();
        self.tree.deinit();
        self.view_state.deinit();
        self.tree_arena.deinit();
        self.filter_text.deinit();
        self.allocator.destroy(self);
    }

    pub const more_actions_id = "outline.moreActions";

    pub fn titleActions(self: *OutlinePane) []const views.TitleAction {
        const all_collapsed = self.isAllCollapsed();
        // Navigation stays in the toolbar. The config and sort groups are
        // secondary actions in the pinned VS Code Outline title menu.
        self.action_buf = .{
            .{
                .id = if (all_collapsed) "outline.expand" else "outline.collapse",
                .label = if (all_collapsed) "Expand All" else "Collapse All",
                .glyph = if (all_collapsed) 0xeb95 else 0xeac5,
            },
            .{ .id = more_actions_id, .label = "More Actions", .glyph = 0xea7c },
        };
        return &self.action_buf;
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

    pub fn setFocused(self: *OutlinePane, focused: bool) void {
        self.focused = focused;
        self.tree.setFocus(focused);
        if (!focused) self.tree.tree.view.clearHover();
    }

    /// Rebinds the pane to the active editor. Called by the workbench when the
    /// active tab or group changes; the editor's view events then drive cursor
    /// following and content rebuilds.
    pub fn setEditor(self: *OutlinePane, editor: ?*Editor) !void {
        if (self.editor == editor) return;
        self.detachEditor();
        self.editor = editor;
        if (editor) |value| {
            value.addViewEventHandler(&self.view_handler);
            self.handler_attached = true;
        }
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
        self.disposeOutline();
        self.message = null;

        const editor = self.host.active_editor(self.host.context);
        if (editor == null or self.editor == null) {
            self.message = "The active editor cannot provide outline information.";
            try self.rebuildInput();
            return;
        }
        if (!self.outline_service.canCreateOutline(editor.?)) {
            self.message = "The active editor cannot provide outline information.";
            try self.rebuildInput();
            return;
        }

        const outline = self.outline_service.createOutline(editor.?, .OutlinePane) catch null;
        if (outline == null) {
            self.message = "The active editor cannot provide outline information.";
            try self.rebuildInput();
            return;
        }
        self.outline = outline;
        try self.rebuildInput();
        if (outline.?.is_empty) {
            self.message = "No symbols found in the active document.";
        } else if (self.view_state.follow_cursor) {
            _ = self.revealActiveElement();
        }
    }

    fn disposeOutline(self: *OutlinePane) void {
        if (self.outline) |outline| {
            self.tree.setInput(null) catch {};
            outline.dispose();
            self.outline = null;
        }
    }

    fn onCursorStateChanged(context: *anyopaque, _: *const view_events.ViewCursorStateChangedEvent) bool {
        const self: *OutlinePane = @ptrCast(@alignCast(context));
        if (!self.view_state.follow_cursor) return false;
        const changed = self.revealActiveElement();
        if (changed) self.host.request_render(self.host.context);
        return changed;
    }

    fn onLinesChanged(context: *anyopaque, _: *const view_events.ViewLinesChangedEvent) bool {
        return rebuildNow(context);
    }

    fn onLinesInserted(context: *anyopaque, _: *const view_events.ViewLinesInsertedEvent) bool {
        return rebuildNow(context);
    }

    fn onLinesDeleted(context: *anyopaque, _: *const view_events.ViewLinesDeletedEvent) bool {
        return rebuildNow(context);
    }

    fn onFlushed(context: *anyopaque, _: *const view_events.ViewFlushedEvent) bool {
        return rebuildNow(context);
    }

    /// Upstream `DocumentSymbolsOutline` debounces this through a
    /// `TimeoutTimer`; the terminal has no timer service, so the outline is
    /// rebuilt directly from the editor's line-change event rather than by a
    /// workbench polling loop.
    fn rebuildNow(context: *anyopaque) bool {
        const self: *OutlinePane = @ptrCast(@alignCast(context));
        self.refresh() catch {
            self.message = "The outline could not be created.";
        };
        self.host.request_render(self.host.context);
        return true;
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
            try self.rebuildInput();
        }
        self.host.request_render(self.host.context);
    }

    pub fn setSortBy(self: *OutlinePane, order: OutlineSortOrder) !void {
        try self.view_state.setSortBy(order);
        try self.rebuildInput();
        self.host.request_render(self.host.context);
    }

    pub fn collapseAll(self: *OutlinePane) void {
        _ = self.tree.tree.setCollapsed(null, true, true) catch {};
        self.host.request_render(self.host.context);
    }

    pub fn expandAll(self: *OutlinePane) void {
        _ = self.tree.tree.setCollapsed(null, false, true) catch {};
        self.host.request_render(self.host.context);
    }

    pub fn isAllCollapsed(self: *const OutlinePane) bool {
        const outline = self.outline orelse return false;
        const source = outline.config.tree_data_source orelse return false;
        var found = false;
        for (source.get_roots(source.context)) |*element| {
            if (element.children.len == 0) continue;
            found = true;
            if (!self.tree.tree.isCollapsed(element)) return false;
        }
        return found;
    }

    pub fn hasHoveredRow(self: *const OutlinePane) bool {
        return self.tree.tree.view.hasHoveredRow();
    }

    pub fn clearHover(self: *OutlinePane) void {
        self.tree.tree.view.clearHover();
    }

    fn rebuildInput(self: *OutlinePane) !void {
        _ = self.tree_arena.reset(.retain_capacity);
        const selected = self.selectionElement();
        if (self.outline) |outline| {
            if (outline.config.tree_data_source) |source| {
                self.root.children = source.get_roots(source.context);
            } else {
                self.root.children = &.{};
            }
            try self.tree.setInput(&self.root);
            if (outline.config.collapse_by_default) {
                _ = self.tree.tree.setCollapsed(null, true, true) catch {};
            }
            if (selected) |element| self.setSelectionElement(element);
        } else {
            self.root.children = &.{};
            try self.tree.setInput(null);
        }
    }

    fn revealActiveElement(self: *OutlinePane) bool {
        const outline = self.outline orelse return false;
        const source = outline.config.tree_data_source orelse return false;
        const roots = source.get_roots(source.context);
        const active = outline.activeElement() orelse return false;
        const target = findElementInTree(roots, active) orelse return false;
        const target_element = findTreeElementById(roots, target.id) orelse return false;
        if (self.selectionElement()) |selected| {
            if (selected == target_element) return false;
        }
        const path = outlinePath(self.allocator, roots, target.id) catch return false;
        defer self.allocator.free(path);
        for (path[0..path.len -| 1]) |ancestor| {
            _ = self.tree.tree.setCollapsed(ancestor, false, false) catch {};
        }
        self.setSelectionElement(target_element);
        return true;
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
        if (self.tree.count() == 0) {
            const style = ui.cell.PaintStyle{
                .fg = ui.cell.packColor(self.foreground()),
                .bg = ui.cell.packColor(self.background()),
                .attrs = ui.cell.Attr.dim,
            };
            _ = drawTextClipped(grid, x + 1, y, width -| 1, "No symbols found in the active document.", style);
            return;
        }
        self.tree.render(grid, rect);
    }

    pub fn handleKey(self: *OutlinePane, event: *const ui.KeyEvent) !bool {
        if (self.tree.handleKey(event)) return true;
        switch (event.key) {
            .escape => {
                if (self.filter_text.items.len > 0) {
                    self.filter_text.clearRetainingCapacity();
                    try self.rebuildInput();
                } else {
                    self.host.focus_editor(self.host.context);
                }
                return true;
            },
            .backspace => {
                if (self.filter_text.items.len > 0) {
                    _ = self.filter_text.pop();
                    try self.rebuildInput();
                }
                return true;
            },
            .char => |ch| {
                if (self.view_state.filter_on_type and !event.mods.ctrl and !event.mods.alt and ch >= 0x20 and ch != 0x7f) {
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(ch, &buf) catch 0;
                    if (len > 0) {
                        try self.filter_text.appendSlice(buf[0..len]);
                        try self.rebuildInput();
                    }
                    return true;
                }
                return false;
            },
            else => return false,
        }
    }

    pub fn handleMouse(self: *OutlinePane, event: *const ui.MouseEvent, rect: ui.Rect) bool {
        const inside = event.x >= ui.cell.snap(rect.x) and event.x < ui.cell.snap(rect.right()) and
            event.y >= ui.cell.snap(rect.y) and event.y < ui.cell.snap(rect.bottom());
        if (!inside) {
            self.tree.tree.view.clearHover();
            return false;
        }
        const handled = self.tree.handleMouse(event);
        if ((event.kind == .down or event.kind == .click) and handled) {
            const element = self.selectionElement() orelse return true;
            const node = self.selectionNode() orelse return true;
            const twistie_x = ui.cell.snap(rect.x) + 2 + node.depth * 2;
            if (element.children.len > 0 and event.x == twistie_x) {
                _ = self.tree.tree.setCollapsed(element, !self.tree.tree.isCollapsed(element), false) catch {};
            } else if (element.children.len == 0 or event.x != twistie_x) {
                if (self.outline) |outline| {
                    outline.reveal(element.element, .{ .select = false }) catch {};
                    self.host.focus_editor(self.host.context);
                }
            }
        }
        return true;
    }

    fn prepareElements(self: *OutlinePane, elements: []const TreeElement) ![]const *const TreeElement {
        return prepareElementsImpl(self, elements);
    }

    fn includeElement(self: *OutlinePane, element: *const TreeElement) bool {
        return includeElementImpl(self, element);
    }

    pub fn selectedIndex(self: *const OutlinePane) ?usize {
        const selected = self.selectionElement() orelse return null;
        for (0..self.tree.count()) |index| {
            const element = self.renderedElement(index) orelse continue;
            if (element == selected) return index;
        }
        return null;
    }

    fn selectionNode(self: *const OutlinePane) ?*OutlineTree.Node {
        return self.tree.tree.selection();
    }

    fn selectionElement(self: *const OutlinePane) ?*const TreeElement {
        const node = self.tree.tree.selection() orelse return null;
        return node.element;
    }

    fn renderedElement(self: *const OutlinePane, index: usize) ?*const TreeElement {
        const node = self.renderedNode(index) orelse return null;
        return node.element;
    }

    fn renderedNode(self: *const OutlinePane, index: usize) ?*OutlineTree.Node {
        if (index >= self.tree.tree.view.rendered.items.len) return null;
        return self.tree.tree.view.rendered.items[index];
    }

    fn setSelectionElement(self: *OutlinePane, element: *const TreeElement) void {
        const node = self.tree.tree.model.getNode(element) catch return;
        self.tree.tree.view.setSelectionNode(node);
    }

    pub fn rowCount(self: *const OutlinePane) usize {
        return self.tree.count();
    }

    pub fn rowLabel(self: *const OutlinePane, index: usize) ?[]const u8 {
        const element = self.renderedElement(index) orelse return null;
        return element.label;
    }

    pub fn rowDepth(self: *const OutlinePane, index: usize) ?usize {
        const node = self.renderedNode(index) orelse return null;
        return node.depth;
    }

    pub fn rowCollapsed(self: *const OutlinePane, index: usize) ?bool {
        const element = self.renderedElement(index) orelse return null;
        return self.tree.tree.isCollapsed(element);
    }

    pub fn selectRow(self: *OutlinePane, index: usize) void {
        const element = self.renderedElement(index) orelse return;
        self.setSelectionElement(element);
    }

    pub fn toggleRow(self: *OutlinePane, index: usize) !void {
        const element = self.renderedElement(index) orelse return;
        const collapsed = self.tree.tree.isCollapsed(element);
        _ = try self.tree.tree.setCollapsed(element, !collapsed, false);
    }

    fn background(self: *const OutlinePane) ui.Color {
        const palette = self.theme orelse return .{ .r = 30, .g = 30, .b = 33 };
        return palette.color("sideBar.background", .{ 30, 30, 33 });
    }

    fn foreground(self: *const OutlinePane) ui.Color {
        const palette = self.theme orelse return .{ .r = 204, .g = 204, .b = 204 };
        return palette.color("sidebar.foreground", .{ 204, 204, 204 });
    }
};

fn outlineHasChildren(_: *anyopaque, node: *const TreeElement) bool {
    return node.children.len > 0;
}

fn outlineGetChildren(context: *anyopaque, element: *const TreeElement) []const *const TreeElement {
    const self: *OutlinePane = @ptrCast(@alignCast(context));
    return self.prepareElements(element.children) catch &.{};
}

fn prepareElementsImpl(self: *OutlinePane, elements: []const TreeElement) ![]const *const TreeElement {
    const arena = self.tree_arena.allocator();
    const pointers = try arena.alloc(*const TreeElement, elements.len);
    for (elements, 0..) |*element, index| pointers[index] = element;
    if (self.outline) |outline| {
        if (outline.config.comparator) |_| {
            const context = SortContext{ .pane = self, .order = self.view_state.sort_by };
            std.mem.sort(*const TreeElement, pointers, context, struct {
                fn lessThan(ctx: SortContext, a: *const TreeElement, b: *const TreeElement) bool {
                    const comparator = ctx.pane.outline.?.config.comparator.?;
                    const order = switch (ctx.order) {
                        .ByPosition => comparator.compare_by_position(comparator.context, @ptrCast(a.element), @ptrCast(b.element)),
                        .ByName => comparator.compare_by_name(comparator.context, @ptrCast(a.element), @ptrCast(b.element)),
                        .ByKind => comparator.compare_by_type(comparator.context, @ptrCast(a.element), @ptrCast(b.element)),
                    };
                    return order == .lt;
                }
            }.lessThan);
        }
    }
    if (self.filter_text.items.len == 0) return pointers;
    var result = std.array_list.Managed(*const TreeElement).init(arena);
    for (pointers) |element| {
        if (self.includeElement(element)) result.append(element) catch continue;
    }
    return result.toOwnedSlice();
}

fn includeElementImpl(self: *OutlinePane, element: *const TreeElement) bool {
    if (matchesFilter(self.filter_text.items, element.label)) return true;
    for (element.children) |*child| {
        if (self.includeElement(child)) return true;
    }
    return false;
}

fn renderRow(context: *anyopaque, row: *const list_mod.Row, node: *const OutlineTree.Node) void {
    const self: *OutlinePane = @ptrCast(@alignCast(context));
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
        if (node.collapsible) {
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

fn activate(context: ?*anyopaque, element: *const TreeElement) void {
    const self: *OutlinePane = @ptrCast(@alignCast(context orelse return));
    const outline = self.outline orelse return;
    outline.reveal(element.element, .{ .select = false }) catch {};
    self.host.focus_editor(self.host.context);
}

fn rowPaint(theme: ?*const theme_colors_mod.ThemeColors, row: *const list_mod.Row) ui.cell.PaintStyle {
    var bg = if (theme) |palette| palette.color("sideBar.background", .{ 30, 30, 33 }) else ui.Color{ .r = 30, .g = 30, .b = 33 };
    var fg = if (theme) |palette| palette.color("sideBar.foreground", .{ 204, 204, 204 }) else ui.Color{ .r = 204, .g = 204, .b = 204 };
    if (row.selected) {
        if (row.focused_selection) {
            bg = if (theme) |palette| palette.color("list.activeSelectionBackground", .{ 4, 57, 94 }) else ui.Color{ .r = 4, .g = 57, .b = 94 };
            fg = .{ .r = 255, .g = 255, .b = 255 };
        } else {
            bg = if (theme) |palette| palette.color("list.inactiveSelectionBackground", .{ 55, 55, 61 }) else ui.Color{ .r = 55, .g = 55, .b = 61 };
        }
    } else if (row.hovered) {
        bg = if (theme) |palette| palette.color("list.hoverBackground", .{ 42, 45, 46 }) else ui.Color{ .r = 42, .g = 45, .b = 46 };
        fg = if (theme) |palette| palette.color("list.hoverForeground", .{ 255, 255, 255 }) else ui.Color{ .r = 255, .g = 255, .b = 255 };
    }
    return .{ .fg = ui.cell.packColor(fg), .bg = ui.cell.packColor(bg) };
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

fn findElementInTree(roots: []const TreeElement, element: *anyopaque) ?TreeElement {
    for (roots) |root| {
        if (root.element == element) return root;
        if (findElementInTree(root.children, element)) |found| return found;
    }
    return null;
}

fn findTreeElementById(roots: []const TreeElement, id: []const u8) ?*const TreeElement {
    for (roots) |*root| {
        if (std.mem.eql(u8, root.id, id)) return root;
        if (findTreeElementById(root.children, id)) |found| return found;
    }
    return null;
}

fn outlinePath(allocator: Allocator, roots: []const TreeElement, id: []const u8) ![]const *const TreeElement {
    var path = std.array_list.Managed(*const TreeElement).init(allocator);
    errdefer path.deinit();
    for (roots) |*root| {
        if (try appendPath(&path, root, id)) return path.toOwnedSlice();
    }
    return path.toOwnedSlice();
}

fn appendPath(path: *std.array_list.Managed(*const TreeElement), element: *const TreeElement, id: []const u8) !bool {
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
    try pane.rebuildInput();
    try std.testing.expectEqual(@as(usize, 3), pane.rowCount());
    try std.testing.expectEqualStrings("Root", pane.rowLabel(0).?);
    try std.testing.expectEqual(@as(usize, 2), pane.rowDepth(1).?);
    try std.testing.expectEqualStrings("zeta", pane.rowLabel(1).?);

    // Indent guides sit under the parent's twistie column: the child row has
    // a guide at the second cell, matching the Explorer renderer.
    var grid = try ui.CellGrid.init(allocator, 20, 5);
    defer grid.deinit();
    pane.tree.tree.view.options.render_indent_guides = .always;
    try pane.render(&grid, .{ .x = 0, .y = 0, .w = 20, .h = 5 }, true);
    try std.testing.expectEqual(@as(u32, 0x2502), grid.cluster[grid.index(2, 1)]);
    try std.testing.expect(grid.cluster[grid.index(1, 1)] != 0x2502);

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
    try pane.rebuildInput();
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
