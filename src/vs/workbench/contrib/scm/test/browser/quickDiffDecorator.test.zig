// Terminal coverage of the quickDiffDecorator.ts workbench contribution.
const std = @import("std");
const Allocator = std.mem.Allocator;
const QuickDiffWorkbenchController = @import("../../browser/quickDiffDecorator.zig").QuickDiffWorkbenchController;
const QuickDiffService = @import("../../common/quickDiffService.zig").QuickDiffService;
const ResourceEvent = @import("../../../../../base/common/event.zig").Emitter(void);
const time = @import("../../../../../base/common/timeCompat.zig");
const testing = std.testing;
const quick_diff = @import("../../common/quickDiff.zig");

const Queue = @import("../../../../../base/common/windowDispatch.zig").Queue;
const Resolver = @import("../../../../services/textmodelResolver/common/textModelResolverService.zig").TextModelResolverService;
const ModelReference = @import("../../../../../editor/common/services/resolverService.zig").ModelReference;
const EditorMod = @import("../../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig");

test "quickDiffController: attach, apply gutter width and detach" {
    const allocator = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var service = QuickDiffService.init(allocator, null);
    defer service.deinit();

    var window: Queue = .{ .io = testing.io };
    var resolver = Resolver.init(allocator, testing.io, &window);
    defer resolver.deinit();
    var provider = TestProvider{};
    try provider.init(&resolver, "git.primary");
    defer provider.deinit();
    const disposable = try service.addQuickDiffProvider(&provider.base);
    defer disposable.dispose();

    const editor = try EditorMod.Editor.createFromText(allocator, io, "a\nB", "test.zig", 60, 10);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    var resources = ResourceEvent.init(allocator);
    defer resources.deinit();
    var models = @import("../../browser/quickDiffModel.zig").QuickDiffModelService.init(allocator, &service, &window, resolver.interface());
    defer models.deinit();
    try models.setRepositoryResources(&resources);
    var controller = QuickDiffWorkbenchController.init(allocator, &service, &models);
    defer controller.deinit();

    try controller.attach(editor, "/repo/test.zig");
    try testing.expectEqual(@as(usize, 1), controller.count());
    try testing.expectEqual(@as(usize, 1), editor.lineDecorationsWidth());
    const then = time.milliTimestamp() + 201;
    try testing.expect(!window.dispatch(then));
    try resolveOriginals(&window, controller.entries.items[0].model, then);
    try testing.expect(controller.entries.items[0].model.pending != null);
    models.worker.waitForReply();
    try finishDiff(&window, controller.entries.items[0].model, then);
    try testing.expect(editor.decorationGeneration() > 0);
    try testing.expect(controller.entries.items[0].model.due_at == null);
    try resources.fire({});
    try testing.expect(controller.entries.items[0].model.due_at != null);

    controller.detach(editor);
    try testing.expect(!resources.hasListeners());
    try testing.expectEqual(@as(usize, 0), controller.count());
    try testing.expectEqual(@as(usize, 0), editor.lineDecorationsWidth());
}

test "quickDiffController: a scheduled diff updates after an edit and config disables decorations" {
    const allocator = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var service = QuickDiffService.init(allocator, null);
    defer service.deinit();

    var window: Queue = .{ .io = testing.io };
    var resolver = Resolver.init(allocator, testing.io, &window);
    defer resolver.deinit();
    var provider = TestProvider{};
    try provider.init(&resolver, "git.primary");
    defer provider.deinit();
    const disposable = try service.addQuickDiffProvider(&provider.base);
    defer disposable.dispose();

    const editor = try EditorMod.Editor.createFromText(allocator, io, "a\nb", "test.zig", 60, 10);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    var models = @import("../../browser/quickDiffModel.zig").QuickDiffModelService.init(allocator, &service, &window, resolver.interface());
    defer models.deinit();
    var controller = QuickDiffWorkbenchController.init(allocator, &service, &models);
    defer controller.deinit();
    try controller.attach(editor, "/repo/test.zig");

    try editor.typeCharacter("x");
    const due = controller.entries.items[0].model.due_at orelse return error.ExpectedContentEvent;
    try testing.expect(!window.dispatch(due - 1));
    try testing.expect(!window.dispatch(due));
    try resolveOriginals(&window, controller.entries.items[0].model, due);
    try testing.expect(controller.entries.items[0].model.pending != null);
    models.worker.waitForReply();
    try finishDiff(&window, controller.entries.items[0].model, due);

    try controller.setConfig(.{ .decorations = .none });
    try testing.expectEqual(@as(usize, 0), editor.lineDecorationsWidth());
}

const TestProvider = struct {
    base: quick_diff.QuickDiffProvider = undefined,
    reference: ModelReference = undefined,

    fn init(self: *TestProvider, resolver: *Resolver, id: []const u8) !void {
        self.reference = try resolver.createResolvedModelReference(try std.Uri.parse("test-quickdiff:/original"), "original.zig", "a\nb", true);
        self.base = .{
            .context = self,
            .id = id,
            .label = id,
            .kind = .primary,
            .get_original_fn = getOriginal,
        };
    }

    fn deinit(self: *TestProvider) void {
        self.reference.dispose();
    }

    fn getOriginal(context: *anyopaque, allocator: Allocator, _: std.Uri) anyerror!?quick_diff.Original {
        _ = context;
        const uri = try allocator.dupe(u8, "test-quickdiff:/original");
        errdefer allocator.free(uri);
        return .{ .content = &.{}, .resource_uri = uri, .ref_label = try allocator.dupe(u8, "HEAD") };
    }
};

test "quickDiffController: visible split editors share one computation and independent model references" {
    const a = testing.allocator;
    var providers = QuickDiffService.init(a, null);
    defer providers.deinit();
    var queue: Queue = .{ .io = testing.io };
    var resolver = Resolver.init(a, testing.io, &queue);
    defer resolver.deinit();
    var provider = TestProvider{};
    try provider.init(&resolver, "git.primary");
    defer provider.deinit();
    _ = try providers.addQuickDiffProvider(&provider.base);
    const editor = try EditorMod.Editor.createFromText(a, testing.io, "a\nB", "test.zig", 60, 10);
    defer {
        editor.deinit();
        a.destroy(editor);
    }
    const split = try EditorMod.Editor.createViewFromEditor(editor, 60, 10);
    defer {
        split.deinit();
        a.destroy(split);
    }
    var resources = ResourceEvent.init(a);
    defer resources.deinit();
    var models = @import("../../browser/quickDiffModel.zig").QuickDiffModelService.init(a, &providers, &queue, resolver.interface());
    defer models.deinit();
    try models.setRepositoryResources(&resources);
    var controller = QuickDiffWorkbenchController.init(a, &providers, &models);
    defer controller.deinit();
    try controller.attach(editor, "/repo/test.zig");
    try controller.attach(split, "/repo/test.zig");
    const first = controller.entries.items[0].model;
    try testing.expectEqual(first, controller.entries.items[1].model);
    try testing.expectEqual(@as(usize, 1), models.references.count());
    try testing.expectEqual(@as(usize, 1), resources.listenerCount());
    const deadline = first.due_at.?;
    _ = queue.dispatch(deadline);
    try resolveOriginals(&queue, first, deadline);
    models.worker.waitForReply();
    try finishDiff(&queue, first, deadline);
    try testing.expectEqual(@as(usize, 1), first.changes.items.len);
    try testing.expectEqual(@as(usize, 1), editor.quick_diff_decoration_count);
    try testing.expectEqual(@as(usize, 1), split.quick_diff_decoration_count);
    controller.detach(editor);
    try testing.expectEqual(@as(usize, 1), models.references.count());
    try testing.expectEqual(first, controller.entries.items[0].model);
    try resources.fire({});
    try testing.expect(first.due_at != null);
    controller.detach(split);
    try testing.expectEqual(@as(usize, 0), models.references.count());
    try testing.expect(!resources.hasListeners());
}

fn resolveOriginals(queue: *Queue, model: *@import("../../browser/quickDiffModel.zig").QuickDiffModel, now: i64) !void {
    for (0..20) |_| {
        if (model.resolving == null) break;
        _ = queue.dispatch(@max(now, time.milliTimestamp()));
    }
    try testing.expect(model.resolving == null);
}

fn finishDiff(queue: *Queue, model: *@import("../../browser/quickDiffModel.zig").QuickDiffModel, now: i64) !void {
    for (0..20) |_| {
        if (model.pending == null) break;
        _ = queue.dispatch(@max(now, time.milliTimestamp()));
    }
    try testing.expect(model.pending == null);
}
