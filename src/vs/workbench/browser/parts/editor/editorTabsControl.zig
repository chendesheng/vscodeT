// Port of the tab context menu and local drag behavior in
// src/vs/workbench/browser/parts/editor/editorTabsControl.ts.
const builtin = @import("builtin");
const std = @import("std");
const ui = @import("ui");
const ThemeColors = @import("../../themeColors.zig").ThemeColors;

pub fn isCopyIntoOtherGroup(mods: ui.Modifiers, singleton: bool) bool {
    return !singleton and if (builtin.os.tag == .macos) mods.alt else mods.ctrl;
}

pub fn isToggleSplitOperation(mods: ui.Modifiers) bool {
    return if (builtin.os.tag == .macos) mods.shift else mods.alt;
}

/// The cell equivalent of the upstream applyDragImage and its .monaco-drag-image
/// styles. The caller places this image one cell away from the pointer.
pub fn applyDragImage(
    allocator: std.mem.Allocator,
    label: []const u8,
    theme: ?*const ThemeColors,
    cell_borders: bool,
) !ui.CellGrid {
    const max_width = 18;
    var text_width: usize = 0;
    var offset: usize = 0;
    while (offset < label.len and text_width < max_width) {
        const decoded = ui.dom.decodeAt(label, offset);
        text_width += ui.dom.defaultMeasureWidth(decoded.cp);
        offset += decoded.len;
    }
    const width = @min(text_width + 2, max_width);
    const fg: ui.Color = if (theme) |colors| colors.color("list.activeSelectionForeground", .{ 255, 255, 255 }) else .{ .r = 255, .g = 255, .b = 255 };
    const bg: ui.Color = if (theme) |colors| colors.color("list.activeSelectionBackground", .{ 4, 57, 94 }) else .{ .r = 4, .g = 57, .b = 94 };
    const paint: ui.cell.PaintStyle = .{ .fg = ui.cell.packColor(fg), .bg = ui.cell.packColor(bg) };
    var image = try ui.CellGrid.init(allocator, width, 1);
    image.fillRect(0, 0, @floatFromInt(width), 1, paint);
    offset = 0;
    var col: usize = 1;
    while (offset < label.len and col < width - 1) {
        const decoded = ui.dom.decodeAt(label, offset);
        const cells = ui.dom.defaultMeasureWidth(decoded.cp);
        if (col + cells >= width or (col + cells == width - 1 and offset + decoded.len < label.len)) {
            image.putCodepoint(col, 0, '…', 1, paint);
            break;
        }
        image.putCodepoint(col, 0, decoded.cp, cells, paint);
        col += cells;
        offset += decoded.len;
    }
    if (cell_borders) {
        const color = if (theme) |colors| colors.color("list.focusOutline", .{ 0, 127, 212 }) else ui.Color{ .r = 0, .g = 127, .b = 212 };
        const stroke: ui.cell_border.Stroke = .{ .width = 32, .color = .{ .rgb = color }, .priority = 3 };
        const edge = ui.cell_border.Segment;
        for (0..width) |x| image.addBorder(x, 0, edge.top | edge.bottom, stroke);
        image.addBorder(0, 0, edge.left, stroke);
        image.addBorder(width - 1, 0, edge.right, stroke);
    }
    return image;
}

const action_mod = @import("../../../../platform/actions/common/actions.zig");
const contextkey = @import("../../../../platform/contextkey/common/contextkey.zig");
const context_menus = @import("../../../../platform/contextview/browser/contextMenuService.zig");
const MenuService = @import("../../../../platform/actions/common/menuService.zig").MenuService;
const GroupActions = @import("editorActions.zig").GroupActions;
const Tab = @import("editorPane.zig").Tab;
const GroupView = @import("editorGroupView.zig").EditorGroupView(*Tab);
const GroupIdentifier = @import("../../../common/editor.zig").GroupIdentifier;
const Capabilities = @import("../../../common/editor.zig").EditorInputCapabilities;

// EditorTitleContext contributions from editor.contribution.ts. Browser-only
// new-window commands and unported editor resolver/share submenus are omitted.
const close_id = "workbench.action.closeActiveEditor";
const close_others_id = "workbench.action.closeOtherEditors";
const close_right_id = "workbench.action.closeEditorsToTheRight";
const close_saved_id = "workbench.action.closeUnmodifiedEditors";
const close_all_id = "workbench.action.closeEditorsInGroup";
const keep_id = "workbench.action.keepEditor";
const pin_id = "workbench.action.pinEditor";
const unpin_id = "workbench.action.unpinEditor";
const split_id = "workbench.action.splitEditor";
const cannot_close: contextkey.Expr = .{ .Not = "activeEditorCannotClose" };
const multiple_tabs: contextkey.Expr = .{ .NotEquals = .{ .key = "groupEditorsCount", .value = .{ .number = 1 } } };
const not_last: contextkey.Expr = .{ .Not = "activeEditorIsLastInGroup" };
const single_selection: contextkey.Expr = .{ .Not = "multipleEditorsSelectedInGroup" };
const close_right_enabled: contextkey.Expr = .{ .And = @constCast(&[_]*const contextkey.Expr{ &not_last, &single_selection }) };
const tabs_visible: contextkey.Expr = .{ .Defined = "editorTabsVisible" };
const preview_enabled: contextkey.Expr = .{ .Defined = "config.workbench.editor.enablePreview" };
const is_preview: contextkey.Expr = .{ .Not = "activeEditorIsNotPreview" };
const not_sticky: contextkey.Expr = .{ .Not = "activeEditorIsPinned" };
const sticky: contextkey.Expr = .{ .Defined = "activeEditorIsPinned" };
const split_vertical: contextkey.Expr = .{ .Defined = "splitEditorsVertically" };
const split_horizontal: contextkey.Expr = .{ .Not = "splitEditorsVertically" };

pub fn registerEditorTitleContext(registry: *action_mod.MenuRegistry) !void {
    const menu = action_mod.menu_ids.EditorTitleContext;
    for ([_]action_mod.IMenuItem{
        .{ .command = .{ .id = close_id, .title = "Close" }, .group = "1_close", .order = 10, .when = &cannot_close },
        .{ .command = .{ .id = close_others_id, .title = "Close Others", .precondition = &multiple_tabs }, .group = "1_close", .order = 20 },
        .{ .command = .{ .id = close_right_id, .title = "Close to the Right", .precondition = &close_right_enabled }, .group = "1_close", .order = 30, .when = &tabs_visible },
        .{ .command = .{ .id = close_saved_id, .title = "Close Saved" }, .group = "1_close", .order = 40 },
        .{ .command = .{ .id = close_all_id, .title = "Close All" }, .group = "1_close", .order = 50 },
        .{ .command = .{ .id = keep_id, .title = "Keep Open", .precondition = &is_preview }, .group = "3_preview", .order = 10, .when = &preview_enabled },
        .{ .command = .{ .id = pin_id, .title = "Pin" }, .group = "3_preview", .order = 20, .when = &not_sticky },
        .{ .command = .{ .id = unpin_id, .title = "Unpin" }, .group = "3_preview", .order = 20, .when = &sticky },
        .{ .command = .{ .id = split_id, .title = "Split Right" }, .group = "5_split", .order = 10, .when = &split_horizontal },
        .{ .command = .{ .id = split_id, .title = "Split Down" }, .group = "5_split", .order = 10, .when = &split_vertical },
    }) |item| try registry.appendMenuItem(menu, item);
}

/// EditorTabsControl.onTabContextMenu uses a scoped context for the picked
/// editor, not the active editor. The native host supplies only the anchor,
/// frame invalidation and terminal-pane commands that require native I/O.
pub const EditorTabsControl = struct {
    allocator: std.mem.Allocator,
    groups: *GroupActions,
    menus: *MenuService,
    context_menu: *context_menus.ContextMenuService,
    context_keys: *const contextkey.IContextKeyService,
    host: struct {
        context: *anyopaque,
        request_frame: *const fn (*anyopaque) void,
        move_terminal_to_panel: *const fn (*anyopaque, *GroupView, *Tab) anyerror!void,
        rename_terminal: *const fn (*anyopaque, *Tab) anyerror!void,
    },

    const Context = struct {
        owner: *EditorTabsControl,
        group_id: GroupIdentifier,
        tabs: []const *Tab = &.{},

        fn groupView(self: *Context) ?*GroupView {
            const part = self.owner.groups.part;
            const group = part.service.getGroup(self.group_id) orelse return null;
            return part.viewForGroup(group);
        }

        fn getValue(ptr: *anyopaque, name: []const u8) contextkey.ContextKeyValue {
            const self: *Context = @ptrCast(@alignCast(ptr));
            const pane = self.groupView() orelse return .undefined_value;
            const tab = self.tabs[0];
            const model = &pane.group.model;
            if (std.mem.eql(u8, name, "groupEditorsCount")) return .{ .number = @floatFromInt(model.count()) };
            if (std.mem.eql(u8, name, "activeEditorIsLastInGroup")) return .{ .boolean = model.isLast(tab.input) };
            if (std.mem.eql(u8, name, "activeEditorIsNotPreview")) return .{ .boolean = model.isPinned(.{ .editor = tab.input }) };
            if (std.mem.eql(u8, name, "activeEditorIsPinned")) return .{ .boolean = model.isSticky(.{ .editor = tab.input }) };
            if (std.mem.eql(u8, name, "activeEditorCannotClose")) return .{ .boolean = tab.input.hasCapability(Capabilities.CannotClose) };
            if (std.mem.eql(u8, name, "multipleEditorsSelectedInGroup")) return .{ .boolean = model.selection.items.len > 1 };
            if (std.mem.eql(u8, name, "editorTabsVisible")) return .{ .boolean = pane.tabs_visible };
            if (std.mem.eql(u8, name, "splitEditorsVertically")) return .{ .boolean = self.owner.groups.preferredSideBySideDirection() == .DOWN };
            if (std.mem.eql(u8, name, "resourceScheme")) return .{ .string = if (tab.terminal_input != null) "vscode-terminal" else "file" };
            const value = self.owner.context_keys.getContextKeyValue(name);
            if (std.mem.eql(u8, name, "config.workbench.editor.enablePreview") and value == .undefined_value) return .{ .boolean = true };
            return value;
        }

        fn focusOnHide(ptr: *anyopaque) void {
            const self: *Context = @ptrCast(@alignCast(ptr));
            if (self.owner.groups.part.activeView()) |pane| pane.focus();
        }

        fn invoke(ptr: *anyopaque, id: []const u8, _: []const []const u8) !void {
            const self: *Context = @ptrCast(@alignCast(ptr));
            try self.run(id);
        }

        fn run(self: *Context, id: []const u8) !void {
            const owner = self.owner;
            defer owner.host.request_frame(owner.host.context);
            const pane = self.groupView() orelse return;
            if (std.mem.startsWith(u8, id, "overflow:")) {
                const index = std.fmt.parseInt(usize, id[9..], 10) catch return;
                if (index >= self.tabs.len or pane.indexOfTab(self.tabs[index]) == null) return;
                try pane.activateTab(self.tabs[index]);
                pane.focus();
                return;
            }
            const tab = self.tabs[0];
            if (pane.indexOfTab(tab) == null) return;
            const model = &pane.group.model;
            if (std.mem.eql(u8, id, close_id)) {
                var candidates: std.ArrayList(*Tab) = .empty;
                defer candidates.deinit(owner.allocator);
                for (self.tabs) |candidate| {
                    if (pane.indexOfTab(candidate) != null and !candidate.input.hasCapability(Capabilities.CannotClose)) try candidates.append(owner.allocator, candidate);
                }
                try pane.closeEditors(candidates.items, owner.groups.dialog_service.*, owner.groups.close_host);
            } else if (std.mem.eql(u8, id, close_others_id) or std.mem.eql(u8, id, close_right_id) or std.mem.eql(u8, id, close_saved_id) or std.mem.eql(u8, id, close_all_id)) {
                const only_others = std.mem.eql(u8, id, close_others_id);
                const only_right = std.mem.eql(u8, id, close_right_id);
                const only_saved = std.mem.eql(u8, id, close_saved_id);
                if (only_others) for (self.tabs) |selected| {
                    if (pane.indexOfTab(selected) != null) _ = try model.pin(selected.input);
                };
                if (only_right) if (pane.activeTab()) |active| {
                    _ = try model.pin(active.input);
                };
                const inputs = try model.getEditors(owner.allocator, if (only_right or only_others) .SEQUENTIAL else .MOST_RECENTLY_ACTIVE, true);
                defer owner.allocator.free(inputs);
                const index = model.indexOfExact(tab.input) orelse return;
                const sticky_count = model.stickyCount();
                var candidates: std.ArrayList(*Tab) = .empty;
                defer candidates.deinit(owner.allocator);
                for (inputs, 0..) |input, i| {
                    if (only_right and i + sticky_count <= index) continue;
                    if (only_saved and input.isDirty() and !input.isSaving()) continue;
                    if (input.hasCapability(Capabilities.CannotClose)) continue;
                    const candidate = pane.tabForInput(input) orelse continue;
                    if (only_others and std.mem.indexOfScalar(*Tab, self.tabs, candidate) != null) continue;
                    try candidates.append(owner.allocator, candidate);
                }
                try pane.closeEditors(candidates.items, owner.groups.dialog_service.*, owner.groups.close_host);
            } else if (std.mem.eql(u8, id, keep_id) or std.mem.eql(u8, id, pin_id) or std.mem.eql(u8, id, unpin_id)) {
                for (self.tabs) |candidate| {
                    if (pane.indexOfTab(candidate) == null) continue;
                    if (std.mem.eql(u8, id, keep_id)) {
                        _ = try model.pin(candidate.input);
                    } else if (std.mem.eql(u8, id, pin_id)) {
                        _ = try model.stick(candidate.input);
                    } else {
                        _ = try model.unstick(candidate.input);
                    }
                }
            } else if (std.mem.eql(u8, id, split_id)) {
                try pane.activateTab(tab);
                pane.focus();
                try owner.groups.splitActiveInDirection(owner.groups.preferredSideBySideDirection());
            } else if (std.mem.eql(u8, id, "workbench.action.terminal.moveToTerminalPanel")) {
                try owner.host.move_terminal_to_panel(owner.host.context, pane, tab);
            } else if (std.mem.eql(u8, id, "workbench.action.terminal.rename")) {
                try owner.host.rename_terminal(owner.host.context, tab);
            } else if (owner.menus.command_registry) |registry| {
                _ = try registry.execute(id);
            }
        }
    };

    pub fn onTabContextMenu(self: *EditorTabsControl, pane: *GroupView, tab: *Tab, anchor: context_menus.Anchor) !void {
        const menu = try context_menus.Menu.init(self.allocator, Context{ .owner = self, .group_id = pane.group.id }, Context.run);
        errdefer menu.deinit();
        const context = menu.getActionsContext(Context).?;
        const arena = menu.arena.allocator();
        var tabs: std.ArrayList(*Tab) = .empty;
        try tabs.append(arena, tab);
        // resolveCommandsContext: a picked selected editor targets the group's
        // selection; a picked unselected editor targets only that editor.
        if (pane.group.model.isSelected(.{ .editor = tab.input })) {
            const selected = try pane.group.model.selectedEditors(arena);
            for (selected) |input| {
                if (input == tab.input) continue;
                if (pane.tabForInput(input)) |candidate| try tabs.append(arena, candidate);
            }
        }
        context.tabs = tabs.items;
        menu.on_hide = Context.focusOnHide;
        try menu.appendMenuActionsWithOptions(self.menus, action_mod.menu_ids.EditorTitleContext, .{ .context = context, .get_value = Context.getValue }, false, .{ .invoker = .{ .context = context, .run = Context.invoke } });
        try self.context_menu.interface().showContextMenu(menu, anchor);
    }

    /// The single-cell leading ellipsis is a terminal replacement for the
    /// browser's horizontally scrollable tab bar.
    pub fn showOverflowMenu(self: *EditorTabsControl, pane: *GroupView, anchor: context_menus.Anchor) !bool {
        var ordered = std.array_list.Managed(*Tab).init(self.allocator);
        defer ordered.deinit();
        try pane.orderedTabs(self.allocator, &ordered);
        if (pane.hits.items.len >= ordered.items.len) return false;
        const menu = try context_menus.Menu.init(self.allocator, Context{ .owner = self, .group_id = pane.group.id }, Context.run);
        errdefer menu.deinit();
        const arena = menu.arena.allocator();
        var hidden: std.ArrayList(*Tab) = .empty;
        for (ordered.items, 0..) |tab, index| {
            for (pane.hits.items) |hit| {
                if (hit.index == index) break;
            } else try hidden.append(arena, tab);
        }
        if (hidden.items.len == 0) {
            menu.deinit();
            return false;
        }
        for (hidden.items, 0..) |tab, index| try menu.add(try std.fmt.allocPrint(arena, "overflow:{d}", .{index}), .{ .label = tab.input.getName() });
        menu.getActionsContext(Context).?.tabs = hidden.items;
        try self.context_menu.interface().showContextMenu(menu, anchor);
        return true;
    }

    pub fn invalidateTab(self: *EditorTabsControl, tab: *Tab) void {
        const menu = self.context_menu.current orelse return;
        const context = menu.getActionsContext(Context) orelse return;
        if (std.mem.indexOfScalar(*Tab, context.tabs, tab) != null) self.context_menu.hideContextMenu();
    }
};
