// Port of `src/vs/platform/undoRedo/test/common/undoRedoService.test.ts`.
// Workspace elements exercise the same resource stack and grouping as model edits.
const std = @import("std");
const undo = @import("../../common/undoRedo.zig");
const UndoRedoService = @import("../../common/undoRedoService.zig").UndoRedoService;
const EditStackElement = @import("../../../../editor/common/model/editStack.zig").EditStackElement;

const Probe = struct {
    undoes: usize = 0,
    redoes: usize = 0,
    disposals: usize = 0,

    fn onUndo(context: *anyopaque) !void {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.undoes += 1;
    }
    fn onRedo(context: *anyopaque) !void {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.redoes += 1;
    }
    fn dispose(context: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.disposals += 1;
    }
    fn interface(self: *Probe, resources: []const std.Uri) undo.IWorkspaceUndoRedoElement {
        return .{ .allocator = std.testing.allocator, .context = self, .resources = resources, .label = "Workspace edit", .code = "test", .undo_fn = onUndo, .redo_fn = onRedo, .dispose_fn = dispose };
    }
    fn push(self: *Probe, service: *UndoRedoService, resources: []const std.Uri, group: ?*undo.UndoRedoGroup) !void {
        const element = try std.testing.allocator.create(EditStackElement);
        errdefer std.testing.allocator.destroy(element);
        element.* = .{ .workspace = self.interface(resources) };
        try service.pushElement(element, group, null);
    }
};

test "UndoRedoService: workspace elements are shared across all resources and disposed once" {
    const first = try std.Uri.parse("file:///first.txt");
    const second = try std.Uri.parse("file:///second.txt");
    var probe: Probe = .{};
    var service = UndoRedoService.init(std.testing.allocator);
    defer service.deinit();
    try probe.push(&service, &.{ first, second, first }, null);
    try std.testing.expect((try service.getLastElement(first)).? == (try service.getLastElement(second)).?);
    try service.undo(.{ .uri = second });
    try std.testing.expectEqual(@as(usize, 1), probe.undoes);
    try std.testing.expect(!(try service.canUndo(.{ .uri = first })));
    try std.testing.expect(try service.canRedo(.{ .uri = first }));
    try service.redo(.{ .uri = first });
    try std.testing.expectEqual(@as(usize, 1), probe.redoes);
    try std.testing.expect(!(try service.canRedo(.{ .uri = second })));
    try service.removeElements(first);
    try std.testing.expectEqual(@as(usize, 0), probe.disposals);
    try service.removeElements(second);
    try std.testing.expectEqual(@as(usize, 1), probe.disposals);
}

test "UndoRedoService: mixed single and workspace elements participate in one group" {
    const first = try std.Uri.parse("file:///first.txt");
    const second = try std.Uri.parse("file:///second.txt");
    const third = try std.Uri.parse("file:///third.txt");
    var a: Probe = .{};
    var b: Probe = .{};
    var service = UndoRedoService.init(std.testing.allocator);
    defer service.deinit();
    var group = undo.UndoRedoGroup.init();
    try a.push(&service, &.{first}, &group);
    try b.push(&service, &.{ second, third }, &group);
    try service.undo(.{ .uri = first });
    try std.testing.expectEqual(@as(usize, 1), a.undoes);
    try std.testing.expectEqual(@as(usize, 1), b.undoes);
    try service.redo(.{ .uri = second });
    try std.testing.expectEqual(@as(usize, 1), a.redoes);
    try std.testing.expectEqual(@as(usize, 1), b.redoes);
}

test "UndoRedoService: decoded and serialized file resources share one history" {
    const raw: std.Uri = .{ .scheme = "file", .path = .{ .raw = "/workspace/file #.txt" } };
    const encoded = try std.Uri.parse("file:///workspace/file%20%23.txt");
    var probe: Probe = .{};
    var service = UndoRedoService.init(std.testing.allocator);
    defer service.deinit();
    try probe.push(&service, &.{encoded}, null);
    try std.testing.expect(try service.canUndo(.{ .uri = raw }));
    try service.undo(.{ .uri = raw });
    try std.testing.expectEqual(@as(usize, 1), probe.undoes);
    try service.redo(.{ .uri = encoded });
    try std.testing.expectEqual(@as(usize, 1), probe.redoes);
}
