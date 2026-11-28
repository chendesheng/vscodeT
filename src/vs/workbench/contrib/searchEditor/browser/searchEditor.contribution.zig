// Port of the editor creation and command registration in
// src/vs/workbench/contrib/searchEditor/browser/searchEditor.contribution.ts.
// Native search editors mount into an existing editor group using the same
// search service, result snapshot and window completion queue as the Search view.
const std = @import("std");
const Allocator = std.mem.Allocator;
const search_editor = @import("searchEditor.zig");
const search_editor_serialization = @import("searchEditorSerialization.zig");
const search_editor_input_mod = @import("searchEditorInput.zig");
const SearchEditorInput = search_editor_input_mod.SearchEditorInput;
const Tab = @import("../../../browser/parts/editor/editorPane.zig").Tab;
const GroupView = @import("../../../browser/parts/editor/editorGroupView.zig").EditorGroupView(*Tab);
const EditorPart = @import("../../../browser/parts/editor/editorPart.zig").EditorPart(GroupView);
const WorkspaceContextService = @import("../../../services/workspaces/common/workspaceContextService.zig").WorkspaceContextService;
const ConfigurationService = @import("../../../services/configuration/browser/configurationService.zig").ConfigurationService;
const search_types = @import("../../../services/search/common/search.zig");
const Range = @import("../../../../editor/common/core/range.zig").Range;
const actions = @import("../../../../platform/actions/common/actions.zig");
const ServicesAccessor = @import("../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;

pub const SearchEditorFactory = struct {
    allocator: Allocator,
    io: std.Io,
    part: *EditorPart,
    workspace: *WorkspaceContextService,
    configuration: *const ?*ConfigurationService,
    view_factory: @import("../../../browser/parts/editor/editorPane.zig").EditorViewFactory,
    window: *@import("../../../../base/common/windowDispatch.zig").Queue,
    host: struct {
        context: *anyopaque,
        start_search: *const fn (*anyopaque, *const search_types.TextQuery) anyerror!search_types.ISearchJob,
        extra_files: *const fn (*anyopaque, Allocator) anyerror![][]u8,
        ensure_configuration: *const fn (*anyopaque) anyerror!void,
        configure_tab: *const fn (*anyopaque, *Tab) void,
        update_focus: *const fn (*anyopaque) anyerror!void,
        layout: *const fn (*anyopaque) void,
        focus_editor: *const fn (*anyopaque) void,
        open_match: *const fn (*anyopaque, []const u8, ?Range) anyerror!void,
    },

    fn startSearchEditorJob(context: *anyopaque, query: *const search_types.TextQuery) !search_types.ISearchJob {
        const self: *SearchEditorFactory = @ptrCast(@alignCast(context));
        return self.host.start_search(self.host.context, query);
    }

    fn searchEditorEnvironment(context: *anyopaque) ?search_editor_input_mod.Environment {
        const self: *SearchEditorFactory = @ptrCast(@alignCast(context));
        return .{ .workspace = self.workspace, .configuration = self.configuration.* orelse return null };
    }

    fn searchExtraFiles(context: *anyopaque, allocator: Allocator) ![][]u8 {
        const self: *SearchEditorFactory = @ptrCast(@alignCast(context));
        return self.host.extra_files(self.host.context, allocator);
    }

    fn searchFreePaths(_: *anyopaque, allocator: Allocator, paths: [][]u8) void {
        for (paths) |path| allocator.free(path);
        allocator.free(paths);
    }

    fn onQueryFocusChanged(self: *SearchEditorFactory) !void {
        try self.host.update_focus(self.host.context);
    }

    pub fn actionDescriptors(self: *SearchEditorFactory) [2]actions.Action2 {
        return .{
            .{ .command = .{ .id = "search.action.openNewEditor", .title = "Open New Search Editor", .category = "Search" }, .f1 = true, .context = self, .run_fn = openNewSearchEditor },
            .{ .command = .{ .id = "rerunSearchEditorSearch", .title = "Search Again", .category = "Search Editor" }, .f1 = true, .context = self, .run_fn = rerunSearchEditor },
        };
    }

    fn openNewSearchEditor(context: *anyopaque, _: ServicesAccessor) !void {
        const self: *SearchEditorFactory = @ptrCast(@alignCast(context));
        try self.openResults(.{}, .{ .text = "", .match_ranges = &.{} });
    }

    fn rerunSearchEditor(context: *anyopaque, _: ServicesAccessor) !void {
        const self: *SearchEditorFactory = @ptrCast(@alignCast(context));
        const pane = self.part.activeView() orelse return;
        const tab = pane.activeTab() orelse return;
        if (tab.search_editor_input) |input| input.search_editor.triggerSearch(0, true);
    }

    pub fn openResults(self: *SearchEditorFactory, config: search_editor.Config, snapshot: search_editor_serialization.Snapshot) !void {
        const pane = self.part.activeView() orelse return error.GroupPaneMissing;
        try self.host.ensure_configuration(self.host.context);
        const configuration = self.configuration.*.?;
        const dims = pane.contentDimensions();
        const query = try search_editor.SearchEditor.init(self.allocator, self.window.io, .{ .context = self, .start_text_search = startSearchEditorJob }, config, configuration);
        _ = query.on_did_change_query_focus.listenSignal(self, onQueryFocusChanged) catch |err| {
            query.deinit();
            return err;
        };
        const input = SearchEditorInput.init(self.allocator, self.io, config.query, query, snapshot.text, dims.width, dims.height) catch |err| {
            query.deinit();
            return err;
        };
        const tab = Tab.initSearchEditor(self.view_factory, self.allocator, input) catch |err| {
            input.deinit();
            return err;
        };
        errdefer tab.deinit();
        try tab.view.setStatusBarVisible(false);
        try input.setMatchRanges(snapshot.match_ranges);
        try query.setLocations(snapshot.files);
        input.attach(self.window, .{ .context = self, .environment = searchEditorEnvironment, .extra_files = searchExtraFiles, .free_paths = searchFreePaths });
        try pane.tabs.ensureUnusedCapacity(1);
        _ = try pane.group.model.openEditor(tab.input, .{ .pinned = true, .active = true });
        errdefer _ = pane.group.model.closeEditor(tab.input, .UNKNOWN, true) catch {};
        try pane.addTab(tab);
        self.host.configure_tab(self.host.context, tab);
        self.host.layout(self.host.context);
        self.host.focus_editor(self.host.context);
        if (config.query.len > 0 and query.form.contextLines() > 0) query.triggerSearch(0, true);
    }

    pub fn openTarget(self: *SearchEditorFactory, tab: *Tab) bool {
        const query = tab.search_editor_input.?.search_editor;
        const target = (query.targetAtCursor(tab.editor) catch null) orelse return false;
        self.host.open_match(self.host.context, target.path, target.range) catch |err| {
            tab.editor.setMessage("Open failed: {s}", .{@errorName(err)});
        };
        return true;
    }
};
