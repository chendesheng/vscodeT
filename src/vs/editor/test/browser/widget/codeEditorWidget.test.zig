// Lifecycle regressions for the CodeEditorWidget.setModel port from
// `src/vs/editor/browser/widget/codeEditor/codeEditorWidget.ts`, alongside
// upstream `src/vs/editor/test/browser/widget/codeEditorWidget.test.ts`.
const std = @import("std");
const common = @import("../../../common/editorCommon.zig");
const terminal = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig");
const Editor = terminal.Editor;
const EditorDocument = terminal.EditorDocument;
const Selection = @import("../../../common/core/selection.zig").Selection;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;

const ModelChanges = struct {
    editor: *Editor,
    old: ?*TextModel = null,
    new: ?*TextModel = null,
    order: usize = 0,
    correct: bool = true,

    fn matches(uri: ?std.Uri, model: ?*TextModel) bool {
        if (model) |value| {
            const resource = uri orelse return false;
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const actual = resource.path.toRawMaybeAlloc(arena.allocator()) catch return false;
            const expected = value.uri().path.toRawMaybeAlloc(arena.allocator()) catch return false;
            return std.mem.eql(u8, resource.scheme, value.uri().scheme) and std.mem.eql(u8, actual, expected);
        }
        return uri == null;
    }

    fn will(event: common.IModelChangedEvent, self: *ModelChanges) !void {
        self.correct = self.correct and self.order % 2 == 0 and self.editor.getModel() == self.old and matches(event.oldModelUrl, self.old) and matches(event.newModelUrl, self.new);
        self.order += 1;
    }

    fn did(event: common.IModelChangedEvent, self: *ModelChanges) !void {
        self.correct = self.correct and self.order % 2 == 1 and self.editor.getModel() == self.new and matches(event.oldModelUrl, self.old) and matches(event.newModelUrl, self.new);
        self.order += 1;
    }
};

test "Editor: setModel keeps the widget and its lifecycle listeners across null and new models" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const one = try EditorDocument.createFromText(a, io, "one.txt", "first\nsecond\nthird", try std.Uri.parse("test:/one.txt"));
    defer one.release();
    const two = try EditorDocument.createFromText(a, io, "two.txt", "new", try std.Uri.parse("test:/two.txt"));
    defer two.release();
    const editor = try Editor.createDetached(a, io, 40, 10, .{});
    defer {
        editor.deinit();
        a.destroy(editor);
    }
    var changes: ModelChanges = .{ .editor = editor, .new = one.model };
    _ = try editor.on_will_change_model.listen(&changes, ModelChanges.will);
    _ = try editor.on_did_change_model.listen(&changes, ModelChanges.did);
    try std.testing.expect(!editor.hasModel());
    try editor.setModel(null);
    try std.testing.expectEqual(@as(usize, 0), changes.order);
    try editor.setModel(one);
    try std.testing.expectEqual(@as(usize, 1), one.editors.items.len);
    try std.testing.expectEqual(@as(usize, 2), changes.order);
    try editor.setModel(one);
    try std.testing.expectEqual(@as(usize, 2), changes.order);
    try editor.setSelections(&.{Selection.init(3, 2, 3, 2)});
    editor.setWordWrapOverride(.off);
    editor.setReadOnly(true);

    changes.old = one.model;
    changes.new = null;
    try editor.setModel(null);
    try std.testing.expectEqual(@as(usize, 4), changes.order);
    try std.testing.expect(!editor.hasModel());
    try std.testing.expectEqual(@as(usize, 0), one.editors.items.len);
    editor.setViewport(32, 7);
    editor.setStatusRow(false);
    editor.setGutterOptions(false, 3, false);

    changes.old = null;
    changes.new = two.model;
    try editor.setModel(two);
    try std.testing.expect(changes.correct);
    try std.testing.expectEqual(@as(usize, 6), changes.order);
    try std.testing.expectEqual(two.model, editor.getModel().?);
    try std.testing.expectEqual(@as(usize, 1), two.editors.items.len);
    try std.testing.expectEqual(@as(usize, 7), editor.textHeight());
    try std.testing.expectEqual(@as(usize, 32), editor.textAreaWidth());
    try std.testing.expectEqual(.off, editor.wrap_mode);
    try std.testing.expect(editor.isReadOnly());
    const selections = try editor.getSelections();
    defer a.free(selections);
    try std.testing.expectEqual(@as(usize, 1), selections.len);
    try std.testing.expectEqual(Selection.init(1, 1, 1, 1), selections[0]);
    _ = try one.replaceGeneratedContents("detached edit\nwith more lines");
    try std.testing.expectEqual(@as(usize, 1), editor.viewLineCount());
    try std.testing.expectEqualStrings("new", try editor.model.borrowLineContent(1));
    _ = try two.replaceGeneratedContents("new\nmodel change");
    try std.testing.expectEqual(@as(usize, 2), editor.viewLineCount());
}

test "Editor: setModel detaches shared cursor tracking and reattaches model updates" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const shared = try EditorDocument.createFromText(a, io, "shared.txt", "shared\nother", null);
    defer shared.release();
    const next = try EditorDocument.createFromText(a, io, "next.txt", "another", null);
    defer next.release();
    const first = try Editor.createViewFromDocument(shared, 40, 10, .{});
    defer {
        first.deinit();
        a.destroy(first);
    }
    const second = try Editor.createViewFromDocument(shared, 40, 10, .{});
    defer {
        second.deinit();
        a.destroy(second);
    }
    try std.testing.expect(first.cursor_tracking and second.cursor_tracking);
    try second.setSelections(&.{Selection.init(2, 2, 2, 2)});
    try second.setModel(next);
    try std.testing.expect(!first.cursor_tracking and !second.cursor_tracking);
    try std.testing.expectEqual(@as(usize, 1), shared.editors.items.len);
    try std.testing.expectEqual(@as(usize, 1), next.editors.items.len);
    _ = try shared.replaceGeneratedContents("this is still the first pane\nsecond\nthird");
    try std.testing.expectEqual(@as(usize, 3), first.viewLineCount());
    try std.testing.expectEqual(@as(usize, 1), second.viewLineCount());
    try second.setModel(shared);
    try std.testing.expect(first.cursor_tracking and second.cursor_tracking);
    try std.testing.expectEqual(@as(usize, 0), next.editors.items.len);
    try std.testing.expectEqual(@as(usize, 3), second.viewLineCount());
}
