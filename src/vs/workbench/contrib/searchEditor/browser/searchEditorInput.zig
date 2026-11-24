// Terminal input for the Open Results in Editor path in
// `src/vs/workbench/contrib/searchEditor/browser/searchEditorInput.ts`.
// Owns a query pane and its generated, in-memory results model.

const std = @import("std");
const editor_input = @import("../../../common/editor/editorInput.zig");
const Editor = @import("../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;

const SearchEditor = @import("searchEditor.zig").SearchEditor;

pub const SearchEditorInput = struct {
    base: editor_input.EditorInput,
    editor: *Editor,
    name: []const u8,
    search_editor: *SearchEditor,

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
        self.editor.deinit();
        allocator.destroy(self.editor);
        allocator.free(self.name);
        allocator.destroy(self);
    }
};
