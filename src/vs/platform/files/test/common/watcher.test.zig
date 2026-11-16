// Port of the active cases in
// `src/vs/platform/files/test/common/watcher.test.ts`.

const std = @import("std");
const common = @import("../../common/watcher.zig");
const files = @import("../../common/files.zig");

fn expectContains(changes: []const files.FileChange, path: []const u8, kind: files.FileChangeType) !void {
    for (changes) |change| {
        if (std.mem.eql(u8, change.resource, path) and change.type == kind) return;
    }
    std.debug.print("missing {s} {s} in:\n", .{ @tagName(kind), path });
    for (changes) |change| std.debug.print("  {s} {s}\n", .{ @tagName(change.type), change.resource });
    return error.TestExpectedEqual;
}

test "parseWatcherPatterns: posix" {
    if (std.fs.path.sep != '/') return;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const path = "/users/data/src";
    const patterns = [_]common.PatternSource{
        .{ .string = "*.js" },
        .{ .string = "/users/data/src/*.js" },
        .{ .string = "/users/data/src/bar/*.js" },
        .{ .string = "**/*.js" },
    };
    const parsed = try common.parseWatcherPatterns(arena.allocator(), path, &patterns, false);

    try std.testing.expect(parsed[0].matches("/users/data/src/foo.js"));
    try std.testing.expect(!parsed[0].matches("/users/data/src/foo.ts"));
    try std.testing.expect(!parsed[0].matches("/users/data/src/bar/foo.js"));
    try std.testing.expect(parsed[1].matches("/users/data/src/foo.js"));
    try std.testing.expect(!parsed[1].matches("/users/data/src/bar/foo.js"));
    try std.testing.expect(parsed[2].matches("/users/data/src/bar/foo.js"));
    try std.testing.expect(parsed[3].matches("/users/data/src/bar/foo.js"));
}

test "parseWatcherPatterns: posix case insensitive" {
    if (std.fs.path.sep != '/') return;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const patterns = [_]common.PatternSource{.{ .string = "**/Test*.JS" }};
    const parsed = try common.parseWatcherPatterns(arena.allocator(), "/users/data/src", &patterns, true);
    try std.testing.expect(parsed[0].matches("/users/data/src/test1.js"));
    try std.testing.expect(parsed[0].matches("/users/data/src/bar/TEST2.JS"));
    try std.testing.expect(!parsed[0].matches("/users/data/src/foo.js"));
}

test "event coalescer: ignore CREATE followed by DELETE" {
    const allocator = std.testing.allocator;
    const changes = [_]files.FileChange{
        .{ .type = .ADDED, .resource = "/users/data/src/related" },
        .{ .type = .DELETED, .resource = "/users/data/src/related" },
        .{ .type = .UPDATED, .resource = "/users/data/src/unrelated" },
    };
    const result = try common.coalesceEventsWithCase(allocator, &changes, false);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try expectContains(result, "/users/data/src/unrelated", .UPDATED);
}

test "event coalescer: flatten DELETE followed by CREATE into CHANGE" {
    const allocator = std.testing.allocator;
    const changes = [_]files.FileChange{
        .{ .type = .DELETED, .resource = "/users/data/src/related" },
        .{ .type = .ADDED, .resource = "/users/data/src/related" },
        .{ .type = .UPDATED, .resource = "/users/data/src/unrelated" },
    };
    const result = try common.coalesceEventsWithCase(allocator, &changes, false);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try expectContains(result, "/users/data/src/related", .UPDATED);
    try expectContains(result, "/users/data/src/unrelated", .UPDATED);
}

test "event coalescer: ignore UPDATE when CREATE received" {
    const allocator = std.testing.allocator;
    const changes = [_]files.FileChange{
        .{ .type = .ADDED, .resource = "/users/data/src/related" },
        .{ .type = .UPDATED, .resource = "/users/data/src/related" },
        .{ .type = .UPDATED, .resource = "/users/data/src/unrelated" },
    };
    const result = try common.coalesceEventsWithCase(allocator, &changes, false);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try expectContains(result, "/users/data/src/related", .ADDED);
    try std.testing.expect(!hasChange(result, "/users/data/src/related", .UPDATED));
}

test "event coalescer: apply DELETE" {
    const allocator = std.testing.allocator;
    const changes = [_]files.FileChange{
        .{ .type = .UPDATED, .resource = "/users/data/src/related" },
        .{ .type = .UPDATED, .resource = "/users/data/src/related" },
        .{ .type = .UPDATED, .resource = "/users/data/src/unrelated" },
        .{ .type = .DELETED, .resource = "/users/data/src/related" },
    };
    const result = try common.coalesceEventsWithCase(allocator, &changes, false);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try expectContains(result, "/users/data/src/related", .DELETED);
    try std.testing.expect(!hasChange(result, "/users/data/src/related", .UPDATED));
}

test "event coalescer: track case renames" {
    const allocator = std.testing.allocator;
    const changes = [_]files.FileChange{
        .{ .type = .ADDED, .resource = "/users/data/src/ADDED" },
        .{ .type = .DELETED, .resource = "/users/data/src/added" },
    };
    const result = try common.coalesceEventsWithCase(allocator, &changes, true);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try expectContains(result, "/users/data/src/added", .DELETED);
    try expectContains(result, "/users/data/src/ADDED", .ADDED);
}

test "event coalescer: delete only reported for top level folder" {
    const allocator = std.testing.allocator;
    const changes = [_]files.FileChange{
        .{ .type = .DELETED, .resource = "/users/data/src/todelete1" },
        .{ .type = .DELETED, .resource = "/users/data/src/todelete2" },
        .{ .type = .DELETED, .resource = "/users/data/src/todelete2/file.txt" },
        .{ .type = .DELETED, .resource = "/users/data/src/todelete2/more/test.txt" },
        .{ .type = .ADDED, .resource = "/users/data/src/added.txt" },
        .{ .type = .UPDATED, .resource = "/users/data/src/updated.txt" },
    };
    const result = try common.coalesceEventsWithCase(allocator, &changes, false);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 4), result.len);
    try expectContains(result, "/users/data/src/todelete1", .DELETED);
    try expectContains(result, "/users/data/src/todelete2", .DELETED);
    try expectContains(result, "/users/data/src/added.txt", .ADDED);
    try expectContains(result, "/users/data/src/updated.txt", .UPDATED);
}

test "event type filter" {
    const resource = "/users/data/src/related";
    try std.testing.expect(!common.isFiltered(.{ .type = .ADDED, .resource = resource }, null));
    try std.testing.expect(common.isFiltered(.{ .type = .ADDED, .resource = resource }, files.FileChangeFilter.UPDATED));
    try std.testing.expect(!common.isFiltered(.{ .type = .ADDED, .resource = resource }, files.FileChangeFilter.ADDED));
    try std.testing.expect(common.isFiltered(.{ .type = .DELETED, .resource = resource }, files.FileChangeFilter.UPDATED));
    try std.testing.expect(!common.isFiltered(.{ .type = .DELETED, .resource = resource }, files.FileChangeFilter.DELETED));
    try std.testing.expect(common.isFiltered(.{ .type = .UPDATED, .resource = resource }, files.FileChangeFilter.ADDED));
    try std.testing.expect(!common.isFiltered(.{ .type = .UPDATED, .resource = resource }, files.FileChangeFilter.UPDATED));
}

fn hasChange(changes: []const files.FileChange, path: []const u8, kind: files.FileChangeType) bool {
    for (changes) |change| {
        if (change.type == kind and std.mem.eql(u8, change.resource, path)) return true;
    }
    return false;
}
