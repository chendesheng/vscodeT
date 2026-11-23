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
const actions_base = @import("./searchActionsBase.zig");
const remove_replace = @import("./searchActionsRemoveReplace.zig");
const configuration_mod = @import("../../../services/configuration/browser/configurationService.zig");
const ConfigurationService = configuration_mod.ConfigurationService;
const tree = @import("./searchTreeModel/searchTreeCommon.zig");
const SearchResult = tree.SearchResult;
const FileMatch = tree.FileMatch;
const FolderMatch = tree.FolderMatch;
const Match = tree.Match;
const ChangeEvent = tree.ChangeEvent;
const replace_service = @import("./replaceService.zig");
const Edit = replace_service.Edit;
const SearchWidget = @import("./searchWidget.zig").SearchWidget;
const Field = @import("./searchWidget.zig").Field;
const Option = @import("./searchWidget.zig").Option;
const Range = @import("../../../../editor/common/core/range.zig").Range;
const workspace_context = @import("../../../services/workspaces/common/workspaceContextService.zig");
const WorkspaceContextService = workspace_context.WorkspaceContextService;

const base_background = ui.Color{ .r = 30, .g = 30, .b = 33 };
const base_foreground = ui.Color{ .r = 210, .g = 210, .b = 210 };
const base_dim = ui.Color{ .r = 135, .g = 135, .b = 142 };
const base_header_background = ui.Color{ .r = 38, .g = 38, .b = 42 };
const base_selected_background = ui.Color{ .r = 55, .g = 65, .b = 80 };
const base_folder_color = ui.Color{ .r = 170, .g = 190, .b = 210 };
const base_match_color = ui.Color{ .r = 240, .g = 190, .b = 90 };
const base_replace_color = ui.Color{ .r = 120, .g = 210, .b = 120 };
const base_scrollbar_track_color = ui.Color{ .r = 30, .g = 32, .b = 40 };
const base_scrollbar_thumb_color = ui.Color{ .r = 105, .g = 108, .b = 122 };

pub const Action = enum { unhandled, handled, focus_editor };

pub const EditorInfo = struct {
    path: []const u8,
    version: u32,
};

/// Workbench integration points. The search view does not import the
/// workbench; the terminal shell implements these callbacks.
pub const Host = struct {
    context: *anyopaque,
    open_match: *const fn (context: *anyopaque, path: []const u8, range: ?Range) anyerror!void,
    highlight_range: *const fn (context: *anyopaque, path: []const u8, range: ?Range) void,
    read_file: *const fn (context: *anyopaque, allocator: Allocator, path: []const u8) anyerror!?[]u8,
    extra_files: *const fn (context: *anyopaque, allocator: Allocator) anyerror![][]u8,
    free_paths: *const fn (context: *anyopaque, allocator: Allocator, paths: [][]u8) void,
    apply_edits: *const fn (context: *anyopaque, path: []const u8, edits: []const Edit) anyerror!void,
    save_file: *const fn (context: *anyopaque, path: []const u8) anyerror!void,
    active_selection_text: *const fn (context: *anyopaque, allocator: Allocator) anyerror!?[]u8,
    active_editor: *const fn (context: *anyopaque) ?EditorInfo,
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
};

pub const SearchView = struct {
    allocator: Allocator,
    workspace: *WorkspaceContextService,
    configuration: *ConfigurationService,
    host: Host,
    controller: *Controller,
    model: *SearchModel,
    widget: *SearchWidget,
    rows: std.array_list.Managed(Row),
    depths: std.array_list.Managed(usize),
    collapsed: OwnedStringSet,
    collapse_seen: OwnedStringSet,
    selected: usize = 0,
    scroll: usize = 0,
    visible_rows: usize = 0,
    scrollbar_drag: bool = false,
    last_rect: ui.Rect = .{},
    /// Rows above the search widget: one while the view paints its own
    /// section header, zero when the side bar part paints the title.
    header_rows: usize = 1,
    focus_field: Field = .search,
    results_focused: bool = false,
    suppress_refresh: bool = false,
    panel_focused: bool = false,
    started_once: bool = false,
    replace_confirmation: ?controller_mod.ReplaceAllRequest = null,
    keybindings: ?*keybinding_service.KeybindingService = null,
    theme: ?*const theme_colors_mod.ThemeColors = null,
    keybinding_removals: []const *const resolved_keybinding_item.ResolvedKeybindingItem = &.{},
    pending_action: ?Action = null,

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
                .active_editor = hostActiveEditor,
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
            .on_replace_all = onWidgetReplaceAll,
        };
        try self.setWidgetValueFromSelection();
        return self;
    }

    pub fn deinit(self: *SearchView) void {
        self.clearHighlight();
        if (self.replace_confirmation) |*request| {
            self.allocator.free(request.confirmation);
            self.allocator.free(request.after);
            self.replace_confirmation = null;
        }
        self.controller.deinit();
        self.widget.deinit();
        self.rows.deinit();
        self.depths.deinit();
        self.collapsed.deinit();
        self.collapse_seen.deinit();
        if (self.keybindings) |service| service.deinit();
        self.allocator.destroy(self);
    }

    /// Number of current search matches, used as the activity-bar badge
    /// source while a search is populated.
    pub fn matchCount(self: *const SearchView) usize {
        return self.controller.matchCount();
    }

    pub fn focus(self: *SearchView) void {
        self.panel_focused = true;
        self.results_focused = false;
        self.focus_field = .search;
        self.widget.focus_field = .search;
        self.widget.focused = true;
        self.controller.setPanelFocused(true);
        self.controller.focus = .search;
        self.controller.last_focus_input = true;
    }

    pub fn focusReplace(self: *SearchView) void {
        self.panel_focused = true;
        self.results_focused = false;
        self.widget.replace_visible = true;
        self.widget.focus_field = .replace;
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
        self.results_focused = false;
        self.widget.focused = false;
        self.controller.setPanelFocused(false);
    }

    pub fn focusResults(self: *SearchView) void {
        self.panel_focused = true;
        self.results_focused = true;
        self.widget.focused = false;
        self.controller.setPanelFocused(true);
        self.controller.focus = .results;
        self.controller.last_focus_input = false;
    }

    pub fn isFocused(self: *const SearchView) bool {
        return self.panel_focused;
    }

    pub fn wantsTick(self: *const SearchView) bool {
        return self.controller.wantsTick();
    }

    pub fn tick(self: *SearchView, now: i64) bool {
        const changed = self.controller.tick(now) catch false;
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
        self.controller.onQueryInputChanged(controllerField(field));
    }

    fn onWidgetSubmit(context: ?*anyopaque, field: Field) void {
        const self: *SearchView = @ptrCast(@alignCast(context orelse return));
        switch (field) {
            .search, .includes, .excludes => {
                self.controller.submitQuery() catch {};
                self.rebuildRows();
            },
            .replace => {
                self.model.setReplaceString(self.widget.value(.replace)) catch {};
            },
        }
    }

    fn onWidgetEscape(context: ?*anyopaque, field: Field) void {
        _ = field;
        const self: *SearchView = @ptrCast(@alignCast(context orelse return));
        if (self.widget.replace_visible and self.focus_field == .replace) {
            self.widget.toggleReplace();
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

    fn onWidgetReplaceAll(context: ?*anyopaque) void {
        const self: *SearchView = @ptrCast(@alignCast(context orelse return));
        self.replaceAll();
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
            self.widget.toggleReplace();
            self.focus_field = if (self.widget.replace_visible) .replace else .search;
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
            self.controller.toggleQueryDetails(null);
            return .handled;
        }
        if (std.mem.eql(u8, command, "search.action.replace")) {
            self.replaceSelected();
            return .handled;
        }
        if (std.mem.eql(u8, command, "search.action.replaceAll")) {
            if (self.replace_confirmation != null) {
                self.confirmReplaceAll();
            } else if (self.controller.requestReplaceAll() catch null) |request| {
                self.replace_confirmation = request;
            }
            return .handled;
        }
        return null;
    }

    fn toggleOption(self: *SearchView, option: Option) void {
        self.controller.toggleOption(controllerOption(option)) catch {};
    }

    pub fn startSearch(self: *SearchView) !void {
        // Enter submits the current value; it must cancel a pending
        // search-on-type debounce instead of letting it start a second query.
        self.controller.debounce_at = null;
        try self.controller.triggerQueryChange(false, false);
        self.rebuildRows();
    }

    pub fn onEditorChanged(self: *SearchView, info: ?EditorInfo) void {
        if (self.suppress_refresh) return;
        self.controller.onEditorChanged(if (info) |value| .{
            .path = value.path,
            .version = value.version,
        } else null);
    }

    pub fn setWorkspace(self: *SearchView, workspace: *WorkspaceContextService) void {
        self.workspace = workspace;
        self.controller.workspace = workspace;
    }

    pub fn onConfigurationChanged(self: *SearchView) void {
        self.controller.onConfigurationChanged();
        self.rebuildRows();
    }

    fn clearHighlight(self: *SearchView) void {
        self.host.highlight_range(self.host.context, "", null);
    }

    fn setControllerFocusFromField(self: *SearchView) void {
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
        self.widget.focus_field = self.focus_field;
        self.results_focused = self.controller.focus == .results;
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

    fn rebuildRows(self: *SearchView) void {
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
        const row = self.selectedRow() orelse return;
        self.suppress_refresh = true;
        defer self.suppress_refresh = false;
        self.controller.replaceElement(row) catch {};
        self.rebuildRows();
    }

    fn replaceAll(self: *SearchView) void {
        self.commandReplaceAll();
    }

    pub fn confirmReplaceAll(self: *SearchView) void {
        if (self.replace_confirmation) |*request| {
            self.allocator.free(request.confirmation);
            self.allocator.free(request.after);
            self.replace_confirmation = null;
            self.controller.executeReplaceAll() catch {};
            self.rebuildRows();
        }
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
            if (self.replace_confirmation) |*request| {
                self.allocator.free(request.confirmation);
                self.allocator.free(request.after);
                self.replace_confirmation = null;
                return .handled;
            }
            if (self.widget.replace_visible and self.focus_field == .replace) {
                self.widget.toggleReplace();
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
            self.results_focused = false;
            self.widget.cycleFocus(event.key == .backtab);
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
                    self.widget.toggleReplace();
                    self.focus_field = if (self.widget.replace_visible) .replace else .search;
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
                    self.controller.toggleQueryDetails(null);
                    return .handled;
                },
                else => {},
            }
        }

        if (event.mods.alt and event.key == .enter and !event.mods.ctrl) {
            self.replaceSelected();
            return .handled;
        }
        if (event.mods.alt and event.mods.ctrl and event.key == .enter) {
            if (self.replace_confirmation != null) {
                self.confirmReplaceAll();
            } else if (self.controller.requestReplaceAll() catch null) |request| {
                self.replace_confirmation = request;
            }
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
                self.results_focused = true;
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
        if (self.header_rows == 1 and local_y == 0) {
            if (event.kind == .down and local_x >= width -| 3) {
                self.controller.toggleQueryDetails(null);
                return true;
            }
            return true;
        }

        const input_top = self.header_rows;
        const input_bottom = input_top + self.widget.layout.height;
        if (local_y >= input_top and local_y < input_bottom) {
            // Pointer motion only hovers a field; press/click moves input
            // focus. Treating motion as activation made the caret jump rows.
            const activating = event.kind == .down or event.kind == .click;
            if (activating) {
                self.panel_focused = true;
                self.results_focused = false;
                self.widget.focused = true;
            }
            var local = event.*;
            local.x = local_x;
            local.y = local_y - input_top;
            if (self.widget.handleMouse(local_x, local_y - input_top, &local)) {
                if (activating) {
                    self.focus_field = self.widget.focus_field;
                    self.setControllerFocusFromField();
                }
            }
            return true;
        }

        const results_top = input_bottom + 1;
        if (local_y < results_top) return true;
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
        if (row >= self.rows.items.len) return true;
        if (event.kind == .move) return true;
        self.panel_focused = true;
        self.results_focused = true;
        self.controller.setPanelFocused(true);
        self.controller.focus = .results;
        self.controller.last_focus_input = false;
        self.selectRow(row);
        if (event.kind == .click or event.kind == .down) {
            switch (self.rows.items[row]) {
                .folder => self.toggleRow(self.rows.items[row]),
                .file => self.toggleRow(self.rows.items[row]),
                .match => self.activateSelected(),
                .heading => self.toggleRow(self.rows.items[row]),
            }
        }
        return true;
    }

    pub fn setThemeColors(self: *SearchView, palette: ?*const theme_colors_mod.ThemeColors) void {
        self.theme = palette;
    }

    pub fn render(self: *SearchView, grid: *ui.CellGrid, rect: ui.Rect, options: RenderOptions) !void {
        self.last_rect = rect;
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
        var folder_color = base_folder_color;
        var match_color = base_match_color;
        var replace_color = base_replace_color;
        var scrollbar_track_color = base_scrollbar_track_color;
        var scrollbar_thumb_color = base_scrollbar_thumb_color;
        if (self.theme) |palette| {
            background = palette.colorOr("sideBar.background", base_background);
            foreground = palette.colorOr("sideBar.foreground", base_foreground);
            dim = palette.colorOr("descriptionForeground", base_dim);
            header_background = palette.colorOr("sideBarSectionHeader.background", base_header_background);
            selected_background = palette.colorOr("list.activeSelectionBackground", base_selected_background);
            folder_color = palette.colorOr("symbolIcon.folderForeground", base_folder_color);
            match_color = palette.colorOr("search.matchHighlightForeground", base_match_color);
            replace_color = palette.colorOr("gitDecoration.addedResourceForeground", base_replace_color);
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
            _ = drawText(grid, x + width -| 3, y, 3, "...", .{ .fg = ui.cell.packColor(dim), .bg = ui.cell.packColor(header_background) });
        }

        // The caret belongs to the field only while the view owns input focus;
        // results navigation and leaving the side bar both hide it.
        self.widget.focused = self.panel_focused and !self.results_focused;
        try self.widget.render(width);
        try grid.blit(self.widget.grid(), x, y + self.header_rows, width, self.widget.layout.height);
        const status_y = y + self.header_rows + self.widget.layout.height;
        var status_buffer: [240]u8 = undefined;
        var status = self.controller.messageText(&status_buffer);
        if (self.replace_confirmation) |request| status = request.confirmation;
        if (status.len == 0) {
            if (self.controller.wantsTick()) {
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
        if (status_y < y + height) {
            _ = drawText(grid, x + 1, status_y, width -| 2, status, status_style);
        }

        const top = status_y + 1;
        const rows = if (top < y + height) y + height - top else 0;
        self.visible_rows = rows;
        self.clampScroll();
        if (rows == 0) return;

        var visible: usize = 0;
        while (visible < rows) : (visible += 1) {
            const index = self.scroll + visible;
            if (index >= self.rows.items.len) break;
            const row_y = top + visible;
            const selected = index == self.selected;
            const row_bg = if (selected) selected_background else background;
            if (selected) {
                grid.fillRect(@floatFromInt(x), @floatFromInt(row_y), @floatFromInt(width), 1, .{
                    .fg = ui.cell.packColor(foreground),
                    .bg = ui.cell.packColor(row_bg),
                });
            }
            self.renderRow(grid, x, row_y, width, self.rows.items[index], self.depths.items[index], row_bg);
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

    fn renderRow(self: *SearchView, grid: *ui.CellGrid, x: usize, y: usize, width: usize, row: Row, depth: usize, row_bg: ui.Color) void {
        const palette = self.theme;
        const base_fg = ui.cell.packColor(if (palette) |colors| colors.colorOr("sideBar.foreground", base_foreground) else base_foreground);
        const dim_fg = ui.cell.packColor(if (palette) |colors| colors.colorOr("descriptionForeground", base_dim) else base_dim);
        const folder_fg = if (palette) |colors| colors.colorOr("symbolIcon.folderForeground", base_folder_color) else base_folder_color;
        const match_fg = if (palette) |colors| colors.colorOr("search.matchHighlightForeground", base_match_color) else base_match_color;
        const replace_fg = if (palette) |colors| colors.colorOr("gitDecoration.addedResourceForeground", base_replace_color) else base_replace_color;
        const bg = ui.cell.packColor(row_bg);
        switch (row) {
            .heading => {
                _ = drawText(grid, x + 1, y, width -| 2, "Text Results", .{ .fg = base_fg, .bg = bg, .attrs = ui.cell.Attr.bold });
            },
            .folder => |folder| {
                const expanded = self.rowExpanded(row);
                var buffer: [160]u8 = undefined;
                const text = std.fmt.bufPrint(&buffer, "{s} {s} ({d})", .{
                    if (expanded) "▾" else "▸",
                    folder.name,
                    folder.recursiveMatchCount(),
                }) catch folder.name;
                const indent = results_view.indentCells(depth);
                _ = drawText(grid, x + indent, y, width -| indent, text, .{ .fg = ui.cell.packColor(folder_fg), .bg = bg });
            },
            .file => |file| {
                const expanded = self.rowExpanded(row);
                var buffer: [200]u8 = undefined;
                const text = std.fmt.bufPrint(&buffer, "{s} {s} ({d})", .{
                    if (expanded) "▾" else "▸",
                    file.name,
                    file.count(),
                }) catch file.name;
                const indent = results_view.indentCells(depth);
                var col = x + indent;
                col += drawText(grid, col, y, width -| (col - x), text, .{ .fg = base_fg, .bg = bg });
                const details = results_view.rowData(row, .{
                    .mode = self.controller.viewMode(),
                    .show_line_numbers = self.controller.showLineNumbers(),
                });
                if (details.description.len > 0 and !std.mem.eql(u8, details.description, file.name)) {
                    col += drawText(grid, col + 1, y, width -| (col + 1 - x), details.description, .{ .fg = dim_fg, .bg = bg });
                }
            },
            .match => |match| {
                const preview = match.preview();
                var replacement: ?[]u8 = null;
                defer if (replacement) |value| self.allocator.free(value);
                if (self.widget.replace_visible and self.model.replaceString().len > 0) {
                    if (self.model.replacePattern()) |pattern| {
                        replacement = match.replaceString(self.allocator, pattern, self.model.preserve_case) catch null;
                    }
                }
                const inside = replacement orelse preview.inside;
                const inside_color = if (replacement != null) replace_fg else match_fg;
                const row_data = results_view.rowData(.{ .match = match }, .{
                    .mode = self.controller.viewMode(),
                    .show_line_numbers = self.controller.showLineNumbers(),
                });
                var line_buffer: [24]u8 = undefined;
                const line = if (row_data.line_number > 0)
                    std.fmt.bufPrint(&line_buffer, "{d}: ", .{row_data.line_number}) catch ""
                else
                    "";
                const indent = results_view.matchIndentCells(depth);
                var col = x + indent;
                col += drawText(grid, col, y, width -| (col - x), line, .{ .fg = dim_fg, .bg = bg });
                col += drawText(grid, col, y, width -| (col - x), preview.before, .{ .fg = base_fg, .bg = bg });
                col += drawText(grid, col, y, width -| (col - x), inside, .{ .fg = ui.cell.packColor(inside_color), .bg = bg, .attrs = ui.cell.Attr.bold });
                _ = drawText(grid, col, y, width -| (col - x), preview.after, .{ .fg = dim_fg, .bg = bg });
            },
        }
    }

    pub fn commandToggle(self: *SearchView, option: Option) void {
        self.toggleOption(option);
    }

    pub fn commandFocusNext(self: *SearchView) void {
        self.results_focused = true;
        self.moveToNextMatch(1);
    }

    pub fn commandFocusPrevious(self: *SearchView) void {
        self.results_focused = true;
        self.moveToNextMatch(-1);
    }

    pub fn commandRemove(self: *SearchView) void {
        self.dismissSelected();
    }

    pub fn commandReplace(self: *SearchView) void {
        self.replaceSelected();
    }

    pub fn commandReplaceAll(self: *SearchView) void {
        if (self.controller.requestReplaceAll() catch null) |request| {
            self.allocator.free(request.confirmation);
            self.allocator.free(request.after);
        }
        self.controller.executeReplaceAll() catch {};
        self.rebuildRows();
    }

    pub fn commandClear(self: *SearchView) void {
        self.controller.clearResults(true);
        self.rows.clearRetainingCapacity();
        self.depths.clearRetainingCapacity();
        self.selected = 0;
        self.scroll = 0;
        self.clearHighlight();
    }

    pub fn commandToggleDetails(self: *SearchView) void {
        self.controller.toggleQueryDetails(null);
    }

    pub fn activeEditorInfo(self: *SearchView) ?EditorInfo {
        _ = self;
        return null;
    }
};

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
    self.widget.replace_visible = visible;
    if (!visible and self.widget.focus_field == .replace) self.widget.focus_field = .search;
}

fn widgetDetailsVisible(context: *anyopaque) bool {
    const self: *SearchView = @ptrCast(@alignCast(context));
    return self.widget.details_visible;
}

fn widgetSetDetailsVisible(context: *anyopaque, visible: bool) void {
    const self: *SearchView = @ptrCast(@alignCast(context));
    self.widget.details_visible = visible;
}

fn widgetUseExcludes(context: *anyopaque) bool {
    const self: *SearchView = @ptrCast(@alignCast(context));
    return self.widget.use_excludes;
}

fn widgetFocus(context: *anyopaque, field: ControllerField) void {
    const self: *SearchView = @ptrCast(@alignCast(context));
    self.widget.focus_field = tuiField(field);
}

fn widgetCycleFocus(context: *anyopaque, backwards: bool) void {
    const self: *SearchView = @ptrCast(@alignCast(context));
    self.widget.cycleFocus(backwards);
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
    self.results_focused = true;
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

fn hostActiveEditor(context: *anyopaque) ?controller_mod.EditorInfo {
    const self: *SearchView = @ptrCast(@alignCast(context));
    const info = self.host.active_editor(self.host.context) orelse return null;
    return .{ .path = info.path, .version = info.version };
}

fn drawText(grid: *ui.CellGrid, x: usize, y: usize, max_width: usize, text: []const u8, style: ui.cell.PaintStyle) usize {
    var col = x;
    var offset: usize = 0;
    while (offset < text.len and col < x + max_width) {
        const decoded = ui.dom.decodeAt(text, offset);
        if (decoded.len == 0) break;
        const width = ui.dom.defaultMeasureWidth(decoded.cp);
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
