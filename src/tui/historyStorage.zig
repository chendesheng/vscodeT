// Terminal profile adapter for the existing history.json format. It stores
// local file paths, scroll positions and closed-editor batches. VS Code
// stores resource editor inputs under the workspace history.entries key.
const std = @import("std");
const Io = std.Io;
const HistoryService = @import("../vs/workbench/services/history/browser/historyService.zig").HistoryService;
const editor_mod = @import("../vs/workbench/common/editor.zig");
const text_editor_selection_mod = @import("../vs/workbench/browser/parts/editor/textEditor.zig");
const Selection = @import("../vs/editor/common/core/selection.zig").Selection;
const WillShutdownEvent = @import("../vs/workbench/services/lifecycle/common/lifecycle.zig").WillShutdownEvent;

pub const HistoryStorage = struct {
    allocator: std.mem.Allocator,
    io: Io,
    path: []const u8,
    history: *HistoryService,

    const HistorySelectionDto = struct {
        start_line: usize,
        start_column: usize,
        end_line: usize,
        end_column: usize,
        selection_start_line: usize,
        selection_start_column: usize,
        position_line: usize,
        position_column: usize,
    };

    const HistoryNavigationDto = struct {
        group_id: u32,
        path: []const u8,
        top_view_line: usize = 1,
        selection: ?HistorySelectionDto = null,
    };

    const HistoryClosedDto = struct {
        path: []const u8,
        group_id: u32,
        index: usize,
        sticky: bool,
        pinned: bool,
        batch_id: u64,
    };

    const HistoryStateDto = struct {
        version: u32 = 1,
        recent: []const []const u8 = &.{},
        navigation: []const HistoryNavigationDto = &.{},
        closed: []const HistoryClosedDto = &.{},
    };

    pub fn save(_: WillShutdownEvent, self: *HistoryStorage) !void {
        const path = self.path;
        if (std.fs.path.dirname(path)) |dir| try Io.Dir.cwd().createDirPath(self.io, dir);
        var navigation = std.array_list.Managed(HistoryNavigationDto).init(self.allocator);
        defer navigation.deinit();
        for (self.history.default_stacks.selections.entries.items) |entry| {
            try navigation.append(.{
                .group_id = entry.group_id,
                .path = entry.path,
                .top_view_line = entry.top_view_line,
                .selection = if (entry.selection) |selection| if (std.mem.eql(u8, selection.kind, "text")) blk: {
                    const text_selection: *text_editor_selection_mod.TextEditorPaneSelection = @ptrCast(@alignCast(selection.context));
                    break :blk .{
                        .start_line = text_selection.selection.startLineNumber,
                        .start_column = text_selection.selection.startColumn,
                        .end_line = text_selection.selection.endLineNumber,
                        .end_column = text_selection.selection.endColumn,
                        .selection_start_line = text_selection.selection.selectionStartLineNumber,
                        .selection_start_column = text_selection.selection.selectionStartColumn,
                        .position_line = text_selection.selection.positionLineNumber,
                        .position_column = text_selection.selection.positionColumn,
                    };
                } else null else null,
            });
        }
        var closed = std.array_list.Managed(HistoryClosedDto).init(self.allocator);
        defer closed.deinit();
        for (self.history.closed_editors.items) |entry| {
            try closed.append(.{
                .path = entry.path,
                .group_id = entry.group_id,
                .index = entry.index,
                .sticky = entry.sticky,
                .pinned = entry.pinned,
                .batch_id = entry.batch_id,
            });
        }
        const dto = HistoryStateDto{ .recent = self.history.getHistory(), .navigation = navigation.items, .closed = closed.items };
        var out: Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        try std.json.Stringify.value(dto, .{}, &out.writer);
        var atomic = try Io.Dir.cwd().createFileAtomic(self.io, path, .{ .replace = true });
        defer atomic.deinit(self.io);
        try atomic.file.writeStreamingAll(self.io, out.written());
        try atomic.replace(self.io);
    }

    pub fn load(self: *HistoryStorage) !void {
        const path = self.path;
        const bytes = Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(8 * 1024 * 1024)) catch return;
        defer self.allocator.free(bytes);
        const parsed = std.json.parseFromSlice(HistoryStateDto, self.allocator, bytes, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value.version != 1) return;
        try self.history.loadHistory(parsed.value.recent);
        for (parsed.value.navigation) |entry| {
            var selection: ?editor_mod.IEditorPaneSelection = null;
            if (entry.selection) |sel| {
                const snapshot = try text_editor_selection_mod.TextEditorPaneSelection.create(self.allocator, Selection.init(
                    sel.selection_start_line,
                    sel.selection_start_column,
                    sel.position_line,
                    sel.position_column,
                ));
                selection = snapshot.interface();
            }
            self.history.recordNavigation(entry.group_id, entry.path, selection, entry.top_view_line, .PROGRAMMATIC) catch {
                if (selection) |iface| iface.dispose();
            };
        }
        for (parsed.value.closed) |entry| {
            const copy = try self.allocator.dupe(u8, entry.path);
            errdefer self.allocator.free(copy);
            try self.history.recordClosedEditor(.{
                .path = copy,
                .group_id = entry.group_id,
                .index = entry.index,
                .sticky = entry.sticky,
                .pinned = entry.pinned,
                .batch_id = entry.batch_id,
            });
            self.history.closed_batch_id = @max(self.history.closed_batch_id, entry.batch_id);
        }
    }
};
