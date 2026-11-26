// Port of `src/vs/workbench/api/test/browser/mainThreadDocumentContentProviders.test.ts`.
// The native resolver owns the actor's pending model update and worker lifetime.
const std = @import("std");
const service_mod = @import("../../../services/textmodelResolver/common/textModelResolverService.zig");
const resolver = @import("../../../../editor/common/services/resolverService.zig");
const dispatch = @import("../../../../base/common/windowDispatch.zig");
const ContentEvent = @import("../../../../editor/common/textModelEvents.zig").InternalModelContentChangeEvent;
const time = @import("../../../../base/common/timeCompat.zig");
const a = std.testing.allocator;

const Completion = struct {
    calls: usize = 0,
    failure: ?anyerror = null,
    fn complete(context: *anyopaque, result: anyerror!void) void {
        const self: *Completion = @ptrCast(@alignCast(context));
        self.calls += 1;
        result catch |err| {
            self.failure = err;
        };
    }
    fn listener(self: *Completion) resolver.VirtualContentListener {
        return .{ .context = self, .complete = complete };
    }
};

fn countChange(_: ContentEvent, count: *usize) !void {
    count.* += 1;
}

test "MainThreadDocumentContentProviders: events are processed properly" {
    var queue: dispatch.Queue = .{ .io = std.testing.io };
    var service = service_mod.TextModelResolverService.init(a, std.testing.io, &queue);
    defer service.deinit();
    const uri = try std.Uri.parse("test:uri");
    var owner = try service.createResolvedModelReference(uri, "uri", "1", true);
    defer owner.dispose();
    const model = owner.object.textEditorModel;
    var events: usize = 0;
    try model.onDidChangeContentWithContext(&events, countChange);
    var first: Completion = .{};
    var second: Completion = .{};
    _ = (try service.updateVirtualContent(uri, "1\n2", first.listener())).?;
    _ = (try service.updateVirtualContent(uri, "1\n2\n3", second.listener())).?;
    try std.testing.expectEqualStrings("1", try model.borrowLineContent(1));
    try std.testing.expectEqual(@as(usize, 1), first.calls);
    try std.testing.expectEqual(@as(usize, 0), second.calls);
    service.worker.?.stopWorker();
    try std.testing.expectEqual(@as(usize, 1), second.calls);
    try std.testing.expectEqual(@as(?anyerror, null), second.failure);
    var text = try model.getValue(.LF, false);
    defer text.deinit();
    try std.testing.expectEqualStrings("1\n2\n3", text.items);
    try std.testing.expectEqual(@as(usize, 1), events);
}

test "MainThreadDocumentContentProviders: model disposed during async operation" {
    var queue: dispatch.Queue = .{ .io = std.testing.io };
    var service = service_mod.TextModelResolverService.init(a, std.testing.io, &queue);
    defer service.deinit();
    const uri = try std.Uri.parse("test:disposed");
    var owner = try service.createResolvedModelReference(uri, "disposed", "initial", true);
    defer owner.dispose();
    var first: Completion = .{};
    _ = (try service.updateVirtualContent(uri, "updated", first.listener())).?;
    service.worker.?.stopWorker();
    try std.testing.expectEqualStrings("updated", try owner.object.textEditorModel.borrowLineContent(1));
    try std.testing.expectEqual(@as(usize, 1), first.calls);
    var second: Completion = .{};
    // The disposal task is queued first: the update must not acquire a strong
    // reference or publish a new model when its reply arrives.
    owner.dispose();
    _ = (try service.updateVirtualContent(uri, "should not apply", second.listener())).?;
    _ = queue.dispatch(time.milliTimestamp());
    try std.testing.expect(!service.hasResolvedModel(uri));
    try std.testing.expectEqual(@as(usize, 1), second.calls);
    service.worker.?.stopWorker();
    try std.testing.expectEqual(@as(usize, 1), second.calls);
    try std.testing.expectEqual(@as(?anyerror, null), second.failure);
    try std.testing.expect(!service.hasResolvedModel(uri));
}
