// Terminal coverage of the quickDiffDecorator.ts workbench contribution.
const std = @import("std");
const Allocator = std.mem.Allocator;
const QuickDiffWorkbenchController = @import("../../browser/quickDiffDecorator.zig").QuickDiffWorkbenchController;
const QuickDiffService = @import("../../common/quickDiffService.zig").QuickDiffService;
const ResourceEvent = @import("../../../../../base/common/event.zig").Emitter(void);
const time = @import("../../../../../base/common/timeCompat.zig");
const testing = std.testing;
const quick_diff = @import("../../common/quickDiff.zig");

const EditorMod = @import("../../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig");

test "quickDiffController: attach, apply gutter width and detach" {
    const allocator = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var service = QuickDiffService.init(allocator, null);
    defer service.deinit();

    var provider = TestProvider{};
    provider.init(allocator, "git.primary");
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
    var window = @import("../../../../../base/common/windowDispatch.zig").Queue{ .io = testing.io };
    var models = @import("../../browser/quickDiffModel.zig").QuickDiffModelService.init(allocator, &service, &window, null);
    defer models.deinit();
    try models.setRepositoryResources(&resources);
    var controller = QuickDiffWorkbenchController.init(allocator, &service, &models);
    defer controller.deinit();

    try controller.attach(editor, "/repo/test.zig");
    try testing.expectEqual(@as(usize, 1), controller.count());
    try testing.expectEqual(@as(usize, 1), editor.lineDecorationsWidth());
    const then = time.milliTimestamp() + 201;
    try testing.expect(!window.dispatch(then));
    try testing.expect(controller.entries.items[0].model.pending != null);
    models.worker.waitForReply();
    try testing.expect(window.dispatch(then));
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

    var provider = TestProvider{};
    provider.init(allocator, "git.primary");
    defer provider.deinit();
    const disposable = try service.addQuickDiffProvider(&provider.base);
    defer disposable.dispose();

    const editor = try EditorMod.Editor.createFromText(allocator, io, "a\nb", "test.zig", 60, 10);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    var window = @import("../../../../../base/common/windowDispatch.zig").Queue{ .io = testing.io };
    var models = @import("../../browser/quickDiffModel.zig").QuickDiffModelService.init(allocator, &service, &window, null);
    defer models.deinit();
    var controller = QuickDiffWorkbenchController.init(allocator, &service, &models);
    defer controller.deinit();
    try controller.attach(editor, "/repo/test.zig");

    try editor.typeCharacter("x");
    const due = controller.entries.items[0].model.due_at orelse return error.ExpectedContentEvent;
    try testing.expect(!window.dispatch(due - 1));
    try testing.expect(!window.dispatch(due));
    try testing.expect(controller.entries.items[0].model.pending != null);
    models.worker.waitForReply();
    try testing.expect(window.dispatch(due));

    try controller.setConfig(.{ .decorations = .none });
    try testing.expectEqual(@as(usize, 0), editor.lineDecorationsWidth());
}

const TestProvider = struct {
    base: quick_diff.QuickDiffProvider = undefined,
    content: []u8 = &.{},

    fn init(self: *TestProvider, allocator: Allocator, id: []const u8) void {
        self.content = allocator.dupe(u8, "a\nb") catch &.{};
        self.base = .{
            .context = self,
            .id = id,
            .label = id,
            .kind = .primary,
            .get_original_fn = getOriginal,
        };
    }

    fn deinit(self: *TestProvider) void {
        if (self.content.len > 0) testing.allocator.free(self.content);
    }

    fn getOriginal(context: *anyopaque, allocator: Allocator, _: std.Uri) anyerror!?quick_diff.Original {
        const self: *TestProvider = @ptrCast(@alignCast(context));
        return .{
            .content = try allocator.dupe(u8, self.content),
            .ref_label = try allocator.dupe(u8, "HEAD"),
        };
    }
};

test "quickDiffController: visible split editors share one computation and independent model references" {
    const a = testing.allocator;
    var providers = QuickDiffService.init(a, null);
    defer providers.deinit();
    var provider = TestProvider{};
    provider.init(a, "git.primary");
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
    var queue: @import("../../../../../base/common/windowDispatch.zig").Queue = .{ .io = testing.io };
    var resources = ResourceEvent.init(a);
    defer resources.deinit();
    var models = @import("../../browser/quickDiffModel.zig").QuickDiffModelService.init(a, &providers, &queue, null);
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
    models.worker.waitForReply();
    _ = queue.dispatch(deadline);
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
