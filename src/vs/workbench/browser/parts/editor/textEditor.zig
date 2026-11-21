// Port of the `TextEditorPaneSelection` portion of
// `src/vs/workbench/browser/parts/editor/textEditor.ts`.
const std = @import("std");
const editor = @import("../../../common/editor.zig");
const Selection = @import("../../../../editor/common/core/selection.zig").Selection;

/// Upstream's `TEXT_EDITOR_SELECTION_THRESHOLD`.
const selection_threshold = 10;

pub const TextEditorPaneSelection = struct {
    allocator: std.mem.Allocator,
    selection: Selection,
    log_buf: [128]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator, selection: Selection) TextEditorPaneSelection {
        return .{ .allocator = allocator, .selection = selection };
    }

    pub fn create(allocator: std.mem.Allocator, selection: Selection) !*TextEditorPaneSelection {
        const self = try allocator.create(TextEditorPaneSelection);
        self.* = init(allocator, selection);
        return self;
    }

    fn dispose(context: *anyopaque) void {
        const self: *TextEditorPaneSelection = @ptrCast(@alignCast(context));
        self.allocator.destroy(self);
    }

    pub fn interface(self: *TextEditorPaneSelection) editor.IEditorPaneSelection {
        return .{
            .context = self,
            .kind = "text",
            .compare_fn = compare,
            .restore_fn = restore,
            .log_fn = log,
            .dispose_fn = dispose,
        };
    }

    fn compare(context: *anyopaque, other: *const editor.IEditorPaneSelection) editor.EditorPaneSelectionCompareResult {
        const self: *TextEditorPaneSelection = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, other.kind, "text")) return .DIFFERENT;
        const other_text: *const TextEditorPaneSelection = @ptrCast(@alignCast(other.context));
        const this_line = @min(self.selection.selectionStartLineNumber, self.selection.positionLineNumber);
        const other_line = @min(other_text.selection.selectionStartLineNumber, other_text.selection.positionLineNumber);
        if (this_line == other_line) return .IDENTICAL;
        const distance = if (this_line > other_line) this_line - other_line else other_line - this_line;
        if (distance < selection_threshold) return .SIMILAR;
        return .DIFFERENT;
    }

    fn restore(context: *anyopaque, options: editor.EditorOptions) editor.EditorOptions {
        const self: *TextEditorPaneSelection = @ptrCast(@alignCast(context));
        var restored = options;
        restored.selection = self.selection;
        restored.center_selection_if_outside_viewport = true;
        return restored;
    }

    fn log(context: *anyopaque) []const u8 {
        const self: *TextEditorPaneSelection = @ptrCast(@alignCast(context));
        return std.fmt.bufPrint(&self.log_buf, "line: {d}-{d}, col: {d}-{d}", .{
            self.selection.startLineNumber,
            self.selection.endLineNumber,
            self.selection.startColumn,
            self.selection.endColumn,
        }) catch "";
    }
};

test "TextEditorPaneSelection compares by line proximity" {
    var a = TextEditorPaneSelection.init(std.testing.allocator, Selection.init(1, 1, 2, 2));
    var a_interface = a.interface();
    var b = TextEditorPaneSelection.init(std.testing.allocator, Selection.init(1, 5, 3, 2));
    const b_interface = b.interface();
    try std.testing.expectEqual(editor.EditorPaneSelectionCompareResult.IDENTICAL, a_interface.compare(&b_interface));

    var c = TextEditorPaneSelection.init(std.testing.allocator, Selection.init(5, 1, 6, 2));
    const c_interface = c.interface();
    try std.testing.expectEqual(editor.EditorPaneSelectionCompareResult.SIMILAR, a_interface.compare(&c_interface));

    var d = TextEditorPaneSelection.init(std.testing.allocator, Selection.init(50, 1, 60, 2));
    const d_interface = d.interface();
    try std.testing.expectEqual(editor.EditorPaneSelectionCompareResult.DIFFERENT, a_interface.compare(&d_interface));

    const restored = a_interface.restore(.{});
    try std.testing.expect(restored.center_selection_if_outside_viewport);
    try std.testing.expect(restored.selection != null);
}
