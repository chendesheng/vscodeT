// Port of `src/vs/platform/markers/test/common/markerService.test.ts`.

const std = @import("std");
const markers = @import("../../common/markers.zig");
const marker_service = @import("../../common/markerService.zig");
const MarkerService = marker_service.MarkerService;

fn fileResource(path: []const u8) markers.Resource {
    return .{ .scheme = "file", .authority = "", .path = path };
}

fn data(message: []const u8, severity: u32) markers.MarkerData {
    return .{ .message = message, .severity = severity, .start_line_number = 1, .start_column = 1, .end_line_number = 1, .end_column = 1 };
}

fn counts(service: *MarkerService, options: markers.ReadOptions) !usize {
    const list = try service.read(std.testing.allocator, options);
    defer std.testing.allocator.free(list);
    return list.len;
}

test "markerService: query" {
    const allocator = std.testing.allocator;
    var service = MarkerService.init(allocator);
    defer service.deinit();

    const resource = fileResource("/c/test/file.cs");
    const other = fileResource("/c/test/other.cs");
    try service.changeOne("far", resource, &.{data("one", markers.MarkerSeverity.Error)}, null);
    try std.testing.expectEqual(@as(usize, 1), try counts(&service, .{}));
    try std.testing.expectEqual(@as(usize, 1), try counts(&service, .{ .owner = "far" }));
    try std.testing.expectEqual(@as(usize, 1), try counts(&service, .{ .resource = resource }));
    try std.testing.expectEqual(@as(usize, 1), try counts(&service, .{ .owner = "far", .resource = resource }));

    try service.changeOne("boo", other, &.{data("two", markers.MarkerSeverity.Warning)}, null);
    try std.testing.expectEqual(@as(usize, 2), try counts(&service, .{}));
    try std.testing.expectEqual(@as(usize, 1), try counts(&service, .{ .owner = "far" }));
    try std.testing.expectEqual(@as(usize, 1), try counts(&service, .{ .owner = "boo" }));
    try std.testing.expectEqual(@as(usize, 1), try counts(&service, .{ .resource = resource }));
    try std.testing.expectEqual(@as(usize, 1), try counts(&service, .{ .severities = markers.MarkerSeverity.Error }));
    try std.testing.expectEqual(@as(usize, 0), try counts(&service, .{ .severities = markers.MarkerSeverity.Hint }));
    try std.testing.expectEqual(@as(usize, 2), try counts(&service, .{ .severities = markers.MarkerSeverity.Error | markers.MarkerSeverity.Warning }));
}

test "markerService: changeOne override and clear" {
    const allocator = std.testing.allocator;
    var service = MarkerService.init(allocator);
    defer service.deinit();
    const resource = fileResource("/c/test/file.cs");

    try service.changeOne("far", resource, &.{data("one", markers.MarkerSeverity.Error)}, null);
    try service.changeOne("boo", resource, &.{data("two", markers.MarkerSeverity.Warning)}, null);
    try std.testing.expectEqual(@as(usize, 2), try counts(&service, .{}));
    try service.changeOne("far", resource, &.{
        data("three", markers.MarkerSeverity.Error),
        data("four", markers.MarkerSeverity.Error),
    }, null);
    try std.testing.expectEqual(@as(usize, 2), try counts(&service, .{ .owner = "far" }));
    try std.testing.expectEqual(@as(usize, 1), try counts(&service, .{ .owner = "boo" }));

    try service.changeOne("far", resource, &.{}, null);
    try std.testing.expectEqual(@as(usize, 1), try counts(&service, .{}));
    try service.changeAll("boo", &.{});
    try std.testing.expectEqual(@as(usize, 0), try counts(&service, .{}));
}

test "markerService: changeAll groups markers" {
    const allocator = std.testing.allocator;
    var service = MarkerService.init(allocator);
    defer service.deinit();
    const resource = fileResource("/d/path");
    try service.changeAll("far", &.{
        .{ .resource = resource, .marker = data("one", markers.MarkerSeverity.Error) },
        .{ .resource = resource, .marker = data("two", markers.MarkerSeverity.Warning) },
    });
    try std.testing.expectEqual(@as(usize, 2), try counts(&service, .{ .owner = "far" }));
    try std.testing.expectEqual(@as(usize, 2), try counts(&service, .{ .resource = resource }));
}

test "markerService: changeAll keeps owners and resources consistent" {
    const allocator = std.testing.allocator;
    var service = MarkerService.init(allocator);
    defer service.deinit();
    const path1 = fileResource("/path/one");
    const path2 = fileResource("/path/two");
    try service.changeAll("far", &.{
        .{ .resource = path1, .marker = data("a", markers.MarkerSeverity.Error) },
        .{ .resource = path2, .marker = data("b", markers.MarkerSeverity.Error) },
    });
    try service.changeAll("boo", &.{
        .{ .resource = path1, .marker = data("c", markers.MarkerSeverity.Warning) },
    });
    try std.testing.expectEqual(@as(usize, 2), try counts(&service, .{ .owner = "far" }));
    try std.testing.expectEqual(@as(usize, 2), try counts(&service, .{ .resource = path1 }));
    const stats = service.internalStats();
    try std.testing.expectEqual(@as(usize, 2), stats.resources);
    try std.testing.expectEqual(@as(usize, 2), stats.owners);
}

test "markerService: invalid data, code zero and version id" {
    const allocator = std.testing.allocator;
    var service = MarkerService.init(allocator);
    defer service.deinit();
    const resource = fileResource("/x");
    try service.changeOne("far", resource, &.{data("", markers.MarkerSeverity.Error)}, null);
    try std.testing.expectEqual(@as(usize, 0), try counts(&service, .{}));
    try service.changeOne("far", resource, &.{.{
        .message = "zero",
        .severity = 0,
        .code = "0",
        .start_line_number = 0,
        .start_column = 0,
        .end_line_number = 0,
        .end_column = 0,
        .model_version_id = 42,
    }}, null);
    const list = try service.read(allocator, .{});
    defer allocator.free(list);
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqual(@as(u32, 0), list[0].severity);
    try std.testing.expectEqualStrings("0", list[0].code.?);
    try std.testing.expectEqual(@as(u32, 1), list[0].start_line_number);
    try std.testing.expectEqual(@as(u32, 1), list[0].end_line_number);
    try std.testing.expectEqual(@as(?u32, 42), list[0].model_version_id);
}

test "markerService: truncation across owners" {
    const allocator = std.testing.allocator;
    var service = MarkerService.init(allocator);
    defer service.deinit();
    const resource = fileResource("/truncated");
    const other = fileResource("/other");
    try service.changeOne("first", resource, &.{data("a", markers.MarkerSeverity.Error)}, .{ .is_truncated = true });
    try service.changeOne("second", resource, &.{data("b", markers.MarkerSeverity.Error)}, null);
    try std.testing.expect(service.isSourceTruncated(resource));
    try service.changeOne("first", resource, &.{data("c", markers.MarkerSeverity.Error)}, null);
    try service.changeOne("first", other, &.{data("d", markers.MarkerSeverity.Error)}, .{ .is_truncated = true });
    try std.testing.expect(!service.isSourceTruncated(resource));
    try std.testing.expect(service.isSourceTruncated(other));
    try service.changeAll("first", &.{});
    try std.testing.expect(!service.isSourceTruncated(other));
}

test "markerService: resource filters" {
    const allocator = std.testing.allocator;
    var service = MarkerService.init(allocator);
    defer service.deinit();
    const r1 = fileResource("/r1");
    const r2 = fileResource("/r2");
    try service.changeOne("owner1", r1, &.{data("one", markers.MarkerSeverity.Error)}, null);
    try service.changeOne("owner2", r2, &.{data("two", markers.MarkerSeverity.Error)}, null);

    const filter = try service.installResourceFilter(r1, "paused");
    try std.testing.expectEqual(@as(usize, 2), try counts(&service, .{}));
    try std.testing.expectEqual(@as(usize, 1), try counts(&service, .{ .resource = r1 }));
    try std.testing.expectEqual(@as(usize, 1), try counts(&service, .{ .resource = r2 }));
    try std.testing.expectEqual(@as(usize, 2), try counts(&service, .{ .ignore_resource_filters = true }));

    const filtered = try service.read(allocator, .{ .resource = r1 });
    defer allocator.free(filtered);
    try std.testing.expectEqual(@as(usize, 1), filtered.len);
    try std.testing.expectEqualStrings("markersFilter", filtered[0].owner);
    try std.testing.expect(std.mem.indexOf(u8, filtered[0].message, "paused") != null);

    filter.dispose();
    try std.testing.expectEqual(@as(usize, 2), try counts(&service, .{}));
}

test "markerService: multiple filters and out-of-order disposal" {
    const allocator = std.testing.allocator;
    var service = MarkerService.init(allocator);
    defer service.deinit();
    const resource = fileResource("/f");
    try service.changeOne("owner", resource, &.{data("one", markers.MarkerSeverity.Error)}, null);
    const first = try service.installResourceFilter(resource, "first");
    const second = try service.installResourceFilter(resource, "second");
    const third = try service.installResourceFilter(resource, "third");
    try std.testing.expectEqual(@as(usize, 1), try counts(&service, .{}));
    second.dispose();
    try std.testing.expectEqual(@as(usize, 1), try counts(&service, .{}));
    third.dispose();
    first.dispose();
    try std.testing.expectEqual(@as(usize, 1), try counts(&service, .{}));
    const list = try service.read(allocator, .{});
    defer allocator.free(list);
    try std.testing.expectEqualStrings("owner", list[0].owner);
}

test "markerService: statistics" {
    const allocator = std.testing.allocator;
    var service = MarkerService.init(allocator);
    defer service.deinit();
    const resource = fileResource("/stats");
    try service.changeOne("owner", resource, &.{
        data("e", markers.MarkerSeverity.Error),
        data("w", markers.MarkerSeverity.Warning),
        data("i", markers.MarkerSeverity.Info),
        data("h", markers.MarkerSeverity.Hint),
    }, null);
    const stats = service.getStatistics();
    try std.testing.expectEqual(@as(usize, 1), stats.errors);
    try std.testing.expectEqual(@as(usize, 1), stats.warnings);
    try std.testing.expectEqual(@as(usize, 1), stats.infos);
    try std.testing.expectEqual(@as(usize, 1), stats.unknowns);
}

/// Forwards to `std.testing.allocator` and overwrites freed memory, so a
/// listener that dereferences a marker freed before `onMarkerChanged` fails the
/// test instead of reading stale-but-plausible bytes.
const PoisonAllocator = struct {
    child: std.mem.Allocator,

    fn allocator(self: *PoisonAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ctx));
        return self.child.vtable.alloc(self.child.ptr, len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ctx));
        return self.child.vtable.resize(self.child.ptr, memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ctx));
        return self.child.vtable.remap(self.child.ptr, memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ctx));
        @memset(memory, 0xAA);
        self.child.vtable.free(self.child.ptr, memory, alignment, ret_addr);
    }
};

test "markerService: replaced markers stay valid during onMarkerChanged" {
    var poisoned = PoisonAllocator{ .child = std.testing.allocator };
    const allocator = poisoned.allocator();
    var service = MarkerService.init(allocator);
    defer service.deinit();
    const resource = fileResource("/live");

    try service.changeOne("owner", resource, &.{data("old", markers.MarkerSeverity.Error)}, null);
    const before = try service.read(allocator, .{ .resource = resource });
    defer allocator.free(before);
    try std.testing.expectEqual(@as(usize, 1), before.len);

    const Probe = struct {
        old: *markers.Marker,
        expected_message: []const u8,
        failed: bool = false,

        fn changed(_: marker_service.MarkerChangeEvent, probe: *@This()) !void {
            // Upstream's marker objects survive the change through the event;
            // a listener may still inspect the marker it saw before the change.
            // `MarkerService.fire` swallows listener errors, so record a
            // mismatch for the test body to assert after the event returns.
            const message = probe.old.message;
            if (message.len != probe.expected_message.len or !std.mem.eql(u8, message, probe.expected_message)) {
                probe.failed = true;
                return;
            }
            const owner = probe.old.owner;
            if (owner.len != 5 or !std.mem.eql(u8, owner, "owner")) probe.failed = true;
            const path = probe.old.resource.path;
            if (path.len != 5 or !std.mem.eql(u8, path, "/live")) probe.failed = true;
        }
    };
    var probe = Probe{ .old = before[0], .expected_message = "old" };
    const listener = try service.on_marker_changed.listen(&probe, Probe.changed);
    defer service.on_marker_changed.unlisten(listener);

    try service.changeOne("owner", resource, &.{data("new", markers.MarkerSeverity.Warning)}, null);
    try std.testing.expect(!probe.failed);
    const after = try service.read(allocator, .{ .resource = resource });
    defer allocator.free(after);
    try std.testing.expectEqual(@as(usize, 1), after.len);
    try std.testing.expectEqualStrings("new", after[0].message);

    // Clearing the resource empties and retires its bucket; the marker and its
    // borrowed resource must also stay readable for the duration of the event.
    probe.old = after[0];
    probe.expected_message = "new";
    probe.failed = false;
    try service.changeOne("owner", resource, &.{}, null);
    try std.testing.expect(!probe.failed);
}
