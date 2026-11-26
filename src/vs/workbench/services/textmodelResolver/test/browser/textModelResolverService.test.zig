// Port of `src/vs/workbench/services/textmodelResolver/test/browser/textModelResolverService.test.ts`.
// The native dispatcher is the promise-disposal boundary in these cases.
const std = @import("std");
const resolver = @import("../../common/textModelResolverService.zig");
const dispatch = @import("../../../../../base/common/windowDispatch.zig");
const std_uri = @import("../../../../../base/common/stdUri.zig");
const EditorDocument = @import("../../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").EditorDocument;
const IdentifiedSingleEditOperation = @import("../../../../../editor/common/model.zig").IdentifiedSingleEditOperation;
const String = @import("../../../../../base/common/strings.zig").String;

fn disposed(_: void, count: *usize) !void {
    count.* += 1;
}
fn flush(queue: *dispatch.Queue) void {
    while (queue.nextTimeout(std.math.maxInt(i64), 1) == 0) _ = queue.dispatch(std.math.maxInt(i64));
}

fn shareSyntheticDocument(creator_first: bool) !void {
    const a = std.testing.allocator;
    var queue: dispatch.Queue = .{ .io = std.testing.io };
    var service = resolver.TextModelResolverService.init(a, std.testing.io, &queue);
    defer service.deinit();
    const api = service.interface();
    var owner = try api.createSyntheticDocument("shared", null);
    defer owner.dispose();
    const model = owner.object.textEditorModel;
    var count: usize = 0;
    _ = try owner.object.onWillDispose.listen(&count, disposed);
    var reference = try api.createModelReference(model.uri());
    defer reference.dispose();
    try std.testing.expectEqual(model, reference.object.textEditorModel);
    if (creator_first) owner.dispose() else reference.dispose();
    flush(&queue);
    try std.testing.expectEqualStrings("shared", try model.borrowLineContent(1));
    try std.testing.expectEqual(@as(usize, 0), count);
    owner.dispose();
    reference.dispose();
    try std.testing.expectEqual(@as(usize, 0), count);
    flush(&queue);
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "TextModelResolverService: synthetic document survives until both owners release (creator first: false)" {
    try shareSyntheticDocument(false);
}
test "TextModelResolverService: synthetic document survives until both owners release (creator first: true)" {
    try shareSyntheticDocument(true);
}

test "TextModelResolverService: synthetic document can be reacquired during pending resolver disposal" {
    const a = std.testing.allocator;
    var queue: dispatch.Queue = .{ .io = std.testing.io };
    var service = resolver.TextModelResolverService.init(a, std.testing.io, &queue);
    defer service.deinit();
    var owner = try service.createSyntheticDocument("shared", null);
    defer owner.dispose();
    const model = owner.object.textEditorModel;
    var count: usize = 0;
    _ = try owner.object.onWillDispose.listen(&count, disposed);
    owner.dispose();
    var second = try service.createModelReference(model.uri());
    defer second.dispose();
    flush(&queue);
    try std.testing.expectEqual(@as(usize, 0), count);
    try std.testing.expectEqual(model, second.object.textEditorModel);
    try std.testing.expectEqualStrings("shared", try model.borrowLineContent(1));
    second.dispose();
    flush(&queue);
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "TextModelResolverService: synthetic documents have unique URIs and preserve content and language" {
    const a = std.testing.allocator;
    var queue: dispatch.Queue = .{ .io = std.testing.io };
    var service = resolver.TextModelResolverService.init(a, std.testing.io, &queue);
    defer service.deinit();
    var first = try service.createSyntheticDocument("first", "json");
    defer first.dispose();
    var second = try service.createSyntheticDocument("second", "plaintext");
    defer second.dispose();
    const first_key = try std_uri.resourceKey(a, first.object.textEditorModel.uri());
    defer a.free(first_key);
    const second_key = try std_uri.resourceKey(a, second.object.textEditorModel.uri());
    defer a.free(second_key);
    try std.testing.expect(!std.mem.eql(u8, first_key, second_key));
    try std.testing.expect(std.mem.startsWith(u8, first_key, "inmemory:/synthetic/"));
    try std.testing.expectEqualStrings("first", try first.object.textEditorModel.borrowLineContent(1));
    try std.testing.expectEqualStrings("second", try second.object.textEditorModel.borrowLineContent(1));
    try std.testing.expectEqualStrings("json", first.object.getLanguageId());
    try std.testing.expectEqualStrings("plaintext", second.object.getLanguageId());
}

test "TextModelResolverService: resolve inMemory throws when model not found" {
    var queue: dispatch.Queue = .{ .io = std.testing.io };
    var service = resolver.TextModelResolverService.init(std.testing.allocator, std.testing.io, &queue);
    defer service.deinit();
    try std.testing.expectError(error.UnableToResolveResource, service.createModelReference(try std.Uri.parse("inmemory:/missing")));
}

test "TextModelResolverService: resolved dirty file eventually disposes and can be reacquired while dirty" {
    const a = std.testing.allocator;
    var queue: dispatch.Queue = .{ .io = std.testing.io };
    var service = resolver.TextModelResolverService.init(a, std.testing.io, &queue);
    defer service.deinit();
    const uri = try std.Uri.parse("file:///path/file_resolver.txt");
    var reference = try service.createResolvedModelReference(uri, "/path/file_resolver.txt", "Hello Html", false);
    defer reference.dispose();
    const doc = resolver.TextModelResolverService.documentOf(reference);
    const model = doc.model;
    var count: usize = 0;
    _ = try reference.object.onWillDispose.listen(&count, disposed);
    var edits = [_]IdentifiedSingleEditOperation{.init(model.getFullModelRange(), String.initBorrowed("make dirty"))};
    _ = try model.applyEdits(&edits, false);
    try std.testing.expect(doc.isDirty());
    reference.dispose();
    flush(&queue);
    try std.testing.expectEqual(@as(usize, 0), count);
    var second = try service.createModelReference(uri);
    defer second.dispose();
    try std.testing.expectEqual(model, second.object.textEditorModel);
    _ = try doc.replaceGeneratedContents("Hello Html");
    flush(&queue);
    try std.testing.expectEqual(@as(usize, 0), count);
    second.dispose();
    flush(&queue);
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "TextModelResolverService: model registered by an editor input shares its URI and outlives the service reference" {
    const a = std.testing.allocator;
    var queue: dispatch.Queue = .{ .io = std.testing.io };
    var service = resolver.TextModelResolverService.init(a, std.testing.io, &queue);
    defer service.deinit();
    const uri = try std.Uri.parse("test:/resource?revision=one");
    const doc = try EditorDocument.createFromText(a, std.testing.io, "/resource", "Hello Test", uri);
    defer doc.release();
    try service.registerDocument(doc, true);
    var reference = try service.interface().createModelReference(try std.Uri.parse("test:/resource?revision=one"));
    defer reference.dispose();
    try std.testing.expectEqual(doc.model, reference.object.textEditorModel);
    try std.testing.expect(reference.object.isReadonly());
    reference.dispose();
    flush(&queue);
    try std.testing.expectEqualStrings("Hello Test", try doc.model.borrowLineContent(1));
}
