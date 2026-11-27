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
    var memory = try MemoryProvider.init(a);
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
