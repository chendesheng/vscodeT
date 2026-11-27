// Port of `src/vs/workbench/api/test/browser/mainThreadDiagnostics.test.ts`
// adapted to the synchronous marker service and explicit flush.

const std = @import("std");
const rpc = @import("../../../services/extensions/common/rpcProtocol.zig");
const actor_mod = @import("../../browser/mainThreadDiagnostics.zig");
const MainThreadDiagnostics = actor_mod.MainThreadDiagnostics;
const MarkerService = @import("../../../../platform/markers/common/markerService.zig").MarkerService;
const markers = @import("../../../../platform/markers/common/markers.zig");

const Fake = struct {
    allocator: std.mem.Allocator,
    notifications: usize = 0,
    /// Serialized copy of the last notification payload. The actor builds its
    /// payload in a scratch arena and frees it when `flush` returns, so the
    /// test must snapshot it inside the callback.
    last_payload_json: ?[]u8 = null,

    fn notify(context: *anyopaque, method: []const u8, args: []const rpc.Arg) anyerror!void {
        const self: *Fake = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, method, "$acceptMarkersChange")) return;
        self.notifications += 1;
        if (args.len == 0) return;
        if (self.last_payload_json) |old| self.allocator.free(old);
        self.last_payload_json = std.json.Stringify.valueAlloc(self.allocator, args[0].json, .{}) catch null;
    }
};

test "mainThreadDiagnostics: changeMany stores markers and forwards changes" {
    const allocator = std.testing.allocator;
    var marker_service = MarkerService.init(allocator);
    defer marker_service.deinit();
    var fake = Fake{ .allocator = allocator };
    defer if (fake.last_payload_json) |json| allocator.free(json);
    const actor = try MainThreadDiagnostics.init(allocator, &marker_service, .{
        .context = &fake,
        .notify = Fake.notify,
    }, null);
    defer actor.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const args_value = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(),
        \\["foo",[[{"$mid":1,"scheme":"file","authority":"","path":"/a","query":"","fragment":""},[{"severity":8,"message":"bad","startLineNumber":1,"startColumn":1,"endLineNumber":1,"endColumn":2}],true]]]
    , .{});
    const args = [_]rpc.Arg{ .{ .json = args_value.array.items[0] }, .{ .json = args_value.array.items[1] } };
    _ = try actor.invoke("$changeMany", &args, arena.allocator());

    const resource = markers.Resource{ .scheme = "file", .authority = "", .path = "/a" };
    const list = try marker_service.read(allocator, .{ .resource = resource });
    defer allocator.free(list);
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqualStrings("bad", list[0].message);
    try std.testing.expect(marker_service.isSourceTruncated(resource));

    try actor.flush();
    try std.testing.expectEqual(@as(usize, 1), fake.notifications);
    const payload_json = fake.last_payload_json orelse return error.TestUnexpectedResult;
    const payload = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), payload_json, .{});
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
    var fake = Fake{ .allocator = allocator };
    defer if (fake.last_payload_json) |json| allocator.free(json);
    const actor = try MainThreadDiagnostics.init(allocator, &marker_service, .{
        .context = &fake,
        .notify = Fake.notify,
    }, null);
    defer actor.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const args_value = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(),
        \\["foo",[[{"$mid":1,"scheme":"file","authority":"","path":"/b","query":"","fragment":""},[{"severity":4,"message":"warn","startLineNumber":1,"startColumn":1,"endLineNumber":1,"endColumn":1}]]]]
    , .{});
    const args = [_]rpc.Arg{ .{ .json = args_value.array.items[0] }, .{ .json = args_value.array.items[1] } };
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

test "mainThreadDiagnostics: preserves diagnostic code targets and related resource locations" {
    const allocator = std.testing.allocator;
    var service = MarkerService.init(allocator);
    defer service.deinit();
    var fake = Fake{ .allocator = allocator };
    defer if (fake.last_payload_json) |json| allocator.free(json);
    const actor = try MainThreadDiagnostics.init(allocator, &service, .{ .context = &fake, .notify = Fake.notify }, null);
    defer actor.deinit();
    {
        var request = std.heap.ArenaAllocator.init(allocator);
        defer request.deinit();
        const arena = request.allocator();
        const value = try std.json.parseFromSliceLeaky(std.json.Value, arena,
            \\["lint",[[{"scheme":"file","path":"/a"},[{"severity":8,"message":"bad","code":{"value":"E42","target":{"scheme":"https","authority":"example.com","path":"/docs","fragment":"E42"}},"relatedInformation":[{"resource":{"scheme":"git","path":"/other file","query":"ref=HEAD"},"message":"previous declaration","startLineNumber":3,"startColumn":5,"endLineNumber":3,"endColumn":8}]}]]]]
        , .{});
        const args = [_]rpc.Arg{ .{ .json = value.array.items[0] }, .{ .json = value.array.items[1] } };
        _ = try actor.invoke("$changeMany", &args, arena);
    }
    const resource: markers.Resource = .{ .scheme = "file", .path = "/a" };
    const list = try service.read(allocator, .{ .resource = resource });
    defer allocator.free(list);
    try std.testing.expectEqual(@as(usize, 1), list.len);
    const marker = list[0];
    try std.testing.expectEqualStrings("E42", marker.code.?);
    try std.testing.expectEqualStrings("E42", marker.code_target.?.fragment);
    try std.testing.expectEqual(@as(usize, 1), marker.related_information.len);
    const info = marker.related_information[0];
    try std.testing.expectEqualStrings("/other file", info.resource.path);
    try std.testing.expectEqualStrings("ref=HEAD", info.resource.query);
    try std.testing.expectEqualStrings("previous declaration", info.message);
    try std.testing.expectEqual(@as(u32, 5), info.start_column);
    // A workbench-owned marker carrying the same diagnostic must be forwarded
    // back to the extension host with structured URIs, not discarded fields.
    try service.changeOne("native", resource, &.{.{ .message = marker.message, .code = marker.code, .code_target = marker.code_target, .related_information = marker.related_information }}, null);
    try actor.flush();
    var response = std.heap.ArenaAllocator.init(allocator);
    defer response.deinit();
    const payload = try std.json.parseFromSliceLeaky(std.json.Value, response.allocator(), fake.last_payload_json.?, .{});
    const diagnostic = payload.array.items[0].array.items[1].array.items[0].object;
    try std.testing.expectEqualStrings("E42", diagnostic.get("code").?.object.get("value").?.string);
    try std.testing.expectEqualStrings("example.com", diagnostic.get("code").?.object.get("target").?.object.get("authority").?.string);
    const related = diagnostic.get("relatedInformation").?.array.items[0].object;
    try std.testing.expectEqualStrings("/other file", related.get("resource").?.object.get("path").?.string);
    try std.testing.expectEqual(@as(i64, 8), related.get("endColumn").?.integer);
}

test "mainThreadDiagnostics: deinit after an owner clears its markers" {
    const allocator = std.testing.allocator;
    var marker_service = MarkerService.init(allocator);
    defer marker_service.deinit();
    var fake = Fake{ .allocator = allocator };
    defer if (fake.last_payload_json) |json| allocator.free(json);
    const actor = try MainThreadDiagnostics.init(allocator, &marker_service, .{
        .context = &fake,
        .notify = Fake.notify,
    }, null);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const args_value = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(),
        \\["foo",[[{"$mid":1,"scheme":"file","authority":"","path":"/c","query":"","fragment":""},[{"severity":8,"message":"bad","startLineNumber":1,"startColumn":1,"endLineNumber":1,"endColumn":1}]]]]
    , .{});
    const args = [_]rpc.Arg{ .{ .json = args_value.array.items[0] }, .{ .json = args_value.array.items[1] } };
    _ = try actor.invoke("$changeMany", &args, arena.allocator());

    // Clear the same owner's markers while the actor still remembers the
    // owner. This retires the resource bucket but keeps "foo" in the actor's
    // active-owner set.
    const empty_value = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(),
        \\["foo",[[{"$mid":1,"scheme":"file","authority":"","path":"/c","query":"","fragment":""},[]]]]
    , .{});
    const empty_args = [_]rpc.Arg{ .{ .json = empty_value.array.items[0] }, .{ .json = empty_value.array.items[1] } };
    _ = try actor.invoke("$changeMany", &empty_args, arena.allocator());

    // deinit -> clearOwnMarkers -> read by owner. The owner index must not
    // point at the retired bucket that was freed after the clear event.
    actor.deinit();

    const list = try marker_service.read(allocator, .{});
    defer allocator.free(list);
    try std.testing.expectEqual(@as(usize, 0), list.len);
}
