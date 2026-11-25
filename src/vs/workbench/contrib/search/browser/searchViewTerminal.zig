// Terminal Search view: the TUI adapter over the portable controller in
// `src/vs/workbench/contrib/search/browser/searchView.zig`.
//
// The query lifecycle, messages, focus state, data source, ordering and action
// helpers live under `src/vs/workbench/contrib/search` and
// `src/vs/workbench/services/search`. This file owns terminal layout, focus,
// flattened row painting, mouse handling and the workbench callbacks that open
// editors or apply replacement edits.
//
// Terminal adaptations:
// - the result tree is flattened into one windowed column instead of a
//   virtualized DOM tree;
// - the input rows are a small `ui.Surface` built by `contrib/search/browser/searchWidget.zig`;
// - folder compression, multi-selection, context menus and drag/drop are not
//   ported;
// - opening a match is explicit (Enter/click) rather than focusing a browser
//   tree row.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const IndentGuides = @import("../../../../base/browser/ui/tree/abstractTree.zig").RenderIndentGuides;
const search_editor = @import("../../searchEditor/browser/searchEditorSerialization.zig");
const search_editor_view = @import("../../searchEditor/browser/searchEditor.zig");
const theme_colors_mod = @import("../../../browser/themeColors.zig");
const keybinding_service = @import("../../../services/keybinding/browser/keybindingService.zig");
const resolved_keybinding_item = @import("../../../../platform/keybinding/common/resolvedKeybindingItem.zig");
const key_codes = @import("../../../../base/common/keyCodes.zig");
const keybinding_registry = @import("../../../../platform/keybinding/common/keybindingsRegistry.zig");
const search = @import("../../../services/search/common/search.zig");
const search_model = @import("./searchTreeModel/searchModel.zig");
const SearchModel = search_model.SearchModel;
const controller_mod = @import("./searchView.zig");
const Controller = controller_mod.SearchView;
const ControllerField = controller_mod.Field;
const ControllerOption = controller_mod.Option;
const results_view = @import("./searchResultsView.zig");
const top_bar = @import("./searchActionsTopBar.zig");
const actions_base = @import("./searchActionsBase.zig");
const remove_replace = @import("./searchActionsRemoveReplace.zig");
const configuration_mod = @import("../../../services/configuration/browser/configurationService.zig");
const ConfigurationService = configuration_mod.ConfigurationService;
const ActivityService = @import("../../../services/activity/browser/activityService.zig").ActivityService;
const tree = @import("./searchTreeModel/searchTreeCommon.zig");
const SearchResult = tree.SearchResult;
const FileMatch = tree.FileMatch;
const FolderMatch = tree.FolderMatch;
const Match = tree.Match;
const ChangeEvent = tree.ChangeEvent;
const replace_service = @import("./replaceService.zig");
const Edit = replace_service.Edit;
const css = @import("media/searchview_css.zig");
const file_icon = @import("../../../services/themes/browser/fileIconThemeData.zig");
const widget_mod = @import("./searchWidget.zig");
const SearchWidget = widget_mod.SearchWidget;
const Field = widget_mod.Field;
const Option = widget_mod.Option;
const Range = @import("../../../../editor/common/core/range.zig").Range;
const workspace_context = @import("../../../services/workspaces/common/workspaceContextService.zig");
const WorkspaceContextService = workspace_context.WorkspaceContextService;

const base_background = ui.Color{ .r = 30, .g = 30, .b = 33 };
const base_foreground = ui.Color{ .r = 210, .g = 210, .b = 210 };
const base_dim = ui.Color{ .r = 135, .g = 135, .b = 142 };
const base_header_background = ui.Color{ .r = 38, .g = 38, .b = 42 };
const base_selected_background = ui.Color{ .r = 55, .g = 65, .b = 80 };

const base_match_background = ui.Color{ .r = 88, .g = 71, .b = 47 };
const base_replace_background = ui.Color{ .r = 50, .g = 79, .b = 49 };
const base_removed_background = ui.Color{ .r = 92, .g = 50, .b = 52 };
const base_badge_background = ui.Color{ .r = 74, .g = 74, .b = 80 };
const base_hover_background = ui.Color{ .r = 42, .g = 42, .b = 46 };
const base_scrollbar_track_color = ui.Color{ .r = 30, .g = 32, .b = 40 };
const base_scrollbar_thumb_color = ui.Color{ .r = 105, .g = 108, .b = 122 };

pub const Action = enum { unhandled, handled, focus_editor };

/// Workbench integration points. The search view does not import the
/// workbench; the terminal shell implements these callbacks.
pub const Host = struct {
    context: *anyopaque,
    open_results: *const fn (context: *anyopaque, config: search_editor_view.Config, snapshot: search_editor.Snapshot) anyerror!void,
    open_match: *const fn (context: *anyopaque, path: []const u8, range: ?Range) anyerror!void,
    highlight_range: *const fn (context: *anyopaque, path: []const u8, range: ?Range) void,
    read_file: *const fn (context: *anyopaque, allocator: Allocator, path: []const u8) anyerror!?[]u8,
    extra_files: *const fn (context: *anyopaque, allocator: Allocator) anyerror![][]u8,
    free_paths: *const fn (context: *anyopaque, allocator: Allocator, paths: [][]u8) void,
    apply_edits: *const fn (context: *anyopaque, path: []const u8, edits: []const Edit) anyerror!void,
    save_file: *const fn (context: *anyopaque, path: []const u8) anyerror!void,
    active_selection_text: *const fn (context: *anyopaque, allocator: Allocator) anyerror!?[]u8,
    confirm_replace_all: *const fn (context: *anyopaque, message: []const u8) anyerror!void,
};

pub const Row = tree.Node;

/// Collapse state keyed by a node id. The ids are owned copies because search
/// nodes (and therefore their id slices) are freed and recreated whenever a
/// query restarts; storing borrowed ids would leave dangling keys while the
/// user types.
const OwnedStringSet = struct {
    allocator: Allocator,
    map: std.StringHashMap(void),

    fn init(allocator: Allocator) OwnedStringSet {
        return .{ .allocator = allocator, .map = std.StringHashMap(void).init(allocator) };
    }

    fn deinit(self: *OwnedStringSet) void {
        self.clear();
        self.map.deinit();
    }

    fn contains(self: *const OwnedStringSet, key: []const u8) bool {
        return self.map.contains(key);
    }

    fn put(self: *OwnedStringSet, key: []const u8) void {
        if (self.map.contains(key)) return;
        const copy = self.allocator.dupe(u8, key) catch return;
        self.map.put(copy, {}) catch self.allocator.free(copy);
    }

    fn remove(self: *OwnedStringSet, key: []const u8) bool {
        if (self.map.fetchRemove(key)) |entry| {
            self.allocator.free(entry.key);
            return true;
        }
        return false;
    }

    fn clear(self: *OwnedStringSet) void {
        var iterator = self.map.keyIterator();
        while (iterator.next()) |key| self.allocator.free(key.*);
        self.map.clearRetainingCapacity();
    }
};

/// Terminal view options. The side bar part owns the title area, so the
/// workbench renders the content without the view's own section header.
pub const RenderOptions = struct {
    show_header: bool = true,
    cell_borders: bool = false,
    border_capabilities: ui.cell_border.Capabilities = .{},
};

const PaneCompositePart = @import("../../../browser/parts/paneCompositePart.zig").PaneCompositePart;
const SearchCommandIds = @import("../common/constants.zig").SearchCommandIds;

const list_service = @import("../../../../platform/list/browser/listService.zig");

pub const SearchView = struct {
    pub const ID = @import("../../../services/search/common/search.zig").VIEW_ID;
    allocator: Allocator,
    workspace: *WorkspaceContextService,
    configuration: *ConfigurationService,
    configuration_listener: ?usize = null,
    title_pane: ?*PaneCompositePart = null,
    title_listener: ?@import("../../../../base/common/event.zig").SignalSubscription = null,
    host: Host,
    controller: *Controller,
    model: *SearchModel,
    widget: *SearchWidget,
    rows: std.array_list.Managed(Row),
    depths: std.array_list.Managed(usize),
    collapsed: OwnedStringSet,
    collapse_seen: OwnedStringSet,
    selected: usize = 0,
    hovered_row: ?usize = null,
    results_hovered: bool = false,
    results_y: usize = 0,
    open_in_editor_rect: ui.Rect = .{},
    open_in_editor_hovered: bool = false,
    scroll: usize = 0,
    visible_rows: usize = 0,
    scrollbar_drag: bool = false,
    last_rect: ui.Rect = .{},
    /// Rows above the search widget: one while the view paints its own
    /// section header, zero when the side bar part paints the title.
    header_rows: usize = 1,
    focus_field: Field = .search,
    results_focused: bool = false,
    list_focus: list_service.ListFocus,
    on_did_change_focus: @import("../../../../base/common/event.zig").Emitter(void),
    panel_focused: bool = false,
    started_once: bool = false,
    replace_confirmation: ?controller_mod.ReplaceAllRequest = null,
    keybindings: ?*keybinding_service.KeybindingService = null,
    theme: ?*const theme_colors_mod.ThemeColors = null,
    keybinding_removals: []const *const resolved_keybinding_item.ResolvedKeybindingItem = &.{},
    pending_action: ?Action = null,
    activity_service: ?*ActivityService = null,
    activity_listener: ?usize = null,
    badge_buf: [32]u8 = undefined,

    pub fn init(
        allocator: Allocator,
        workspace: *WorkspaceContextService,
        configuration: *ConfigurationService,
        service: search.ISearchService,
        host: Host,
    ) !*SearchView {
        const self = try allocator.create(SearchView);
        errdefer allocator.destroy(self);
        const widget = try SearchWidget.init(allocator);
        errdefer widget.deinit();
        self.* = .{
            .allocator = allocator,
            .on_did_change_focus = .init(allocator),
            .list_focus = .init(allocator),
            .workspace = workspace,
            .configuration = configuration,
            .host = host,
            .controller = undefined,
            .model = undefined,
            .widget = widget,
            .rows = std.array_list.Managed(Row).init(allocator),
            .depths = std.array_list.Managed(usize).init(allocator),
            .collapsed = OwnedStringSet.init(allocator),
            .collapse_seen = OwnedStringSet.init(allocator),
        };

        errdefer self.on_did_change_focus.deinit();
        errdefer self.list_focus.deinit();
        const controller = try Controller.init(
            allocator,
            workspace,
            configuration,
            service,
            .{
                .context = self,
                .open_match = hostOpenMatch,
                .highlight_range = hostHighlightRange,
                .apply_edits = hostApplyEdits,
                .save_file = hostSaveFile,
                .active_selection_text = hostActiveSelectionText,
                .extra_files = hostExtraFiles,
                .free_paths = hostFreePaths,
            },
            .{
                .context = self,
                .value = widgetValue,
                .set_value = widgetSetValue,
                .clear = widgetClear,
                .option = widgetOption,
                .set_option = widgetSetOption,
                .replace_visible = widgetReplaceVisible,
                .set_replace_visible = widgetSetReplaceVisible,
                .details_visible = widgetDetailsVisible,
                .set_details_visible = widgetSetDetailsVisible,
                .use_excludes = widgetUseExcludes,
                .focus = widgetFocus,
                .cycle_focus = widgetCycleFocus,
            },
            viewerInterface(self),
        );
        errdefer controller.deinit();
        self.controller = controller;
        self.model = controller.searchModel();

        widget.callbacks = .{
            .context = self,
            .on_change = onWidgetChange,
            .on_submit = onWidgetSubmit,
            .on_escape = onWidgetEscape,
            .on_toggle = onWidgetToggle,
            .on_toggle_replace = onWidgetToggleReplace,
            .on_toggle_details = onWidgetToggleDetails,
            .on_use_excludes = onWidgetUseExcludes,
            .on_replace_all = onWidgetReplaceAll,
        };
        try self.setWidgetValueFromSelection();
        try self.attachConfiguration(configuration);
        return self;
    }

    pub fn deinit(self: *SearchView) void {
        if (self.title_listener) |listener| listener.dispose();
        self.list_focus.deinit();
        self.detachConfiguration();
        self.detachActivity();
        self.clearHighlight();
        self.clearReplaceConfirmation();
        self.controller.deinit();
        self.widget.deinit();
        self.rows.deinit();
        self.depths.deinit();
        self.collapsed.deinit();
        self.collapse_seen.deinit();
        if (self.keybindings) |service| service.deinit();
        self.on_did_change_focus.deinit();
        self.allocator.destroy(self);
    }

    /// Terminal-specific result-count badge. Its input follows the original
    /// SearchResult event, not the workbench paint loop.
    pub fn attachActivity(self: *SearchView, service: *ActivityService) !void {
        self.detachActivity();
        self.activity_listener = try self.model.result.on_change.listen(self, onResultActivityChanged);
        self.activity_service = service;
        try self.updateActivity();
    }

    pub fn detachActivity(self: *SearchView) void {
        if (self.activity_listener) |id| self.model.result.on_change.unlisten(id);
        self.activity_listener = null;
        if (self.activity_service) |service| service.removeActivity("search", "search.results");
        self.activity_service = null;
    }

    fn onResultActivityChanged(_: ChangeEvent, self: *SearchView) !void {
        try self.updateActivity();
    }

    fn updateActivity(self: *SearchView) !void {
        const service = self.activity_service orelse return;
        const count = self.model.result.count();
        if (count == 0) {
            service.removeActivity("search", "search.results");
            return;
        }
        const text = try std.fmt.bufPrint(&self.badge_buf, "{d}", .{count});
        try service.setViewContainerActivity("search", .{
            .id = "search.results",
            .badge = .{ .description = text },
        });
    }

    /// Number of current search matches, used as the activity-bar badge
    /// source while a search is populated.
    pub fn matchCount(self: *const SearchView) usize {
        return self.controller.matchCount();
    }

    pub fn focus(self: *SearchView) void {
        self.panel_focused = true;
        self.setResultsFocused(false);
        self.focus_field = .search;
        self.widget.focusField(.search);
        self.widget.focused = true;
        self.controller.setPanelFocused(true);
        self.controller.focus = .search;
        self.controller.last_focus_input = true;
    }

    fn setResultsFocused(self: *SearchView, focused: bool) void {
        if (self.results_focused == focused) return;
        self.results_focused = focused;
        self.list_focus.setFocused(focused);
        self.on_did_change_focus.fire({}) catch {};
    }

    pub fn focusReplace(self: *SearchView) void {
        self.panel_focused = true;
        self.setResultsFocused(false);
        self.setReplaceVisible(true);
        self.widget.focusField(.replace);
        self.widget.focused = true;
        self.focus_field = .replace;
        self.controller.setPanelFocused(true);
        self.controller.focus = .replace;
        self.controller.last_focus_input = true;
    }

    pub fn seedFromSelection(self: *SearchView) !void {
        try self.setWidgetValueFromSelection();
    }

    pub fn blur(self: *SearchView) void {
        self.panel_focused = false;
        self.setResultsFocused(false);
        self.widget.focused = false;
        self.controller.setPanelFocused(false);
    }

    pub fn registerList(self: *SearchView, service: *list_service.ListService) !void {
        try service.register(.{ .context = self, .focus = &self.list_focus, .run = runListCommand });
    }

    fn runListCommand(context: *anyopaque, operation: list_service.Navigation) !void {
        const self: *SearchView = @ptrCast(@alignCast(context));
        self.focusResults();
        var event = ui.KeyEvent{ .key = operation.key() };
        _ = self.handleKey(&event);
    }

    pub fn focusResults(self: *SearchView) void {
        self.panel_focused = true;
        self.setResultsFocused(true);
        self.widget.focused = false;
        self.controller.setPanelFocused(true);
        self.controller.focus = .results;
        self.controller.last_focus_input = false;
    }

    pub fn isFocused(self: *const SearchView) bool {
        return self.panel_focused;
    }

    pub fn isSearchPending(self: *const SearchView) bool {
        return self.controller.isSearchPending();
    }

    pub fn dispatchSearch(context: *anyopaque, now: i64, progress: bool) bool {
        const self: *SearchView = @ptrCast(@alignCast(context));
        const changed = self.controller.dispatch(now, progress) catch false;
        if (changed) self.rebuildRows();
        return changed;
    }

    fn setWidgetValueFromSelection(self: *SearchView) !void {
        if (self.host.active_selection_text(self.host.context, self.allocator) catch null) |text| {
            defer self.allocator.free(text);
            if (text.len > 0) try self.widget.setValue(.search, text);
        }
    }

    fn onWidgetChange(context: ?*anyopaque, field: Field, value: []const u8) void {
        _ = value;
        const self: *SearchView = @ptrCast(@alignCast(context orelse return));
        if (field == .search) self.setReplaceAllActionState(false);
        defer self.updateTitleActions();
        self.controller.onQueryInputChanged(controllerField(field));
    }

    fn onWidgetSubmit(context: ?*anyopaque, field: Field) void {
        const self: *SearchView = @ptrCast(@alignCast(context orelse return));
        switch (field) {
            .search, .includes, .excludes => self.controller.submitQuery() catch {},
            .replace => {
                self.controller.debounce_at = null;
                self.controller.triggerQueryChange(true, false) catch {};
            },
        }
    }

    fn onWidgetEscape(context: ?*anyopaque, field: Field) void {
        _ = field;
        const self: *SearchView = @ptrCast(@alignCast(context orelse return));
        if (self.widget.replace_visible and self.focus_field == .replace and self.widget.focus_control == null) {
            self.setReplaceVisible(!self.widget.replace_visible);
            self.focus_field = .search;
            self.setControllerFocusFromField();
            return;
        }
        self.panel_focused = false;
        self.controller.setPanelFocused(false);
    }

    fn onWidgetToggle(context: ?*anyopaque, option: Option) void {
        const self: *SearchView = @ptrCast(@alignCast(context orelse return));
        self.toggleOption(option);
    }

    fn onWidgetToggleReplace(context: *anyopaque) void {
        const self: *SearchView = @ptrCast(@alignCast(context));
        self.setReplaceVisible(!self.widget.replace_visible);
    }

    fn onWidgetToggleDetails(context: *anyopaque) void {
        const self: *SearchView = @ptrCast(@alignCast(context));
        self.commandToggleDetails();
    }

    fn onWidgetUseExcludes(context: *anyopaque) void {
        const self: *SearchView = @ptrCast(@alignCast(context));
        self.controller.debounce_at = null;
        self.controller.triggerQueryChange(true, false) catch {};
    }

    fn setReplaceVisible(self: *SearchView, visible: bool) void {
        self.widget.setReplaceVisible(visible);
        self.updateReplaceAllActionState();
    }

    fn updateReplaceAllActionState(self: *SearchView) void {
        const query = self.model.query orelse return self.setReplaceAllActionState(false);
        self.setReplaceAllActionState(self.model.result.count() > 0 and self.model.replacePattern() != null and
            std.mem.eql(u8, query.pattern, std.mem.trim(u8, self.widget.value(.search), " \t\r\n")));
    }

    fn setReplaceAllActionState(self: *SearchView, enabled: bool) void {
        self.widget.replace_all_enabled = enabled;
        self.model.replace_active = self.widget.replace_visible and enabled;
    }

    fn onWidgetReplaceAll(context: ?*anyopaque) void {
        const self: *SearchView = @ptrCast(@alignCast(context orelse return));
        self.commandReplaceAll();
    }

    fn ensureKeybindings(self: *SearchView) !void {
        if (self.keybindings != null) return;
        const service = try keybinding_service.KeybindingService.initWithOptions(self.allocator, .{
            .rules = &search_keybinding_rules,
            .executor = .{ .context = self, .execute = executeSearchCommand },
            .overrides = self.keybinding_removals,
        });
        self.keybindings = service;
    }

    /// Rebuilds the search shortcut host after the user keymap changed. The
    /// removals stay borrowed from the workbench's keymap owner.
    pub fn reloadKeybindings(
        self: *SearchView,
        overrides: []const *const resolved_keybinding_item.ResolvedKeybindingItem,
    ) void {
        if (self.keybindings) |service| {
            service.deinit();
            self.keybindings = null;
        }
        self.keybinding_removals = overrides;
    }

    fn executeSearchCommand(context: *anyopaque, command: []const u8) anyerror!void {
        const self: *SearchView = @ptrCast(@alignCast(context));
        self.pending_action = self.runSearchCommand(command);
    }

    fn runSearchCommand(self: *SearchView, command: []const u8) ?Action {
        if (std.mem.eql(u8, command, "search.action.toggleReplace")) {
            self.setReplaceVisible(!self.widget.replace_visible);
            self.focus_field = if (self.widget.replace_visible) .replace else .search;
            self.widget.focusField(self.focus_field);
            self.setControllerFocusFromField();
            return .handled;
        }
        if (std.mem.eql(u8, command, "search.action.toggleCaseSensitive")) {
            self.toggleOption(.match_case);
            return .handled;
        }
        if (std.mem.eql(u8, command, "search.action.toggleWholeWord")) {
            self.toggleOption(.whole_word);
            return .handled;
        }
        if (std.mem.eql(u8, command, "search.action.toggleRegex")) {
            self.toggleOption(.regex);
            return .handled;
        }
        if (std.mem.eql(u8, command, "search.action.togglePreserveCase")) {
            self.toggleOption(.preserve_case);
            return .handled;
        }
        if (std.mem.eql(u8, command, "workbench.action.search.toggleQueryDetails")) {
            self.commandToggleDetails();
            return .handled;
        }
        if (std.mem.eql(u8, command, "search.action.replace")) {
            if (self.results_focused and self.model.isReplaceActive()) {
                self.replaceSelected();
            } else {
                self.openInEditor() catch self.controller.reportOpenInEditorError();
            }
            return .handled;
        }
        if (std.mem.eql(u8, command, "search.action.replaceAll")) {
            self.commandReplaceAll();
            return .handled;
        }
        return null;
    }

    fn toggleOption(self: *SearchView, option: Option) void {
        self.controller.toggleOption(controllerOption(option)) catch {};
    }

    pub fn startSearch(self: *SearchView) !void {
        self.clearReplaceConfirmation();
        // Enter submits the current value; it must cancel a pending
        // search-on-type debounce instead of letting it start a second query.
        self.controller.debounce_at = null;
        try self.controller.triggerQueryChange(false, false);
        self.rebuildRows();
    }

    pub fn setWorkspace(self: *SearchView, workspace: *WorkspaceContextService) void {
        self.workspace = workspace;
        self.controller.workspace = workspace;
    }

    pub fn attachConfiguration(self: *SearchView, service: *ConfigurationService) !void {
        self.detachConfiguration();
        self.configuration = service;
        self.controller.configuration = service;
        self.configuration_listener = try service.listenConfigurationChange(self, onConfigurationChanged);
        self.controller.onConfigurationChanged();
        self.rebuildRows();
    }

    pub fn detachConfiguration(self: *SearchView) void {
        if (self.configuration_listener) |id| self.configuration.unlistenConfigurationChange(id);
        self.configuration_listener = null;
    }

    fn onConfigurationChanged(change: configuration_mod.Change, self: *SearchView) !void {
        const config = @import("../../../../platform/configuration/common/configuration.zig");
        if (config.affectsConfiguration(change, "search") or
            config.affectsConfiguration(change, "files.exclude") or
            config.affectsConfiguration(change, "files.encoding"))
        {
            self.controller.onConfigurationChanged();
        } else if (config.affectsConfiguration(change, "workbench.tree")) {
            self.rebuildRows();
        }
    }

    fn clearHighlight(self: *SearchView) void {
        self.host.highlight_range(self.host.context, "", null);
    }

    fn setControllerFocusFromField(self: *SearchView) void {
        self.widget.focus_field = self.focus_field;
        self.controller.focus = switch (self.focus_field) {
            .search => .search,
            .replace => .replace,
            .includes => .includes,
            .excludes => .excludes,
        };
        self.controller.setPanelFocused(true);
        self.controller.last_focus_input = true;
    }

    fn syncFieldFromController(self: *SearchView) void {
        self.focus_field = switch (self.controller.focus) {
            .search => .search,
            .replace => .replace,
            .includes => .includes,
            .excludes => .excludes,
            .results => .search,
        };
        self.widget.focusField(self.focus_field);
        self.setResultsFocused(self.controller.focus == .results);
        if (self.results_focused) {
            self.panel_focused = true;
        }
    }

    fn selectedRow(self: *const SearchView) ?Row {
        if (self.selected >= self.rows.items.len) return null;
        return self.rows.items[self.selected];
    }

    fn rowId(row: Row) []const u8 {
        return row.id();
    }

    fn rowExpanded(self: *const SearchView, row: Row) bool {
        return !self.collapsed.contains(rowId(row));
    }

    fn toggleRow(self: *SearchView, row: Row) void {
        const id = rowId(row);
        if (self.collapsed.contains(id)) {
            _ = self.collapsed.remove(id);
        } else {
            self.collapsed.put(id);
        }
        self.rebuildRows();
    }

    pub fn attachTitleActions(self: *SearchView, pane: *PaneCompositePart) !void {
        if (self.title_listener) |listener| listener.dispose();
        self.title_listener = null;
        self.title_pane = pane;
        self.title_listener = try pane.on_did_pane_composite_open.listenSignal(self, onCompositeOpened);
        self.updateTitleActions();
    }

    fn onCompositeOpened(self: *SearchView) !void {
        self.updateTitleActions();
    }

    /// The Search view owns its title toolbar state. Input and result/tree
    /// events call this handler; rendering never recomputes command state.
    pub fn updateTitleActions(self: *SearchView) void {
        const pane = self.title_pane orelse return;
        if (!std.mem.eql(u8, pane.active_id orelse "", "search")) return;
        const tree_mode = self.controller.viewMode() == .tree;
        const expanded = self.hasExpandedResults();
        const has_results = self.matchCount() != 0;
        pane.setTitleActions(&.{
            .{ .id = SearchCommandIds.refresh_search_results, .label = "Refresh", .glyph = '↻', .enabled = self.widget.value(.search).len != 0 },
            .{ .id = SearchCommandIds.clear_search_results, .label = "Clear Search Results", .glyph = '×', .enabled = has_results },
            // Codicon.listFlat/listTree fit one terminal cell.
            if (tree_mode)
                .{ .id = SearchCommandIds.view_as_list, .label = "View as List", .glyph = 0xeb84 }
            else
                .{ .id = SearchCommandIds.view_as_tree, .label = "View as Tree", .glyph = 0xeb86 },
            if (expanded or !has_results)
                .{ .id = SearchCommandIds.collapse_search_results, .label = "Collapse All", .glyph = '⊟', .enabled = has_results }
            else
                .{ .id = SearchCommandIds.expand_search_results, .label = "Expand All", .glyph = '⊞' },
        }, &.{}) catch {};
    }

    fn rebuildRows(self: *SearchView) void {
        defer self.updateTitleActions();
        self.updateReplaceAllActionState();
        self.rows.clearRetainingCapacity();
        self.depths.clearRetainingCapacity();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const data_source = results_view.SearchViewDataSource.init(self.model.result, .{
            .mode = self.controller.viewMode(),
            .sort_order = self.controller.sortOrder(),
            .show_line_numbers = self.controller.showLineNumbers(),
        });
        const visible = data_source.visibleRows(arena.allocator(), .{
            .context = self,
            .is_collapsed = viewerIsCollapsed,
            .on_visit = visitCollapseNode,
        }) catch return;
        for (visible) |row| {
            self.rows.append(row.node) catch return;
            self.depths.append(row.depth) catch return;
        }
        self.clampSelection();
        self.ensureSelectionVisible();
    }

    fn visitCollapseNode(context: *anyopaque, node: Row) void {
        const self: *SearchView = @ptrCast(@alignCast(context));
        _ = self.applyDefaultCollapse(node);
    }

    /// Applies `search.collapseResults` the first time a node is seen. Later
    /// rebuilds preserve the user's explicit collapse state.
    fn applyDefaultCollapse(self: *SearchView, node: Row) bool {
        const id = rowId(node);
        if (self.collapse_seen.contains(id)) return self.collapsed.contains(id);
        self.collapse_seen.put(id);
        const collapse = switch (node) {
            .match => false,
            else => blk: {
                const value = self.configuration.getValue("search.collapseResults", .{}) orelse
                    break :blk false;
                const setting = switch (value.*) {
                    .string => |text| text,
                    else => "alwaysExpand",
                };
                if (std.mem.eql(u8, setting, "alwaysCollapse")) break :blk true;
                if (std.mem.eql(u8, setting, "auto")) {
                    const count = switch (node) {
                        .folder => |folder| folder.recursiveMatchCount(),
                        .file => |file| file.count(),
                        else => 0,
                    };
                    break :blk count > 10;
                }
                break :blk false;
            },
        };
        if (collapse) self.collapsed.put(id);
        return collapse;
    }

    fn clampSelection(self: *SearchView) void {
        if (self.rows.items.len == 0) {
            self.selected = 0;
            self.scroll = 0;
        } else if (self.selected >= self.rows.items.len) {
            self.selected = self.rows.items.len - 1;
        }
    }

    fn selectRow(self: *SearchView, index: usize) void {
        if (index >= self.rows.items.len) return;
        self.selected = index;
        self.ensureSelectionVisible();
        self.highlightSelected();
    }

    fn maxScroll(self: *const SearchView) usize {
        return self.rows.items.len -| self.visible_rows;
    }

    fn clampScroll(self: *SearchView) void {
        self.scroll = @min(self.scroll, self.maxScroll());
    }

    fn ensureSelectionVisible(self: *SearchView) void {
        if (self.visible_rows == 0) return;
        if (self.selected < self.scroll) {
            self.scroll = self.selected;
        } else if (self.selected >= self.scroll + self.visible_rows) {
            self.scroll = self.selected - self.visible_rows + 1;
        }
        self.clampScroll();
    }

    fn highlightSelected(self: *SearchView) void {
        const row = self.selectedRow() orelse {
            self.clearHighlight();
            return;
        };
        switch (row) {
            .match => |match| self.host.highlight_range(self.host.context, match.parent_file.path, match.range()),
            else => self.clearHighlight(),
        }
    }

    fn activateSelected(self: *SearchView) void {
        const row = self.selectedRow() orelse return;
        switch (row) {
            .heading => self.toggleRow(row),
            .folder => self.toggleRow(row),
            .file => self.toggleRow(row),
            .match => {
                self.controller.openElement(row, false) catch {};
                self.panel_focused = false;
            },
        }
    }

    fn moveSelection(self: *SearchView, delta: isize) void {
        if (self.rows.items.len == 0) return;
        const count: isize = @intCast(self.rows.items.len);
        const next = @mod(@as(isize, @intCast(self.selected)) + delta, count);
        self.selectRow(@intCast(next));
    }

    fn moveToNextMatch(self: *SearchView, direction: isize) void {
        if (self.rows.items.len == 0) return;
        var index = self.selected;
        var guard: usize = 0;
        while (guard < self.rows.items.len) : (guard += 1) {
            if (direction > 0) {
                index = (index + 1) % self.rows.items.len;
            } else {
                index = (index + self.rows.items.len - 1) % self.rows.items.len;
            }
            switch (self.rows.items[index]) {
                .match => {
                    self.selectRow(index);
                    return;
                },
                else => {},
            }
        }
    }

    fn dismissSelected(self: *SearchView) void {
        const row = self.selectedRow() orelse return;
        remove_replace.removeElement(
            self.allocator,
            viewerInterface(self),
            self.model.result,
            row,
        ) catch {};
        self.rebuildRows();
    }

    fn replaceSelected(self: *SearchView) void {
        if (!self.model.isReplaceActive()) return;
        const row = self.selectedRow() orelse return;
        self.controller.replaceElement(row) catch {
            self.controller.reportReplaceError();
            self.rebuildRows();
            return;
        };
        // VS Code recomputes matches after a line replacement. Refresh via the
        // workspace provider here, which also handles closed files and matches
        // spanning multiple lines.
        if (row == .match) self.controller.triggerQueryChange(true, false) catch self.controller.reportReplaceError();
        self.rebuildRows();
    }

    pub fn clearReplaceConfirmation(self: *SearchView) void {
        const request = self.replace_confirmation orelse return;
        self.allocator.free(request.confirmation);
        self.allocator.free(request.after);
        self.replace_confirmation = null;
    }

    pub fn confirmReplaceAll(self: *SearchView) void {
        const request = self.replace_confirmation orelse return;
        const current = request.occurrences == self.model.result.count() and request.file_count == self.model.result.fileCount();
        self.clearReplaceConfirmation();
        if (!current) {
            self.commandReplaceAll();
            return;
        }
        self.controller.executeReplaceAll() catch self.controller.reportReplaceError();
        self.rebuildRows();
    }

    pub fn handleKey(self: *SearchView, event: *const ui.KeyEvent) Action {
        if (event.mods.ctrl or event.mods.alt) {
            self.ensureKeybindings() catch {};
            if (self.keybindings) |service| {
                self.pending_action = null;
                if (service.dispatch(event.*)) {
                    if (self.pending_action) |action| return action;
                    return .handled;
                }
            }
        }

        if (event.key == .escape) {
            if (self.widget.replace_visible and self.focus_field == .replace and self.widget.focus_control == null) {
                self.setReplaceVisible(!self.widget.replace_visible);
                self.focus_field = .search;
                self.setControllerFocusFromField();
                return .handled;
            }
            if (self.controller.stateValue() != .idle) {
                _ = self.controller.cancelSearch();
                self.rebuildRows();
                return .handled;
            }
            self.panel_focused = false;
            self.controller.setPanelFocused(false);
            self.clearHighlight();
            return .focus_editor;
        }

        if (event.key == .tab or event.key == .backtab) {
            self.setResultsFocused(false);
            _ = self.widget.cycleFocus(event.key == .backtab);
            self.focus_field = self.widget.focus_field;
            self.setControllerFocusFromField();
            return .handled;
        }

        if (event.mods.ctrl and !event.mods.alt and (event.key == .down or event.key == .up)) {
            if (event.key == .down) {
                self.controller.focusNextInputBox();
            } else {
                self.controller.focusPreviousInputBox();
            }
            self.syncFieldFromController();
            return .handled;
        }

        if (event.mods.ctrl and !event.mods.alt) {
            if (event.key == .char) {
                const ch = event.key.char;
                if (ch == 'r' or ch == 'R') {
                    self.setReplaceVisible(!self.widget.replace_visible);
                    self.focus_field = if (self.widget.replace_visible) .replace else .search;
                    self.widget.focusField(self.focus_field);
                    self.setControllerFocusFromField();
                    return .handled;
                }
            }
        }
        if (event.mods.alt and !event.mods.ctrl and event.key == .char) {
            switch (event.key.char) {
                'c', 'C' => {
                    self.toggleOption(.match_case);
                    return .handled;
                },
                'w', 'W' => {
                    self.toggleOption(.whole_word);
                    return .handled;
                },
                'r', 'R' => {
                    self.toggleOption(.regex);
                    return .handled;
                },
                'p', 'P' => {
                    self.toggleOption(.preserve_case);
                    return .handled;
                },
                'd', 'D' => {
                    self.commandToggleDetails();
                    return .handled;
                },
                else => {},
            }
        }

        if (event.mods.alt and event.key == .enter and !event.mods.ctrl) {
            if (self.results_focused and self.model.isReplaceActive()) {
                self.replaceSelected();
            } else {
                self.openInEditor() catch self.controller.reportOpenInEditorError();
            }
            return .handled;
        }
        if (event.mods.alt and event.mods.ctrl and event.key == .enter) {
            self.commandReplaceAll();
            return .handled;
        }

        if (self.results_focused) {
            switch (event.key) {
                .up => {
                    if (event.mods.alt) self.moveToNextMatch(-1) else self.moveSelection(-1);
                    return .handled;
                },
                .down => {
                    if (event.mods.alt) self.moveToNextMatch(1) else self.moveSelection(1);
                    return .handled;
                },
                .left => {
                    const row = self.selectedRow() orelse return .handled;
                    switch (row) {
                        .folder, .file, .heading => self.toggleRow(row),
                        .match => {},
                    }
                    return .handled;
                },
                .right => {
                    const row = self.selectedRow() orelse return .handled;
                    switch (row) {
                        .folder, .file, .heading => self.toggleRow(row),
                        .match => {},
                    }
                    return .handled;
                },
                .enter => {
                    self.activateSelected();
                    return .handled;
                },
                .delete => {
                    self.dismissSelected();
                    return .handled;
                },
                .page_up => {
                    self.moveSelection(-10);
                    return .handled;
                },
                .page_down => {
                    self.moveSelection(10);
                    return .handled;
                },
                .home => {
                    self.selectRow(0);
                    return .handled;
                },
                .end => {
                    if (self.rows.items.len > 0) self.selectRow(self.rows.items.len - 1);
                    return .handled;
                },
                else => return .handled,
            }
        }

        var local_event = event.*;
        if (self.widget.handleKey(&local_event)) {
            self.focus_field = self.widget.focus_field;
            return .handled;
        }
        switch (event.key) {
            .down, .up => {
                self.setResultsFocused(true);
                self.moveSelection(if (event.key == .down) 1 else -1);
                return .handled;
            },
            .enter => {
                if (self.focus_field == .search or self.focus_field == .includes or self.focus_field == .excludes) {
                    self.startSearch() catch {};
                    return .handled;
                }
            },
            else => {},
        }
        return .unhandled;
    }

    pub fn handleMouse(self: *SearchView, event: *const ui.MouseEvent) bool {
        const rect = self.last_rect;
        const x0 = ui.cell.snap(rect.x);
        const y0 = ui.cell.snap(rect.y);
        const width = ui.cell.snap(rect.w);
        const height = ui.cell.snap(rect.h);
        if (event.x < x0 or event.x >= x0 + width or event.y < y0 or event.y >= y0 + height) return false;
        const local_x = event.x - x0;
        const local_y = event.y - y0;
        if (self.replace_confirmation != null) return true;
        if (local_y < self.header_rows) return true;

        const input_top = self.header_rows;
        const input_bottom = input_top + self.widget.layout.height;
        self.open_in_editor_hovered = pointInRect(self.open_in_editor_rect, event.x, event.y);
        self.results_hovered = local_y >= self.results_y;
        if (local_y < input_bottom) {
            self.hovered_row = null;
            const activating = (event.kind == .down or event.kind == .click) and event.button != .right and event.button != .middle;
            var local = event.*;
            local.x = local_x;
            local.y = local_y - input_top;
            if (self.widget.handleMouse(local.x, local.y, &local) and activating) {
                self.panel_focused = true;
                self.setResultsFocused(false);
                self.widget.focused = true;
                self.focus_field = self.widget.focus_field;
                self.setControllerFocusFromField();
            }
            return true;
        }

        self.widget.clearHover();
        const results_top = self.results_y;
        if (local_y < results_top) {
            self.hovered_row = null;
            if (self.open_in_editor_hovered and (event.kind == .down or event.kind == .click) and event.button == .left) {
                self.openInEditor() catch self.controller.reportOpenInEditorError();
            }
            return true;
        }
        const has_scrollbar = width > 1 and self.rows.items.len > self.visible_rows and self.visible_rows > 0;
        if (has_scrollbar and local_x == width - 1) {
            switch (event.kind) {
                .down, .click => self.scrollbar_drag = true,
                .up => {
                    self.scrollbar_drag = false;
                    return true;
                },
                .move => if (!self.scrollbar_drag) return true,
                else => {},
            }
            const track_y = local_y - results_top;
            if (track_y < self.visible_rows) {
                const max_scroll = self.maxScroll();
                const thumb_height = @min(
                    self.visible_rows,
                    @max(@as(usize, 1), (self.visible_rows * self.visible_rows) / self.rows.items.len),
                );
                if (self.visible_rows > thumb_height) {
                    self.scroll = @min(
                        max_scroll,
                        (track_y * max_scroll) / (self.visible_rows - thumb_height),
                    );
                }
            }
            return true;
        }
        if (event.kind == .down or event.kind == .click) self.scrollbar_drag = false;
        if (event.kind == .wheel) {
            if (event.delta_y > 0) {
                self.scroll = @min(self.maxScroll(), self.scroll + 3);
            } else if (event.delta_y < 0) {
                self.scroll -|= 3;
            }
            return true;
        }
        const row = local_y - results_top + self.scroll;
        if (row >= self.rows.items.len) {
            self.hovered_row = null;
            return true;
        }
        if (event.kind == .up or event.button == .right or event.button == .middle) return true;
        const action = if (self.showRowActions(row)) self.rowAction(row, local_x, width) else null;
        self.hovered_row = row;
        if (event.kind == .move) return true;
        self.focusResults();
        self.selectRow(row);
        if (event.kind == .click or event.kind == .down) {
            if (action) |value| {
                switch (value) {
                    .replace => self.replaceSelected(),
                    .remove => self.dismissSelected(),
                }
                return true;
            }
            switch (self.rows.items[row]) {
                .folder, .file, .heading => self.toggleRow(self.rows.items[row]),
                .match => self.activateSelected(),
            }
        }
        return true;
    }

    pub fn clearHover(self: *SearchView) void {
        self.hovered_row = null;
        self.results_hovered = false;
        self.open_in_editor_hovered = false;
        self.widget.clearHover();
    }

    pub fn pointerAt(self: *SearchView, x: usize, y: usize) ui.Pointer {
        if (pointInRect(self.open_in_editor_rect, x, y)) return .pointer;
        const local_x = x -| ui.cell.snap(self.last_rect.x);
        const local_y = y -| ui.cell.snap(self.last_rect.y);
        const input_end = self.header_rows + self.widget.layout.height;
        if (local_y >= self.header_rows and local_y < input_end) {
            return self.widget.pointerAt(local_x, local_y - self.header_rows);
        }
        if (self.hovered_row) |row| {
            if (self.rowAction(row, local_x, ui.cell.snap(self.last_rect.w)) != null) return .pointer;
        }
        return .default;
    }

    pub fn setThemeColors(self: *SearchView, palette: ?*const theme_colors_mod.ThemeColors) void {
        self.theme = palette;
    }

    pub fn render(self: *SearchView, grid: *ui.CellGrid, rect: ui.Rect, options: RenderOptions) !void {
        self.last_rect = rect;
        self.open_in_editor_rect = .{};
        const x = ui.cell.snap(rect.x);
        const y = ui.cell.snap(rect.y);
        const width = ui.cell.snap(rect.w);
        const height = ui.cell.snap(rect.h);
        if (width == 0 or height == 0) return;
        var background = base_background;
        var foreground = base_foreground;
        var dim = base_dim;
        var header_background = base_header_background;
        var selected_background = base_selected_background;
        var scrollbar_track_color = base_scrollbar_track_color;
        var scrollbar_thumb_color = base_scrollbar_thumb_color;
        if (self.theme) |palette| {
            background = palette.colorOr("sideBar.background", base_background);
            foreground = palette.colorOr("sideBar.foreground", base_foreground);
            dim = palette.colorOr("descriptionForeground", base_dim);
            header_background = palette.colorOr("sideBarSectionHeader.background", base_header_background);
            selected_background = palette.colorOr("list.activeSelectionBackground", base_selected_background);
            scrollbar_track_color = palette.colorOr("sideBar.background", base_scrollbar_track_color);
            scrollbar_thumb_color = palette.colorOr("scrollbarSlider.background", base_scrollbar_thumb_color);
        }

        const base = ui.cell.PaintStyle{ .fg = ui.cell.packColor(foreground), .bg = ui.cell.packColor(background) };
        grid.fillRect(@floatFromInt(x), @floatFromInt(y), @floatFromInt(width), @floatFromInt(height), base);

        // Upstream the Search view pane container has no section header: the
        // side bar title area shows `SEARCH` and its actions. The header stays
        // for standalone preview/test rendering.
        self.header_rows = if (options.show_header) 1 else 0;
        if (options.show_header) {
            const header_style = ui.cell.PaintStyle{ .fg = ui.cell.packColor(foreground), .bg = ui.cell.packColor(header_background) };
            grid.fillRect(@floatFromInt(x), @floatFromInt(y), @floatFromInt(width), 1, header_style);
            _ = drawText(grid, x + 1, y, width -| 1, if (self.panel_focused) " SEARCH " else " Search ", header_style);
        }

        // The caret belongs to the field only while the view owns input focus;
        // results navigation and leaving the side bar both hide it.
        self.widget.focused = self.panel_focused and !self.results_focused;
        self.widget.cell_borders = options.cell_borders;
        self.widget.colors = resolveWidgetColors(self.theme, background, foreground);
        try self.widget.render(width);
        try grid.blit(self.widget.grid(), x, y + self.header_rows, width, @min(self.widget.layout.height, height -| self.header_rows));
        const status_y = y + self.header_rows + self.widget.layout.height;
        var status_buffer: [240]u8 = undefined;
        var status = self.controller.messageText(&status_buffer);
        if (status.len == 0) {
            if (self.controller.isSearchPending()) {
                status = "Searching...";
            } else if (self.model.result.count() == 0 and self.workspace.getWorkspace().folders.items.len == 0) {
                status = "No workspace folder";
            }
        }
        var is_error = false;
        for (self.controller.messages.items) |message| {
            switch (message.kind) {
                .err => is_error = true,
                else => {},
            }
        }
        const status_style = ui.cell.PaintStyle{
            .fg = ui.cell.packColor(if (is_error) ui.Color{ .r = 240, .g = 120, .b = 120 } else dim),
            .bg = ui.cell.packColor(background),
        };
        var top = status_y + 1;
        const message_width = width -| 2;
        if (status_y < y + height) {
            _ = drawTextEllipsis(grid, x + 1, status_y, message_width, &.{.{ .text = status, .style = status_style }}, status_style);
            if (self.matchCount() > 0 and !is_error and message_width > 0) {
                const link = "Open in editor";
                const status_width = textWidth(status);
                const inline_link = status_width + " - ".len + link.len <= message_width;
                const link_y = status_y + @intFromBool(!inline_link);
                if (link_y < y + height) {
                    var link_x = x + 1;
                    if (inline_link) {
                        link_x += status_width;
                        link_x += drawText(grid, link_x, link_y, " - ".len, " - ", status_style);
                    }
                    const link_style: ui.cell.PaintStyle = .{
                        .fg = ui.cell.packColor(self.color(if (self.open_in_editor_hovered) "textLink.activeForeground" else "textLink.foreground", .{ .r = 83, .g = 168, .b = 215 })),
                        .bg = status_style.bg,
                        .attrs = if (self.open_in_editor_hovered) ui.cell.Attr.underline else 0,
                    };
                    const link_width = @min(link.len, x + width -| 1 -| link_x);
                    _ = drawTextEllipsis(grid, link_x, link_y, link_width, &.{.{ .text = link, .style = link_style }}, link_style);
                    self.open_in_editor_rect = .{
                        .x = @floatFromInt(link_x),
                        .y = @floatFromInt(link_y),
                        .w = @floatFromInt(link_width),
                        .h = 1,
                    };
                    top = link_y + 1;
                }
            }
        }
        self.results_y = top - y;
        const rows = if (top < y + height) y + height - top else 0;
        self.visible_rows = rows;
        self.clampScroll();
        if (rows == 0) return;

        const guide_setting = self.configuration.getValue("workbench.tree.renderIndentGuides", .{});
        const guides = if (guide_setting) |setting| switch (setting.*) {
            .string => |value| IndentGuides.fromString(value),
            else => IndentGuides.on_hover,
        } else IndentGuides.on_hover;
        const show_inactive = guides == .always or (guides == .on_hover and self.results_hovered);
        const active_guide = if (guides != .none and self.results_focused) self.activeGuide() else null;
        const native_center = options.cell_borders and options.border_capabilities.has(.center);

        var visible: usize = 0;
        while (visible < rows) : (visible += 1) {
            const index = self.scroll + visible;
            if (index >= self.rows.items.len) break;
            const row_y = top + visible;
            const selected = self.results_focused and index == self.selected;
            const hovered = index == self.hovered_row;
            const row_bg = if (selected)
                selected_background
            else if (hovered)
                self.color("list.hoverBackground", base_hover_background)
            else
                background;
            const row_fg = if (selected) self.color("list.activeSelectionForeground", foreground) else foreground;
            if (selected or hovered) {
                grid.fillRect(@floatFromInt(x), @floatFromInt(row_y), @floatFromInt(width), 1, .{
                    .fg = ui.cell.packColor(row_fg),
                    .bg = ui.cell.packColor(row_bg),
                });
            }
            const row_width = width - @intFromBool(width > 1 and self.rows.items.len > self.visible_rows);
            self.renderRow(grid, x, row_y, row_width, index, row_fg, row_bg);
            self.renderIndentGuides(grid, x, row_y, row_width, index, row_bg, show_inactive, active_guide, native_center);
        }

        if (width > 1 and self.rows.items.len > self.visible_rows and self.visible_rows > 0) {
            const scrollbar_x = x + width - 1;
            grid.fillRect(@floatFromInt(scrollbar_x), @floatFromInt(top), 1, @floatFromInt(self.visible_rows), .{
                .bg = ui.cell.packColor(scrollbar_track_color),
            });
            const max_scroll = self.maxScroll();
            const thumb_height = @min(
                self.visible_rows,
                @max(@as(usize, 1), (self.visible_rows * self.visible_rows) / self.rows.items.len),
            );
            const thumb_top = if (max_scroll == 0 or self.visible_rows <= thumb_height)
                0
            else
                (self.scroll * (self.visible_rows - thumb_height)) / max_scroll;
            grid.fillRect(@floatFromInt(scrollbar_x), @floatFromInt(top + thumb_top), 1, @floatFromInt(thumb_height), .{
                .bg = ui.cell.packColor(scrollbar_thumb_color),
            });
        }
    }

    const ActiveGuide = struct { depth: usize, first: usize, end: usize };

    fn activeGuide(self: *const SearchView) ?ActiveGuide {
        const row = self.selectedRow() orelse return null;
        var parent = self.selected;
        if (row == .match or !self.rowExpanded(row) or
            parent + 1 >= self.depths.items.len or self.depths.items[parent + 1] <= self.depths.items[parent])
        {
            const depth = self.depths.items[parent];
            if (depth == 0) return null;
            while (parent > 0 and self.depths.items[parent] >= depth) parent -= 1;
        }

        const depth = self.depths.items[parent];
        var end = parent + 1;
        while (end < self.depths.items.len and self.depths.items[end] > depth) : (end += 1) {}
        return .{ .depth = depth, .first = parent + 1, .end = end };
    }

    fn renderIndentGuides(
        self: *const SearchView,
        grid: *ui.CellGrid,
        x: usize,
        y: usize,
        width: usize,
        index: usize,
        bg: ui.Color,
        show_inactive: bool,
        active: ?ActiveGuide,
        native_center: bool,
    ) void {
        for (0..self.depths.items[index]) |level| {
            // The guide belongs to the ancestor's twistie column.
            const col = results_view.indentCells(level);
            if (col >= width) break;
            const is_active = if (active) |guide|
                guide.depth == level and index >= guide.first and index < guide.end
            else
                false;
            if (!show_inactive and !is_active) continue;
            const stroke = if (is_active)
                self.color("tree.indentGuidesStroke", .{ .r = 88, .g = 88, .b = 88 })
            else
                self.color("tree.inactiveIndentGuidesStroke", .{ .r = 57, .g = 57, .b = 57 });
            if (native_center) {
                grid.addBorder(x + col, y, ui.cell_border.Segment.vertical, .{ .width = 16, .color = .{ .rgb = stroke } });
            } else {
                grid.putCodepoint(x + col, y, '│', 1, .{ .fg = ui.cell.packColor(stroke), .bg = ui.cell.packColor(bg) });
            }
        }
    }

    const RowAction = enum { replace, remove };

    fn showRowActions(self: *const SearchView, index: usize) bool {
        return index == self.hovered_row or (self.results_focused and index == self.selected);
    }

    fn rowAction(self: *const SearchView, index: usize, x: usize, width: usize) ?RowAction {
        if (index >= self.rows.items.len or self.rows.items[index] == .heading) return null;
        const row_width = width -| @intFromBool(width > 1 and self.rows.items.len > self.visible_rows);
        const end = row_width -| css.action_bar_padding_right;
        const remove_x = end -| css.action_bar_item_spacing;
        if (x >= remove_x and x < end and end > 0) return .remove;
        const replace_x = remove_x -| css.action_bar_item_spacing;
        if (self.model.isReplaceActive() and x >= replace_x and x < remove_x) return .replace;
        return null;
    }

    fn color(self: *const SearchView, id: []const u8, fallback: ui.Color) ui.Color {
        return if (self.theme) |theme| theme.colorOr(id, fallback) else fallback;
    }

    fn renderRow(
        self: *SearchView,
        grid: *ui.CellGrid,
        x: usize,
        y: usize,
        width: usize,
        index: usize,
        fg: ui.Color,
        bg: ui.Color,
    ) void {
        const row = self.rows.items[index];
        const depth = self.depths.items[index];
        const base = ui.cell.PaintStyle{ .fg = ui.cell.packColor(fg), .bg = ui.cell.packColor(bg) };
        const dim = ui.cell.PaintStyle{
            .fg = ui.cell.packColor(self.color("descriptionForeground", base_dim)),
            .bg = base.bg,
        };
        const data = results_view.rowData(row, .{
            .mode = self.controller.viewMode(),
            .show_line_numbers = self.controller.showLineNumbers(),
        });
        const actions = self.showRowActions(index) and row != .heading;
        const end = if (actions) blk: {
            const right = width -| css.action_bar_padding_right;
            const remove = right -| css.action_bar_item_spacing;
            if (right > 0) _ = drawText(grid, x + remove, y, right - remove, "×", base);
            const replace = remove -| css.action_bar_item_spacing;
            if (self.model.isReplaceActive()) {
                _ = drawText(grid, x + replace, y, remove - replace, if (row == .match) "→" else "⇄", base);
                break :blk x + replace;
            }
            break :blk x + remove;
        } else x + (width -| css.count_badge_margin_right);

        switch (row) {
            .heading => _ = drawText(grid, x + 1, y, end -| (x + 1), data.label, .{ .fg = base.fg, .bg = base.bg, .attrs = ui.cell.Attr.bold }),
            .folder, .file => {
                const expanded = self.rowExpanded(row);
                const indent = results_view.indentCells(depth);
                var col = x + indent;
                if (data.collapsible) _ = drawText(grid, col, y, end -| col, if (expanded) "⌄" else "›", base);
                col += 2;
                const icon = switch (row) {
                    .folder => file_icon.folder(expanded),
                    .file => file_icon.file(data.label),
                    else => unreachable,
                };
                if (col < end) grid.putCodepoint(col, y, icon.glyph, 1, .{ .fg = ui.cell.packColor(icon.color), .bg = base.bg });
                col += 2;

                var count_buf: [32]u8 = undefined;
                const count = std.fmt.bufPrint(&count_buf, " {d} ", .{data.count}) catch "";
                var label_end = end;
                if (!actions and end -| col > count.len) {
                    label_end = end - count.len - 1;
                    _ = drawText(grid, end - count.len, y, count.len, count, .{
                        .fg = ui.cell.packColor(self.color("badge.foreground", fg)),
                        .bg = ui.cell.packColor(self.color("badge.background", base_badge_background)),
                    });
                }
                const label_runs = [_]TextRun{
                    .{ .text = data.label, .style = base },
                    .{ .text = if (data.description.len > 0) " " else "", .style = base },
                    .{ .text = data.description, .style = dim },
                };
                _ = drawTextEllipsis(grid, col, y, label_end -| col, &label_runs, base);
            },
            .match => |match| {
                var replacement: ?[]u8 = null;
                defer if (replacement) |value| self.allocator.free(value);
                if (self.model.isReplaceActive() and self.model.replaceString().len > 0) {
                    if (self.model.replacePattern()) |pattern| {
                        replacement = match.replaceString(self.allocator, pattern, self.model.preserve_case) catch null;
                    }
                }
                const removed = replacement != null;
                var match_paint = css.findInFileMatch(ui.cell.packColor(if (removed)
                    self.color("diffEditor.removedTextBackground", base_removed_background)
                else
                    self.color("editor.findMatchHighlightBackground", base_match_background)), removed);
                match_paint.fg = base.fg;
                var replace_paint = css.replaceMatch(ui.cell.packColor(self.color("diffEditor.insertedTextBackground", base_replace_background)));
                replace_paint.fg = base.fg;

                var col = x + results_view.matchIndentCells(depth);
                var line_buffer: [48]u8 = undefined;
                const line = data.lineLabel(&line_buffer);
                if (line.len > 0) col += drawText(grid, col, y, end -| col, line, dim) + 1;
                const room = end -| col;
                const prefix_room = room -| @min(textWidth(data.inside) + @intFromBool(data.after.len != 0), room);
                const before_width = textWidth(data.before);
                const leading = (data.before_truncated or before_width > prefix_room) and prefix_room > 0;
                const before = trimLeftToFit(data.before, prefix_room -| @intFromBool(leading));
                const runs = [_]TextRun{
                    .{ .text = if (leading) "…" else "", .style = base },
                    .{ .text = before, .style = base },
                    .{ .text = data.inside, .style = match_paint },
                    .{ .text = replacement orelse "", .style = replace_paint },
                    .{ .text = data.after, .style = base },
                };
                _ = drawTextEllipsis(grid, col, y, room, &runs, base);
            },
        }
    }

    pub fn openInEditor(self: *SearchView) !void {
        const query = self.model.query orelse return;
        if (self.matchCount() == 0) return;
        const snapshot = try search_editor.serializeSearchResultForEditor(self.allocator, self.model.result, self.controller.sortOrder(), self.model.current_limit_hit);
        defer snapshot.deinit(self.allocator);
        try self.host.open_results(self.host.context, .{
            .query = query.pattern,
            .includes = self.widget.value(.includes),
            .excludes = self.widget.value(.excludes),
            .match_case = self.widget.match_case,
            .whole_word = self.widget.whole_word,
            .regex = self.widget.regex,
            .use_excludes = self.widget.use_excludes,
            .show_details = self.widget.details_visible,
        }, snapshot);
    }

    pub fn commandToggle(self: *SearchView, option: Option) void {
        self.toggleOption(option);
    }

    pub fn commandFocusNext(self: *SearchView) void {
        self.setResultsFocused(true);
        self.moveToNextMatch(1);
    }

    pub fn commandFocusPrevious(self: *SearchView) void {
        self.setResultsFocused(true);
        self.moveToNextMatch(-1);
    }

    pub fn commandRemove(self: *SearchView) void {
        self.dismissSelected();
    }

    pub fn commandReplace(self: *SearchView) void {
        self.replaceSelected();
    }

    pub fn commandReplaceAll(self: *SearchView) void {
        if (!self.model.isReplaceActive() or self.replace_confirmation != null) return;
        const request = (self.controller.requestReplaceAll() catch null) orelse return;
        self.replace_confirmation = request;
        self.host.confirm_replace_all(self.host.context, request.confirmation) catch self.clearReplaceConfirmation();
    }

    pub fn commandRefresh(self: *SearchView) !void {
        try top_bar.refreshSearch(self.controller);
    }

    pub fn commandViewAsTree(self: *SearchView, tree_view: bool) void {
        self.controller.setTreeView(tree_view);
    }

    pub fn hasExpandedResults(self: *SearchView) bool {
        for (self.rows.items) |row| {
            if (row != .match and self.rowExpanded(row)) return true;
        }
        return false;
    }

    pub fn commandSetExpanded(self: *SearchView, expanded: bool) void {
        if (expanded) top_bar.expandAll(viewerInterface(self)) else top_bar.collapseAll(viewerInterface(self));
    }

    pub fn commandClear(self: *SearchView) void {
        defer self.updateTitleActions();
        self.clearReplaceConfirmation();
        self.controller.clearResults(true);
        self.updateReplaceAllActionState();
        self.rows.clearRetainingCapacity();
        self.depths.clearRetainingCapacity();
        self.selected = 0;
        self.scroll = 0;
        self.clearHighlight();
    }

    pub fn commandToggleDetails(self: *SearchView) void {
        self.controller.toggleQueryDetails(null);
        self.widget.focusField(if (self.widget.details_visible) .includes else .search);
        self.focus_field = self.widget.focus_field;
        self.widget.input(self.focus_field).selectAll();
        self.setResultsFocused(false);
        self.panel_focused = true;
        self.setControllerFocusFromField();
    }
};

pub fn resolveWidgetColors(palette: ?*const theme_colors_mod.ThemeColors, background: ui.Color, foreground: ui.Color) widget_mod.Colors {
    var colors: widget_mod.Colors = .{ .background = background, .foreground = foreground };
    if (palette) |theme| {
        colors.input_background = theme.colorOr("input.background", colors.input_background);
        colors.input_foreground = theme.colorOr("input.foreground", foreground);
        colors.placeholder = theme.colorOr("input.placeholderForeground", colors.placeholder);
        colors.border = theme.colorOr("input.border", colors.border);
        colors.focus_border = theme.colorOr("focusBorder", colors.focus_border);
        colors.hover = theme.colorOr("toolbar.hoverBackground", colors.hover);
        colors.option_active = theme.colorOr("inputOption.activeBackground", colors.option_active);
        colors.option_foreground = theme.colorOr("inputOption.activeForeground", foreground);
        colors.disabled = theme.colorOr("disabledForeground", colors.disabled);
    }
    return colors;
}

fn controllerField(field: Field) ControllerField {
    return switch (field) {
        .search => .search,
        .replace => .replace,
        .includes => .includes,
        .excludes => .excludes,
    };
}

fn tuiField(field: ControllerField) Field {
    return switch (field) {
        .search => .search,
        .replace => .replace,
        .includes => .includes,
        .excludes => .excludes,
    };
}

fn controllerOption(option: Option) ControllerOption {
    return switch (option) {
        .match_case => .match_case,
        .whole_word => .whole_word,
        .regex => .regex,
        .preserve_case => .preserve_case,
    };
}

fn widgetValue(context: *anyopaque, field: ControllerField) []const u8 {
    const self: *SearchView = @ptrCast(@alignCast(context));
    return self.widget.value(tuiField(field));
}

fn widgetSetValue(context: *anyopaque, field: ControllerField, value: []const u8) anyerror!void {
    const self: *SearchView = @ptrCast(@alignCast(context));
    try self.widget.setValue(tuiField(field), value);
}

fn widgetClear(context: *anyopaque, field: ControllerField) void {
    const self: *SearchView = @ptrCast(@alignCast(context));
    self.widget.setValue(tuiField(field), "") catch {};
}

fn widgetOption(context: *anyopaque, option: ControllerOption) bool {
    const self: *SearchView = @ptrCast(@alignCast(context));
    return switch (option) {
        .match_case => self.widget.match_case,
        .whole_word => self.widget.whole_word,
        .regex => self.widget.regex,
        .preserve_case => self.widget.preserve_case,
    };
}

fn widgetSetOption(context: *anyopaque, option: ControllerOption, value: bool) void {
    const self: *SearchView = @ptrCast(@alignCast(context));
    switch (option) {
        .match_case => self.widget.match_case = value,
        .whole_word => self.widget.whole_word = value,
        .regex => self.widget.regex = value,
        .preserve_case => self.widget.preserve_case = value,
    }
}

fn widgetReplaceVisible(context: *anyopaque) bool {
    const self: *SearchView = @ptrCast(@alignCast(context));
    return self.widget.replace_visible;
}

fn widgetSetReplaceVisible(context: *anyopaque, visible: bool) void {
    const self: *SearchView = @ptrCast(@alignCast(context));
    self.setReplaceVisible(visible);
}

fn widgetDetailsVisible(context: *anyopaque) bool {
    const self: *SearchView = @ptrCast(@alignCast(context));
    return self.widget.details_visible;
}

fn widgetSetDetailsVisible(context: *anyopaque, visible: bool) void {
    const self: *SearchView = @ptrCast(@alignCast(context));
    self.widget.setDetailsVisible(visible);
}

fn widgetUseExcludes(context: *anyopaque) bool {
    const self: *SearchView = @ptrCast(@alignCast(context));
    return self.widget.use_excludes;
}

fn widgetFocus(context: *anyopaque, field: ControllerField) void {
    const self: *SearchView = @ptrCast(@alignCast(context));
    self.widget.focusField(tuiField(field));
}

fn widgetCycleFocus(context: *anyopaque, backwards: bool) void {
    const self: *SearchView = @ptrCast(@alignCast(context));
    _ = self.widget.cycleFocus(backwards);
}

fn viewerInterface(self: *SearchView) actions_base.Viewer {
    return .{
        .context = self,
        .row_count = viewerRowCount,
        .row_at = viewerRowAt,
        .index_of = viewerIndexOf,
        .last_visible = viewerLastVisible,
        .is_collapsed = viewerIsCollapsed,
        .expand = viewerExpand,
        .collapse = viewerCollapse,
        .collapse_all = viewerCollapseAll,
        .expand_all = viewerExpandAll,
        .selected = viewerSelected,
        .set_selected = viewerSetSelected,
        .focus = viewerFocus,
        .refresh = viewerRefresh,
    };
}

fn viewerRowCount(context: *anyopaque) usize {
    const self: *SearchView = @ptrCast(@alignCast(context));
    return self.rows.items.len;
}

fn viewerRowAt(context: *anyopaque, index: usize) ?Row {
    const self: *SearchView = @ptrCast(@alignCast(context));
    if (index >= self.rows.items.len) return null;
    return self.rows.items[index];
}

fn viewerIndexOf(context: *anyopaque, node: Row) ?usize {
    const self: *SearchView = @ptrCast(@alignCast(context));
    for (self.rows.items, 0..) |row, index| {
        if (tree.nodeEql(row, node)) return index;
    }
    return null;
}

fn viewerLastVisible(context: *anyopaque) ?Row {
    const self: *SearchView = @ptrCast(@alignCast(context));
    if (self.rows.items.len == 0) return null;
    return self.rows.items[self.rows.items.len - 1];
}

fn viewerIsCollapsed(context: *anyopaque, node: Row) bool {
    const self: *SearchView = @ptrCast(@alignCast(context));
    return self.collapsed.contains(node.id());
}

fn viewerExpand(context: *anyopaque, node: Row, recursive: bool) bool {
    _ = recursive;
    const self: *SearchView = @ptrCast(@alignCast(context));
    const changed = self.collapsed.remove(node.id());
    if (changed) self.rebuildRows();
    return changed;
}

fn viewerCollapse(context: *anyopaque, node: Row, recursive: bool) bool {
    _ = recursive;
    const self: *SearchView = @ptrCast(@alignCast(context));
    if (self.collapsed.contains(node.id())) return false;
    self.collapsed.put(node.id());
    self.rebuildRows();
    return true;
}

fn viewerCollapseAll(context: *anyopaque) void {
    const self: *SearchView = @ptrCast(@alignCast(context));
    for (self.rows.items) |row| {
        if (row != .match) self.collapsed.put(row.id());
    }
    self.rebuildRows();
}

fn viewerExpandAll(context: *anyopaque) void {
    const self: *SearchView = @ptrCast(@alignCast(context));
    self.collapsed.clear();
    self.rebuildRows();
}

fn viewerSelected(context: *anyopaque) ?Row {
    const self: *SearchView = @ptrCast(@alignCast(context));
    return self.selectedRow();
}

fn viewerSetSelected(context: *anyopaque, node: ?Row) void {
    const self: *SearchView = @ptrCast(@alignCast(context));
    if (node) |value| {
        if (viewerIndexOf(context, value)) |index| {
            self.selectRow(index);
            return;
        }
    }
    self.selected = 0;
}

fn viewerFocus(context: *anyopaque) void {
    const self: *SearchView = @ptrCast(@alignCast(context));
    self.panel_focused = true;
    self.setResultsFocused(true);
}

fn viewerRefresh(context: *anyopaque) void {
    const self: *SearchView = @ptrCast(@alignCast(context));
    self.rebuildRows();
}

fn hostOpenMatch(context: *anyopaque, path: []const u8, range: ?Range, preserve_focus: bool, side_by_side: bool) anyerror!void {
    _ = side_by_side;
    const self: *SearchView = @ptrCast(@alignCast(context));
    try self.host.open_match(self.host.context, path, range);
    if (preserve_focus) self.host.highlight_range(self.host.context, path, range);
}

fn hostHighlightRange(context: *anyopaque, path: []const u8, range: ?Range) void {
    const self: *SearchView = @ptrCast(@alignCast(context));
    self.host.highlight_range(self.host.context, path, range);
}

fn hostApplyEdits(context: *anyopaque, path: []const u8, edits: []const Edit) anyerror!void {
    const self: *SearchView = @ptrCast(@alignCast(context));
    return self.host.apply_edits(self.host.context, path, edits);
}

fn hostSaveFile(context: *anyopaque, path: []const u8) anyerror!void {
    const self: *SearchView = @ptrCast(@alignCast(context));
    return self.host.save_file(self.host.context, path);
}

fn hostActiveSelectionText(context: *anyopaque, allocator: Allocator) anyerror!?[]u8 {
    const self: *SearchView = @ptrCast(@alignCast(context));
    return self.host.active_selection_text(self.host.context, allocator);
}

fn hostExtraFiles(context: *anyopaque, allocator: Allocator) anyerror![][]u8 {
    const self: *SearchView = @ptrCast(@alignCast(context));
    return self.host.extra_files(self.host.context, allocator);
}

fn hostFreePaths(context: *anyopaque, allocator: Allocator, paths: [][]u8) void {
    const self: *SearchView = @ptrCast(@alignCast(context));
    self.host.free_paths(self.host.context, allocator, paths);
}

fn pointInRect(rect: ui.Rect, x: usize, y: usize) bool {
    return x >= ui.cell.snap(rect.x) and x < ui.cell.snap(rect.right()) and
        y >= ui.cell.snap(rect.y) and y < ui.cell.snap(rect.bottom());
}

const TextRun = struct { text: []const u8, style: ui.cell.PaintStyle };

fn drawTextEllipsis(grid: *ui.CellGrid, x: usize, y: usize, width: usize, runs: []const TextRun, style: ui.cell.PaintStyle) usize {
    if (width == 0) return 0;
    var total: usize = 0;
    for (runs) |run| total += textWidth(run.text);
    const truncated = total > width;
    const end = x + width - @intFromBool(truncated);
    var col = x;
    for (runs) |run| {
        const used = drawText(grid, col, y, end - col, run.text, run.style);
        col += used;
        if (used < textWidth(run.text)) break;
    }
    if (truncated) col += drawText(grid, col, y, 1, "…", style);
    return col - x;
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

fn trimLeftToFit(text: []const u8, width: usize) []const u8 {
    var remaining = textWidth(text);
    var offset: usize = 0;
    while (remaining > width and offset < text.len) {
        const decoded = ui.dom.decodeAt(text, offset);
        remaining -= ui.dom.defaultMeasureWidth(decoded.cp);
        offset += decoded.len;
    }
    return text[offset..];
}

fn drawText(grid: *ui.CellGrid, x: usize, y: usize, max_width: usize, text: []const u8, style: ui.cell.PaintStyle) usize {
    var col = x;
    var offset: usize = 0;
    while (offset < text.len and col < x + max_width) {
        const decoded = ui.dom.decodeAt(text, offset);
        if (decoded.len == 0) break;
        const width = ui.dom.defaultMeasureWidth(decoded.cp);
        if (width == 0) {
            offset += decoded.len;
            continue;
        }
        if (col + width > x + max_width) break;
        grid.putCodepoint(col, y, decoded.cp, width, style);
        col += width;
        offset += decoded.len;
    }
    return col - x;
}

const search_keybinding_rules = [_]keybinding_registry.IKeybindingRule{
    .{
        .id = "search.action.toggleReplace",
        .weight = 200,
        .bindings = .{
            .primary = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyR),
            .secondary = &.{key_codes.KeyMod.CtrlCmd | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.KeyR)},
        },
    },
    .{
        .id = "search.action.toggleCaseSensitive",
        .weight = 200,
        .bindings = .{
            .primary = key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.KeyC),
            .secondary = &.{key_codes.KeyMod.Alt | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.KeyC)},
        },
    },
    .{
        .id = "search.action.toggleWholeWord",
        .weight = 200,
        .bindings = .{
            .primary = key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.KeyW),
            .secondary = &.{key_codes.KeyMod.Alt | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.KeyW)},
        },
    },
    .{
        .id = "search.action.toggleRegex",
        .weight = 200,
        .bindings = .{
            .primary = key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.KeyR),
            .secondary = &.{key_codes.KeyMod.Alt | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.KeyR)},
        },
    },
    .{
        .id = "search.action.togglePreserveCase",
        .weight = 200,
        .bindings = .{
            .primary = key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.KeyP),
            .secondary = &.{key_codes.KeyMod.Alt | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.KeyP)},
        },
    },
    .{
        .id = "workbench.action.search.toggleQueryDetails",
        .weight = 200,
        .bindings = .{
            .primary = key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.KeyD),
            .secondary = &.{key_codes.KeyMod.Alt | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.KeyD)},
        },
    },
    .{ .id = "search.action.replace", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.Enter) } },
    .{
        .id = "search.action.replaceAll",
        .weight = 200,
        .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | key_codes.KeyMod.Alt | @backingInt(key_codes.KeyCode.Enter) },
    },
};

const NativeSearchService = @import("../../../services/search/common/searchService.zig").SearchService;
const NativeTab = @import("../../../browser/parts/editor/editorPane.zig").Tab;
const NativeGroupView = @import("../../../browser/parts/editor/editorGroupView.zig").EditorGroupView(*NativeTab);
const NativeEditorPart = @import("../../../browser/parts/editor/editorPart.zig").EditorPart(NativeGroupView);
const EditorService = @import("../../../services/editor/browser/editorService.zig").EditorService;
const EditorOpening = @import("../../../services/editor/browser/editorService.zig").EditorOpening;
const SearchEditorFactory = @import("../../searchEditor/browser/searchEditor.contribution.zig").SearchEditorFactory;
const NativeReplaceHost = @import("replaceService.zig").NativeEditorHost;
const NativeReplaceEdit = @import("replaceService.zig").Edit;
const NativeDialogs = @import("../../../../platform/dialogs/common/dialogs.zig");
const DialogService = @import("../../../services/dialogs/common/dialogService.zig").DialogService;
const NativeEditorBrowser = @import("../../../../editor/browser/editorBrowser.zig");

/// Native Search contribution lifetime. The workbench supplies only window
/// focus/layout/configuration dependencies; the Search view owns its service,
/// editor factory, activity registration and editor/file query adapters.
pub const SearchWindow = struct {
    lists: *list_service.ListService,
    allocator: Allocator,
    io: std.Io,
    part: *NativeEditorPart,
    workspace: *WorkspaceContextService,
    configuration: *const ?*ConfigurationService,
    editor_opening: *EditorOpening,
    activity_service: *ActivityService,
    title_pane: *PaneCompositePart,
    dialog_service: *DialogService,
    window: *@import("../../../../base/common/windowDispatch.zig").Queue,
    view_factory: @import("../../../browser/parts/editor/editorPane.zig").EditorViewFactory,
    host: struct {
        context: *anyopaque,
        ensure_configuration: *const fn (*anyopaque) anyerror!void,
        configure_tab: *const fn (*anyopaque, *NativeTab) void,
        update_focus: *const fn (*anyopaque) anyerror!void,
        layout: *const fn (*anyopaque) void,
        focus_editor: *const fn (*anyopaque) void,
        focus_result: *const fn (*anyopaque) void,
    },
    service: ?*NativeSearchService = null,
    view: ?*SearchView = null,
    factory: SearchEditorFactory = undefined,

    /// The CLI can replace the workspace context service when it switches
    /// folders. Both the view's next search and existing Search Editor
    /// inputs must resolve the replacement, not retain the disposed service.
    pub fn setWorkspace(self: *SearchWindow, workspace: *WorkspaceContextService) void {
        self.workspace = workspace;
        self.factory.workspace = workspace;
    }

    pub fn bindEditorFactory(self: *SearchWindow) void {
        self.factory = .{
            .allocator = self.allocator,
            .io = self.io,
            .part = self.part,
            .workspace = self.workspace,
            .configuration = self.configuration,
            .view_factory = self.view_factory,
            .window = self.window,
            .host = .{
                .context = self,
                .start_search = startSearchEditorJob,
                .extra_files = searchExtraFiles,
                .ensure_configuration = struct {
                    fn run(context: *anyopaque) !void {
                        const window: *SearchWindow = @ptrCast(@alignCast(context));
                        try window.host.ensure_configuration(window.host.context);
                    }
                }.run,
                .configure_tab = struct {
                    fn run(context: *anyopaque, tab: *NativeTab) void {
                        const window: *SearchWindow = @ptrCast(@alignCast(context));
                        window.host.configure_tab(window.host.context, tab);
                    }
                }.run,
                .update_focus = struct {
                    fn run(context: *anyopaque) !void {
                        const window: *SearchWindow = @ptrCast(@alignCast(context));
                        try window.host.update_focus(window.host.context);
                    }
                }.run,
                .layout = struct {
                    fn run(context: *anyopaque) void {
                        const window: *SearchWindow = @ptrCast(@alignCast(context));
                        window.host.layout(window.host.context);
                    }
                }.run,
                .focus_editor = struct {
                    fn run(context: *anyopaque) void {
                        const window: *SearchWindow = @ptrCast(@alignCast(context));
                        window.host.focus_editor(window.host.context);
                    }
                }.run,
                .open_match = searchOpenMatch,
            },
        };
    }

    fn activeTab(self: *SearchWindow) ?*NativeTab {
        const pane = self.part.activeView() orelse return null;
        return pane.activeTab();
    }

    fn startSearchEditorJob(context: *anyopaque, query: *const search.TextQuery) !search.ISearchJob {
        const self: *SearchWindow = @ptrCast(@alignCast(context));
        if (self.service == null) try self.initFromWorkspace();
        return self.service.?.startTextSearch(query);
    }

    fn searchOpenResults(context: *anyopaque, config: search_editor_view.Config, snapshot: search_editor.Snapshot) !void {
        const self: *SearchWindow = @ptrCast(@alignCast(context));
        try self.factory.openResults(config, snapshot);
    }

    fn searchApplyEdits(context: *anyopaque, path: []const u8, edits: []const NativeReplaceEdit) !void {
        const self: *SearchWindow = @ptrCast(@alignCast(context));
        var host = NativeReplaceHost{ .allocator = self.allocator, .io = self.io, .part = self.part };
        try host.applyEdits(path, edits);
    }

    fn searchSaveFile(context: *anyopaque, path: []const u8) !void {
        const self: *SearchWindow = @ptrCast(@alignCast(context));
        var host = NativeReplaceHost{ .allocator = self.allocator, .io = self.io, .part = self.part };
        try host.saveFile(path);
    }

    pub fn initFromWorkspace(self: *SearchWindow) !void {
        self.destroy();
        const service = try self.allocator.create(NativeSearchService);
        errdefer self.allocator.destroy(service);
        service.* = NativeSearchService.init(self.allocator, self.io, self.workspace, .{
            .context = self,
            .read = searchReadFile,
            .extra_files = searchExtraFiles,
            .open_files = searchOpenFiles,
            .free_paths = searchFreePaths,
        });
        const view = try SearchView.init(
            self.allocator,
            self.workspace,
            self.configuration.*.?,
            service.interface(),
            .{
                .context = self,
                .open_match = searchOpenMatch,
                .open_results = searchOpenResults,
                .highlight_range = searchHighlightRange,
                .read_file = searchReadFile,
                .extra_files = searchExtraFiles,
                .free_paths = searchFreePaths,
                .apply_edits = searchApplyEdits,
                .save_file = searchSaveFile,
                .active_selection_text = searchActiveSelectionText,
                .confirm_replace_all = searchConfirmReplaceAll,
            },
        );
        errdefer view.deinit();
        try view.registerList(self.lists);
        try view.attachActivity(self.activity_service);
        try view.attachTitleActions(self.title_pane);
        view.model.result.model_host = .{ .context = self, .get = searchTextModel, .queue = self.window };
        _ = try view.on_did_change_focus.listenSignal(self, onSearchFocusChanged);
        self.service = service;
        view.model.delivery.attach(self.window, view, SearchView.dispatchSearch);
        self.view = view;
    }

    fn onSearchFocusChanged(self: *SearchWindow) !void {
        try self.host.update_focus(self.host.context);
    }

    pub fn destroy(self: *SearchWindow) void {
        if (self.view) |view| view.deinit();
        self.view = null;
        if (self.service) |service| self.allocator.destroy(service);
        self.service = null;
    }

    fn searchOpenMatch(context: *anyopaque, path: []const u8, range: ?Range) anyerror!void {
        const self: *SearchWindow = @ptrCast(@alignCast(context));
        try self.editor_opening.openPathWithOptions(path, .{});
        self.host.focus_result(self.host.context);
        if (self.activeTab()) |tab| {
            if (range) |value| try tab.editor.setSelection(value);
            tab.focusEditor();
        }
        if (range) |value| searchHighlightRange(context, path, value) else searchHighlightRange(context, path, null);
    }

    fn searchHighlightRange(context: *anyopaque, path: []const u8, range: ?Range) void {
        const self: *SearchWindow = @ptrCast(@alignCast(context));
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (range != null and std.mem.eql(u8, tab.editor.path, path)) {
                    const decorations = [_]NativeEditorBrowser.Decoration{.{ .range = range.?, .kind = .search_range_highlight }};
                    tab.view.setSearchHighlights(&decorations) catch {};
                } else {
                    tab.view.setSearchHighlights(&.{}) catch {};
                }
            }
        }
    }

    fn searchReadFile(context: *anyopaque, allocator: Allocator, path: []const u8) anyerror!?[]u8 {
        const self: *SearchWindow = @ptrCast(@alignCast(context));
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (!std.mem.eql(u8, tab.editor.path, path)) continue;
                var value = try tab.editor.model.getValue(null, false);
                defer value.deinit();
                return try allocator.dupe(u8, value.items);
            }
        }
        return null;
    }

    fn searchOpenFiles(context: *anyopaque, allocator: Allocator) anyerror![][]u8 {
        const self: *SearchWindow = @ptrCast(@alignCast(context));
        var paths = std.array_list.Managed([]u8).init(allocator);
        errdefer {
            for (paths.items) |path| allocator.free(path);
            paths.deinit();
        }
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (tab.search_editor_input != null) continue;
                var duplicate = false;
                for (paths.items) |existing| {
                    if (std.mem.eql(u8, existing, tab.editor.path)) {
                        duplicate = true;
                        break;
                    }
                }
                if (!duplicate) try paths.append(try allocator.dupe(u8, tab.editor.path));
            }
        }
        return try paths.toOwnedSlice();
    }

    fn searchExtraFiles(context: *anyopaque, allocator: Allocator) anyerror![][]u8 {
        const self: *SearchWindow = @ptrCast(@alignCast(context));
        var paths = std.array_list.Managed([]u8).init(allocator);
        errdefer {
            for (paths.items) |path| allocator.free(path);
            paths.deinit();
        }
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (tab.search_editor_input != null) continue;
                if (self.workspace.isInsideWorkspace(tab.editor.path)) continue;
                var duplicate = false;
                for (paths.items) |existing| {
                    if (std.mem.eql(u8, existing, tab.editor.path)) {
                        duplicate = true;
                        break;
                    }
                }
                if (!duplicate) try paths.append(try allocator.dupe(u8, tab.editor.path));
            }
        }
        return try paths.toOwnedSlice();
    }

    fn searchFreePaths(_: *anyopaque, allocator: Allocator, paths: [][]u8) void {
        for (paths) |path| allocator.free(path);
        allocator.free(paths);
    }

    fn searchActiveSelectionText(context: *anyopaque, allocator: Allocator) anyerror!?[]u8 {
        const self: *SearchWindow = @ptrCast(@alignCast(context));
        const tab = self.activeTab() orelse return null;
        const selections = try tab.editor.getSelections();
        defer self.allocator.free(selections);
        for (selections) |selection| {
            if (selection.isEmpty()) continue;
            var value = try tab.editor.model.getValueInRange(Range.init(
                selection.startLineNumber,
                selection.startColumn,
                selection.endLineNumber,
                selection.endColumn,
            ), null);
            defer value.deinit();
            return try allocator.dupe(u8, value.items);
        }
        return null;
    }

    fn searchConfirmReplaceAll(context: *anyopaque, message: []const u8) !void {
        const self: *SearchWindow = @ptrCast(@alignCast(context));
        if (self.dialog_service.hasDialog()) return error.DialogAlreadyOpen;
        _ = try self.dialog_service.confirm(.{ .message = message, .primary_button = "Replace" }, .{ .context = self, .complete = onSearchReplaceAllConfirmed });
    }

    fn onSearchReplaceAllConfirmed(context: *anyopaque, result: NativeDialogs.IConfirmationResult) void {
        const self: *SearchWindow = @ptrCast(@alignCast(context));
        if (self.view) |view| {
            if (result.confirmed) view.confirmReplaceAll() else view.clearReplaceConfirmation();
        }
    }

    fn searchTextModel(context: *anyopaque, path: []const u8) ?*@import("../../../../editor/common/model/textModel.zig").TextModel {
        const self: *SearchWindow = @ptrCast(@alignCast(context));
        const input = (EditorService{ .part = self.part }).findOpenFileInput(self.io, path) orelse return null;
        return input.editor.model;
    }
};
