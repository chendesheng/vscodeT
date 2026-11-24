// Tests for the terminal port of
// `src/vs/workbench/contrib/scm/browser/quickDiffModel.ts`.
const std = @import("std");
const Allocator = std.mem.Allocator;

const model_mod = @import("../../browser/quickDiffModel.zig");
const quick_diff = @import("../../common/quickDiff.zig");
const quick_diff_service = @import("../../common/quickDiffService.zig");
const TestModel = @import("../../../../../editor/test/common/port/testSupport.zig").TestModel;

const EditorWorkerService = @import("../../../../../editor/browser/services/editorWorkerService.zig").EditorWorkerService;
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

    fn init(self: *Harness, text: []const u8, language: []const u8) !void {
        self.allocator = std.testing.allocator;
        self.service = quick_diff_service.QuickDiffService.init(self.allocator, null);
        self.providers = std.array_list.Managed(*ModelProvider).init(self.allocator);
        self.disposables = std.array_list.Managed(@import("../../../../../base/common/lifecycle.zig").IDisposable).init(self.allocator);
        self.model = try TestModel.init(self.allocator, text, language);
        self.quick_model = QuickDiffModel.init(
            self.allocator,
            self.model.model,
            "/repo/file.zig",
            &self.service,
            .{},
        );
    }

    fn deinit(self: *Harness) void {
        self.quick_model.deinit();
        self.model.deinit();
        for (self.providers.items) |provider| {
            provider.deinit();
            self.allocator.destroy(provider);
        }
        self.providers.deinit();
        for (self.disposables.items) |disposable| disposable.dispose();
        self.disposables.deinit();
        self.service.deinit();
    }

    fn addProvider(self: *Harness, id: []const u8, kind: QuickDiffProviderKind, content: ?[]const u8) !*ModelProvider {
        const provider = try self.allocator.create(ModelProvider);
        errdefer self.allocator.destroy(provider);
        try provider.init(self.allocator, id, kind, content);
        try self.providers.append(provider);
        try self.disposables.append(try self.service.addQuickDiffProvider(&provider.base));
        return provider;
    }

    fn recompute(self: *Harness) !void {
        try self.quick_model.recompute();
    }
};

const ModelProvider = struct {
    allocator: Allocator,
    base: QuickDiffProvider,
    content: ?[]u8,

    fn init(self: *ModelProvider, allocator: Allocator, id: []const u8, kind: QuickDiffProviderKind, content: ?[]const u8) !void {
        self.allocator = allocator;
        self.content = if (content) |value| try allocator.dupe(u8, value) else null;
        self.base = .{
            .context = self,
            .id = id,
            .label = id,
            .kind = kind,
            .get_original_fn = getOriginal,
        };
    }

    fn deinit(self: *ModelProvider) void {
        if (self.content) |content| self.allocator.free(content);
    }

    fn getOriginal(context: *anyopaque, allocator: Allocator, path: []const u8) anyerror!?quick_diff.Original {
        _ = path;
        const self: *ModelProvider = @ptrCast(@alignCast(context));
        const content = self.content orelse return null;
        return .{
            .content = try allocator.dupe(u8, content),
            .ref_label = try allocator.dupe(u8, "HEAD"),
        };
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
    try std.testing.expect(harness.quick_model.runScheduledDiff(&worker, 200));
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
        const thread = worker.thread.?.getHandle();
        try std.testing.expect(!open.quick_model.runScheduledDiff(&worker, 200));
        try std.testing.expectEqual(thread, worker.thread.?.getHandle());
    }

    // The replies may arrive together or in separate UI turns.
    while (open.quick_model.pending != null) {
        worker.waitForReply();
        _ = worker.dispatchReplies();
    }
    try std.testing.expectEqual(@as(usize, 1), open.quick_model.changes.items.len);
    worker.checkStopIdleWorker(200 + 5 * 60 * 1000 + 1);
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
