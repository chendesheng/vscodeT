// Regression for the model URI contract of
// `src/vs/workbench/api/test/browser/mainThreadDocumentsAndEditors.test.ts`.
const std = @import("std");
const documents = @import("../../browser/mainThreadDocumentsAndEditors.zig");
const Editor = @import("../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const std_uri = @import("../../../../base/common/stdUri.zig");

test "documentsAndEditors: the document resource is the model URI" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    // The editor's path is a relative spelling; the model resource is the
    // canonical absolute URI language-feature requests carry.
    var editor = try Editor.createFromText(allocator, io, "{\n  \"a\": 1\n}\n", "relative.json", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const delta = try documents.addDocumentDelta(
        arena.allocator(),
        editor.model,
        "json",
        false,
        .{ .tab_size = 2, .indent_size = 2, .insert_spaces = true },
        &.{},
    );
    const a = arena.allocator();
    const document_value = delta.object.get("addedDocuments").?.array.items[0].object.get("uri").?;
    const editor_value = delta.object.get("addedEditors").?.array.items[0].object.get("documentUri").?;
    // VS Code sends URI components, not native fsPath strings. In particular
    // Windows file URIs have /C:/... paths, not C:\\... paths.
    const document_components = try std_uri.componentsFromJson(document_value, a);
    try std.testing.expectEqualStrings("file", document_components.scheme);
    try std.testing.expect(std.mem.startsWith(u8, document_components.path, "/"));
    if (@import("builtin").os.tag == .windows) try std.testing.expect(std.mem.indexOfScalar(u8, document_components.path, '\\') == null);

    const document_uri = try std.Uri.parse(try std_uri.encodedResourceFromJson(a, document_value));
    const editor_uri = try std.Uri.parse(try std_uri.encodedResourceFromJson(a, editor_value));
    const document_path = try std_uri.fsPath(document_uri, a);
    try std.testing.expect(std.fs.path.isAbsolute(document_path));
    // The mirror must not fall back to the editor's relative path spelling:
    // that is what the extension host could not match to `model.uri()`.
    try std.testing.expect(!std.mem.eql(u8, editor.path, document_path));
    try std.testing.expectEqualStrings(try std_uri.resourceKey(a, editor.model.uri()), try std_uri.resourceKey(a, document_uri));
    try std.testing.expectEqualStrings(try std_uri.resourceKey(a, document_uri), try std_uri.resourceKey(a, editor_uri));
    try std.testing.expectEqualStrings(try std_uri.fsPath(editor.model.uri(), a), document_path);
}
