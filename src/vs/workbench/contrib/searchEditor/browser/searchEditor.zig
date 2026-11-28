// Query editor and search lifecycle port of vscode/src/vs/workbench/contrib/searchEditor/browser/searchEditor.ts.
const std = @import("std");
const ui = @import("ui");
const Allocator = std.mem.Allocator;
const time = @import("../../../../base/common/timeCompat.zig");
const ConfigurationService = @import("../../../services/configuration/browser/configurationService.zig").ConfigurationService;
const WorkspaceContextService = @import("../../../services/workspaces/common/workspaceContextService.zig").WorkspaceContextService;
const QueryBuilder = @import("../../../services/search/common/queryBuilder.zig").QueryBuilder;
const search = @import("../../../services/search/common/search.zig");
const SearchModel = @import("../../search/browser/searchTreeModel/searchModel.zig").SearchModel;
const widget = @import("../../search/browser/searchWidget.zig");
const Range = @import("../../../../editor/common/core/range.zig").Range;
const Editor = @import("../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const SearchEditorInput = @import("searchEditorInput.zig").SearchEditorInput;
const serialization = @import("searchEditorSerialization.zig");

pub const Config = struct {
    query: []const u8 = "",
    includes: []const u8 = "",
    excludes: []const u8 = "",
    match_case: bool = false,
    whole_word: bool = false,
    regex: bool = false,
    use_excludes: bool = true,
    show_details: bool = false,
};

pub const SearchEditor = struct {
    io: std.Io,
    allocator: Allocator,
    form: *widget.SearchWidget,
    model: *SearchModel,
    query_focused: bool = true,
    on_did_change_query_focus: @import("../../../../base/common/event.zig").Emitter(bool),
    pending_at: ?i64 = null,
    reset_cursor: bool = true,
    focus_results_on_search: bool = false,
    search_on_type: bool = true,
    debounce: i64 = 300,
    files: []const serialization.FileLocation = &.{},
    last_result_click: ?struct { x: usize, y: usize, at: i64 } = null,

    pub fn init(allocator: Allocator, io: std.Io, service: search.ISearchService, config: Config, configuration: *ConfigurationService) !*SearchEditor {
        const self = try allocator.create(SearchEditor);
        errdefer allocator.destroy(self);
        const form = try widget.SearchWidget.init(allocator);
        errdefer form.deinit();
        const model = try SearchModel.init(allocator, io, service);
        errdefer model.deinit();
        self.* = .{ .allocator = allocator, .io = io, .form = form, .model = model, .on_did_change_query_focus = .init(allocator) };
        errdefer self.on_did_change_query_focus.deinit();

        form.editor_mode = true;
        try form.setValue(.search, config.query);
        try form.setValue(.includes, config.includes);
        try form.setValue(.excludes, config.excludes);
        form.match_case = config.match_case;
        form.whole_word = config.whole_word;
        form.regex = config.regex;
        form.use_excludes = config.use_excludes;
        form.details_visible = config.show_details or config.includes.len != 0 or config.excludes.len != 0 or !config.use_excludes;
        const context = readContextLines(configuration);
        form.context_enabled = context > 0;
        var number: [8]u8 = undefined;
        try form.context_lines.setValue(try std.fmt.bufPrint(&number, "{d}", .{if (context == 0) 1 else context}));
        self.configure(configuration);
        form.callbacks = .{
            .context = self,
            .on_change = onChange,
            .on_submit = onSubmit,
            .on_toggle = onToggle,
            .on_toggle_details = onDetails,
            .on_use_excludes = onImmediate,
            .on_context = onOptionChanged,
        };
        return self;
    }

    pub fn deinit(self: *SearchEditor) void {
        serialization.freeLocations(self.allocator, self.files);
        self.on_did_change_query_focus.deinit();
        self.model.deinit();
        self.form.deinit();
        self.allocator.destroy(self);
    }

    pub fn configure(self: *SearchEditor, configuration: *ConfigurationService) void {
        self.search_on_type = configuration.getBool("search.searchOnType", true);
        self.focus_results_on_search = configuration.getBool("search.searchEditor.focusResultsOnSearch", false);
        if (configuration.getValue("search.searchOnTypeDebouncePeriod", .{})) |value| {
            if (value.* == .integer) self.debounce = @max(value.integer, 0);
        }
    }

    pub fn headerRows(self: *const SearchEditor) usize {
        return self.form.computeLayout().height;
    }

    pub fn triggerSearch(self: *SearchEditor, delay_ms: i64, reset_cursor: bool) void {
        _ = self.model.cancelSearch();
        self.pending_at = time.milliTimestamp(self.io) + delay_ms;
        self.model.delivery.timer.schedule(self.pending_at);
        self.reset_cursor = reset_cursor;
    }

    pub fn isSearchPending(self: *const SearchEditor) bool {
        return self.pending_at != null or self.model.isSearching();
    }

    pub fn setQueryFocused(self: *SearchEditor, focused: bool) void {
        if (self.query_focused == focused) return;
        self.query_focused = focused;
        self.on_did_change_query_focus.fire(focused) catch {};
    }

    pub fn handleKey(self: *SearchEditor, event: *ui.KeyEvent) bool {
        if (!self.query_focused) {
            if (event.key != .tab and event.key != .backtab) return false;
            self.setQueryFocused(true);
            self.form.focusField(.search);
            return true;
        }
        if (event.key == .escape) {
            self.pending_at = null;
            self.model.delivery.timer.schedule(null);
            _ = self.model.cancelSearch();
            self.setQueryFocused(false);
            return true;
        }
        if (event.key == .tab or event.key == .backtab) {
            if (!self.form.cycleFocus(event.key == .backtab)) self.setQueryFocused(false);
            return true;
        }
        if ((event.mods.alt or event.mods.ctrl) and self.form.focus_control != null and self.form.focus_control != .context_lines) return false;
        return self.form.handleKey(event) or (!event.mods.ctrl and !event.mods.alt);
    }

    pub fn dispatch(
        self: *SearchEditor,
        now_ms: i64,
        configuration: *ConfigurationService,
        workspace: *WorkspaceContextService,
        extras: []const []const u8,
        input: *SearchEditorInput,
        progress: bool,
    ) !bool {
        if (self.pending_at) |deadline| {
            if (now_ms < deadline) return false;
            self.pending_at = null;
            self.model.delivery.timer.schedule(null);
            const value = self.form.value(.search);
            if (value.len == 0) {
                self.model.clear();
                try input.editor.replaceGeneratedContents("", true);
                try input.setMatchRanges(&.{});
                try self.setLocations(&.{});
                return true;
            }
            const builder = QueryBuilder.init(self.allocator, configuration, workspace);
            const query = try builder.text(.{
                .pattern = value,
                .is_case_sensitive = self.form.match_case,
                .is_word_match = self.form.whole_word,
                .is_regex = self.form.regex,
            }, .{
                .include_pattern = self.form.value(.includes),
                .exclude_pattern = self.form.value(.excludes),
                .use_excludes_and_ignore_files = self.form.use_excludes,
                .extra_files = extras,
                .surrounding_context = self.form.contextLines(),
                .is_smart_case = configuration.getBool("search.smartCase", false),
            });
            if (!try self.model.search(query)) {
                input.editor.setMessage("Invalid search pattern", .{});
                return true;
            }
        }
        if (!progress or !self.model.isSearching()) return false;
        _ = try self.model.onSearchProgress(32);
        if (self.model.takeMessage()) |message| {
            defer self.allocator.free(message.text);
            input.editor.setMessage("{s}", .{message.text});
            if (message.kind == .err) return true;
        }
        if (self.model.isSearching()) return false;
        const setting = configuration.getValue("search.sortOrder", .{});
        const order: search.SearchSortOrder = if (setting != null and setting.?.* == .string)
            search.SearchSortOrder.fromString(setting.?.string)
        else
            .default;
        const snapshot = try serialization.serializeSearchResultForEditor(self.allocator, self.model.result, order, self.model.limitHit());
        defer snapshot.deinit(self.allocator);
        try input.editor.replaceGeneratedContents(snapshot.text, self.reset_cursor);
        try self.setLocations(snapshot.files);
        try input.setMatchRanges(snapshot.match_ranges);
        if (self.focus_results_on_search) self.setQueryFocused(false);
        return true;
    }

    pub fn setLocations(self: *SearchEditor, files: []const serialization.FileLocation) !void {
        const copy = try self.allocator.alloc(serialization.FileLocation, files.len);
        errdefer self.allocator.free(copy);
        var count: usize = 0;
        errdefer for (copy[0..count]) |file| self.allocator.free(file.path);
        for (files, copy) |file, *destination| {
            destination.* = .{ .line = file.line, .path = try self.allocator.dupe(u8, file.path) };
            count += 1;
        }
        serialization.freeLocations(self.allocator, self.files);
        self.files = copy;
    }

    pub const Target = struct { path: []const u8, range: ?Range = null };

    pub fn targetAtCursor(self: *SearchEditor, editor: *Editor) !?Target {
        const position = editor.modelCursorPosition();
        var index = self.files.len;
        if (index == 0) return null;
        while (index > 0) {
            index -= 1;
            const file = self.files[index];
            if (file.line > position.lineNumber) continue;
            if (file.line == position.lineNumber) return .{ .path = file.path };
            var line = try editor.model.getLineContent(position.lineNumber);
            defer line.deinit();
            const number = std.mem.trimStart(u8, line.items, " ");
            const digits = std.mem.indexOfAny(u8, number, ": ") orelse return null;
            const source_line = std.fmt.parseInt(usize, number[0..digits], 10) catch return null;
            if (source_line == 0) return null;
            const prefix = line.items.len - number.len + digits + 2;
            const column = @max(1, position.column -| prefix);
            return .{ .path = file.path, .range = Range.init(source_line, column, source_line, column) };
        }
        return null;
    }

    fn onChange(context: *anyopaque, _: widget.Field, _: []const u8) void {
        const self: *SearchEditor = @ptrCast(@alignCast(context));
        _ = self.model.cancelSearch();
        self.pending_at = null;
        self.model.delivery.timer.schedule(null);
        if (self.search_on_type) self.triggerSearch(self.debounce, true);
    }

    fn onSubmit(context: *anyopaque, field: widget.Field) void {
        const self: *SearchEditor = @ptrCast(@alignCast(context));
        self.triggerSearch(0, field == .search);
    }

    fn onImmediate(context: *anyopaque) void {
        const self: *SearchEditor = @ptrCast(@alignCast(context));
        self.triggerSearch(0, true);
    }

    fn onToggle(context: *anyopaque, option: widget.Option) void {
        const self: *SearchEditor = @ptrCast(@alignCast(context));
        switch (option) {
            .match_case => self.form.match_case = !self.form.match_case,
            .whole_word => self.form.whole_word = !self.form.whole_word,
            .regex => self.form.regex = !self.form.regex,
            .preserve_case => return,
        }
        self.triggerSearch(0, false);
    }

    fn onOptionChanged(context: *anyopaque) void {
        const self: *SearchEditor = @ptrCast(@alignCast(context));
        self.triggerSearch(0, false);
    }

    fn onDetails(context: *anyopaque) void {
        const self: *SearchEditor = @ptrCast(@alignCast(context));
        self.form.setDetailsVisible(!self.form.details_visible);
    }
};

fn readContextLines(configuration: *ConfigurationService) u16 {
    const value = configuration.getValue("search.searchEditor.defaultNumberOfContextLines", .{}) orelse return 1;
    return switch (value.*) {
        .integer => |number| @intCast(std.math.clamp(number, 0, std.math.maxInt(u16))),
        .null => 0,
        else => 1,
    };
}
