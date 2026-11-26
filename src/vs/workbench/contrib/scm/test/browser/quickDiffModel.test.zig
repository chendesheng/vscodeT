// Tests for the terminal port of
// `src/vs/workbench/contrib/scm/browser/quickDiffModel.ts`.
const std = @import("std");
const Allocator = std.mem.Allocator;

const model_mod = @import("../../browser/quickDiffModel.zig");
const quick_diff = @import("../../common/quickDiff.zig");
const quick_diff_service = @import("../../common/quickDiffService.zig");
const TestModel = @import("../../../../../editor/test/common/port/testSupport.zig").TestModel;

const EditorWorkerService = @import("../../../../../editor/browser/services/editorWorkerService.zig").EditorWorkerService;
const Queue = @import("../../../../../base/common/windowDispatch.zig").Queue;
const Resolver = @import("../../../../services/textmodelResolver/common/textModelResolverService.zig").TextModelResolverService;
const ModelReference = @import("../../../../../editor/common/services/resolverService.zig").ModelReference;
const time = @import("../../../../../base/common/timeCompat.zig");
const QuickDiffModel = model_mod.QuickDiffModel;
const QuickDiffModelOptions = model_mod.QuickDiffModelOptions;
const QuickDiffProvider = quick_diff.QuickDiffProvider;
const QuickDiffProviderKind = quick_diff.QuickDiffProviderKind;
const ChangeType = quick_diff.ChangeType;

const Harness = struct {
    allocator: Allocator,
    service: quick_diff_service.QuickDiffService,
    providers: std.array_list.Managed(*ModelProvider),
    disposables: std.array_list.Managed(@import("../../../../../base/common/lifecycle.zig").IDisposable),
    model: TestModel,
    quick_model: QuickDiffModel,
    queue: Queue,
    resolver: Resolver,
    worker: EditorWorkerService,

    fn init(self: *Harness, text: []const u8, language: []const u8) !void {
        self.allocator = std.testing.allocator;
        self.queue = .{ .io = std.testing.io };
        self.resolver = Resolver.init(self.allocator, std.testing.io, &self.queue);
        self.worker = EditorWorkerService.init();
        self.service = quick_diff_service.QuickDiffService.init(self.allocator, null);
        self.providers = std.array_list.Managed(*ModelProvider).init(self.allocator);
        self.disposables = std.array_list.Managed(@import("../../../../../base/common/lifecycle.zig").IDisposable).init(self.allocator);
        self.model = try TestModel.init(self.allocator, text, language);
        self.quick_model = QuickDiffModel.init(
            self.allocator,
            self.model.model,
            "/repo/file.zig",
            &self.service,
            self.resolver.interface(),
            .{},
        );
    }

    fn deinit(self: *Harness) void {
        self.quick_model.deinit();
        self.worker.deinit();
        self.model.deinit();
        for (self.disposables.items) |disposable| disposable.dispose();
        self.disposables.deinit();
        for (self.providers.items) |provider| {
            provider.deinit();
            self.allocator.destroy(provider);
        }
        self.providers.deinit();
        self.service.deinit();
        self.resolver.deinit();
    }

    fn addProvider(self: *Harness, id: []const u8, kind: QuickDiffProviderKind, content: ?[]const u8) !*ModelProvider {
        const provider = try self.allocator.create(ModelProvider);
        errdefer self.allocator.destroy(provider);
        try provider.init(self.allocator, &self.resolver, id, kind, content);
        errdefer provider.deinit();
        try self.providers.append(provider);
        try self.disposables.append(try self.service.addQuickDiffProvider(&provider.base));
        return provider;
    }

    fn recompute(self: *Harness) !void {
        self.quick_model.triggerDiff(time.milliTimestamp());
        _ = self.quick_model.runScheduledDiff(&self.worker, self.quick_model.due_at.?);
        try self.resolveOriginals();
        if (self.quick_model.pending != null) {
            self.worker.waitForReply();
            try std.testing.expect(self.worker.dispatchReplies());
        }
        try std.testing.expect(self.quick_model.pending == null);
    }

    fn resolveOriginals(self: *Harness) !void {
        // The fixture's original models are already published. The resolver
        // still delivers references asynchronously on the real window queue.
        for (0..20) |_| {
            if (self.quick_model.resolving == null) break;
            _ = self.queue.dispatch(time.milliTimestamp() + 1);
        }
        try std.testing.expect(self.quick_model.resolving == null);
    }
};

const ModelProvider = struct {
    allocator: Allocator,
    base: QuickDiffProvider,
    uri: ?[]u8,
    reference: ?ModelReference,

    fn init(self: *ModelProvider, allocator: Allocator, resolver: *Resolver, id: []const u8, kind: QuickDiffProviderKind, content: ?[]const u8) !void {
        self.allocator = allocator;
        self.uri = if (content != null) try std.fmt.allocPrint(allocator, "test-quickdiff:/{s}", .{id}) else null;
        errdefer if (self.uri) |uri| allocator.free(uri);
        self.reference = if (self.uri) |uri| try resolver.createResolvedModelReference(try std.Uri.parse(uri), "original.zig", content.?, true) else null;
        self.base = .{
            .context = self,
            .id = id,
            .label = id,
            .kind = kind,
            .get_original_fn = getOriginal,
        };
    }

    fn deinit(self: *ModelProvider) void {
        if (self.reference) |*reference| reference.dispose();
        if (self.uri) |uri| self.allocator.free(uri);
    }

    fn getOriginal(context: *anyopaque, allocator: Allocator, resource: std.Uri) anyerror!?quick_diff.Original {
        _ = resource;
        const self: *ModelProvider = @ptrCast(@alignCast(context));
        const uri = try allocator.dupe(u8, self.uri orelse return null);
        errdefer allocator.free(uri);
        return .{ .resource_uri = uri, .ref_label = try allocator.dupe(u8, "HEAD") };
    }
};

test "quickDiffModel: clean file has no changes" {
    var harness: Harness = undefined;
    try harness.init("a\nb\nc", "zig");
    defer harness.deinit();
    _ = try harness.addProvider("git.primary", .primary, "a\nb\nc");

    try harness.recompute();
    try std.testing.expectEqual(@as(usize, 1), harness.quick_model.quickDiffs().len);
    try std.testing.expectEqual(@as(usize, 0), harness.quick_model.changes.items.len);
    try std.testing.expectEqual(@as(usize, 0), harness.quick_model.all_changes.items.len);
}

test "quickDiffModel: modify, add and delete classification" {
    var harness: Harness = undefined;
    try harness.init("a\nB\nc", "zig");
    defer harness.deinit();
    _ = try harness.addProvider("git.primary", .primary, "a\nb\nc");

    try harness.recompute();
    try std.testing.expectEqual(@as(usize, 1), harness.quick_model.changes.items.len);
    const change = harness.quick_model.changes.items[0];
    try std.testing.expectEqual(ChangeType.modify, quick_diff.getChangeType(change.change));
    try std.testing.expectEqual(@as(usize, 2), change.change.modifiedStartLineNumber);
    try std.testing.expectEqual(@as(usize, 2), change.change.modifiedEndLineNumber);

    // Insertion.
    var added: Harness = undefined;
    try added.init("a\nx\nb", "zig");
    defer added.deinit();
    _ = try added.addProvider("git.primary", .primary, "a\nb");
    try added.recompute();
    try std.testing.expectEqual(@as(usize, 1), added.quick_model.changes.items.len);
    try std.testing.expectEqual(ChangeType.add, quick_diff.getChangeType(added.quick_model.changes.items[0].change));

    // Deletion.
    var deleted: Harness = undefined;
    try deleted.init("a\nc", "zig");
    defer deleted.deinit();
    _ = try deleted.addProvider("git.primary", .primary, "a\nb\nc");
    try deleted.recompute();
    try std.testing.expectEqual(@as(usize, 1), deleted.quick_model.changes.items.len);
    try std.testing.expectEqual(ChangeType.delete, quick_diff.getChangeType(deleted.quick_model.changes.items[0].change));
}

test "quickDiffModel: untracked files have no original and no changes" {
    var harness: Harness = undefined;
    try harness.init("new\nfile", "zig");
    defer harness.deinit();
    _ = try harness.addProvider("git.primary", .primary, null);

    try harness.recompute();
    try std.testing.expectEqual(@as(usize, 0), harness.quick_model.quickDiffs().len);
    try std.testing.expectEqual(@as(usize, 0), harness.quick_model.changes.items.len);
}

test "quickDiffModel: ignore trim whitespace follows the option" {
    var harness: Harness = undefined;
    try harness.init("a   \nb", "zig");
    defer harness.deinit();
    _ = try harness.addProvider("git.primary", .primary, "a\nb");

    try harness.recompute();
    try std.testing.expectEqual(@as(usize, 0), harness.quick_model.changes.items.len);

    harness.quick_model.setIgnoreTrimWhitespace(false);
    try harness.recompute();
    try std.testing.expectEqual(@as(usize, 1), harness.quick_model.changes.items.len);
}

test "quickDiffModel: version tracking updates after a model edit" {
    var harness: Harness = undefined;
    try harness.init("a\nb", "zig");
    defer harness.deinit();
    _ = try harness.addProvider("git.primary", .primary, "a\nb");

    try harness.recompute();
    const initial_version = harness.quick_model.changes_version_id;
    try std.testing.expectEqual(harness.model.model.getVersionId(), initial_version);
    try std.testing.expectEqual(@as(usize, 0), harness.quick_model.changes.items.len);

    try harness.model.applyEdit(@import("../../../../../editor/common/core/range.zig").Range.init(2, 2, 2, 2), "x");
    try harness.recompute();
    try std.testing.expect(harness.quick_model.changes_version_id != initial_version);
    try std.testing.expectEqual(@as(usize, 1), harness.quick_model.changes.items.len);
}

test "quickDiffModel publishes the captured version before running a queued diff on the same worker" {
    var harness: Harness = undefined;
    try harness.init("a", "zig");
    defer harness.deinit();
    _ = try harness.addProvider("git.primary", .primary, "b");

    var worker = EditorWorkerService.init();
    defer worker.deinit();
    harness.quick_model.triggerDiff(1000);
    try std.testing.expect(!harness.quick_model.runScheduledDiff(&worker, 1100));
    try std.testing.expect(harness.quick_model.pending == null);
    try std.testing.expect(!harness.quick_model.runScheduledDiff(&worker, 1200));
    try harness.resolveOriginals();
    try std.testing.expect(harness.quick_model.pending != null);
    const first_thread = worker.thread.?.getHandle();
    const first_version = harness.model.model.getVersionId();
    try harness.model.applyEdit(@import("../../../../../editor/common/core/range.zig").Range.init(1, 1, 1, 2), "b");
    harness.quick_model.triggerDiff(1250);
    worker.waitForReply();
    try std.testing.expect(worker.dispatchReplies());
    try std.testing.expectEqual(first_version, harness.quick_model.changes_version_id);
    try std.testing.expectEqual(@as(usize, 1), harness.quick_model.changes.items.len);
    try std.testing.expect(!harness.quick_model.runScheduledDiff(&worker, 1449));
    try std.testing.expect(harness.quick_model.pending == null);
    try std.testing.expect(!harness.quick_model.runScheduledDiff(&worker, 1450));
    try harness.resolveOriginals();
    try std.testing.expect(harness.quick_model.pending != null);
    try std.testing.expectEqual(first_thread, worker.thread.?.getHandle());
    worker.waitForReply();
    try std.testing.expect(worker.dispatchReplies());
    try std.testing.expectEqual(harness.model.model.getVersionId(), harness.quick_model.changes_version_id);
    try std.testing.expectEqual(@as(usize, 0), harness.quick_model.changes.items.len);
}

test "quickDiffModel publishes an empty result without starting the editor worker" {
    var harness: Harness = undefined;
    try harness.init("a", "zig");
    defer harness.deinit();
    var worker = EditorWorkerService.init();
    defer worker.deinit();
    _ = harness.quick_model.runScheduledDiff(&worker, 200);
    try harness.resolveOriginals();
    try std.testing.expect(worker.thread == null);
    try std.testing.expect(harness.quick_model.pending == null);
    try std.testing.expectEqual(harness.model.model.getVersionId(), harness.quick_model.changes_version_id);
}

test "quickDiffModel detaches the reply for a closed file while the shared worker serves another file" {
    var worker = EditorWorkerService.init();
    defer worker.deinit();
    var open: Harness = undefined;
    try open.init("x", "zig");
    defer open.deinit();
    _ = try open.addProvider("git.primary", .primary, "y");

    {
        var closing: Harness = undefined;
        try closing.init("a", "zig");
        defer closing.deinit();
        _ = try closing.addProvider("git.primary", .primary, "b");
        try std.testing.expect(!closing.quick_model.runScheduledDiff(&worker, 200));
        try closing.resolveOriginals();
        const thread = worker.thread.?.getHandle();
        try std.testing.expect(!open.quick_model.runScheduledDiff(&worker, 200));
        try open.resolveOriginals();
        try std.testing.expectEqual(thread, worker.thread.?.getHandle());
    }

    // The replies may arrive together or in separate UI turns.
    while (open.quick_model.pending != null) {
        worker.waitForReply();
        _ = worker.dispatchReplies();
    }
    try std.testing.expectEqual(@as(usize, 1), open.quick_model.changes.items.len);
    worker.checkStopIdleWorker(worker.last_used + 5 * 60 * 1000 + 1);
    try std.testing.expect(worker.thread == null);
}

test "quickDiffModel: primary/secondary overlap suppression" {
    var harness: Harness = undefined;
    try harness.init("a\nB\nc", "zig");
    defer harness.deinit();
    _ = try harness.addProvider("git.primary", .primary, "a\nb\nc");
    _ = try harness.addProvider("git.secondary", .secondary, "a\nb\nc");

    try harness.recompute();
    // Both providers produce the identical change; the secondary one is kept
    // in `all_changes` but suppressed from the painted `changes`.
    try std.testing.expectEqual(@as(usize, 2), harness.quick_model.all_changes.items.len);
    try std.testing.expectEqual(@as(usize, 1), harness.quick_model.changes.items.len);
    try std.testing.expectEqualStrings("git.primary", harness.quick_model.changes.items[0].provider_id);

    // A secondary with a different original baseline is not suppressed.
    var different: Harness = undefined;
    try different.init("a\nB\nc", "zig");
    defer different.deinit();
    _ = try different.addProvider("git.primary", .primary, "a\nb\nc");
    _ = try different.addProvider("git.secondary", .secondary, "a\nx\nc");
    try different.recompute();
    try std.testing.expectEqual(@as(usize, 2), different.quick_model.changes.items.len);
}

test "quickDiffModel: results and navigation" {
    var harness: Harness = undefined;
    try harness.init("a\nB\nc\nD\ne", "zig");
    defer harness.deinit();
    _ = try harness.addProvider("git.primary", .primary, "a\nb\nc\nd\ne");

    try harness.recompute();
    try std.testing.expectEqual(@as(usize, 2), harness.quick_model.changes.items.len);

    try std.testing.expectEqual(@as(usize, 0), harness.quick_model.findNextClosestChange(1, true, null));
    try std.testing.expectEqual(@as(usize, 1), harness.quick_model.findNextClosestChange(2, false, null));
    try std.testing.expectEqual(@as(usize, 1), harness.quick_model.findPreviousClosestChange(5, true, null));

    const results = try harness.quick_model.getQuickDiffResults(std.testing.allocator);
    defer QuickDiffModel.freeQuickDiffResults(std.testing.allocator, results);
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqual(@as(usize, 2), results[0].changes.len);
    try std.testing.expectEqualStrings("HEAD", harness.quick_model.getDiffEditorModel("git.primary").?.ref_label);
}

test "quickDiffModel: URI references are shared, updated by model events, and released on provider removal" {
    const a = std.testing.allocator;
    var queue: Queue = .{ .io = std.testing.io };
    var resolver = Resolver.init(a, std.testing.io, &queue);
    defer resolver.deinit();
    const uri = try std.Uri.parse("test:/quick-diff-original");
    var reference = try resolver.createResolvedModelReference(uri, "original.txt", "old", true);
    defer reference.dispose();
    const original = Resolver.documentOf(reference);
    var modified = try TestModel.init(a, "new", "plaintext");
    defer modified.deinit();
    var service = quick_diff_service.QuickDiffService.init(a, null);
    defer service.deinit();
    const Provider = struct {
        fn get(_: *anyopaque, allocator: Allocator, _: std.Uri) !?quick_diff.Original {
            const resource = try allocator.dupe(u8, "test:/quick-diff-original");
            errdefer allocator.free(resource);
            return .{ .ref_label = try allocator.dupe(u8, "Original"), .resource_uri = resource };
        }
    };
    var primary: QuickDiffProvider = .{ .context = @constCast(&{}), .id = "one", .label = "One", .kind = .primary, .get_original_fn = Provider.get };
    var secondary: QuickDiffProvider = .{ .context = @constCast(&{}), .id = "two", .label = "Two", .kind = .secondary, .get_original_fn = Provider.get };
    _ = try service.addQuickDiffProvider(&primary);
    _ = try service.addQuickDiffProvider(&secondary);
    var worker = EditorWorkerService.init();
    defer worker.deinit();
    worker.attachWindow(&queue);
    var model = QuickDiffModel.init(a, modified.model, "/repo/file.txt", &service, resolver.interface(), .{});
    model.attachWindow(&queue, &worker);
    defer model.deinit();
    const Pump = struct {
        fn settle(q: *Queue, quick: *QuickDiffModel, w: *EditorWorkerService) !void {
            const deadline = quick.due_at orelse return error.MissingQuickDiffDeadline;
            for (0..20) |_| {
                if (quick.due_at == null and quick.resolving == null) break;
                _ = q.dispatch(@max(deadline, time.milliTimestamp()));
            }
            try std.testing.expect(quick.resolving == null);
            if (quick.pending != null) {
                w.waitForReply();
                for (0..20) |_| {
                    if (quick.pending == null) break;
                    _ = q.dispatch(@max(deadline, time.milliTimestamp()));
                }
                try std.testing.expect(quick.pending == null);
            }
        }
    };
    model.triggerDiff(time.milliTimestamp());
    try Pump.settle(&queue, &model, &worker);
    try std.testing.expectEqual(@as(usize, 1), model.original_models.count());
    try std.testing.expectEqual(@as(usize, 2), model.quickDiffs().len);
    try std.testing.expectEqual(original, model.getDiffEditorModel("one").?.original_document);
    try std.testing.expectEqual(original, model.getDiffEditorModel("two").?.original_document);
    try std.testing.expectEqual(@as(usize, 2), model.all_changes.items.len);
    try std.testing.expectEqual(@as(usize, 1), model.changes.items.len);
    try std.testing.expectEqualStrings("test:/quick-diff-original", model.quickDiffs()[0].original.resource_uri);

    // The original model's content event is sufficient to schedule the next
    // diff; there is no provider or renderer polling for changed bytes.
    _ = try original.replaceGeneratedContents("new");
    try Pump.settle(&queue, &model, &worker);
    try std.testing.expectEqual(original, model.getDiffEditorModel("one").?.original_document);
    try std.testing.expectEqual(@as(usize, 0), model.all_changes.items.len);
    service.removeProvider(&primary);
    service.removeProvider(&secondary);
    model.triggerDiff(time.milliTimestamp());
    try Pump.settle(&queue, &model, &worker);
    try std.testing.expectEqual(@as(usize, 0), model.original_models.count());
    try std.testing.expectEqual(@as(usize, 0), model.quickDiffs().len);

    // A model disposed before its asynchronously delivered reference must
    // cancel the acquisition without publishing a stale result.
    _ = try service.addQuickDiffProvider(&primary);
    var abandoned = QuickDiffModel.init(a, modified.model, "/repo/file.txt", &service, resolver.interface(), .{});
    abandoned.attachWindow(&queue, &worker);
    abandoned.triggerDiff(time.milliTimestamp());
    const deadline = abandoned.due_at.?;
    _ = queue.dispatch(deadline);
    try std.testing.expect(abandoned.resolving != null);
    abandoned.deinit();
    for (0..20) |_| {
        if (queue.nextTimeout(time.milliTimestamp(), 1) != 0) break;
        _ = queue.dispatch(time.milliTimestamp());
    }
    try std.testing.expectEqualStrings("new", try original.model.borrowLineContent(1));
}

test "QuickDiffModelService: canonical resource and options share model lifetime independently of callers" {
    const a = std.testing.allocator;
    const Emitter = @import("../../../../../base/common/event.zig").Emitter;
    var queue: Queue = .{ .io = std.testing.io };
    var resolver = Resolver.init(a, std.testing.io, &queue);
    defer resolver.deinit();
    const uri = try std.Uri.parse("file:///repo/quick-diff.txt");
    var working = try resolver.createResolvedModelReference(uri, "/repo/quick-diff.txt", "file", false);
    defer working.dispose();
    const doc = Resolver.documentOf(working);
    var providers = quick_diff_service.QuickDiffService.init(a, null);
    defer providers.deinit();
    var resources = Emitter(void).init(a);
    defer resources.deinit();
    var models = model_mod.QuickDiffModelService.init(a, &providers, &queue, resolver.interface());
    defer models.deinit();
    try models.setRepositoryResources(&resources);
    const api = models.interface();
    try std.testing.expect((try api.createQuickDiffModelReference(try std.Uri.parse("git:/missing"), .{})) == null);
    try std.testing.expect((try api.createQuickDiffModelReference(try std.Uri.parse("file:///repo/missing.txt"), .{})) == null);
    var first = (try api.createQuickDiffModelReference(uri, .{})).?;
    defer first.dispose();
    var second = (try api.createQuickDiffModelReference(uri, .{})).?;
    defer second.dispose();
    var different = (try api.createQuickDiffModelReference(uri, .{ .max_computation_time_ms = null })).?;
    defer different.dispose();
    try std.testing.expectEqual(first.object, second.object);
    try std.testing.expect(first.object != different.object);
    try std.testing.expectEqual(doc.model, first.object.model);
    try std.testing.expectEqual(@as(usize, 2), models.references.count());
    try std.testing.expectEqual(@as(usize, 2), resources.listenerCount());
    first.dispose();
    try std.testing.expectEqual(@as(usize, 2), models.references.count());
    different.dispose();
    try std.testing.expectEqual(@as(usize, 1), resources.listenerCount());
    second.object.due_at = null;
    second.object.scheduler.schedule(null);
    _ = try doc.replaceGeneratedContents("new content");
    try std.testing.expect(second.object.due_at.? >= time.milliTimestamp());
    second.dispose();
    try std.testing.expectEqual(@as(usize, 0), models.references.count());
    try std.testing.expectEqual(@as(usize, 0), resources.listenerCount());
}
