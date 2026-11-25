// Terminal input for the Open Results in Editor path in
// `src/vs/workbench/contrib/searchEditor/browser/searchEditorInput.ts`.
// Owns a query pane and its generated, in-memory results model.

const std = @import("std");
const editor_input = @import("../../../common/editor/editorInput.zig");
const Editor = @import("../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;

const SearchEditor = @import("searchEditor.zig").SearchEditor;
const Range = @import("../../../../editor/common/core/range.zig").Range;
const model = @import("../../../../editor/common/model.zig");

pub const SearchEditorFindMatchClass = "searchEditorFindMatch";
// Terminal adaptation: inline class and z-order retain the cell painter's
// match background, without changing the model range/stickiness contract.
const match_decoration_options: model.ModelDecorationOptions = blk: {
    var options = model.ModelDecorationOptions.init("search-editor-find-match", .NeverGrowsWhenTypingAtEdges);
    options.className = SearchEditorFindMatchClass;
    options.inlineClassName = SearchEditorFindMatchClass;
    options.zIndex = 10;
    break :blk options;
};
const match_owner_id = 8;

const Queue = @import("../../../../base/common/windowDispatch.zig").Queue;
const Workspace = @import("../../../services/workspaces/common/workspaceContextService.zig").WorkspaceContextService;
const Configuration = @import("../../../services/configuration/browser/configurationService.zig").ConfigurationService;

pub const Environment = struct { workspace: *Workspace, configuration: *Configuration };
pub const Host = struct {
    context: *anyopaque,
    environment: *const fn (*anyopaque) ?Environment,
    extra_files: *const fn (*anyopaque, std.mem.Allocator) anyerror![][]u8,
    free_paths: *const fn (*anyopaque, std.mem.Allocator, [][]u8) void,
};

pub const SearchEditorInput = struct {
    base: editor_input.EditorInput,
    editor: *Editor,
    name: []const u8,
    search_editor: *SearchEditor,
    host: Host = undefined,
    old_decorations_ids: []u64 = &.{},

    pub fn attach(self: *SearchEditorInput, queue: *Queue, host: Host) void {
        self.host = host;
        self.search_editor.model.delivery.attach(queue, self, deliver);
    }

    fn deliver(context: *anyopaque, now: i64, progress: bool) bool {
        const self: *SearchEditorInput = @ptrCast(@alignCast(context));
        const query = self.search_editor;
        const env = self.host.environment(self.host.context) orelse return false;
        const extras = if (query.pending_at != null and query.pending_at.? <= now)
            self.host.extra_files(self.host.context, query.allocator) catch null
        else
            null;
        defer if (extras) |paths| self.host.free_paths(self.host.context, query.allocator, paths);
        const changed = query.dispatch(now, env.configuration, env.workspace, extras orelse &.{}, self, progress) catch |err| {
            _ = query.model.cancelSearch();
            self.editor.setMessage("Search failed: {s}", .{@errorName(err)});
            return true;
        };
        if (changed) self.updateName() catch {};
        return changed;
    }

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        query: []const u8,
        search_editor: *SearchEditor,
        text: []const u8,
        width: usize,
        height: usize,
    ) !*SearchEditorInput {
        const self = try allocator.create(SearchEditorInput);
        errdefer allocator.destroy(self);
        const name = try createName(allocator, query);
        errdefer allocator.free(name);
        const editor = try Editor.createFromTextWithOptions(allocator, io, text, "search-results.code-search", width, height, .{ .reserve_scrollbar = true });
        editor.setReadOnly(true);
        self.* = .{
            .base = editor_input.EditorInput.init(allocator, "workbench.editorinputs.searchEditorInput"),
            .editor = editor,
            .name = name,
            .search_editor = search_editor,
        };
        self.base.name = name;
        self.base.capabilities = editor_input.EditorInputCapabilities.Readonly;
        return self;
    }

    /// Port of SearchEditorInput.getMatchRanges. The results model, not the
    /// terminal view or a separate snapshot, is the source of the ranges.
    pub fn getMatchRanges(self: *SearchEditorInput, allocator: std.mem.Allocator) ![]Range {
        const results_model = self.editor.model;
        const decorations = try results_model.getAllDecorations(0, false);
        defer results_model.getAllocator().free(decorations);
        var ranges: std.ArrayList(Range) = .empty;
        errdefer ranges.deinit(allocator);
        for (decorations) |decoration| {
            const class_name = decoration.options.className orelse continue;
            if (!std.mem.eql(u8, class_name, SearchEditorFindMatchClass)) continue;
            const range = decoration.range;
            if (range.startColumn == 1 and range.endColumn == 1) continue;
            try ranges.append(allocator, range);
        }
        return ranges.toOwnedSlice(allocator);
    }

    /// Port of SearchEditorInput.setMatchRanges: replace the previous IDs
    /// in one model delta, preserving the underlying decoration event flow.
    pub fn setMatchRanges(self: *SearchEditorInput, ranges: []const Range) !void {
        const results_model = self.editor.model;
        const allocator = results_model.getAllocator();
        const deltas = try allocator.alloc(model.ModelDeltaDecoration, ranges.len);
        defer allocator.free(deltas);
        for (deltas, ranges) |*delta, range| {
            delta.* = .{ .range = range, .options = @constCast(&match_decoration_options) };
        }
        const ids = try results_model.deltaDecorations(self.old_decorations_ids, deltas, match_owner_id);
        allocator.free(self.old_decorations_ids);
        self.old_decorations_ids = ids;
    }

    fn createName(allocator: std.mem.Allocator, query: []const u8) ![]const u8 {
        return if (query.len == 0)
            allocator.dupe(u8, "Search")
        else
            std.fmt.allocPrint(allocator, "Search: {s}", .{query});
    }

    pub fn updateName(self: *SearchEditorInput) !void {
        const query = self.search_editor.form.value(.search);
        const allocator = self.base.allocator;
        const name = try createName(allocator, query);
        if (std.mem.eql(u8, self.name, name)) {
            allocator.free(name);
            return;
        }
        allocator.free(self.name);
        self.name = name;
        self.base.name = name;
        try self.base.fireLabel();
    }

    pub fn deinit(self: *SearchEditorInput) void {
        const allocator = self.base.allocator;
        self.search_editor.deinit();
        self.base.dispose();
        self.base.deinit();
        self.editor.model.getAllocator().free(self.old_decorations_ids);
        self.editor.deinit();
        allocator.destroy(self.editor);
        allocator.free(self.name);
        allocator.destroy(self);
    }
};
