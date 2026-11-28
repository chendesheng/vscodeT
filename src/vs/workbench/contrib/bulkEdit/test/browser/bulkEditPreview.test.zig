// Port of `src/vs/workbench/contrib/bulkEdit/test/browser/bulkEditPreview.test.ts`.
const std = @import("std");
const a = std.testing.allocator;
const BulkFileOperations = @import("../../browser/preview/bulkEditPreview.zig").BulkFileOperations;
const ResourceEdit = @import("../../../../../editor/common/languages.zig").WorkspaceResourceEdit;
const Range = @import("../../../../../editor/common/core/range.zig").Range;
const FileService = @import("../../../../../platform/files/common/fileService.zig").ProviderFileService;

fn uri(value: []const u8) std.Uri {
    return std.Uri.parse(value) catch unreachable;
}

test "BulkEditPreview: one needsConfirmation unchecks all of file" {
    var files = FileService.init(a);
    defer files.deinit();
    const edits = [_]ResourceEdit{
        .{ .file = .{ .new_resource = uri("some:///uri1"), .metadata = .{ .label = "cat1", .needs_confirmation = true } } },
        .{ .file = .{ .old_resource = uri("some:///uri1"), .new_resource = uri("some:///uri2"), .metadata = .{ .label = "cat2", .needs_confirmation = false } } },
    };
    const ops = try BulkFileOperations.create(a, files.interface(), null, &edits);
    defer ops.dispose();
    try std.testing.expectEqual(@as(usize, 1), ops.file_operations.items.len);
    try std.testing.expect(!ops.checked.isChecked(0));
}

test "BulkEditPreview: has categories" {
    var files = FileService.init(a);
    defer files.deinit();
    const edits = [_]ResourceEdit{
        .{ .file = .{ .new_resource = uri("some:///uri1"), .metadata = .{ .label = "uri1", .needs_confirmation = true } } },
        .{ .file = .{ .new_resource = uri("some:///uri2"), .metadata = .{ .label = "uri2", .needs_confirmation = false } } },
    };
    const ops = try BulkFileOperations.create(a, files.interface(), null, &edits);
    defer ops.dispose();
    try std.testing.expectEqual(@as(usize, 2), ops.categories.items.len);
    try std.testing.expectEqualStrings("uri1", ops.categories.items[0].metadata.label);
    try std.testing.expectEqualStrings("uri2", ops.categories.items[1].metadata.label);
}

test "BulkEditPreview: has not categories" {
    var files = FileService.init(a);
    defer files.deinit();
    const edits = [_]ResourceEdit{
        .{ .file = .{ .new_resource = uri("some:///uri1"), .metadata = .{ .label = "uri1", .needs_confirmation = true } } },
        .{ .file = .{ .new_resource = uri("some:///uri2"), .metadata = .{ .label = "uri1", .needs_confirmation = false } } },
    };
    const ops = try BulkFileOperations.create(a, files.interface(), null, &edits);
    defer ops.dispose();
    try std.testing.expectEqual(@as(usize, 1), ops.categories.items.len);
    try std.testing.expectEqualStrings("uri1", ops.categories.items[0].metadata.label);
    try std.testing.expectEqualStrings("uri1", ops.categories.items[0].metadata.label);
}

test "BulkEditPreview: category selection" {
    var files = FileService.init(a);
    defer files.deinit();
    const edits = [_]ResourceEdit{
        .{ .file = .{ .new_resource = uri("some:///uri1"), .metadata = .{ .label = "C1", .needs_confirmation = false } } },
        .{ .text = .{ .resource = uri("some:///uri2"), .text = "foo", .range = Range.init(1, 1, 1, 1), .metadata = .{ .label = "C2", .needs_confirmation = false } } },
    };
    const ops = try BulkFileOperations.create(a, files.interface(), null, &edits);
    defer ops.dispose();
    try std.testing.expect(ops.checked.isChecked(0));
    try std.testing.expect(ops.checked.isChecked(1));
    const original = try ops.getWorkspaceEdit(a);
    try std.testing.expect(!original.owned);
    try std.testing.expect(original.edits.ptr == edits[0..].ptr);
    ops.checked.updateChecked(0, false);
    const filtered = try ops.getWorkspaceEdit(a);
    defer if (filtered.owned) a.free(filtered.edits);
    try std.testing.expect(filtered.owned and filtered.edits.ptr != edits[0..].ptr);
    try std.testing.expectEqual(@as(usize, 2), edits.len);
    try std.testing.expectEqual(@as(usize, 1), filtered.edits.len);
}

test "BulkEditPreview: fix bad metadata" {
    var files = FileService.init(a);
    defer files.deinit();
    const edits = [_]ResourceEdit{
        .{ .file = .{ .new_resource = uri("some:///uri1"), .metadata = .{ .label = "C1", .needs_confirmation = true } } },
        .{ .text = .{ .resource = uri("some:///uri1"), .text = "foo", .range = Range.init(1, 1, 1, 1), .metadata = .{ .label = "C2", .needs_confirmation = false } } },
    };
    const ops = try BulkFileOperations.create(a, files.interface(), null, &edits);
    defer ops.dispose();
    try std.testing.expect(!ops.checked.isChecked(0));
    try std.testing.expect(!ops.checked.isChecked(1));
}

test "BulkEditPreview: rename groups subsequent text edits at the original URI" {
    var files = FileService.init(a);
    defer files.deinit();
    const edits = [_]ResourceEdit{
        .{ .file = .{ .old_resource = uri("some:///old"), .new_resource = uri("some:///new") } },
        .{ .text = .{ .resource = uri("some:///new"), .text = "foo", .range = Range.init(1, 1, 1, 1) } },
    };
    const ops = try BulkFileOperations.create(a, files.interface(), null, &edits);
    defer ops.dispose();
    try std.testing.expectEqual(@as(usize, 1), ops.file_operations.items.len);
    const original = ops.getUriOfEdit(1).?;
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    try std.testing.expectEqualStrings("/old", try @import("../../../../../base/common/stdUri.zig").path(original, scratch.allocator()));
    const text = try ops.getFileEdits(a, original);
    defer a.free(text);
    try std.testing.expectEqual(@as(usize, 1), text.len);
    try std.testing.expectEqualStrings("foo", text[0].text);
}

test "BulkEditPreview: model version and content conflicts are recorded without waiting for paint" {
    const Resolver = @import("../../../../services/textmodelResolver/common/textModelResolverService.zig").TextModelResolverService;
    const Queue = @import("../../../../../base/common/windowDispatch.zig").Queue;
    const model_types = @import("../../../../../editor/common/model.zig");
    const String = @import("../../../../../base/common/strings.zig").String;
    var files = FileService.init(a);
    defer files.deinit();
    var queue: Queue = .{ .io = std.testing.io };
    defer queue.deinitWindowEvents();
    var model_resolver = Resolver.init(a, std.testing.io, &queue);
    defer model_resolver.deinit();
    const target = uri("inmemory:/preview.txt");
    var reference = try model_resolver.createResolvedModelReference(target, "preview.txt", "old", false);
    defer reference.dispose();
    const model = reference.object.textEditorModel;
    const edits = [_]ResourceEdit{.{ .text = .{ .resource = target, .range = Range.init(1, 1, 1, 1), .text = "new", .version_id = model.getVersionId() } }};
    const ops = try BulkFileOperations.create(a, files.interface(), model_resolver.modelService(), &edits);
    defer ops.dispose();
    try std.testing.expect(!ops.conflicts.?.hasConflicts());
    var changes = [_]model_types.IdentifiedSingleEditOperation{.init(Range.init(1, 1, 1, 2), String.initBorrowed("n"))};
    _ = try model.applyEdits(&changes, false);
    try std.testing.expect(ops.conflicts.?.hasConflicts());
    try std.testing.expectEqual(@as(usize, 1), ops.conflicts.?.list().len);
    const stale = try BulkFileOperations.create(a, files.interface(), model_resolver.modelService(), &edits);
    defer stale.dispose();
    try std.testing.expect(stale.conflicts.?.hasConflicts());
}

test "BulkEditPreview: file changes conflict only for resources without a live model" {
    const Resolver = @import("../../../../services/textmodelResolver/common/textModelResolverService.zig").TextModelResolverService;
    const Queue = @import("../../../../../base/common/windowDispatch.zig").Queue;
    const MemoryProvider = @import("../../../../../platform/files/common/inMemoryFilesystemProvider.zig").InMemoryFileSystemProvider;
    var memory = try MemoryProvider.init(a, std.testing.io);
    defer memory.deinit();
    var files = FileService.init(a);
    defer files.deinit();
    _ = try files.registerProvider("inmemory", memory.interface());
    var queue: Queue = .{ .io = std.testing.io };
    defer queue.deinitWindowEvents();
    var model_resolver = Resolver.init(a, std.testing.io, &queue);
    defer model_resolver.deinit();
    const target = uri("inmemory:/before%20file.txt");
    const edits = [_]ResourceEdit{.{ .text = .{ .resource = target, .range = Range.init(1, 1, 1, 1), .text = "new" } }};
    const ops = try BulkFileOperations.create(a, files.interface(), model_resolver.modelService(), &edits);
    defer ops.dispose();
    var reference = try model_resolver.createResolvedModelReference(target, "before file.txt", "old", false);
    try files.interface().writeFile(target, "disk", .{ .create = true, .overwrite = true });
    try std.testing.expect(!ops.conflicts.?.hasConflicts());
    reference.dispose();
    for (0..8) |_| _ = queue.dispatch(std.math.maxInt(i64));
    try std.testing.expect(model_resolver.modelService().getModel(target) == null);
    try files.interface().writeFile(target, "disk2", .{ .create = true, .overwrite = true });
    try std.testing.expect(ops.conflicts.?.hasConflicts());
}

test "BulkEditPreview: the registered preview handler owns acceptance before applying workspace text edits" {
    const Resolver = @import("../../../../services/textmodelResolver/common/textModelResolverService.zig").TextModelResolverService;
    const Queue = @import("../../../../../base/common/windowDispatch.zig").Queue;
    const bulk = @import("../../../../../editor/browser/services/bulkEditService.zig");
    const BulkService = @import("../../browser/bulkEditService.zig").BulkEditService;
    const Disposable = @import("../../../../../base/common/lifecycle.zig").IDisposable;
    const Probe = struct {
        callback: ?bulk.PreviewListener = null,
        edits: []const ResourceEdit = &.{},
        result: ?bulk.IBulkEditResult = null,
        failure: ?anyerror = null,
        canceled: bool = false,
        fn preview(context: *anyopaque, edits: []const ResourceEdit, _: bulk.IBulkEditOptions, listener: bulk.PreviewListener) !?Disposable {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.edits = edits;
            self.callback = listener;
            return Disposable.from(@This(), self, cancel);
        }
        fn cancel(self: *@This()) void {
            self.canceled = true;
            self.callback = null;
        }
        fn applied(context: *anyopaque, result: anyerror!bulk.IBulkEditResult) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (result) |value| self.result = value else |err| self.failure = err;
        }
        fn accept(self: *@This(), selected: []const ResourceEdit) void {
            const callback = self.callback.?;
            self.callback = null;
            callback.complete(callback.context, selected);
        }
    };
    var queue: Queue = .{ .io = std.testing.io };
    defer queue.deinitWindowEvents();
    var model_resolver = Resolver.init(a, std.testing.io, &queue);
    defer model_resolver.deinit();
    const target = uri("inmemory:/preview.txt");
    var reference = try model_resolver.createResolvedModelReference(target, "preview.txt", "old", false);
    defer reference.dispose();
    const model = reference.object.textEditorModel;
    var service: BulkService = .{ .allocator = a, .resolver_service = model_resolver.interface(), .undo_redo_service = &(try model_resolver.undoRedoStore()).service };
    const api = service.interface();
    var probe: Probe = .{};
    const first = try api.setPreviewHandler(.{ .context = &probe, .preview = Probe.preview });
    const second = try api.setPreviewHandler(.{ .context = &probe, .preview = Probe.preview });
    defer second.dispose();
    first.dispose();
    try std.testing.expect(api.hasPreviewHandler());
    const edits = [_]ResourceEdit{
        .{ .text = .{ .resource = target, .range = Range.init(1, 1, 1, 2), .text = "b", .metadata = .{ .label = "confirm", .needs_confirmation = true } } },
        .{ .text = .{ .resource = target, .range = Range.init(1, 2, 1, 3), .text = "a" } },
    };
    const listener: bulk.EditListener = .{ .context = &probe, .complete = Probe.applied };
    const pending = try api.apply(.{ .edits = &edits }, .{}, listener);
    try std.testing.expect(pending != null and probe.callback != null);
    try std.testing.expectEqualStrings("old", try model.borrowLineContent(1));
    probe.accept(edits[0..1]);
    for (0..8) |_| _ = queue.dispatch(std.math.maxInt(i64));
    try std.testing.expect(probe.result.?.is_applied);
    try std.testing.expectEqualStrings("bld", try model.borrowLineContent(1));
    try std.testing.expectEqual(@as(usize, 1), probe.result.?.edit_count);
    probe.result = null;
    const discarded = try api.apply(.{ .edits = &edits }, .{ .show_preview = true }, listener);
    try std.testing.expect(discarded != null);
    probe.accept(&.{});
    try std.testing.expect(!probe.result.?.is_applied);
    try std.testing.expectEqualStrings("bld", try model.borrowLineContent(1));
    probe.result = null;
    const canceled = (try api.apply(.{ .edits = &edits }, .{ .show_preview = true }, listener)).?;
    canceled.dispose();
    try std.testing.expect(probe.canceled and probe.callback == null);
    try std.testing.expect(probe.result == null and probe.failure == null);
}

test "BulkEditPreview: checked changes update the same real preview model and leave the original intact" {
    const Resolver = @import("../../../../services/textmodelResolver/common/textModelResolverService.zig").TextModelResolverService;
    const Queue = @import("../../../../../base/common/windowDispatch.zig").Queue;
    const Provider = @import("../../browser/preview/bulkEditPreview.zig").BulkEditPreviewProvider;
    var files = FileService.init(a);
    defer files.deinit();
    var queue: Queue = .{ .io = std.testing.io };
    defer queue.deinitWindowEvents();
    var model_resolver = Resolver.init(a, std.testing.io, &queue);
    defer model_resolver.deinit();
    const target = uri("inmemory:/preview.txt");
    var reference = try model_resolver.createResolvedModelReference(target, "preview.txt", "old", false);
    defer reference.dispose();
    const model = reference.object.textEditorModel;
    const edits = [_]ResourceEdit{
        .{ .text = .{ .resource = target, .range = Range.init(1, 1, 1, 2), .text = "b" } },
        .{ .text = .{ .resource = target, .range = Range.init(1, 2, 1, 3), .text = "a" } },
    };
    const operations = try BulkFileOperations.create(a, files.interface(), model_resolver.modelService(), &edits);
    defer operations.dispose();
    const provider = try Provider.create(a, operations, model_resolver.interface(), model_resolver.modelService(), &queue);
    defer provider.dispose();
    // Drive-letter and UNC paths must remain URI paths after switching the
    // scheme and authority, even when the test runs on a POSIX machine.
    const uri_util = @import("../../../../../base/common/stdUri.zig");
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const arena = scratch.allocator();
    for ([_]struct { native: []const u8, expected: []const u8 }{
        .{ .native = "C:\\Users\\me\\preview.txt", .expected = "/C:/Users/me/preview.txt" },
        .{ .native = "\\\\server\\share\\preview.txt", .expected = "/share/preview.txt" },
    }) |fixture| {
        const original: std.Uri = .{ .scheme = "file", .path = .{ .raw = fixture.native } };
        const preview_uri = try provider.asPreviewUri(original);
        try std.testing.expectEqualStrings(fixture.expected, try uri_util.path(preview_uri, arena));
        const key = try uri_util.resourceKey(arena, preview_uri);
        const parsed = try std.Uri.parse(key);
        try std.testing.expectEqualStrings(try uri_util.authority(preview_uri, arena), try uri_util.authority(parsed, arena));
        try std.testing.expectEqualStrings(fixture.expected, try uri_util.path(parsed, arena));
        try std.testing.expectEqualStrings(try uri_util.encodedResource(arena, original), try uri_util.query(preview_uri, arena));
    }
    for (0..16) |_| _ = queue.dispatch(std.math.maxInt(i64));
    try std.testing.expect(provider.ready);
    const resources = try provider.resources(a);
    defer a.free(resources);
    try std.testing.expectEqual(@as(usize, 1), resources.len);
    const preview = model_resolver.modelService().getModel(resources[0].modified.?).?;
    try std.testing.expect(preview.isReadonly());
    try std.testing.expectEqualStrings("bad", try preview.textEditorModel.borrowLineContent(1));
    try std.testing.expectEqualStrings("old", try model.borrowLineContent(1));
    operations.checked.updateChecked(1, false);
    for (0..16) |_| _ = queue.dispatch(std.math.maxInt(i64));
    try std.testing.expectEqual(preview.textEditorModel, model_resolver.modelService().getModel(resources[0].modified.?).?.textEditorModel);
    try std.testing.expectEqualStrings("bld", try preview.textEditorModel.borrowLineContent(1));
    operations.checked.updateChecked(0, false);
    for (0..16) |_| _ = queue.dispatch(std.math.maxInt(i64));
    try std.testing.expectEqualStrings("old", try preview.textEditorModel.borrowLineContent(1));
    try std.testing.expect(!operations.conflicts.?.hasConflicts());
}

test "BulkEditPreview: shared tree enforces file/category check state and token-context rows" {
    const Resolver = @import("../../../../services/textmodelResolver/common/textModelResolverService.zig").TextModelResolverService;
    const Queue = @import("../../../../../base/common/windowDispatch.zig").Queue;
    const BulkTree = @import("../../browser/preview/bulkEditTree.zig").BulkEditTree;
    var files = FileService.init(a);
    defer files.deinit();
    var queue: Queue = .{ .io = std.testing.io };
    defer queue.deinitWindowEvents();
    var model_resolver = Resolver.init(a, std.testing.io, &queue);
    defer model_resolver.deinit();
    const target = uri("inmemory:/preview.txt");
    var reference = try model_resolver.createResolvedModelReference(target, "preview.txt", "alpha beta gamma", false);
    defer reference.dispose();
    const edits = [_]ResourceEdit{
        .{ .file = .{ .new_resource = target, .metadata = .{ .label = "Create", .needs_confirmation = true } } },
        .{ .text = .{ .resource = target, .range = Range.init(1, 7, 1, 11), .text = "new", .metadata = .{ .label = "Change" } } },
    };
    const operations = try BulkFileOperations.create(a, files.interface(), model_resolver.modelService(), &edits);
    defer operations.dispose();
    const tree = try BulkTree.create(a, operations, model_resolver.modelService(), false);
    defer tree.dispose();
    var text_element: ?*@import("../../browser/preview/bulkEditTree.zig").Element = null;
    for (tree.tree.view.rendered.items) |node| if (node.element) |element| {
        if (element.* == .text) text_element = element;
    };
    const text = text_element orelse return error.MissingTextEdit;
    try std.testing.expectEqualStrings("alpha ", text.text.prefix);
    try std.testing.expectEqualStrings("beta", text.text.selecting);
    try std.testing.expectEqualStrings("new", text.text.inserting);
    try std.testing.expect(text.isDisabled(operations));
    text.setChecked(operations, true);
    try std.testing.expect(!operations.checked.isChecked(1));
    for (tree.tree.view.rendered.items) |node| if (node.element) |element| {
        if (element.* == .file and element.file.operation.type_mask != 1) {
            element.setChecked(operations, true);
            break;
        }
    };
    try std.testing.expect(operations.checked.isChecked(0));
    try std.testing.expect(operations.checked.isChecked(1));
    try std.testing.expect(!text.isDisabled(operations));
    try tree.setGrouping(true, null);
    try std.testing.expectEqual(@as(usize, 2), tree.tree.count());
    tree.toggleChecked();
    try std.testing.expectEqual(@as(usize, 0), operations.checked.checked_count);
}
