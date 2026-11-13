// Terminal Search view: the TUI counterpart of
// `src/vs/workbench/contrib/search/browser/searchView.ts` and
// `searchResultsView.ts`.
//
// The portable tree/query/replace behavior lives under
// `src/vs/workbench/contrib/search` and `src/vs/workbench/services/search`.
// This file owns terminal layout, focus, row painting, mouse handling and the
// workbench callbacks that open editors or apply replacement edits.
//
// Terminal adaptations:
// - the result tree is flattened into one windowed column instead of a
//   virtualized DOM tree;
// - the input rows are a small `ui.Surface` built by `searchWidget.zig`;
// - folder compression, multi-selection, context menus and drag/drop are not
//   ported;
// - opening a match is explicit (Enter/click) rather than focusing a browser
//   tree row.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const search = @import("../vs/workbench/services/search/common/search.zig");
const TextQuery = search.TextQuery;
const search_model = @import("../vs/workbench/contrib/search/browser/searchTreeModel/searchModel.zig");
const SearchModel = search_model.SearchModel;
const tree = @import("../vs/workbench/contrib/search/browser/searchTreeModel/searchTreeCommon.zig");
const SearchResult = tree.SearchResult;
const FileMatch = tree.FileMatch;
const FolderMatch = tree.FolderMatch;
const Match = tree.Match;
const ChangeEvent = tree.ChangeEvent;
const replace_service = @import("../vs/workbench/contrib/search/browser/replaceService.zig");
const ReplaceService = replace_service.ReplaceService;
const Edit = replace_service.Edit;
const SearchWidget = @import("searchWidget.zig").SearchWidget;
const Field = @import("searchWidget.zig").Field;
const Option = @import("searchWidget.zig").Option;
const comparers = @import("../vs/base/common/comparers.zig");
const time_compat = @import("../vs/base/common/timeCompat.zig");
const Range = @import("../vs/editor/common/core/range.zig").Range;
const workspace_context = @import("../vs/workbench/services/workspaces/common/workspaceContextService.zig");
const WorkspaceContextService = workspace_context.WorkspaceContextService;

const background = ui.Color{ .r = 30, .g = 30, .b = 33 };
const foreground = ui.Color{ .r = 210, .g = 210, .b = 210 };
const dim = ui.Color{ .r = 135, .g = 135, .b = 142 };
const header_background = ui.Color{ .r = 38, .g = 38, .b = 42 };
const selected_background = ui.Color{ .r = 55, .g = 65, .b = 80 };
const folder_color = ui.Color{ .r = 170, .g = 190, .b = 210 };
const match_color = ui.Color{ .r = 240, .g = 190, .b = 90 };
const replace_color = ui.Color{ .r = 120, .g = 210, .b = 120 };

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

pub const Row = union(enum) {
    heading,
    folder: *FolderMatch,
    file: *FileMatch,
    match: *Match,
};

pub const SearchView = struct {
    allocator: Allocator,
    workspace: *WorkspaceContextService,
    host: Host,
    model: *SearchModel,
    replace_service: *ReplaceService,
    widget: *SearchWidget,
    rows: std.array_list.Managed(Row),
    collapsed: std.StringHashMap(void),
    selected: usize = 0,
    scroll: usize = 0,
    last_rect: ui.Rect = .{},
    focus_field: Field = .search,
    results_focused: bool = false,
    status: std.array_list.Managed(u8),
    status_is_error: bool = false,
    debounce_at: ?i64 = null,
    refresh_at: ?i64 = null,
    result_dirty: bool = false,
    suppress_refresh: bool = false,
    last_editor_path: std.array_list.Managed(u8),
    last_editor_version: u32 = 0,
    panel_focused: bool = false,
    started_once: bool = false,

    pub fn init(
        allocator: Allocator,
        workspace: *WorkspaceContextService,
        service: search.ISearchService,
        replace: *ReplaceService,
        host: Host,
    ) !*SearchView {
        const self = try allocator.create(SearchView);
        errdefer allocator.destroy(self);
        const model = try SearchModel.init(allocator, service);
        errdefer model.deinit();
        const widget = try SearchWidget.init(allocator);
        errdefer widget.deinit();
        self.* = .{
            .allocator = allocator,
            .workspace = workspace,
            .host = host,
            .model = model,
            .replace_service = replace,
            .widget = widget,
            .rows = std.array_list.Managed(Row).init(allocator),
            .collapsed = std.StringHashMap(void).init(allocator),
            .status = std.array_list.Managed(u8).init(allocator),
            .last_editor_path = std.array_list.Managed(u8).init(allocator),
        };
        widget.callbacks = .{
            .context = self,
            .on_change = onWidgetChange,
            .on_submit = onWidgetSubmit,
            .on_escape = onWidgetEscape,
            .on_toggle = onWidgetToggle,
            .on_replace_all = onWidgetReplaceAll,
        };
        try model.result.listen(self, onResultChanged);
        try self.setWidgetValueFromSelection();
        return self;
    }

    pub fn deinit(self: *SearchView) void {
        self.clearHighlight();
        self.widget.deinit();
        self.model.deinit();
        self.rows.deinit();
        self.collapsed.deinit();
        self.status.deinit();
        self.last_editor_path.deinit();
        self.allocator.destroy(self);
    }

    pub fn focus(self: *SearchView) void {
        self.panel_focused = true;
        self.results_focused = false;
        self.focus_field = .search;
        self.widget.focus_field = .search;
    }

    pub fn focusReplace(self: *SearchView) void {
        self.widget.replace_visible = true;
        self.widget.focus_field = .replace;
        self.focus_field = .replace;
        self.panel_focused = true;
        self.results_focused = false;
    }

    pub fn seedFromSelection(self: *SearchView) !void {
        try self.setWidgetValueFromSelection();
    }

    pub fn blur(self: *SearchView) void {
        self.panel_focused = false;
    }

    pub fn focusResults(self: *SearchView) void {
        self.panel_focused = true;
        self.results_focused = true;
    }

    pub fn isFocused(self: *const SearchView) bool {
        return self.panel_focused;
    }

    pub fn wantsTick(self: *const SearchView) bool {
        return self.debounce_at != null or self.refresh_at != null or self.model.isSearching();
    }

    pub fn tick(self: *SearchView, now: i64) bool {
        var changed = false;
        if (self.refresh_at) |deadline| {
            if (now >= deadline) {
                self.refresh_at = null;
                self.startSearch() catch |err| self.report(err);
                changed = true;
            }
        }
        if (self.debounce_at) |deadline| {
            if (now >= deadline) {
                self.debounce_at = null;
                self.startSearch() catch |err| self.report(err);
                changed = true;
            }
        }
        if (self.model.isSearching()) {
            if (self.model.poll(16) catch |err| blk: {
                _ = self.model.cancelSearch();
                self.report(err);
                break :blk false;
            }) {
                self.result_dirty = true;
                changed = true;
            }
        }
        if (!self.model.isSearching() and std.mem.eql(u8, self.status.items, "Searching...")) {
            self.status.clearRetainingCapacity();
        }
        if (self.result_dirty) {
            self.result_dirty = false;
            self.rebuildRows();
            changed = true;
        }
        return changed;
    }

    fn onResultChanged(event: ChangeEvent, context: *SearchView) !void {
        _ = event;
        context.result_dirty = true;
    }

    pub fn setStatus(self: *SearchView, text: []const u8, is_error: bool) void {
        self.status.clearRetainingCapacity();
        self.status.appendSlice(text) catch {};
        self.status_is_error = is_error;
    }

    fn report(self: *SearchView, err: anyerror) void {
        var buffer: [160]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "search failed: {s}", .{@errorName(err)}) catch "search failed";
        self.setStatus(message, true);
        self.rebuildRows();
    }

    fn setWidgetValueFromSelection(self: *SearchView) !void {
        if (self.host.active_selection_text(self.host.context, self.allocator) catch null) |text| {
            defer self.allocator.free(text);
            if (text.len > 0) try self.widget.setValue(.search, text);
        }
    }

    fn onWidgetChange(context: ?*anyopaque, field: Field, value: []const u8) void {
        const self: *SearchView = @ptrCast(@alignCast(context orelse return));
        switch (field) {
            .search, .includes, .excludes => {
                self.debounce_at = time_compat.milliTimestamp() + 200;
            },
            .replace => {
                self.model.setReplaceString(value) catch {};
            },
        }
    }

    fn onWidgetSubmit(context: ?*anyopaque, field: Field) void {
        const self: *SearchView = @ptrCast(@alignCast(context orelse return));
        switch (field) {
            .search, .includes, .excludes => {
                self.debounce_at = null;
                self.startSearch() catch |err| self.report(err);
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
            return;
        }
        self.panel_focused = false;
    }

    fn onWidgetToggle(context: ?*anyopaque, option: Option) void {
        const self: *SearchView = @ptrCast(@alignCast(context orelse return));
        self.toggleOption(option);
    }

    fn onWidgetReplaceAll(context: ?*anyopaque) void {
        const self: *SearchView = @ptrCast(@alignCast(context orelse return));
        self.replaceAll();
    }

    fn toggleOption(self: *SearchView, option: Option) void {
        switch (option) {
            .match_case => self.widget.match_case = !self.widget.match_case,
            .whole_word => self.widget.whole_word = !self.widget.whole_word,
            .regex => self.widget.regex = !self.widget.regex,
            .preserve_case => {
                self.widget.preserve_case = !self.widget.preserve_case;
                self.model.setPreserveCase(self.widget.preserve_case);
                return;
            },
        }
        self.debounce_at = null;
        self.startSearch() catch |err| self.report(err);
    }

    pub fn startSearch(self: *SearchView) !void {
        const pattern = std.mem.trim(u8, self.widget.value(.search), " \t\r\n");
        if (pattern.len == 0) {
            self.model.clear();
            self.rows.clearRetainingCapacity();
            self.selected = 0;
            self.scroll = 0;
            self.setStatus("", false);
            self.clearHighlight();
            return;
        }

        var folder_paths = std.array_list.Managed([]const u8).init(self.allocator);
        defer folder_paths.deinit();
        for (self.workspace.getWorkspace().folders.items) |*folder| {
            try folder_paths.append(folder.resource);
        }

        const extras = self.host.extra_files(self.host.context, self.allocator) catch null;
        defer if (extras) |paths| self.host.free_paths(self.host.context, self.allocator, paths);
        var extra_slices = std.array_list.Managed([]const u8).init(self.allocator);
        defer extra_slices.deinit();
        if (extras) |paths| {
            for (paths) |path| try extra_slices.append(path);
        }

        var query = try TextQuery.init(
            self.allocator,
            pattern,
            folder_paths.items,
            self.widget.value(.includes),
            self.widget.value(.excludes),
            extra_slices.items,
        );
        query.is_regex = self.widget.regex;
        query.is_word_match = self.widget.whole_word;
        query.is_case_sensitive = self.widget.match_case;
        query.preview = .{
            .match_lines = 1,
            .chars_per_line = if (self.widget.regex) 10000 else 1000,
        };

        self.rows.clearRetainingCapacity();
        self.selected = 0;
        self.scroll = 0;
        self.clearHighlight();
        self.setStatus("Searching...", false);
        const accepted = try self.model.search(query);
        if (!accepted) {
            self.setStatus("Invalid regular expression", true);
        }
        self.result_dirty = true;
    }

    pub fn onEditorChanged(self: *SearchView, info: ?EditorInfo) void {
        if (info == null) return;
        const current = info.?;
        if (current.version == self.last_editor_version and
            std.mem.eql(u8, self.last_editor_path.items, current.path)) return;
        self.last_editor_version = current.version;
        self.last_editor_path.clearRetainingCapacity();
        self.last_editor_path.appendSlice(current.path) catch {};
        if (self.suppress_refresh) return;
        if (self.model.query == null) return;
        if (self.model.result.isEmpty()) return;
        self.refresh_at = time_compat.milliTimestamp() + 500;
    }

    pub fn setWorkspace(self: *SearchView, workspace: *WorkspaceContextService) void {
        self.workspace = workspace;
    }

    fn clearHighlight(self: *SearchView) void {
        self.host.highlight_range(self.host.context, "", null);
    }

    fn selectedRow(self: *const SearchView) ?Row {
        if (self.selected >= self.rows.items.len) return null;
        return self.rows.items[self.selected];
    }

    fn rowId(row: Row) []const u8 {
        return switch (row) {
            .heading => "heading",
            .folder => |folder| folder.id,
            .file => |file| file.id,
            .match => |match| match.id,
        };
    }

    fn rowExpanded(self: *const SearchView, row: Row) bool {
        return !self.collapsed.contains(rowId(row));
    }

    fn toggleRow(self: *SearchView, row: Row) void {
        const id = rowId(row);
        if (self.collapsed.contains(id)) {
            _ = self.collapsed.remove(id);
        } else {
            self.collapsed.put(id, {}) catch {};
        }
        self.rebuildRows();
    }

    fn rebuildRows(self: *SearchView) void {
        self.rows.clearRetainingCapacity();
        self.rows.append(.heading) catch return;
        if (!self.rowExpanded(.heading)) {
            self.clampSelection();
            return;
        }
        const folders = self.model.result.folderMatches(self.allocator) catch return;
        defer self.allocator.free(folders);
        std.sort.heap(*FolderMatch, folders, {}, folderLessThan);
        for (folders) |folder| self.appendFolder(folder, 0);
        self.clampSelection();
    }

    fn folderLessThan(_: void, a: *FolderMatch, b: *FolderMatch) bool {
        return a.index < b.index;
    }

    fn appendFolder(self: *SearchView, folder: *FolderMatch, depth: usize) void {
        self.rows.append(.{ .folder = folder }) catch return;
        if (!self.rowExpanded(.{ .folder = folder })) return;
        var folders = std.array_list.Managed(*FolderMatch).init(self.allocator);
        defer folders.deinit();
        folders.appendSlice(folder.folders.items) catch {};
        std.sort.heap(*FolderMatch, folders.items, {}, folderLessThan);
        for (folders.items) |child| self.appendFolder(child, depth + 1);

        var files = std.array_list.Managed(*FileMatch).init(self.allocator);
        defer files.deinit();
        files.appendSlice(folder.files.items) catch {};
        std.sort.heap(*FileMatch, files.items, {}, fileLessThan);
        for (files.items) |file| {
            self.rows.append(.{ .file = file }) catch return;
            if (!self.rowExpanded(.{ .file = file })) continue;
            for (file.matches()) |match| self.rows.append(.{ .match = match }) catch return;
        }
    }

    fn fileLessThan(_: void, a: *FileMatch, b: *FileMatch) bool {
        return comparers.comparePaths(a.path, b.path) < 0;
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
        self.highlightSelected();
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
            .match => |match| {
                self.host.open_match(self.host.context, match.parent_file.path, match.range()) catch |err| self.report(err);
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
        self.suppress_refresh = true;
        defer self.suppress_refresh = false;
        switch (row) {
            .match => |match| self.model.result.removeMatch(match),
            .file => |file| self.model.result.removeFile(file),
            .folder => |folder| {
                const files = folder.allDownstreamFiles(self.allocator) catch return;
                defer self.allocator.free(files);
                for (files) |file| self.model.result.removeFile(file);
            },
            .heading => return,
        }
        self.result_dirty = true;
        self.rebuildRows();
    }

    fn replaceSelected(self: *SearchView) void {
        const row = self.selectedRow() orelse return;
        var files = std.array_list.Managed(*FileMatch).init(self.allocator);
        defer files.deinit();
        switch (row) {
            .match => |match| {
                const pattern = self.model.replacePattern() orelse {
                    self.setStatus("No replace pattern", true);
                    return;
                };
                self.suppress_refresh = true;
                defer self.suppress_refresh = false;
                var selected_matches = [1]*Match{match};
                self.replace_service.replaceMatches(self.allocator, &selected_matches, pattern, self.model.preserve_case) catch |err| {
                    self.report(err);
                    return;
                };
                self.model.result.removeMatch(match);
                self.result_dirty = true;
                self.rebuildRows();
                return;
            },
            .file => |file| files.append(file) catch return,
            .folder => |folder| {
                const all = folder.allDownstreamFiles(self.allocator) catch return;
                defer self.allocator.free(all);
                files.appendSlice(all) catch return;
            },
            .heading => {
                self.replaceAll();
                return;
            },
        }
        self.replaceFiles(files.items);
    }

    fn replaceAll(self: *SearchView) void {
        const files = self.model.result.matches(self.allocator) catch return;
        defer self.allocator.free(files);
        self.replaceFiles(files);
        self.model.result.clear();
    }

    fn replaceFiles(self: *SearchView, files: []*FileMatch) void {
        const pattern = self.model.replacePattern() orelse {
            self.setStatus("No replace pattern", true);
            return;
        };
        self.suppress_refresh = true;
        defer self.suppress_refresh = false;
        self.replace_service.replaceFiles(
            self.allocator,
            files,
            pattern,
            self.model.preserve_case,
        ) catch |err| {
            self.report(err);
            return;
        };
        for (files) |file| self.model.result.removeFile(file);
        self.result_dirty = true;
        self.rebuildRows();
    }

    pub fn handleKey(self: *SearchView, event: *const ui.KeyEvent) Action {
        if (event.key == .escape) {
            if (self.widget.replace_visible and self.focus_field == .replace) {
                self.widget.toggleReplace();
                self.focus_field = .search;
                return .handled;
            }
            _ = self.model.cancelSearch();
            self.panel_focused = false;
            self.clearHighlight();
            return .focus_editor;
        }

        if (event.key == .tab or event.key == .backtab) {
            self.results_focused = false;
            self.widget.cycleFocus(event.key == .backtab);
            self.focus_field = self.widget.focus_field;
            return .handled;
        }

        if (event.mods.ctrl and !event.mods.alt) {
            if (event.key == .char) {
                const ch = event.key.char;
                if (ch == 'r' or ch == 'R') {
                    self.widget.toggleReplace();
                    self.focus_field = if (self.widget.replace_visible) .replace else .search;
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
                    self.widget.toggleDetails();
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
            self.replaceAll();
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
                    self.debounce_at = null;
                    self.startSearch() catch |err| self.report(err);
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
        if (local_y == 0) {
            if (event.kind == .down and local_x >= width -| 3) {
                self.widget.toggleDetails();
                return true;
            }
            return true;
        }

        const input_top = 1;
        const input_bottom = input_top + self.widget.layout.height;
        if (local_y >= input_top and local_y < input_bottom) {
            self.panel_focused = true;
            self.results_focused = false;
            var local = event.*;
            local.x = local_x;
            local.y = local_y - input_top;
            if (self.widget.handleMouse(local_x, local_y - input_top, &local)) {
                self.focus_field = self.widget.focus_field;
            }
            return true;
        }

        const results_top = input_bottom + 1;
        if (local_y < results_top) return true;
        const row = local_y - results_top + self.scroll;
        if (row >= self.rows.items.len) return true;
        if (event.kind == .wheel) {
            if (event.delta_y > 0) {
                self.scroll = @min(self.rows.items.len -| 1, self.scroll + 3);
            } else if (event.delta_y < 0) {
                self.scroll -|= 3;
            }
            return true;
        }
        if (event.kind == .move) return true;
        self.panel_focused = true;
        self.results_focused = true;
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

    pub fn render(self: *SearchView, grid: *ui.CellGrid, rect: ui.Rect) !void {
        self.last_rect = rect;
        const x = ui.cell.snap(rect.x);
        const y = ui.cell.snap(rect.y);
        const width = ui.cell.snap(rect.w);
        const height = ui.cell.snap(rect.h);
        if (width == 0 or height == 0) return;

        const base = ui.cell.PaintStyle{ .fg = ui.cell.packColor(foreground), .bg = ui.cell.packColor(background) };
        grid.fillRect(@floatFromInt(x), @floatFromInt(y), @floatFromInt(width), @floatFromInt(height), base);

        const header_style = ui.cell.PaintStyle{ .fg = ui.cell.packColor(foreground), .bg = ui.cell.packColor(header_background) };
        grid.fillRect(@floatFromInt(x), @floatFromInt(y), @floatFromInt(width), 1, header_style);
        _ = drawText(grid, x + 1, y, width -| 1, if (self.panel_focused) " SEARCH " else " Search ", header_style);
        _ = drawText(grid, x + width -| 3, y, 3, "...", .{ .fg = ui.cell.packColor(dim), .bg = ui.cell.packColor(header_background) });

        try self.widget.render(width);
        grid.blit(self.widget.grid(), x, y + 1, width, self.widget.layout.height);

        const status_y = y + 1 + self.widget.layout.height;
        var status_buffer: [160]u8 = undefined;
        const status = if (self.status.items.len > 0)
            self.status.items
        else if (self.model.isSearching())
            "Searching..."
        else if (self.model.limitHit())
            "Result limit reached"
        else if (self.model.result.count() == 0 and self.workspace.getWorkspace().folders.items.len == 0)
            "No workspace folder"
        else if (self.model.result.count() == 0)
            "No results"
        else
            std.fmt.bufPrint(&status_buffer, "{d} results in {d} files", .{ self.model.result.count(), self.model.result.fileCount() }) catch "";
        const status_style = ui.cell.PaintStyle{
            .fg = ui.cell.packColor(if (self.status_is_error) ui.Color{ .r = 240, .g = 120, .b = 120 } else dim),
            .bg = ui.cell.packColor(background),
        };
        if (status_y < y + height) {
            _ = drawText(grid, x + 1, status_y, width -| 2, status, status_style);
        }

        const top = status_y + 1;
        const rows = if (top < y + height) y + height - top else 0;
        if (rows == 0) return;
        if (self.selected < self.scroll) self.scroll = self.selected;
        if (self.selected >= self.scroll + rows) self.scroll = self.selected - rows + 1;

        var visible: usize = 0;
        while (visible < rows) : (visible += 1) {
            const index = self.scroll + visible;
            if (index >= self.rows.items.len) break;
            const row_y = top + visible;
            const selected = index == self.selected;
            if (selected) {
                grid.fillRect(@floatFromInt(x), @floatFromInt(row_y), @floatFromInt(width), 1, .{
                    .fg = ui.cell.packColor(foreground),
                    .bg = ui.cell.packColor(selected_background),
                });
            }
            self.renderRow(grid, x, row_y, width, self.rows.items[index], selected);
        }
    }

    fn renderRow(self: *SearchView, grid: *ui.CellGrid, x: usize, y: usize, width: usize, row: Row, selected: bool) void {
        _ = selected;
        const base_fg = ui.cell.packColor(foreground);
        const dim_fg = ui.cell.packColor(dim);
        const bg = ui.cell.packColor(if (false) header_background else background);
        _ = bg;
        switch (row) {
            .heading => {
                _ = drawText(grid, x + 1, y, width -| 2, "Text Results", .{ .fg = base_fg, .attrs = ui.cell.Attr.bold });
            },
            .folder => |folder| {
                const expanded = self.rowExpanded(row);
                var buffer: [160]u8 = undefined;
                const text = std.fmt.bufPrint(&buffer, "{s} {s} ({d})", .{
                    if (expanded) "▾" else "▸",
                    folder.name,
                    folder.recursiveMatchCount(),
                }) catch folder.name;
                const indent = 1 + folderDepth(folder) * 2;
                _ = drawText(grid, x + indent, y, width -| indent, text, .{ .fg = ui.cell.packColor(folder_color) });
            },
            .file => |file| {
                const expanded = self.rowExpanded(row);
                var buffer: [200]u8 = undefined;
                const text = std.fmt.bufPrint(&buffer, "{s} {s} ({d})", .{
                    if (expanded) "▾" else "▸",
                    file.name,
                    file.count(),
                }) catch file.name;
                const indent = 1 + (folderDepth(file.parent_folder) + 1) * 2;
                _ = drawText(grid, x + indent, y, width -| indent, text, .{ .fg = base_fg });
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
                const inside_color = if (replacement != null) replace_color else match_color;
                var line_buffer: [24]u8 = undefined;
                const line = std.fmt.bufPrint(&line_buffer, "{d}: ", .{match.range().startLineNumber}) catch "";
                const indent = 1 + (folderDepth(match.parent_file.parent_folder) + 1) * 2 + 1;
                var col = x + indent;
                col += drawText(grid, col, y, width -| (col - x), line, .{ .fg = dim_fg });
                col += drawText(grid, col, y, width -| (col - x), preview.before, .{ .fg = base_fg });
                col += drawText(grid, col, y, width -| (col - x), inside, .{ .fg = ui.cell.packColor(inside_color), .attrs = ui.cell.Attr.bold });
                _ = drawText(grid, col, y, width -| (col - x), preview.after, .{ .fg = dim_fg });
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
        self.replaceAll();
    }

    pub fn commandClear(self: *SearchView) void {
        self.model.clear();
        self.widget.setValue(.search, "") catch {};
        self.widget.setValue(.replace, "") catch {};
        self.model.setReplaceString("") catch {};
        self.debounce_at = null;
        self.rows.clearRetainingCapacity();
        self.status.clearRetainingCapacity();
        self.status_is_error = false;
        self.selected = 0;
        self.scroll = 0;
        self.clearHighlight();
    }

    pub fn commandToggleDetails(self: *SearchView) void {
        self.widget.toggleDetails();
    }

    pub fn activeEditorInfo(self: *SearchView) ?EditorInfo {
        _ = self;
        return null;
    }
};

fn folderDepth(folder: *FolderMatch) usize {
    var depth: usize = 0;
    var current: ?*FolderMatch = folder.parent_folder;
    while (current) |parent| : (current = parent.parent_folder) depth += 1;
    return depth;
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
