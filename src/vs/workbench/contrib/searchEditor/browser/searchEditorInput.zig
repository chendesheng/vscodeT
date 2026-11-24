// Terminal input for the Open Results in Editor path in
// `src/vs/workbench/contrib/searchEditor/browser/searchEditorInput.ts`.
// A read-only in-memory text editor hosts the serialized result snapshot.
// The Search panel owns the live query and runs subsequent searches.

const std = @import("std");
const editor_input = @import("../../../common/editor/editorInput.zig");
const Editor = @import("../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;

pub const SearchEditorInput = struct {
    base: editor_input.EditorInput,
    editor: *Editor,
    name: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        query: []const u8,
        text: []const u8,
        width: usize,
        height: usize,
    ) !*SearchEditorInput {
        const self = try allocator.create(SearchEditorInput);
        errdefer allocator.destroy(self);
        const name = try std.fmt.allocPrint(allocator, "Search: {s}", .{query});
        errdefer allocator.free(name);
        const editor = try Editor.createFromTextWithOptions(allocator, io, text, "search-results.code-search", width, height, .{ .reserve_scrollbar = true });
        editor.setReadOnly(true);
        self.* = .{
            .base = editor_input.EditorInput.init(allocator, "workbench.editorinputs.searchEditorInput"),
            .editor = editor,
            .name = name,
        };
        self.base.name = name;
        self.base.capabilities = editor_input.EditorInputCapabilities.Readonly;
        return self;
    }

    pub fn deinit(self: *SearchEditorInput) void {
        const allocator = self.base.allocator;
        self.base.dispose();
        self.base.deinit();
        self.editor.deinit();
        allocator.destroy(self.editor);
        allocator.free(self.name);
        allocator.destroy(self);
    }
};
