// Port of `src/vs/editor/browser/widget/diffEditor/features/gutterFeature.ts`.
// The retained menus, cursor/selection mapping, action context and staged
// text calculation follow the upstream gutter. The cell grid maps its DOM
// toolbar to adjacent primary/overflow cells and uses the shared EditorGutter
// iterator for visible hunk layout; the separate cell sash retains resizing.
const std = @import("std");

const view_model = @import("../diffEditorViewModel.zig");
const LineRange = @import("../../../../common/core/ranges/lineRange.zig").LineRange;

const range_mod = @import("../../../../common/core/range.zig");
const Range = range_mod.Range;
const Selection = @import("../../../../common/core/selection.zig").Selection;
const LineRangeSet = @import("../../../../common/core/ranges/lineRange.zig").LineRangeSet;
const AbstractText = @import("../../../../common/core/text/abstractText.zig").AbstractText;
const TextModel = @import("../../../../common/model/textModel.zig").TextModel;

pub const SelectedDiffs = struct {
    mapping_indices: []usize,
    range_mappings: []view_model.RangeMapping,

    pub fn deinit(self: *SelectedDiffs, allocator: std.mem.Allocator) void {
        allocator.free(self.mapping_indices);
        allocator.free(self.range_mappings);
    }
};

/// Shared upstream _selectedDiffs calculation for the gutter and legacy
/// revert buttons. Selections are modified-model ranges, not view rows.
pub fn selectedDiffs(allocator: std.mem.Allocator, mappings: []const view_model.DiffMapping, selections: []const Selection) !SelectedDiffs {
    var any_nonempty = false;
    var selected_lines = LineRangeSet.empty(allocator);
    defer selected_lines.deinit();
    for (selections) |selection| {
        any_nonempty = any_nonempty or !selection.isEmpty();
        try selected_lines.addRange(LineRange.fromRangeInclusive(Range.init(selection.startLineNumber, selection.startColumn, selection.endLineNumber, selection.endColumn)));
    }
    var indices: std.ArrayList(usize) = .empty;
    defer indices.deinit(allocator);
    var ranges: std.ArrayList(view_model.RangeMapping) = .empty;
    defer ranges.deinit(allocator);
    if (any_nonempty) for (mappings, 0..) |mapping, index| {
        const change = mapping.line_range_mapping;
        const inner = change.inner_changes orelse continue;
        if (!selected_lines.intersects(change.modified)) continue;
        try indices.append(allocator, index);
        for (inner) |range_mapping| {
            for (selections) |selection| {
                const range = Range.init(selection.startLineNumber, selection.startColumn, selection.endLineNumber, selection.endColumn);
                if (range_mod.areIntersecting(&range_mapping.modifiedRange, &range)) {
                    try ranges.append(allocator, range_mapping);
                    break;
                }
            }
        }
    };
    // Upstream returns the shared empty result when no inner change intersects.
    if (ranges.items.len == 0) indices.clearRetainingCapacity();
    const owned_indices = try indices.toOwnedSlice(allocator);
    errdefer allocator.free(owned_indices);
    return .{ .mapping_indices = owned_indices, .range_mappings = try ranges.toOwnedSlice(allocator) };
}

/// DiffEditorGutter.computeStagedValue: apply only the provided changes to the
/// original model. TextModelText preserves the models' own EOLs and validates
/// the inclusive line ranges (including the upstream end-column sentinel).
pub fn computeStagedValue(allocator: std.mem.Allocator, mapping: view_model.DetailedLineRangeMapping, original: *TextModel, modified: *TextModel) ![]u8 {
    var temporary = std.heap.ArenaAllocator.init(allocator);
    defer temporary.deinit();
    var original_text = AbstractText.initTextModel(allocator, original);
    defer original_text.deinit();
    var modified_text = AbstractText.initTextModel(temporary.allocator(), modified);
    defer modified_text.deinit();
    var edit = try view_model.DetailedLineRangeMapping.toTextEdit(allocator, &.{mapping}, &modified_text);
    defer edit.deinit();
    return edit.apply(allocator, &original_text);
}

const ui = @import("ui");
const menu_api = @import("../../../../../platform/actions/common/menuService.zig");
const menu_ids = @import("../../../../../platform/actions/common/actions.zig").menu_ids;
const MenuId = @import("../../../../../platform/actions/common/actions.zig").MenuId;
const contextkey = @import("../../../../../platform/contextkey/common/contextkey.zig");
const context_menu = @import("../../../../../platform/contextview/browser/contextMenuService.zig");
const CommandArgument = @import("../../../../../platform/commands/common/commands.zig").CommandArgument;
const IAction = @import("../../../../../base/common/actions.zig").IAction;
const SignalSubscription = @import("../../../../../base/common/event.zig").SignalSubscription;
const SelectionEvent = @import("../../../../common/cursorEvents.zig").ICursorSelectionChangedEvent;
const URI = @import("../../../../../base/common/uri.zig").URI;

// Upstream DiffEditorSelectionHunkToolbarContext. The encoding is included
// at the terminal boundary so the Git extension encodes the same document
// without reopening the resource or losing its unsaved encoding choice.
pub const DiffEditorSelectionHunkToolbarContext = struct {
    mapping: view_model.DetailedLineRangeMapping,
    originalWithModifiedChanges: []const u8,
    modifiedUri: std.Uri,
    originalUri: std.Uri,
    modifiedEncoding: []const u8,
};

pub const toolbar_width: usize = 2;

/// Retained menu and selected-diff state owned by the diff widget. One cell
/// represents the first primary action; the adjacent cell shows a second
/// primary action or overflow for remaining actions. This replaces the
/// browser toolbar of nested buttons with subpixel geometry.
pub const DiffGutterToolbar = struct {
    allocator: std.mem.Allocator,
    model: *view_model.DiffEditorViewModel,
    original: *Editor,
    modified: *Editor,
    host: ?Host = null,
    hunk_menu: ?*menu_api.Menu = null,
    selection_menu: ?*menu_api.Menu = null,
    selection_listener: ?SignalSubscription = null,
    original_uri: []const u8 = "",
    modified_uri: []const u8 = "",
    selected_mapping: ?view_model.DetailedLineRangeMapping = null,
    current_diff: ?usize = null,
    hovered: bool = false,
    inline_mode: bool = false,
    open: bool = false,
    pressed: ?Press = null,

    pub const Host = struct {
        menus: *menu_api.MenuService,
        parent_context: contextkey.IContext,
        context_menu: context_menu.IContextMenuService,
        context: *anyopaque,
        changed: *const fn (*anyopaque, bool) void,
    };

    const Press = struct { row: usize, col: usize, original_version: u32, modified_version: u32 };
    const Item = struct { index: ?usize, mapping: view_model.DetailedLineRangeMapping, bounds: LineRange, menu: MenuId };
    const Buttons = struct {
        primary: ?IAction = null,
        second_primary: ?IAction = null,
        count: usize = 0,

        fn secondAction(self: Buttons) ?IAction {
            if (self.count != 2) return null;
            return self.second_primary;
        }
    };

    pub fn attach(self: *DiffGutterToolbar, host: Host) !void {
        if (self.host != null) return;
        self.host = host;
        errdefer self.deinit();
        try self.updateUris();
        self.hunk_menu = try host.menus.createMenu(self.allocator, menu_ids.DiffEditorHunkToolbar, self.context());
        self.selection_menu = try host.menus.createMenu(self.allocator, menu_ids.DiffEditorSelectionToolbar, self.context());
        _ = try self.hunk_menu.?.onDidChange.listenSignal(self, onMenuChanged);
        _ = try self.selection_menu.?.onDidChange.listenSignal(self, onMenuChanged);
        self.selection_listener = try self.modified.on_did_change_cursor_selection.listenDisposable(self, onSelection);
        try self.updateSelection();
        host.changed(host.context, true);
    }

    pub fn deinit(self: *DiffGutterToolbar) void {
        if (self.open) if (self.host) |host| host.context_menu.hideContextMenu();
        self.open = false;
        if (self.selection_listener) |listener| listener.dispose();
        self.selection_listener = null;
        for ([_]?*menu_api.Menu{ self.hunk_menu, self.selection_menu }) |menu| if (menu) |value| {
            value.deinit();
            self.allocator.destroy(value);
        };
        self.hunk_menu = null;
        self.selection_menu = null;
        if (self.selected_mapping) |*mapping| mapping.deinit(self.allocator);
        self.selected_mapping = null;
        self.allocator.free(self.original_uri);
        self.allocator.free(self.modified_uri);
        self.original_uri = "";
        self.modified_uri = "";
        self.host = null;
        self.pressed = null;
        self.hovered = false;
    }

    fn updateUris(self: *DiffGutterToolbar) !void {
        var original = try URI.fromStd(self.allocator, self.original.model.uri());
        defer original.deinit();
        var modified = try URI.fromStd(self.allocator, self.modified.model.uri());
        defer modified.deinit();
        const original_uri = try original.toStringEncoded(self.allocator);
        errdefer self.allocator.free(original_uri);
        const modified_uri = try modified.toStringEncoded(self.allocator);
        self.allocator.free(self.original_uri);
        self.allocator.free(self.modified_uri);
        self.original_uri = original_uri;
        self.modified_uri = modified_uri;
    }

    pub fn setEditors(self: *DiffGutterToolbar, original: *Editor, modified: *Editor) !void {
        const host = self.host;
        self.deinit();
        self.original = original;
        self.modified = modified;
        if (host) |value| try self.attach(value);
    }

    fn context(self: *DiffGutterToolbar) contextkey.IContext {
        return .{ .context = self, .get_value = getValue };
    }

    fn getValue(ptr: *anyopaque, key: []const u8) contextkey.ContextKeyValue {
        const self: *DiffGutterToolbar = @ptrCast(@alignCast(ptr));
        if (std.mem.eql(u8, key, "diffEditorOriginalUri")) return .{ .string = self.original_uri };
        if (std.mem.eql(u8, key, "diffEditorModifiedUri")) return .{ .string = self.modified_uri };
        if (std.mem.eql(u8, key, "diffEditorInlineMode")) return .{ .boolean = self.inline_mode };
        if (std.mem.eql(u8, key, "diffEditorModifiedWritable")) return .{ .boolean = !self.modified.isReadOnly() };
        if (std.mem.eql(u8, key, "isInDiffEditor")) return .{ .boolean = true };
        return if (self.host) |host| host.parent_context.getValue(key) else .undefined_value;
    }

    fn onMenuChanged(self: *DiffGutterToolbar) !void {
        if (self.host) |host| host.changed(host.context, true);
    }

    fn onSelection(_: SelectionEvent, self: *DiffGutterToolbar) !void {
        try self.updateSelection();
        if (self.host) |host| host.changed(host.context, false);
    }

    pub fn setInlineMode(self: *DiffGutterToolbar, inline_mode: bool) !void {
        if (self.inline_mode == inline_mode) return;
        self.inline_mode = inline_mode;
        try self.refreshMenus();
    }

    pub fn refreshMenus(self: *DiffGutterToolbar) !void {
        if (self.hunk_menu) |menu| try menu.refresh();
        if (self.selection_menu) |menu| try menu.refresh();
    }

    pub fn updateSelection(self: *DiffGutterToolbar) !void {
        if (self.host == null) return;
        if (self.selected_mapping) |*mapping| mapping.deinit(self.allocator);
        self.selected_mapping = null;
        self.current_diff = null;
        const state = self.model.stateRef() orelse return;
        self.current_diff = mappingIndexAtModelLine(state.mappings, false, self.modified.modelCursorPosition().lineNumber);
        const selections = try self.modified.getSelections();
        defer self.modified.allocator.free(selections);
        var selected = try selectedDiffs(self.allocator, state.mappings, selections);
        defer selected.deinit(self.allocator);
        if (selected.range_mappings.len > 0) self.selected_mapping = try view_model.DetailedLineRangeMapping.fromRangeMappings(self.allocator, selected.range_mappings);
    }

    pub fn hasActions(self: *const DiffGutterToolbar) bool {
        return if (self.hunk_menu) |menu| menu.getActions().len > 0 else false;
    }

    pub fn setHovered(self: *DiffGutterToolbar, hovered: bool) bool {
        if (self.hovered == hovered) return false;
        self.hovered = hovered;
        return true;
    }

    fn getButtons(self: *const DiffGutterToolbar, id: MenuId) Buttons {
        const menu = if (std.mem.eql(u8, id.id, menu_ids.DiffEditorSelectionToolbar.id)) self.selection_menu else self.hunk_menu;
        var result: Buttons = .{};
        if (menu) |value| for (value.getActions()) |group| {
            result.count += group.actions.len;
            if (std.mem.startsWith(u8, group.id, "primary")) for (group.actions) |action| {
                if (result.primary == null) {
                    result.primary = action;
                } else if (result.second_primary == null) {
                    result.second_primary = action;
                }
            };
        };
        return result;
    }

    fn getSelectedItem(self: *const DiffGutterToolbar) ?Item {
        const mapping = self.selected_mapping orelse return null;
        return .{ .index = null, .mapping = mapping, .bounds = hunkBounds(mapping, self.original, self.modified), .menu = menu_ids.DiffEditorSelectionToolbar };
    }

    fn getHunkItem(self: *const DiffGutterToolbar, index: usize) ?Item {
        const state = self.model.stateRef() orelse return null;
        if (index >= state.mappings.len) return null;
        const mapping = state.mappings[index].line_range_mapping;
        return .{ .index = index, .mapping = mapping, .bounds = hunkBounds(mapping, self.original, self.modified), .menu = menu_ids.DiffEditorHunkToolbar };
    }

    fn buttonRow(bounds: LineRange, top: usize, height: usize) ?usize {
        const visible = bounds.intersect(LineRange.ofLength(top, height)) orelse return null;
        if (visible.isEmpty()) return null;
        return std.math.clamp(bounds.startLineNumber + (bounds.length() - 1) / 2, visible.startLineNumber, visible.endLineNumberExclusive - 1) - top;
    }

    fn itemAt(self: *const DiffGutterToolbar, row: usize, height: usize) ?Item {
        const top = self.modified.scrollTop();
        const item = self.getSelectedItem() orelse blk: {
            const state = self.model.stateRef() orelse return null;
            const index = mappingIndexAtVerticalOffset(state.mappings, self.original, self.modified, top + row) orelse return null;
            break :blk self.getHunkItem(index) orelse return null;
        };
        if (buttonRow(item.bounds, top, height) != row) return null;
        return item;
    }

    fn glyph(action: IAction) u21 {
        const item = menu_api.MenuItemAction.from(action) orelse return '•';
        const icon = item.item.icon orelse return '•';
        if (std.mem.eql(u8, icon, "plus") or std.mem.eql(u8, icon, "add")) return '+';
        if (std.mem.eql(u8, icon, "arrow-right")) return '→';
        if (std.mem.eql(u8, icon, "trash")) return '×';
        if (std.mem.eql(u8, icon, "discard")) return '↶';
        return '•';
    }

    fn paintItem(self: *const DiffGutterToolbar, grid: *ui.CellGrid, x: usize, y: usize, width: usize, height: usize, item: Item, normal: ui.cell.PaintStyle, active: ui.cell.PaintStyle) void {
        const row = buttonRow(item.bounds, self.modified.scrollTop(), height) orelse return;
        const buttons = self.getButtons(item.menu);
        if (buttons.primary) |primary| {
            grid.putCodepoint(x, y + row, glyph(primary), 1, if (primary.enabled() and self.model.is_diff_up_to_date) active else normal);
            if (width > 1 and buttons.count > 1) {
                if (buttons.secondAction()) |second| {
                    grid.putCodepoint(x + 1, y + row, glyph(second), 1, if (second.enabled() and self.model.is_diff_up_to_date) active else normal);
                } else grid.putCodepoint(x + 1, y + row, '…', 1, active);
            }
        } else if (buttons.count > 0) grid.putCodepoint(x, y + row, '…', 1, active);
    }

    pub fn paint(self: *const DiffGutterToolbar, grid: *ui.CellGrid, x: usize, y: usize, width: usize, height: usize, normal: ui.cell.PaintStyle, active: ui.cell.PaintStyle) void {
        if (width == 0) return;
        if (self.getSelectedItem()) |item| return self.paintItem(grid, x, y, width, height, item, normal, active);
        if (!self.hovered) {
            if (self.current_diff) |index| if (self.getHunkItem(index)) |item| self.paintItem(grid, x, y, width, height, item, normal, active);
            return;
        }
        const state = self.model.stateRef() orelse return;
        const items: DiffEditorGutter = .{ .mappings = state.mappings, .original = self.original, .modified = self.modified };
        var visible = items.render(self.modified.scrollTop(), height);
        while (visible.next()) |item| if (self.getHunkItem(item.index)) |hunk| self.paintItem(grid, x, y, width, height, hunk, normal, active);
    }

    pub fn pointerAt(self: *const DiffGutterToolbar, col: usize, row: usize, height: usize) ui.Pointer {
        const item = self.itemAt(row, height) orelse return .default;
        const buttons = self.getButtons(item.menu);
        return if (buttons.count > 0 and (col == 0 or (col == 1 and buttons.count > 1))) .pointer else .default;
    }

    pub fn dispatch(self: *DiffGutterToolbar, event: *const ui.MouseEvent, col: usize, height: usize, anchor: context_menu.Anchor) !bool {
        if (event.kind == .wheel) return false;
        if (event.kind == .move) return true;
        if (event.button != .left) return false;
        const old_press = if (event.kind == .up) self.pressed else null;
        if (event.kind == .up) self.pressed = null;
        const item = self.itemAt(event.y, height) orelse return true;
        if (self.pointerAt(col, event.y, height) != .pointer) return true;
        if (event.kind == .down) {
            self.pressed = .{ .row = event.y, .col = col, .original_version = self.original.model.getVersionId(), .modified_version = self.modified.model.getVersionId() };
            return true;
        }
        if (event.kind == .up) {
            const press = old_press orelse return true;
            if (press.row != event.y or press.col != col or !self.versionsMatch(press.original_version, press.modified_version)) return true;
        } else if (event.kind != .click) return true;
        if (!self.model.is_diff_up_to_date) return true;
        const buttons = self.getButtons(item.menu);
        const action = if (col == 0) buttons.primary else if (col == 1) buttons.secondAction() else null;
        if (action) |primary| {
            if (primary.enabled()) try self.runItem(item, primary.id());
        } else try self.showOverflow(item, anchor);
        return true;
    }

    fn versionsMatch(self: *const DiffGutterToolbar, original: u32, modified: u32) bool {
        return self.original.model.getVersionId() == original and self.modified.model.getVersionId() == modified and self.model.is_diff_up_to_date;
    }

    fn mappingForAction(self: *const DiffGutterToolbar, item: Item, allocator: std.mem.Allocator) !view_model.DetailedLineRangeMapping {
        _ = self;
        if (item.index != null) return item.mapping.withInnerChangesFromLineRanges(allocator);
        return .{ .original = item.mapping.original, .modified = item.mapping.modified, .inner_changes = if (item.mapping.inner_changes) |inner| try allocator.dupe(view_model.RangeMapping, inner) else null };
    }

    pub fn runCurrentHunk(self: *DiffGutterToolbar, id: []const u8) !bool {
        if (!self.model.is_diff_up_to_date) return false;
        const index = self.current_diff orelse return false;
        const item = self.getHunkItem(index) orelse return false;
        try self.runItem(item, id);
        return true;
    }

    fn runItem(self: *DiffGutterToolbar, item: Item, id: []const u8) !void {
        const allocator = self.allocator;
        var mapping = try self.mappingForAction(item, allocator);
        defer mapping.deinit(allocator);
        try self.runMapping(item.menu, mapping, id);
    }

    fn runMapping(self: *DiffGutterToolbar, menu: MenuId, mapping: view_model.DetailedLineRangeMapping, id: []const u8) !void {
        const host = self.host orelse return;
        const allocator = self.allocator;
        var resolved = try host.menus.getMenuActionsWithOptions(allocator, menu, self.context(), .{ .should_forward_args = true });
        defer resolved.deinit();
        for (resolved.groups) |group| for (group.actions) |action| {
            if (!std.mem.eql(u8, id, action.id()) or !action.enabled()) continue;
            const command = menu_api.MenuItemAction.from(action) orelse continue;
            const staged_value = try computeStagedValue(allocator, mapping, self.original.model, self.modified.model);
            defer allocator.free(staged_value);
            const argument: DiffEditorSelectionHunkToolbarContext = .{ .mapping = mapping, .originalWithModifiedChanges = staged_value, .modifiedUri = self.modified.model.uri(), .originalUri = self.original.model.uri(), .modifiedEncoding = @tagName(self.modified.getEncoding()) };
            try command.runWithArgument(CommandArgument.from(DiffEditorSelectionHunkToolbarContext, &argument));
            return;
        };
    }

    const OverflowContext = struct {
        owner: *DiffGutterToolbar,
        menu: MenuId,
        mapping: view_model.DetailedLineRangeMapping,
        original_version: u32,
        modified_version: u32,
        fn run(self: *OverflowContext, id: []const u8) !void {
            if (!self.owner.versionsMatch(self.original_version, self.modified_version)) return;
            try self.owner.runMapping(self.menu, self.mapping, id);
        }
        fn hide(ptr: *anyopaque) void {
            const self: *OverflowContext = @ptrCast(@alignCast(ptr));
            self.owner.open = false;
        }
    };

    fn showOverflow(self: *DiffGutterToolbar, item: Item, anchor: context_menu.Anchor) !void {
        const host = self.host orelse return;
        const menu = try context_menu.Menu.init(self.allocator, OverflowContext{ .owner = self, .menu = item.menu, .mapping = undefined, .original_version = self.original.model.getVersionId(), .modified_version = self.modified.model.getVersionId() }, OverflowContext.run);
        errdefer menu.deinit();
        menu.on_hide = OverflowContext.hide;
        const arena = menu.arena.allocator();
        menu.getActionsContext(OverflowContext).?.mapping = try self.mappingForAction(item, arena);
        var resolved = try host.menus.getMenuActions(self.allocator, item.menu, self.context());
        defer resolved.deinit();
        for (resolved.groups) |group| {
            if (group.actions.len == 0) continue;
            if (menu.items.items.len > 0) try menu.separator();
            for (group.actions) |action| try menu.add(try arena.dupe(u8, action.id()), .{ .label = try arena.dupe(u8, action.label()), .enabled = action.enabled() });
        }
        if (menu.items.items.len == 0) {
            menu.deinit();
            return;
        }
        try host.context_menu.showContextMenu(menu, anchor);
        self.open = true;
    }
};

pub const marker_column_width: usize = 1;

pub const ChangeKind = enum { add, delete, modify };

pub fn changeKind(mapping: view_model.DetailedLineRangeMapping) ChangeKind {
    if (mapping.original.isEmpty()) return .add;
    if (mapping.modified.isEmpty()) return .delete;
    return .modify;
}

pub fn markerGlyph(kind: ChangeKind) u21 {
    return switch (kind) {
        .add => '+',
        .delete => '-',
        .modify => '~',
    };
}

pub fn markerForMapping(mapping: view_model.DetailedLineRangeMapping) u21 {
    return markerGlyph(changeKind(mapping));
}

/// The glyph for a display row inside a changed block: the marker on the block
/// start row, the vertical continuation elsewhere.
pub fn gutterGlyph(mapping: view_model.DetailedLineRangeMapping, display_row: usize) u21 {
    if (display_row == mapping.modified.startLineNumber) return markerForMapping(mapping);
    return '│';
}

const Editor = @import("../../codeEditor/codeEditorWidgetTerminal.zig").Editor;

fn rangeRows(editor: *Editor, range: LineRange) ?LineRange {
    if (range.isEmpty() or range.startLineNumber < 1 or range.startLineNumber > editor.model.getLineCount()) return null;
    const start = editor.viewPositionOfModelPosition(.{ .lineNumber = range.startLineNumber, .column = 1 }).lineNumber;
    const last = @min(range.endLineNumberExclusive - 1, editor.model.getLineCount());
    const end = editor.viewPositionOfModelPosition(.{ .lineNumber = last, .column = editor.model.getLineMaxColumn(last) }).lineNumber;
    const layout = editor.viewLayout();
    return LineRange.init(@intFromFloat(layout.getVerticalOffsetForLineNumber(start, false)), @intFromFloat(layout.getVerticalOffsetAfterLineNumber(end, false)));
}

/// Hunk bounds on the common vertical axis, including the longer side's
/// text and the shorter side's alignment zone. Coordinates are zero-based
/// layout offsets, not model or view line numbers.
pub fn hunkBounds(mapping: view_model.DetailedLineRangeMapping, original: *Editor, modified: *Editor) LineRange {
    const left = rangeRows(original, mapping.original);
    const right = rangeRows(modified, mapping.modified);
    if (left) |l| {
        if (right) |r| return LineRange.init(@min(l.startLineNumber, r.startLineNumber), @max(l.endLineNumberExclusive, r.endLineNumberExclusive));
        return l;
    }
    return right orelse LineRange.init(0, 0);
}

const EditorGutter = @import("../utils/editorGutter.zig").EditorGutter;
const IGutterItemProvider = @import("../utils/editorGutter.zig").IGutterItemProvider;

/// The diff gutter supplies the hunk items and their common-axis geometry to
/// the shared gutter layout. The view owns the viewport clipping.
pub const DiffEditorGutter = struct {
    mappings: []const view_model.DiffMapping,
    original: *Editor,
    modified: *Editor,

    fn bounds(context: *const anyopaque, index: usize) LineRange {
        const self: *const DiffEditorGutter = @ptrCast(@alignCast(context));
        return hunkBounds(self.mappings[index].line_range_mapping, self.original, self.modified);
    }

    pub fn render(self: *const DiffEditorGutter, top: usize, height: usize) EditorGutter {
        const provider: IGutterItemProvider = .{ .context = self, .item_count = self.mappings.len, .bounds = bounds };
        return EditorGutter.render(provider, LineRange.ofLength(top, height));
    }
};

pub fn mappingIndexAtVerticalOffset(mappings: []const view_model.DiffMapping, original: *Editor, modified: *Editor, offset: usize) ?usize {
    var low: usize = 0;
    var high = mappings.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const bounds = hunkBounds(mappings[mid].line_range_mapping, original, modified);
        if (offset < bounds.startLineNumber) {
            high = mid;
        } else if (offset >= bounds.endLineNumberExclusive) {
            low = mid + 1;
        } else return mid;
    }
    return null;
}

pub fn mappingIndexAtModelLine(mappings: []const view_model.DiffMapping, original: bool, line: usize) ?usize {
    var low: usize = 0;
    var high = mappings.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const mapping = mappings[mid].line_range_mapping;
        const range = if (original) mapping.original else mapping.modified;
        if (line < range.startLineNumber) {
            high = mid;
        } else if (line >= range.endLineNumberExclusive) {
            low = mid + 1;
        } else return mid;
    }
    return null;
}

test "gutterFeature: selection toolbar intersects inner mappings and stages only selected text" {
    const allocator = std.testing.allocator;
    const TestModel = @import("../../../../test/common/port/testSupport.zig").TestModel;
    var original = try TestModel.init(allocator, "prefix\r\nabc old def stale\r\nsuffix", "plaintext");
    defer original.deinit();
    var modified = try TestModel.init(allocator, "prefix\r\nabc new def fresh\r\nsuffix", "plaintext");
    defer modified.deinit();
    var inner = [_]view_model.RangeMapping{
        .{ .originalRange = Range.init(2, 5, 2, 8), .modifiedRange = Range.init(2, 5, 2, 8) },
        .{ .originalRange = Range.init(2, 13, 2, 18), .modifiedRange = Range.init(2, 13, 2, 18) },
    };
    const mappings = [_]view_model.DiffMapping{.{ .line_range_mapping = .{
        .original = LineRange.ofLength(2, 1),
        .modified = LineRange.ofLength(2, 1),
        .inner_changes = &inner,
    } }};
    var selected = try selectedDiffs(allocator, &mappings, &.{ Selection.init(2, 6, 2, 7), Selection.init(2, 10, 2, 10) });
    defer selected.deinit(allocator);
    try std.testing.expectEqualSlices(usize, &.{0}, selected.mapping_indices);
    try std.testing.expectEqualSlices(view_model.RangeMapping, inner[0..1], selected.range_mappings);
    var selected_mapping = try view_model.DetailedLineRangeMapping.fromRangeMappings(allocator, selected.range_mappings);
    defer selected_mapping.deinit(allocator);
    const selected_value = try computeStagedValue(allocator, selected_mapping, original.model, modified.model);
    defer allocator.free(selected_value);
    try std.testing.expectEqualStrings("prefix\r\nabc new def stale\r\nsuffix", selected_value);

    var hunk = try mappings[0].line_range_mapping.withInnerChangesFromLineRanges(allocator);
    defer hunk.deinit(allocator);
    const hunk_value = try computeStagedValue(allocator, hunk, original.model, modified.model);
    defer allocator.free(hunk_value);
    try std.testing.expectEqualStrings("prefix\r\nabc new def fresh\r\nsuffix", hunk_value);

    var empty = try selectedDiffs(allocator, &mappings, &.{Selection.init(2, 8, 2, 9)});
    defer empty.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), empty.mapping_indices.len);
    try std.testing.expectEqual(@as(usize, 0), empty.range_mappings.len);
}

test "gutterFeature: whole-line staging handles document boundaries" {
    const allocator = std.testing.allocator;
    const TestModel = @import("../../../../test/common/port/testSupport.zig").TestModel;
    for ([_]struct { old: []const u8, new: []const u8, original: LineRange, modified: LineRange }{
        .{ .old = "tail", .new = "head\ntail", .original = LineRange.ofLength(1, 0), .modified = LineRange.ofLength(1, 1) },
        .{ .old = "head\ntail", .new = "tail", .original = LineRange.ofLength(1, 1), .modified = LineRange.ofLength(1, 0) },
        .{ .old = "head", .new = "head\ntail", .original = LineRange.ofLength(2, 0), .modified = LineRange.ofLength(2, 1) },
        .{ .old = "head\ntail", .new = "head", .original = LineRange.ofLength(2, 1), .modified = LineRange.ofLength(2, 0) },
    }) |fixture| {
        var original = try TestModel.init(allocator, fixture.old, "plaintext");
        defer original.deinit();
        var modified = try TestModel.init(allocator, fixture.new, "plaintext");
        defer modified.deinit();
        const change: view_model.DetailedLineRangeMapping = .{ .original = fixture.original, .modified = fixture.modified, .inner_changes = null };
        var hunk = try change.withInnerChangesFromLineRanges(allocator);
        defer hunk.deinit(allocator);
        const value = try computeStagedValue(allocator, hunk, original.model, modified.model);
        defer allocator.free(value);
        try std.testing.expectEqualStrings(fixture.new, value);
    }
}

test "gutterFeature: markers for insert, delete and modify" {
    const add = view_model.DetailedLineRangeMapping{
        .original = LineRange.ofLength(2, 0),
        .modified = LineRange.ofLength(2, 1),
        .inner_changes = null,
    };
    const remove = view_model.DetailedLineRangeMapping{
        .original = LineRange.ofLength(2, 1),
        .modified = LineRange.ofLength(2, 0),
        .inner_changes = null,
    };
    const modify = view_model.DetailedLineRangeMapping{
        .original = LineRange.ofLength(2, 1),
        .modified = LineRange.ofLength(2, 1),
        .inner_changes = null,
    };
    try std.testing.expectEqual(ChangeKind.add, changeKind(add));
    try std.testing.expectEqual(@as(u21, '+'), markerForMapping(add));
    try std.testing.expectEqual(@as(u21, '-'), markerForMapping(remove));
    try std.testing.expectEqual(@as(u21, '~'), markerForMapping(modify));
    try std.testing.expectEqual(@as(u21, '~'), gutterGlyph(modify, 2));
    try std.testing.expectEqual(@as(u21, '│'), gutterGlyph(modify, 3));
}

test "gutterFeature: benchmark 1k and 10k real-layout hunks" {
    const time = @import("../../../../../base/common/timeCompat.zig");
    const allocator = std.testing.allocator;
    for ([_]usize{ 1000, 10000 }) |count| {
        const text = try allocator.alloc(u8, count * 2 - 1);
        defer allocator.free(text);
        @memset(text, '\n');
        const original = try Editor.createFromText(allocator, std.testing.io, text, "original.txt", 40, 40);
        defer {
            original.deinit();
            allocator.destroy(original);
        }
        const modified = try Editor.createFromText(allocator, std.testing.io, text, "modified.txt", 40, 40);
        defer {
            modified.deinit();
            allocator.destroy(modified);
        }
        const mappings = try allocator.alloc(view_model.DiffMapping, count);
        defer allocator.free(mappings);
        for (mappings, 0..) |*mapping, index| {
            const range = LineRange.ofLength(index * 2 + 1, 1);
            mapping.* = .{ .line_range_mapping = .{ .original = range, .modified = range, .inner_changes = null } };
        }
        const start = time.milliTimestamp();
        var sum: usize = 0;
        for (0..1000) |frame| {
            const top = (frame * 31) % (count * 2);
            for (0..40) |offset| {
                const row = (top + offset) % (count * 2);
                const index = mappingIndexAtVerticalOffset(mappings, original, modified, row);
                try std.testing.expectEqual(if (row % 2 == 0) @as(?usize, row / 2) else null, index);
                sum += index orelse 0;
            }
        }
        std.debug.print("[bench] diff real-layout gutter: {d} hunks, 40000 lookups, {d} ms, checksum {d}\n", .{ count, time.milliTimestamp() - start, sum });
        const provider: DiffEditorGutter = .{ .mappings = mappings, .original = original, .modified = modified };
        const item_start = time.milliTimestamp();
        var item_sum: usize = 0;
        for (0..1000) |frame| {
            const top = (frame * 31) % (count * 2);
            const first_height = @min(40, count * 2 - top);
            var items = provider.render(top, first_height);
            while (items.next()) |item| {
                try std.testing.expectEqual(item.index * 2, item.bounds.startLineNumber);
                item_sum += item.index;
            }
            if (first_height < 40) {
                items = provider.render(0, 40 - first_height);
                while (items.next()) |item| item_sum += item.index;
            }
        }
        try std.testing.expectEqual(sum, item_sum);
        std.debug.print("[bench] diff visible gutter items: {d} hunks, 1000 frames, {d} ms, checksum {d}\n", .{ count, time.milliTimestamp() - item_start, item_sum });
    }
}
