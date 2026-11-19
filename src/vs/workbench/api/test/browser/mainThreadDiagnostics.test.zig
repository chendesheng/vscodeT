// Port of `src/vs/workbench/api/test/browser/mainThreadDiagnostics.test.ts`
// adapted to the synchronous marker service and explicit flush.

const std = @import("std");
const rpc = @import("../../../services/extensions/common/rpcProtocol.zig");
const actor_mod = @import("../../browser/mainThreadDiagnostics.zig");
const MainThreadDiagnostics = actor_mod.MainThreadDiagnostics;
const MarkerService = @import("../../../../platform/markers/common/markerService.zig").MarkerService;
const markers = @import("../../../../platform/markers/common/markers.zig");

const Fake = struct {
    notifications: usize = 0,
    last_payload: ?std.json.Value = null,

    fn notify(context: *anyopaque, method: []const u8, args: []const rpc.Arg) anyerror!void {
        const self: *Fake = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, method, "$acceptMarkersChange")) return;
        self.notifications += 1;
        if (args.len > 0) self.last_payload = args[0].json;
    }
};

test "mainThreadDiagnostics: changeMany stores markers and forwards changes" {
    const allocator = std.testing.allocator;
    var marker_service = MarkerService.init(allocator);
    defer marker_service.deinit();
    var fake = Fake{};
    const actor = try MainThreadDiagnostics.init(allocator, &marker_service, .{
        .context = &fake,
        .notify = Fake.notify,
    });
    defer actor.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const args_value = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(),
        \\["foo",[[{"$mid":1,"scheme":"file","authority":"","path":"/a","query":"","fragment":""},[{"severity":8,"message":"bad","startLineNumber":1,"startColumn":1,"endLineNumber":1,"endColumn":2}],true]]]
    , .{});
    const args = [_]rpc.Arg{.{ .json = args_value }};
    _ = try actor.invoke("$changeMany", &args, arena.allocator());

    const resource = markers.Resource{ .scheme = "file", .authority = "", .path = "/a" };
    const list = try marker_service.read(allocator, .{ .resource = resource });
    defer allocator.free(list);
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqualStrings("bad", list[0].message);
    try std.testing.expect(marker_service.isSourceTruncated(resource));

    try actor.flush();
    try std.testing.expectEqual(@as(usize, 1), fake.notifications);
    try std.testing.expect(fake.last_payload != null);
    const payload = fake.last_payload.?;
    try std.testing.expectEqual(@as(usize, 1), payload.array.items.len);
    const entry = payload.array.items[0];
    try std.testing.expectEqual(@as(usize, 2), entry.array.items.len);
    // The actor's own marker is filtered from the host-bound delta.
    try std.testing.expectEqual(@as(usize, 0), entry.array.items[1].array.items.len);
}

test "mainThreadDiagnostics: clear removes owner markers on dispose" {
    const allocator = std.testing.allocator;
    var marker_service = MarkerService.init(allocator);
    defer marker_service.deinit();
    var fake = Fake{};
    const actor = try MainThreadDiagnostics.init(allocator, &marker_service, .{
        .context = &fake,
        .notify = Fake.notify,
    });
    defer actor.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const args_value = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(),
        \\["foo",[[{"$mid":1,"scheme":"file","authority":"","path":"/b","query":"","fragment":""},[{"severity":4,"message":"warn","startLineNumber":1,"startColumn":1,"endLineNumber":1,"endColumn":1}]]]]
    , .{});
    const args = [_]rpc.Arg{.{ .json = args_value }};
    _ = try actor.invoke("$changeMany", &args, arena.allocator());
    const resource = markers.Resource{ .scheme = "file", .authority = "", .path = "/b" };
    try std.testing.expectEqual(@as(usize, 1), blk: {
        const list = try marker_service.read(allocator, .{ .resource = resource });
        defer allocator.free(list);
        break :blk list.len;
    });
    const clear_args = [_]rpc.Arg{.{ .json = .{ .string = "foo" } }};
    _ = try actor.invoke("$clear", &clear_args, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), blk: {
        const list = try marker_service.read(allocator, .{ .resource = resource });
        defer allocator.free(list);
        break :blk list.len;
    });
}
