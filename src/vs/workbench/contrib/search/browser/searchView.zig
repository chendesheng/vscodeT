// Portable Search view controller, ported from
// `src/vs/workbench/contrib/search/browser/searchView.ts`.
//
// The controller owns the query/model lifecycle, result counts and messages,
// navigation, open, and replace-all requests. DOM layout, input editing,
// row painting, context menus and AI/notebook/search-editor results stay in
// the terminal adapter or are not ported.
//
// Terminal adaptations:
// - the result tree is flattened by the TUI; the controller talks to a
//   `Viewer` over the visible rows (`searchActionsBase.zig`);
// - the input widget is a `Widget` vtable over `searchWidget.zig`;
// - replace-all confirmation is exposed as a request/execute pair so the TUI
//   can use its inline message row instead of a native dialog;
// - messages are plain text (no command links, ARIA live regions or progress).

const std = @import("std");
const Allocator = std.mem.Allocator;
const time_compat = @import("../../../../base/common/timeCompat.zig");
const Range = @import("../../../../editor/common/core/range.zig").Range;
const tree = @import("searchTreeModel/searchTreeCommon.zig");
const Node = tree.Node;
const Match = tree.Match;
const FileMatch = tree.FileMatch;
const FolderMatch = tree.FolderMatch;
const SearchResult = tree.SearchResult;
const SearchModel = @import("searchTreeModel/searchModel.zig").SearchModel;
const replace_service_mod = @import("replaceService.zig");
const ReplaceService = replace_service_mod.ReplaceService;
const ReplacePattern = @import("../../../services/search/common/replace.zig").ReplacePattern;
const search = @import("../../../services/search/common/search.zig");
const TextQuery = search.TextQuery;
const PatternInfo = search.PatternInfo;
const ViewMode = search.ViewMode;
const SearchSortOrder = search.SearchSortOrder;
const ISearchService = search.ISearchService;
const query_builder = @import("../../../services/search/common/queryBuilder.zig");
const QueryBuilder = query_builder.QueryBuilder;
const TextQueryBuilderOptions = query_builder.TextQueryBuilderOptions;
const configuration_mod = @import("../../../services/configuration/browser/configurationService.zig");
const ConfigurationService = configuration_mod.ConfigurationService;
const workspace_context = @import("../../../services/workspaces/common/workspaceContextService.zig");
const WorkspaceContextService = workspace_context.WorkspaceContextService;
const search_common = @import("../common/search.zig");
const SearchUIState = search_common.SearchUIState;
const base = @import("searchActionsBase.zig");
const Viewer = base.Viewer;

pub const Field = enum { search, replace, includes, excludes };
pub const Option = enum { match_case, whole_word, regex, preserve_case };
pub const Focus = enum { search, replace, includes, excludes, results };
pub const MessageKind = enum { info, warning, err };

pub const Message = struct {
    text: []u8,
    kind: MessageKind = .info,
};

pub const Widget = struct {
    context: *anyopaque,
    value: *const fn (context: *anyopaque, field: Field) []const u8,
    set_value: *const fn (context: *anyopaque, field: Field, value: []const u8) anyerror!void,
    clear: *const fn (context: *anyopaque, field: Field) void,
    option: *const fn (context: *anyopaque, option: Option) bool,
    set_option: *const fn (context: *anyopaque, option: Option, value: bool) void,
    replace_visible: *const fn (context: *anyopaque) bool,
    set_replace_visible: *const fn (context: *anyopaque, visible: bool) void,
    details_visible: *const fn (context: *anyopaque) bool,
    set_details_visible: *const fn (context: *anyopaque, visible: bool) void,
    use_excludes: *const fn (context: *anyopaque) bool,
    focus: *const fn (context: *anyopaque, field: Field) void,
    cycle_focus: *const fn (context: *anyopaque, backwards: bool) void,
};

pub const Host = struct {
    context: *anyopaque,
    open_match: *const fn (context: *anyopaque, path: []const u8, range: ?Range, preserve_focus: bool, side_by_side: bool) anyerror!void,
    highlight_range: *const fn (context: *anyopaque, path: []const u8, range: ?Range) void,
    apply_edits: *const fn (context: *anyopaque, path: []const u8, edits: []const replace_service_mod.Edit) anyerror!void,
    save_file: *const fn (context: *anyopaque, path: []const u8) anyerror!void,
    active_selection_text: *const fn (context: *anyopaque, allocator: Allocator) anyerror!?[]u8,
    extra_files: *const fn (context: *anyopaque, allocator: Allocator) anyerror![][]u8,
    free_paths: *const fn (context: *anyopaque, allocator: Allocator, paths: [][]u8) void,
};

pub const ReplaceAllRequest = struct {
    occurrences: usize,
    file_count: usize,
    confirmation: []u8,
    after: []u8,
};

pub const Context = struct {
    view_focused: bool = false,
    input_box_focused: bool = false,
    search_input_focused: bool = false,
    replace_input_focused: bool = false,
    includes_focused: bool = false,
    excludes_focused: bool = false,
    replace_active: bool = false,
    has_results: bool = false,
    match_focus: bool = false,
    file_focus: bool = false,
    folder_focus: bool = false,
    file_or_match_focus: bool = false,
    file_or_folder_focus: bool = false,
    editable_item: bool = true,
    tree_view: bool = false,
    has_search_pattern: bool = false,
    has_replace_pattern: bool = false,
    has_file_pattern: bool = false,
};

pub const SearchView = struct {
    allocator: Allocator,
    workspace: *WorkspaceContextService,
    configuration: *ConfigurationService,
    service: ISearchService,
    host: Host,
    widget: Widget,
    viewer: Viewer,
    model: *SearchModel,
    replace_service: ReplaceService,
    state: SearchUIState = .idle,
    focus: Focus = .search,
    last_focus_input: bool = true,
    panel_focused: bool = false,
    view_mode: ViewMode = .list,
    messages: std.array_list.Managed(Message),
    debounce_at: ?i64 = null,
    refresh_at: ?i64 = null,
    search_started_at: ?i64 = null,
    last_search_count: usize = 0,
    last_search_files: usize = 0,
    pending_replace_all: ?ReplaceAllRequest = null,

    pub fn init(
        allocator: Allocator,
        workspace: *WorkspaceContextService,
        configuration: *ConfigurationService,
        service: ISearchService,
        host: Host,
        widget: Widget,
        viewer: Viewer,
    ) !*SearchView {
        const self = try allocator.create(SearchView);
        errdefer allocator.destroy(self);
        const model = try SearchModel.init(allocator, service);
        errdefer model.deinit();
        const view_mode = readViewMode(configuration);
        self.* = .{
            .allocator = allocator,
            .workspace = workspace,
            .configuration = configuration,
            .service = service,
            .host = host,
            .widget = widget,
            .viewer = viewer,
            .model = model,
            .replace_service = ReplaceService.init(allocator, .{
                .context = host.context,
                .apply_edits = host.apply_edits,
                .save_file = host.save_file,
            }),
            .view_mode = view_mode,
            .messages = std.array_list.Managed(Message).init(allocator),
        };
        try model.result.listen(self, onResultChanged);
        return self;
    }

    pub fn deinit(self: *SearchView) void {
        self.clearMessages();
        self.messages.deinit();
        self.model.deinit();
        self.allocator.destroy(self);
    }

    pub fn setViewer(self: *SearchView, viewer: Viewer) void {
        self.viewer = viewer;
    }

    pub fn searchModel(self: *SearchView) *SearchModel {
        return self.model;
    }

    pub fn replaceService(self: *SearchView) *ReplaceService {
        return &self.replace_service;
    }

    pub fn hasSearchResults(self: *const SearchView) bool {
        return !self.model.result.isEmpty();
    }

    pub fn matchCount(self: *const SearchView) usize {
        return self.model.result.count();
    }

    pub fn stateValue(self: *const SearchView) SearchUIState {
        return self.state;
    }

    pub fn viewMode(self: *const SearchView) ViewMode {
        return self.view_mode;
    }

    pub fn sortOrder(self: *const SearchView) SearchSortOrder {
        return readSortOrder(self.configuration);
    }

    pub fn showLineNumbers(self: *const SearchView) bool {
        return self.configuration.getBool("search.showLineNumbers", false);
    }

    pub fn setPanelFocused(self: *SearchView, focused: bool) void {
        self.panel_focused = focused;
    }

    pub fn isFocused(self: *const SearchView) bool {
        return self.panel_focused;
    }

    pub fn focusView(self: *SearchView) void {
        self.panel_focused = true;
        if (self.last_focus_input or !self.hasSearchResults()) {
            self.focus = .search;
            self.widget.focus(self.widget.context, .search);
            self.last_focus_input = true;
        } else {
            self.focus = .results;
            self.viewer.focusView();
        }
    }

    pub fn focusReplace(self: *SearchView) void {
        self.panel_focused = true;
        self.widget.set_replace_visible(self.widget.context, true);
        self.focus = .replace;
        self.widget.focus(self.widget.context, .replace);
        self.last_focus_input = true;
    }

    pub fn focusResults(self: *SearchView) void {
        self.panel_focused = true;
        self.focus = .results;
        self.last_focus_input = false;
        self.viewer.focusView();
    }

    pub fn blur(self: *SearchView) void {
        self.panel_focused = false;
    }

    pub fn seedFromSelection(self: *SearchView) !void {
        const text = try self.host.active_selection_text(self.host.context, self.allocator) orelse return;
        defer self.allocator.free(text);
        if (text.len == 0) return;
        try self.widget.set_value(self.widget.context, .search, text);
    }

    /// Debounced entry point for input changes when `search.searchOnType` is
    /// enabled. The replace field only refreshes the replace preview.
    pub fn onQueryInputChanged(self: *SearchView, field: Field) void {
        defer self.scheduleDeadline();
        if (field == .replace) {
            self.model.setReplaceString(self.widget.value(self.widget.context, .replace)) catch {};
            self.viewer.refreshView();
            return;
        }
        if (!self.configuration.getBool("search.searchOnType", true)) return;
        const period = self.configuration.getValue("search.searchOnTypeDebouncePeriod", .{}) orelse
            null;
        const delay: i64 = if (period) |value| switch (value.*) {
            .integer => |inner| @intCast(inner),
            else => 300,
        } else 300;
        self.debounce_at = time_compat.milliTimestamp() + @max(delay, 0);
    }

    pub fn submitQuery(self: *SearchView) !void {
        self.debounce_at = null;
        try self.triggerQueryChange(false, false);
    }

    pub fn triggerQueryChange(self: *SearchView, preserve_focus: bool, triggered_on_type: bool) !void {
        defer self.scheduleDeadline();
        // A new query supersedes any pending refresh scheduled by an earlier
        // editor/content or configuration change.
        self.refresh_at = null;
        self.state = .idle;
        self.search_started_at = null;
        const pattern = std.mem.trim(u8, self.widget.value(self.widget.context, .search), " \t\r\n");
        if (pattern.len == 0) {
            self.clearResults(false);
            return;
        }

        const include = std.mem.trim(u8, self.widget.value(self.widget.context, .includes), " \t\r\n");
        const exclude = std.mem.trim(u8, self.widget.value(self.widget.context, .excludes), " \t\r\n");
        const extras = self.host.extra_files(self.host.context, self.allocator) catch null;
        defer if (extras) |paths| self.host.free_paths(self.host.context, self.allocator, paths);
        var extra_slices = std.array_list.Managed([]const u8).init(self.allocator);
        defer extra_slices.deinit();
        if (extras) |paths| {
            for (paths) |path| try extra_slices.append(path);
        }

        const builder = QueryBuilder.init(self.allocator, self.configuration, self.workspace);
        const query = builder.text(
            .{
                .pattern = pattern,
                .is_regex = self.widget.option(self.widget.context, .regex),
                .is_word_match = self.widget.option(self.widget.context, .whole_word),
                .is_case_sensitive = self.widget.option(self.widget.context, .match_case),
            },
            .{
                .include_pattern = include,
                .exclude_pattern = exclude,
                .extra_files = extra_slices.items,
                .use_excludes_and_ignore_files = self.widget.use_excludes(self.widget.context),
                .is_smart_case = self.configuration.getBool("search.smartCase", false),
            },
        ) catch {
            self.setSingleMessage("Search query could not be created", .err);
            self.model.clear();
            self.viewer.refreshView();
            return;
        };
        self.model.setReplaceString(self.widget.value(self.widget.context, .replace)) catch {};
        self.model.setPreserveCase(self.widget.option(self.widget.context, .preserve_case));
        const accepted = self.model.search(query) catch |err| {
            self.setSingleMessage(searchErrorMessage(err), .err);
            self.viewer.refreshView();
            return;
        };
        if (!accepted) {
            self.setSingleMessage("Invalid regular expression", .err);
            self.model.clear();
            self.viewer.refreshView();
            return;
        }

        self.state = .searching;
        self.search_started_at = time_compat.milliTimestamp();
        self.clearMessages();
        self.pending_replace_all = null;
        self.viewer.refreshView();
        if (!preserve_focus) self.widget.focus(self.widget.context, .search);
        _ = triggered_on_type;
    }

    fn searchErrorMessage(err: anyerror) []const u8 {
        return switch (err) {
            error.InvalidSearchPattern => "Invalid regular expression",
            error.InvalidSearchQuery => "Invalid search query",
            else => @errorName(err),
        };
    }

    fn scheduleDeadline(self: *SearchView) void {
        var next = self.debounce_at;
        if (self.refresh_at) |at| next = @min(next orelse at, at);
        if (self.state == .searching) {
            if (self.search_started_at) |start| next = @min(next orelse (start + 2000), start + 2000);
        }
        self.model.delivery.timer.schedule(next);
    }

    pub fn dispatch(self: *SearchView, now: i64, progress: bool) !bool {
        defer self.scheduleDeadline();
        var changed = false;
        if (self.debounce_at) |deadline| {
            if (now >= deadline) {
                self.debounce_at = null;
                self.triggerQueryChange(true, true) catch |err| {
                    self.setSingleMessage(@errorName(err), .err);
                };
                changed = true;
            }
        }
        if (self.refresh_at) |deadline| {
            if (now >= deadline) {
                self.refresh_at = null;
                self.triggerQueryChange(true, false) catch |err| {
                    self.setSingleMessage(searchErrorMessage(err), .err);
                };
                changed = true;
            }
        }

        if (self.state == .searching and self.search_started_at != null and
            now - self.search_started_at.? >= 2000)
        {
            self.state = .slow_search;
            changed = true;
        }

        if (progress and self.model.isSearching()) {
            const step_changed = self.model.onSearchProgress(16) catch |err| blk: {
                _ = self.model.cancelSearch();
                self.setSingleMessage(searchErrorMessage(err), .err);
                break :blk true;
            };
            if (step_changed) {
                self.updateSearchResultCount(false);
                self.viewer.refreshView();
                changed = true;
            }
            if (!self.model.isSearching()) {
                self.state = .idle;
                self.search_started_at = null;
                self.finalizeSearch();
                changed = true;
            }
            if (self.model.takeMessage()) |message| {
                const kind: MessageKind = switch (message.kind) {
                    .info => .info,
                    .warning => .warning,
                    .err => .err,
                };
                self.setOwnedMessage(message.text, kind);
                changed = true;
            }
        }
        return changed;
    }

    pub fn isSearchPending(self: *const SearchView) bool {
        return self.debounce_at != null or self.refresh_at != null or
            self.model.isSearching() or self.state == .searching or self.state == .slow_search;
    }

    pub fn cancelSearch(self: *SearchView) bool {
        defer self.scheduleDeadline();
        self.debounce_at = null;
        self.refresh_at = null;
        const cancelled = self.model.cancelSearch();
        self.state = .idle;
        self.search_started_at = null;
        if (cancelled and self.model.result.isEmpty()) {
            self.setSingleMessage("Search was canceled before any results could be found - ", .warning);
        }
        self.viewer.refreshView();
        return cancelled;
    }

    pub fn clearResults(self: *SearchView, clear_input: bool) void {
        defer self.scheduleDeadline();
        _ = self.model.cancelSearch();
        self.model.clear();
        self.state = .idle;
        self.search_started_at = null;
        self.clearMessages();
        self.pending_replace_all = null;
        if (clear_input) {
            self.widget.clear(self.widget.context, .search);
            self.widget.clear(self.widget.context, .replace);
            self.model.setReplaceString("") catch {};
            if (self.allFilePatternFieldsClear()) {
                self.widget.clear(self.widget.context, .includes);
                self.widget.clear(self.widget.context, .excludes);
            }
        }
        self.viewer.refreshView();
        self.viewer.select(null);
    }

    fn allFilePatternFieldsClear(self: *const SearchView) bool {
        return self.widget.value(self.widget.context, .includes).len == 0 and
            self.widget.value(self.widget.context, .excludes).len == 0;
    }

    fn finalizeSearch(self: *SearchView) void {
        self.updateSearchResultCount(true);
    }

    fn onResultChanged(change: tree.ChangeEvent, self: *SearchView) !void {
        if (change.force_update_model) {
            self.updateSearchResultCount(self.state == .idle);
            self.viewer.refreshView();
        }
    }

    fn updateSearchResultCount(self: *SearchView, final: bool) void {
        const count = self.model.result.count();
        const file_count = self.model.result.fileCount();
        self.last_search_count = count;
        self.last_search_files = file_count;

        if (count > 0) {
            const message = buildResultCountMessage(self.allocator, count, file_count) catch return;
            self.setOwnedMessage(message, .info);
        } else if (final and self.state == .idle) {
            self.setNoResultsMessage();
        }
    }

    fn setNoResultsMessage(self: *SearchView) void {
        const include = std.mem.trim(u8, self.widget.value(self.widget.context, .includes), " \t\r\n");
        const exclude = std.mem.trim(u8, self.widget.value(self.widget.context, .excludes), " \t\r\n");
        const text = if (include.len > 0 and exclude.len > 0)
            std.fmt.allocPrint(self.allocator, "No results found in '{s}' excluding '{s}' - ", .{ include, exclude }) catch return
        else if (include.len > 0)
            std.fmt.allocPrint(self.allocator, "No results found in '{s}' - ", .{include}) catch return
        else if (exclude.len > 0)
            std.fmt.allocPrint(self.allocator, "No results found excluding '{s}' - ", .{exclude}) catch return
        else
            self.allocator.dupe(u8, "No results found. Review your configured exclusions and check your gitignore files - ") catch return;
        self.setOwnedMessage(text, .info);
    }

    pub fn clearMessages(self: *SearchView) void {
        for (self.messages.items) |message| self.allocator.free(message.text);
        self.messages.clearRetainingCapacity();
    }

    fn setSingleMessage(self: *SearchView, text: []const u8, kind: MessageKind) void {
        self.clearMessages();
        self.appendMessage(text, kind);
    }

    fn setOwnedMessage(self: *SearchView, text: []u8, kind: MessageKind) void {
        self.clearMessages();
        self.messages.append(.{ .text = text, .kind = kind }) catch self.allocator.free(text);
    }

    fn appendMessage(self: *SearchView, text: []const u8, kind: MessageKind) void {
        const owned = self.allocator.dupe(u8, text) catch return;
        self.messages.append(.{ .text = owned, .kind = kind }) catch self.allocator.free(owned);
    }

    pub fn messageText(self: *const SearchView, buffer: []u8) []const u8 {
        var used: usize = 0;
        for (self.messages.items, 0..) |message, index| {
            if (index > 0) {
                if (used + 3 > buffer.len) break;
                buffer[used] = ' ';
                buffer[used + 1] = '-';
                buffer[used + 2] = ' ';
                used += 3;
            }
            const count = @min(message.text.len, buffer.len - used);
            @memcpy(buffer[used..][0..count], message.text[0..count]);
            used += count;
        }
        return buffer[0..used];
    }

    pub fn selectNextMatch(self: *SearchView) !void {
        if (!self.hasSearchResults()) return;
        const selected = self.viewer.selectedNode();
        if (selected) |node| {
            if (node != .match and self.viewer.isCollapsed(node)) {
                _ = self.viewer.expandNode(node, false);
            }
        }
        var navigator = base.navigate(self.viewer, selected);
        var next = navigator.next() orelse navigator.first();
        while (next) |node| {
            if (node == .match) break;
            if (self.viewer.isCollapsed(node)) _ = self.viewer.expandNode(node, false);
            next = navigator.next();
        }
        if (next) |node| {
            self.viewer.select(node);
        }
    }

    pub fn selectPreviousMatch(self: *SearchView) !void {
        if (!self.hasSearchResults()) return;
        const selected = self.viewer.selectedNode();
        var navigator = base.navigate(self.viewer, selected);
        var previous = navigator.previous();
        while (previous == null or (previous.? != .match and !self.viewer.isCollapsed(previous.?))) {
            const next_previous = if (previous != null) navigator.previous() else navigator.last();
            if (previous == null and next_previous == null) return;
            previous = next_previous;
        }
        while (previous) |node| {
            if (node == .match) break;
            const next_item = navigator.next() orelse break;
            _ = self.viewer.expandNode(node, false);
            navigator = base.navigate(self.viewer, next_item);
            previous = navigator.previous() orelse navigator.last();
        }
        if (previous) |node| self.viewer.select(node);
    }

    pub fn openElement(self: *SearchView, element: Node, preserve_focus: bool) !void {
        switch (element) {
            .match => |match| {
                const range = match.range();
                try self.host.open_match(self.host.context, match.parent_file.path, range, preserve_focus, false);
                if (preserve_focus) self.host.highlight_range(self.host.context, match.parent_file.path, range);
            },
            .file => |file| {
                try self.host.open_match(self.host.context, file.path, null, preserve_focus, false);
            },
            else => {},
        }
    }

    /// Builds the confirmation for Replace All. The TUI shows it, then calls
    /// `executeReplaceAll` when the user confirms.
    pub fn requestReplaceAll(self: *SearchView) !?ReplaceAllRequest {
        const occurrences = self.model.result.count();
        if (occurrences == 0) return null;
        const file_count = self.model.result.fileCount();
        const replace_value = self.widget.value(self.widget.context, .replace);
        const confirmation = try buildReplaceAllConfirmationMessage(
            self.allocator,
            occurrences,
            file_count,
            replace_value,
        );
        errdefer self.allocator.free(confirmation);
        const after = try buildAfterReplaceAllMessage(
            self.allocator,
            occurrences,
            file_count,
            replace_value,
        );
        return .{
            .occurrences = occurrences,
            .file_count = file_count,
            .confirmation = confirmation,
            .after = after,
        };
    }

    pub fn executeReplaceAll(self: *SearchView) !void {
        defer self.scheduleDeadline();
        const pattern = self.model.replacePattern() orelse return;
        const files = try self.model.result.matches(self.allocator);
        defer self.allocator.free(files);
        try self.replace_service.replaceFiles(self.allocator, files, pattern, self.model.preserve_case);
        const occurrences = self.model.result.count();
        const file_count = self.model.result.fileCount();
        const replace_value = self.widget.value(self.widget.context, .replace);
        self.model.result.clear();
        _ = self.model.cancelSearch();
        self.state = .idle;
        const message = try buildAfterReplaceAllMessage(
            self.allocator,
            occurrences,
            file_count,
            replace_value,
        );
        self.setOwnedMessage(message, .info);
        self.viewer.refreshView();
    }

    pub fn reportOpenInEditorError(self: *SearchView) void {
        self.setSingleMessage("Could not open search results in an editor.", .err);
    }

    pub fn reportReplaceError(self: *SearchView) void {
        self.setSingleMessage("Could not replace all requested occurrences.", .err);
    }

    /// Replaces one match/file/folder and removes it from the result tree.
    pub fn replaceElement(self: *SearchView, element: Node) !void {
        const pattern = self.model.replacePattern() orelse return;
        switch (element) {
            .match => |match| {
                const matches = [_]*Match{match};
                try self.replace_service.replaceMatches(self.allocator, matches[0..], pattern, self.model.preserve_case);
                self.model.result.removeMatch(match);
            },
            .file => |file| {
                const files = [_]*FileMatch{file};
                try self.replace_service.replaceFiles(self.allocator, files[0..], pattern, self.model.preserve_case);
                self.model.result.removeFile(file);
            },
            .folder => |folder| {
                const files = try folder.allDownstreamFiles(self.allocator);
                defer self.allocator.free(files);
                try self.replace_service.replaceFiles(self.allocator, files, pattern, self.model.preserve_case);
                if (folder.parent_folder) |parent| {
                    parent.removeFolder(folder);
                } else {
                    self.model.result.heading.removeFolder(folder);
                }
            },
            .heading => {},
        }
        self.viewer.refreshView();
    }

    pub fn onConfigurationChanged(self: *SearchView) void {
        defer self.scheduleDeadline();
        if (self.model.query != null) {
            self.refresh_at = time_compat.milliTimestamp();
        }
        self.viewer.refreshView();
    }

    pub fn toggleOption(self: *SearchView, option: Option) !void {
        if (option == .preserve_case) {
            const next = !self.widget.option(self.widget.context, option);
            self.widget.set_option(self.widget.context, option, next);
            self.model.setPreserveCase(next);
            self.viewer.refreshView();
            return;
        }
        const next = !self.widget.option(self.widget.context, option);
        self.widget.set_option(self.widget.context, option, next);
        try self.triggerQueryChange(true, false);
    }

    pub fn setTreeView(self: *SearchView, tree_view: bool) void {
        self.view_mode = if (tree_view) .tree else .list;
        self.viewer.refreshView();
    }

    pub fn toggleQueryDetails(self: *SearchView, show: ?bool) void {
        const visible = show orelse !self.widget.details_visible(self.widget.context);
        self.widget.set_details_visible(self.widget.context, visible);
    }

    pub fn focusNextInputBox(self: *SearchView) void {
        switch (self.focus) {
            .search => if (self.widget.replace_visible(self.widget.context)) {
                self.focus = .replace;
                self.widget.focus(self.widget.context, .replace);
            } else if (self.widget.details_visible(self.widget.context)) {
                self.focus = .includes;
                self.widget.focus(self.widget.context, .includes);
            } else {
                self.focusResults();
            },
            .replace => {
                if (self.widget.details_visible(self.widget.context)) {
                    self.focus = .includes;
                    self.widget.focus(self.widget.context, .includes);
                } else {
                    self.focusResults();
                }
            },
            .includes => {
                self.focus = .excludes;
                self.widget.focus(self.widget.context, .excludes);
            },
            .excludes => self.focusResults(),
            .results => {},
        }
    }

    pub fn focusPreviousInputBox(self: *SearchView) void {
        switch (self.focus) {
            .search => {},
            .replace => {
                self.focus = .search;
                self.widget.focus(self.widget.context, .search);
            },
            .includes => {
                if (self.widget.replace_visible(self.widget.context)) {
                    self.focus = .replace;
                    self.widget.focus(self.widget.context, .replace);
                } else {
                    self.focus = .search;
                    self.widget.focus(self.widget.context, .search);
                }
            },
            .excludes => {
                self.focus = .includes;
                self.widget.focus(self.widget.context, .includes);
            },
            .results => {
                if (self.widget.details_visible(self.widget.context)) {
                    self.focus = .excludes;
                    self.widget.focus(self.widget.context, .excludes);
                } else if (self.widget.replace_visible(self.widget.context)) {
                    self.focus = .replace;
                    self.widget.focus(self.widget.context, .replace);
                } else {
                    self.focus = .search;
                    self.widget.focus(self.widget.context, .search);
                }
            },
        }
    }

    pub fn context(self: *const SearchView) Context {
        const selected = self.viewer.selectedNode();
        var value = Context{
            .view_focused = self.panel_focused,
            .input_box_focused = self.focus != .results,
            .search_input_focused = self.focus == .search,
            .replace_input_focused = self.focus == .replace,
            .includes_focused = self.focus == .includes,
            .excludes_focused = self.focus == .excludes,
            .replace_active = self.model.isReplaceActive(),
            .has_results = self.hasSearchResults(),
            .tree_view = self.view_mode == .tree,
            .has_search_pattern = self.widget.value(self.widget.context, .search).len > 0,
            .has_replace_pattern = self.widget.value(self.widget.context, .replace).len > 0,
            .has_file_pattern = self.widget.value(self.widget.context, .includes).len > 0 or
                self.widget.value(self.widget.context, .excludes).len > 0,
        };
        if (selected) |node| {
            switch (node) {
                .match => value.match_focus = true,
                .file => value.file_focus = true,
                .folder => value.folder_focus = true,
                .heading => {},
            }
            value.file_or_match_focus = value.match_focus or value.file_focus or value.folder_focus;
            value.file_or_folder_focus = value.file_focus or value.folder_focus;
        }
        return value;
    }
};

pub fn buildResultCountMessage(allocator: Allocator, result_count: usize, file_count: usize) ![]u8 {
    if (result_count == 1 and file_count == 1) {
        return std.fmt.allocPrint(allocator, "{d} result in {d} file", .{ result_count, file_count });
    }
    if (result_count == 1) {
        return std.fmt.allocPrint(allocator, "{d} result in {d} files", .{ result_count, file_count });
    }
    if (file_count == 1) {
        return std.fmt.allocPrint(allocator, "{d} results in {d} file", .{ result_count, file_count });
    }
    return std.fmt.allocPrint(allocator, "{d} results in {d} files", .{ result_count, file_count });
}

pub fn buildReplaceAllConfirmationMessage(
    allocator: Allocator,
    occurrences: usize,
    file_count: usize,
    replace_value: []const u8,
) ![]u8 {
    const value = try truncateValue(allocator, replace_value);
    defer if (value) |slice| allocator.free(slice);
    if (value) |text| {
        if (occurrences == 1) {
            if (file_count == 1) {
                return std.fmt.allocPrint(allocator, "Replace {d} occurrence across {d} file with '{s}'?", .{ occurrences, file_count, text });
            }
            return std.fmt.allocPrint(allocator, "Replace {d} occurrence across {d} files with '{s}'?", .{ occurrences, file_count, text });
        }
        if (file_count == 1) {
            return std.fmt.allocPrint(allocator, "Replace {d} occurrences across {d} file with '{s}'?", .{ occurrences, file_count, text });
        }
        return std.fmt.allocPrint(allocator, "Replace {d} occurrences across {d} files with '{s}'?", .{ occurrences, file_count, text });
    }
    if (occurrences == 1) {
        if (file_count == 1) {
            return std.fmt.allocPrint(allocator, "Replace {d} occurrence across {d} file?", .{ occurrences, file_count });
        }
        return std.fmt.allocPrint(allocator, "Replace {d} occurrence across {d} files?", .{ occurrences, file_count });
    }
    if (file_count == 1) {
        return std.fmt.allocPrint(allocator, "Replace {d} occurrences across {d} file?", .{ occurrences, file_count });
    }
    return std.fmt.allocPrint(allocator, "Replace {d} occurrences across {d} files?", .{ occurrences, file_count });
}

pub fn buildAfterReplaceAllMessage(
    allocator: Allocator,
    occurrences: usize,
    file_count: usize,
    replace_value: []const u8,
) ![]u8 {
    if (replace_value.len > 0) {
        if (occurrences == 1) {
            if (file_count == 1) {
                return std.fmt.allocPrint(allocator, "Replaced {d} occurrence across {d} file with '{s}'.", .{ occurrences, file_count, replace_value });
            }
            return std.fmt.allocPrint(allocator, "Replaced {d} occurrence across {d} files with '{s}'.", .{ occurrences, file_count, replace_value });
        }
        if (file_count == 1) {
            return std.fmt.allocPrint(allocator, "Replaced {d} occurrences across {d} file with '{s}'.", .{ occurrences, file_count, replace_value });
        }
        return std.fmt.allocPrint(allocator, "Replaced {d} occurrences across {d} files with '{s}'.", .{ occurrences, file_count, replace_value });
    }
    if (occurrences == 1) {
        if (file_count == 1) {
            return std.fmt.allocPrint(allocator, "Replaced {d} occurrence across {d} file.", .{ occurrences, file_count });
        }
        return std.fmt.allocPrint(allocator, "Replaced {d} occurrence across {d} files.", .{ occurrences, file_count });
    }
    if (file_count == 1) {
        return std.fmt.allocPrint(allocator, "Replaced {d} occurrences across {d} file.", .{ occurrences, file_count });
    }
    return std.fmt.allocPrint(allocator, "Replaced {d} occurrences across {d} files.", .{ occurrences, file_count });
}

fn truncateValue(allocator: Allocator, value: []const u8) !?[]u8 {
    if (value.len == 0) return null;
    var lines: usize = 0;
    var index: usize = 0;
    while (index < value.len) : (index += 1) {
        if (value[index] != '\n') continue;
        lines += 1;
        if (lines < 10) continue;
        const end = index;
        return try std.fmt.allocPrint(allocator, "{s}\n...", .{value[0..end]});
    }
    return try allocator.dupe(u8, value);
}

fn readViewMode(configuration: *ConfigurationService) ViewMode {
    const value = configuration.getValue("search.defaultViewMode", .{}) orelse return .list;
    return switch (value.*) {
        .string => |text| ViewMode.fromString(text),
        else => .list,
    };
}

fn readSortOrder(configuration: *ConfigurationService) SearchSortOrder {
    const value = configuration.getValue("search.sortOrder", .{}) orelse return .default;
    return switch (value.*) {
        .string => |text| SearchSortOrder.fromString(text),
        else => .default,
    };
}
