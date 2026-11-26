// Port of the EditorTitleControl menu/toolbar ownership in
// src/vs/workbench/browser/parts/editor/editorTitleControl.ts.
// The terminal draws the primary icon actions and overflow in one title row.
// The retained menu observes registry/context events; the group binds the
// active diff widget's context rather than deriving it during paint.
const std = @import("std");
const action_mod = @import("../../../../base/common/actions.zig");
const contextkey = @import("../../../../platform/contextkey/common/contextkey.zig");
const actions = @import("../../../../platform/actions/common/actions.zig");
const menus = @import("../../../../platform/actions/common/menuService.zig");
const context_menus = @import("../../../../platform/contextview/browser/contextMenuService.zig");
const View = @import("../../../../editor/browser/widget/codeEditor/terminalEditorView.zig").IEditorView;
const DiffWidget = @import("../../../../editor/browser/widget/diffEditor/diffEditorWidget.zig").DiffEditorWidget(View);
const MultiDiffPane = @import("../../../contrib/multiDiffEditor/browser/multiDiffEditor.zig").MultiDiffEditor(View);
const multi_common = @import("../../../contrib/multiDiffEditor/common/multiDiffEditor.zig");

pub const Host = struct {
    menus: *menus.MenuService,
    parent_context: contextkey.IContext,
    context: *anyopaque,
    request_frame: *const fn (*anyopaque) void,
};

pub const ToolbarHit = struct {
    start: usize,
    end: usize,
    id: []const u8,
    enabled: bool,
    include_navigation: bool = false,
};

pub const overflow_id = "editorTitle.overflow";

pub const EditorTitleControl = struct {
    allocator: std.mem.Allocator,
    host: ?Host = null,
    menu: ?*menus.Menu = null,
    widget: ?*DiffWidget = null,
    multi_pane: ?*MultiDiffPane = null,
    widget_listener: ?@import("../../../../base/common/event.zig").SignalSubscription = null,

    pub fn attach(self: *EditorTitleControl, host: Host) !void {
        if (self.menu != null) return;
        self.host = host;
        const menu = try host.menus.createMenu(self.allocator, actions.menu_ids.EditorTitle, self.context());
        errdefer {
            menu.deinit();
            self.allocator.destroy(menu);
        }
        _ = try menu.onDidChange.listenSignal(self, onMenuChanged);
        self.menu = menu;
    }

    pub fn deinit(self: *EditorTitleControl) void {
        self.detachWidget();
        if (self.menu) |menu| {
            menu.deinit();
            self.allocator.destroy(menu);
        }
        self.menu = null;
        self.host = null;
    }

    fn detachWidget(self: *EditorTitleControl) void {
        if (self.widget_listener) |listener| listener.dispose();
        self.widget_listener = null;
        self.widget = null;
        self.multi_pane = null;
    }

    pub fn setActiveDiff(self: *EditorTitleControl, widget: ?*DiffWidget) !void {
        if (self.menu == null or (self.widget == widget and self.multi_pane == null)) return;
        self.detachWidget();
        if (widget) |value| {
            self.widget = value;
            self.widget_listener = try value.on_did_change_context.listenSignal(self, onWidgetChanged);
        }
        try self.refresh();
    }

    pub fn setActiveMultiDiff(self: *EditorTitleControl, widget: *MultiDiffPane) !void {
        if (self.menu == null or self.multi_pane == widget) return;
        self.detachWidget();
        self.multi_pane = widget;
        self.widget_listener = try widget.changed.listenSignal(self, onWidgetChanged);
        try self.refresh();
    }

    fn onWidgetChanged(self: *EditorTitleControl) !void {
        try self.refresh();
    }

    fn refresh(self: *EditorTitleControl) !void {
        if (self.menu) |menu| try menu.refresh();
        try onMenuChanged(self);
    }

    fn onMenuChanged(self: *EditorTitleControl) !void {
        if (self.host) |host| host.request_frame(host.context);
    }

    fn context(self: *EditorTitleControl) contextkey.IContext {
        return .{ .context = self, .get_value = getValue };
    }

    fn getValue(ptr: *anyopaque, key: []const u8) contextkey.ContextKeyValue {
        const self: *EditorTitleControl = @ptrCast(@alignCast(ptr));
        const widget = self.widget orelse if (self.multi_pane) |multi| multi.widget.activeControl() else null;
        if (std.mem.eql(u8, key, "isInDiffEditor")) return .{ .boolean = self.widget != null or self.multi_pane != null };
        for ([_][]const u8{ "textCompareEditorActive", "activeCompareEditorCanSwap" }) |name| {
            if (std.mem.eql(u8, key, name)) return .{ .boolean = self.widget != null };
        }
        if (std.mem.eql(u8, key, "activeEditor")) {
            if (self.multi_pane != null) return .{ .string = multi_common.MULTI_DIFF_EDITOR_ID };
            return .{ .string = "" };
        }
        if (std.mem.eql(u8, key, "inMultiDiffEditor")) return .{ .boolean = self.multi_pane != null };
        if (std.mem.eql(u8, key, "multiDiffEditorAllCollapsed")) return .{ .boolean = if (self.multi_pane) |multi| multi.widget.impl.allCollapsed() else false };
        if (std.mem.eql(u8, key, "multiDiffEditorRenderSideBySide")) return .{ .boolean = if (self.multi_pane) |multi| multi.widget.impl.config.render_side_by_side orelse true else true };
        if (std.mem.eql(u8, key, "multiDiffEditorFileListAvailable")) return .{ .boolean = if (self.multi_pane) |multi| multi.fileListAvailable() else false };
        if (std.mem.eql(u8, key, "multiDiffEditorFileListEnabled")) return .{ .boolean = if (self.multi_pane) |multi| multi.fileListEnabled() else false };
        if (std.mem.eql(u8, key, "multiDiffEditorFileListVisible")) return .{ .boolean = if (self.multi_pane) |multi| multi.fileListVisible() else false };
        if (std.mem.eql(u8, key, "multiDiffEditorFileListFocus")) return .{ .boolean = if (self.multi_pane) |multi| multi.fileListFocused() else false };
        if (std.mem.eql(u8, key, "multiDiffEditorFileListViewMode")) return .{ .string = if (self.multi_pane) |multi| @tagName(multi.fileListViewMode()) else "list" };
        if (std.mem.eql(u8, key, "multiDiffEditorFileListPosition")) return .{ .string = if (self.multi_pane) |multi| @tagName(multi.fileListPosition()) else "right" };
        if (std.mem.eql(u8, key, "diffEditorHasChanges")) return .{ .boolean = if (widget) |value| value.context_state.has_changes else false };
        if (std.mem.eql(u8, key, "diffEditorInlineMode")) return .{ .boolean = if (widget) |value| value.context_state.inline_mode else false };
        if (std.mem.eql(u8, key, "diffEditorAutomaticRenderSideBySide")) return .{ .boolean = if (widget) |value| value.context_state.automatic_side_by_side else true };
        if (std.mem.eql(u8, key, "diffEditorTemporaryInlineMode")) return .{ .boolean = if (widget) |value| value.context_state.temporary_inline_mode else false };
        if (widget) |value| {
            const state = value.context_state;
            if (std.mem.eql(u8, key, "config.diffEditor.renderSideBySide")) return .{ .boolean = state.render_side_by_side };
            if (std.mem.eql(u8, key, "config.diffEditor.useInlineViewWhenSpaceIsLimited")) return .{ .boolean = state.auto_inline };
            if (std.mem.eql(u8, key, "config.diffEditor.ignoreTrimWhitespace")) return .{ .boolean = state.ignore_whitespace };
            if (std.mem.eql(u8, key, "config.diffEditor.hideUnchangedRegions.enabled")) return .{ .boolean = state.hide_unchanged };
        }
        if (self.multi_pane) |multi| if (multi.widget.impl.getContextKey(key)) |value| return value;
        return if (self.host) |host| host.parent_context.getValue(key) else .undefined_value;
    }

    pub fn primaryActions(self: *const EditorTitleControl) []const action_mod.IAction {
        const menu = self.menu orelse return &.{};
        for (menu.getActions()) |group| {
            if (std.mem.eql(u8, group.id, "navigation")) return group.actions;
        }
        return &.{};
    }

    pub fn hasSecondaryActions(self: *const EditorTitleControl) bool {
        const menu = self.menu orelse return false;
        for (menu.getActions()) |group| {
            if (!std.mem.eql(u8, group.id, "navigation") and group.actions.len > 0) return true;
        }
        return false;
    }

    pub fn actionVisible(action: action_mod.IAction) bool {
        return if (menus.MenuItemAction.from(action)) |item| !item.hidden else true;
    }

    pub fn glyph(action: action_mod.IAction) u21 {
        const icon = if (menus.MenuItemAction.from(action)) |item| item.item.icon orelse "" else "";
        if (std.mem.eql(u8, icon, "diff-editor-previous-change")) return '↑';
        if (std.mem.eql(u8, icon, "diff-editor-next-change")) return '↓';
        if (std.mem.eql(u8, icon, "arrow-swap")) return '↔';
        if (std.mem.eql(u8, icon, "diff-editor-toggle-whitespace")) return '␣';
        if (std.mem.eql(u8, icon, "map")) return '▤';
        if (std.mem.eql(u8, icon, "arrow-up")) return '↑';
        if (std.mem.eql(u8, icon, "arrow-down")) return '↓';
        if (std.mem.eql(u8, icon, "collapse-all")) return '⊟';
        if (std.mem.eql(u8, icon, "expand-all")) return '⊞';
        if (std.mem.eql(u8, icon, "list-flat")) return '≡';
        return '•';
    }

    pub fn hitAt(hits: []const ToolbarHit, column: usize) ?ToolbarHit {
        for (hits) |hit| {
            if (column >= hit.start and column < hit.end) return hit;
        }
        return null;
    }

    pub fn runAction(self: *EditorTitleControl, hit: ToolbarHit, service: context_menus.IContextMenuService, anchor: context_menus.Anchor) !void {
        if (!hit.enabled) return;
        if (std.mem.eql(u8, hit.id, overflow_id)) {
            const host = self.host orelse return;
            const Context = struct {
                fn run(_: *@This(), _: []const u8) !void {}
            };
            const menu = try context_menus.Menu.init(self.allocator, Context{}, Context.run);
            errdefer menu.deinit();
            try menu.appendMenuActions(host.menus, actions.menu_ids.EditorTitle, self.context(), !hit.include_navigation);
            try service.showContextMenu(menu, anchor);
            return;
        }
        for (self.primaryActions()) |action| {
            if (!std.mem.eql(u8, action.id(), hit.id)) continue;
            if (action.enabled()) try action.execute(null);
            return;
        }
    }
};
