// Port of `src/vs/editor/test/common/services/modelService.test.ts`.
// Native EditorDocument uses the same shared ModelUndoRedoStore as the
// workbench's resource model collection, without mounting an editor view.
const std = @import("std");
const ModelUndoRedoStore = @import("../../../common/services/modelService.zig").ModelUndoRedoStore;
const EditorDocument = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").EditorDocument;
const Edit = @import("../../../common/model.zig").IdentifiedSingleEditOperation;
const Range = @import("../../../common/core/range.zig").Range;
const String = @import("../../../../base/common/strings.zig").String;
const UndoRedoGroup = @import("../../../../platform/undoRedo/common/undoRedo.zig").UndoRedoGroup;

fn create(store: *ModelUndoRedoStore, uri: std.Uri, text: []const u8) !*EditorDocument {
    return EditorDocument.createFromTextWithUndoStore(std.testing.allocator, std.testing.io, "test.txt", text, uri, store);
}
fn edit(document: *EditorDocument, group: ?*UndoRedoGroup) !void {
    var edits = [_]Edit{.init(Range.init(1, 5, 1, 5), String.initBorrowed("1"))};
    _ = try document.model.pushEditOperations(null, &edits, null, group);
    try std.testing.expectEqualStrings("text1", try document.model.borrowLineContent(1));
}

test "ModelService: maintains undo for same resource and same content" {
    const store = try ModelUndoRedoStore.create(std.testing.allocator);
    defer store.releaseOwner();
    const uri = try std.Uri.parse("file:///test.txt");
    {
        const first = try create(store, uri, "text");
        defer first.release();
        try edit(first, null);
    }
    const second = try create(store, uri, "text1");
    defer second.release();
    try second.model.undo();
    try std.testing.expectEqualStrings("text", try second.model.borrowLineContent(1));
}

test "ModelService: maintains version id and alternative version id for same resource and same content" {
    const store = try ModelUndoRedoStore.create(std.testing.allocator);
    defer store.releaseOwner();
    const uri = try std.Uri.parse("file:///test.txt");
    var version: u32 = undefined;
    var alternative: u32 = undefined;
    {
        const first = try create(store, uri, "text");
        defer first.release();
        try edit(first, null);
        version = first.model.getVersionId();
        alternative = first.model.getAlternativeVersionId();
    }
    const second = try create(store, uri, "text1");
    defer second.release();
    try std.testing.expectEqual(version, second.model.getVersionId());
    try std.testing.expectEqual(alternative, second.model.getAlternativeVersionId());
}

test "ModelService: does not maintain undo for same resource and different content" {
    const store = try ModelUndoRedoStore.create(std.testing.allocator);
    defer store.releaseOwner();
    const uri = try std.Uri.parse("file:///test.txt");
    {
        const first = try create(store, uri, "text");
        defer first.release();
        try edit(first, null);
    }
    const second = try create(store, uri, "text2");
    defer second.release();
    try second.model.undo();
    try std.testing.expectEqualStrings("text2", try second.model.borrowLineContent(1));
}

test "ModelService: model edits from distinct resources share the undo group" {
    const store = try ModelUndoRedoStore.create(std.testing.allocator);
    defer store.releaseOwner();
    const one = try create(store, try std.Uri.parse("file:///first.txt"), "text");
    defer one.release();
    const two = try create(store, try std.Uri.parse("file:///second.txt"), "text");
    defer two.release();
    var group = UndoRedoGroup.init();
    try edit(one, &group);
    try edit(two, &group);
    try one.model.undo();
    try std.testing.expectEqualStrings("text", try one.model.borrowLineContent(1));
    try std.testing.expectEqualStrings("text", try two.model.borrowLineContent(1));
    try two.model.redo();
    try std.testing.expectEqualStrings("text1", try one.model.borrowLineContent(1));
    try std.testing.expectEqualStrings("text1", try two.model.borrowLineContent(1));
}
