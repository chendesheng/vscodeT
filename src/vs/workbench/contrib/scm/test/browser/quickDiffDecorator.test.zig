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
    var controller = QuickDiffWorkbenchController.init(allocator, &service, &window);
    controller.resources_changed = &resources;
    defer controller.deinit();

    try controller.attach(editor, "/repo/test.zig");
    try testing.expectEqual(@as(usize, 1), controller.count());
    try testing.expectEqual(@as(usize, 1), editor.lineDecorationsWidth());
    const then = time.milliTimestamp() + 201;
    try testing.expect(!window.dispatch(then));
    try testing.expect(controller.entries.items[0].model.pending != null);
    controller.worker.waitForReply();
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
    var controller = QuickDiffWorkbenchController.init(allocator, &service, &window);
    defer controller.deinit();
    try controller.attach(editor, "/repo/test.zig");

    try editor.typeCharacter("x");
    const due = controller.entries.items[0].model.due_at orelse return error.ExpectedContentEvent;
    try testing.expect(!window.dispatch(due - 1));
    try testing.expect(!window.dispatch(due));
    try testing.expect(controller.entries.items[0].model.pending != null);
    controller.worker.waitForReply();
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

    fn getOriginal(context: *anyopaque, allocator: Allocator, _: []const u8) anyerror!?quick_diff.Original {
        const self: *TestProvider = @ptrCast(@alignCast(context));
        return .{
            .content = try allocator.dupe(u8, self.content),
            .ref_label = try allocator.dupe(u8, "HEAD"),
        };
    }
};
