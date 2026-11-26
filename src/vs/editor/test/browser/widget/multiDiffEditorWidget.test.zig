// Port of the multi-diff model/widget contracts tested by
// `src/vs/editor/test/browser/widget/multiDiffEditorWidget.test.ts`.
// Model lifecycle and the real terminal widget are tested independently.
const std = @import("std");
const testing = std.testing;
const model = @import("../../../browser/widget/multiDiffEditor/model.zig");
const view_model = @import("../../../browser/widget/multiDiffEditor/multiDiffEditorViewModel.zig");
const EditorDocument = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").EditorDocument;
const dispatch = @import("../../../../base/common/windowDispatch.zig");

fn doc(path: []const u8, text: []const u8) !*EditorDocument {
    return EditorDocument.createFromText(testing.allocator, testing.io, path, text, null);
}

fn source(document: *EditorDocument) model.DiffItemSource {
    return .{ .uri = document.model.uri(), .textModel = document };
}

test "MultiDiffEditorWidget: model retains real document identities, synthetic missing sides and active item" {
    var original = try doc("original.txt", "before\nold\na\nb\nc\nd\ne\nf\ng\nend");
    defer original.release();
    var modified = try doc("modified.txt", "before\nnew\na\nb\nc\nd\ne\nf\ng\nend");
    defer modified.release();
    const deleted = try doc("deleted.txt", "deleted");
    defer deleted.release();
    const a = try model.IDocumentDiffItem.create(testing.allocator, source(original), source(modified), .{});
    defer a.release();
    const b = try model.IDocumentDiffItem.create(testing.allocator, source(deleted), null, .{});
    defer b.release();
    var documents = model.MultiDiffEditorModel.init(testing.allocator);
    defer documents.deinit();
    var queue: dispatch.Queue = .{ .io = testing.io };
    const vm = try view_model.MultiDiffEditorViewModel.create(testing.allocator, testing.io, documents.interface(), &queue, null);
    defer vm.destroy();
    try testing.expect(vm.isLoading);
    try documents.setDocuments(.{ .items = &.{ a, b } });
    try testing.expect(!vm.isLoading);
    try testing.expectEqual(@as(usize, 2), vm.items.len);
    const va = vm.items[0];
    const vb = vm.items[1];
    try testing.expectEqual(original, va.original);
    try testing.expectEqual(modified, va.modified);
    try testing.expect(va.options.hide_unchanged_regions);
    try testing.expect(va.diffEditorViewModel.is_diff_up_to_date);
    try testing.expect(va.diffEditorViewModel.unchangedRegions().len != 0);
    try testing.expect(vb.documentDiffItem.modified == null);
    try testing.expect(!vb.isBinary());
    try testing.expectEqualStrings("", try vb.modified.model.borrowLineContent(1));
    try testing.expect(va.isFirst());
    try va.setFocused(true);
    try testing.expectEqual(va, vm.activeDiffItem.?);
    try va.setFocused(false);
    try testing.expect(vm.focusedDiffItem == null);
    try testing.expectEqual(va, vm.activeDiffItem.?);
    try vm.collapseAll();
    try testing.expect(va.collapsed and vb.collapsed);
    try vm.expandAll();
    try testing.expect(!va.collapsed and !vb.collapsed);
    try documents.setDocuments(.{ .items = &.{ b, a } });
    try testing.expectEqual(va, vm.items[1]);
    try testing.expectEqual(vb, vm.items[0]);
    try testing.expect(vb.isFirst() and va.isActive());
    try documents.setDocuments(.{ .items = &.{b} });
    try testing.expect(vm.activeDiffItem == null);
    try testing.expectEqual(vb, vm.items[0]);
}

test "MultiDiffEditorWidget: binary sources and option updates are distinct from missing text sides" {
    const original = try doc("original.txt", "old");
    defer original.release();
    const modified = try doc("modified.txt", "new");
    defer modified.release();
    const binary = try model.IDocumentDiffItem.create(testing.allocator, null, .{ .uri = .{ .scheme = "file", .path = .{ .raw = "/image.png" } } }, .{});
    defer binary.release();
    const text = try model.IDocumentDiffItem.create(testing.allocator, source(original), source(modified), .{});
    defer text.release();
    var documents = model.MultiDiffEditorModel.init(testing.allocator);
    defer documents.deinit();
    try documents.setDocuments(.{ .items = &.{ binary, text } });
    var queue: dispatch.Queue = .{ .io = testing.io };
    const vm = try view_model.MultiDiffEditorViewModel.create(testing.allocator, testing.io, documents.interface(), &queue, null);
    defer vm.destroy();
    try testing.expect(vm.items[0].isBinary());
    const item = vm.items[1];
    var options = text.options;
    options.ignore_trim_whitespace = false;
    options.render_side_by_side = false;
    try text.updateOptions(options);
    try testing.expect(!item.options.render_side_by_side);
    try testing.expect(!item.diffEditorViewModel.options.ignore_trim_whitespace);
    try testing.expect(item.diffEditorViewModel.is_diff_up_to_date);
    try testing.expect(item.options.hide_unchanged_regions);
}
