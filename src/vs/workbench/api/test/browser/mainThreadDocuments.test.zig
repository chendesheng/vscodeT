// Port of `src/vs/workbench/api/test/browser/mainThreadDocuments.test.ts`.
const std = @import("std");
const Collection = @import("../../browser/mainThreadDocuments.zig").BoundModelReferenceCollection;
const resolver = @import("../../../../editor/common/services/resolverService.zig");
const dispatch = @import("../../../../base/common/windowDispatch.zig");
const time = @import("../../../../base/common/timeCompat.zig");

const Release = struct {
    disposed: *std.ArrayList(usize),
    id: usize,

    fn callback(context: *anyopaque) void {
        const self: *Release = @ptrCast(@alignCast(context));
        self.disposed.append(std.testing.allocator, self.id) catch @panic("out of memory");
    }

    fn reference(self: *Release) resolver.ModelReference {
        return .{ .object = undefined, .release = .{ .context = self, .disposeFn = callback } };
    }
};

test "BoundModelReferenceCollection: max age" {
    var window: dispatch.Queue = .{ .io = std.testing.io };
    var collection: Collection = .{ .allocator = std.testing.allocator, .window = &window, .max_age = 15, .max_length = 75 };
    var disposed: std.ArrayList(usize) = .empty;
    defer disposed.deinit(std.testing.allocator);
    var release: Release = .{ .disposed = &disposed, .id = 0 };
    defer collection.deinit();
    try collection.add(try std.Uri.parse("test://farboo"), release.reference(), 0);
    _ = window.dispatch(time.milliTimestamp(std.testing.io) + 30);
    try std.testing.expectEqualSlices(usize, &.{0}, disposed.items);
}

test "BoundModelReferenceCollection: max size" {
    var window: dispatch.Queue = .{ .io = std.testing.io };
    var collection: Collection = .{ .allocator = std.testing.allocator, .window = &window, .max_age = 15, .max_length = 75 };
    var disposed: std.ArrayList(usize) = .empty;
    defer disposed.deinit(std.testing.allocator);
    var releases = [_]Release{ .{ .disposed = &disposed, .id = 0 }, .{ .disposed = &disposed, .id = 1 }, .{ .disposed = &disposed, .id = 2 } };
    defer collection.deinit();
    try collection.add(try std.Uri.parse("test://farboo"), releases[0].reference(), 6);
    try collection.add(try std.Uri.parse("test://boofar"), releases[1].reference(), 6);
    try collection.add(try std.Uri.parse("test://xxxxxxx"), releases[2].reference(), 70);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, disposed.items);
}

test "BoundModelReferenceCollection: max count" {
    var window: dispatch.Queue = .{ .io = std.testing.io };
    var collection: Collection = .{ .allocator = std.testing.allocator, .window = &window, .max_age = 10000, .max_length = 10000, .max_size = 2 };
    var disposed: std.ArrayList(usize) = .empty;
    defer disposed.deinit(std.testing.allocator);
    var releases = [_]Release{ .{ .disposed = &disposed, .id = 0 }, .{ .disposed = &disposed, .id = 1 }, .{ .disposed = &disposed, .id = 2 } };
    defer collection.deinit();
    for (&releases) |*release| try collection.add(try std.Uri.parse("test://xxxxxxx"), release.reference(), 0);
    try std.testing.expectEqualSlices(usize, &.{0}, disposed.items);
}

test "BoundModelReferenceCollection: dispose uri" {
    var window: dispatch.Queue = .{ .io = std.testing.io };
    var collection: Collection = .{ .allocator = std.testing.allocator, .window = &window, .max_age = 15, .max_length = 75 };
    var disposed: std.ArrayList(usize) = .empty;
    defer disposed.deinit(std.testing.allocator);
    var releases: [5]Release = undefined;
    defer collection.deinit();
    for ([_][]const u8{ "test:///farboo", "test:///boofar", "test:///boo/far1", "test:///boo/far2", "test:///boo1/far" }, 0..) |uri, i| {
        releases[i] = .{ .disposed = &disposed, .id = i };
        try collection.add(try std.Uri.parse(uri), releases[i].reference(), 0);
    }
    collection.remove(try std.Uri.parse("test:///unknown"));
    try std.testing.expectEqualSlices(usize, &.{}, disposed.items);
    collection.remove(try std.Uri.parse("test:///farboo"));
    try std.testing.expectEqualSlices(usize, &.{0}, disposed.items);
    disposed.clearRetainingCapacity();
    collection.remove(try std.Uri.parse("test:///boo"));
    try std.testing.expectEqualSlices(usize, &.{ 2, 3 }, disposed.items);
}
