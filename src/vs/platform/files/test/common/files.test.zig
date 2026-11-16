// Port of the watcher-related cases in
// `src/vs/platform/files/test/common/files.test.ts`.

const std = @import("std");
const files = @import("../../common/files.zig");

test "FileChangesEvent: basics" {
    const allocator = std.testing.allocator;
    const changes = [_]files.FileChange{
        .{ .type = .UPDATED, .resource = "/foo/updated.txt" },
        .{ .type = .UPDATED, .resource = "/foo/otherupdated.txt" },
        .{ .type = .ADDED, .resource = "/added.txt" },
        .{ .type = .DELETED, .resource = "/bar/deleted.txt" },
        .{ .type = .DELETED, .resource = "/bar/folder" },
        .{ .type = .DELETED, .resource = "/BAR/FOLDER" },
    };

    for ([_]bool{ false, true }) |ignore_case| {
        var event = try files.FileChangesEvent.init(allocator, &changes, ignore_case);
        defer event.deinit();

        try std.testing.expect(!event.contains("/foo", &.{.UPDATED}));
        try std.testing.expect(event.affects("/foo", &.{.UPDATED}));
        try std.testing.expect(event.contains("/foo/updated.txt", &.{.UPDATED}));
        try std.testing.expect(event.affects("/foo/updated.txt", &.{.UPDATED}));
        try std.testing.expect(event.contains("/foo/updated.txt", &.{ .UPDATED, .ADDED }));
        try std.testing.expect(!event.contains("/foo/updated.txt", &.{.ADDED}));
        try std.testing.expect(!event.affects("/foo/updated.txt", &.{.DELETED}));

        try std.testing.expect(event.contains("/bar/folder", &.{.DELETED}));
        try std.testing.expect(event.contains("/BAR/FOLDER", &.{.DELETED}));
        try std.testing.expect(event.affects("/BAR", &.{.DELETED}));
        if (ignore_case) {
            try std.testing.expect(event.contains("/BAR/folder", &.{.DELETED}));
        } else {
            try std.testing.expect(!event.contains("/BAR/folder", &.{.DELETED}));
        }
        try std.testing.expect(event.contains("/bar/folder/somefile", &.{.DELETED}));
        try std.testing.expect(!event.contains("/bar/folder2/somefile", &.{.DELETED}));

        try std.testing.expectEqual(@as(usize, 1), event.raw_added.len);
        try std.testing.expectEqual(@as(usize, 2), event.raw_updated.len);
        try std.testing.expectEqual(@as(usize, 3), event.raw_deleted.len);
        try std.testing.expect(event.gotAdded());
        try std.testing.expect(event.gotUpdated());
        try std.testing.expect(event.gotDeleted());
    }
}

test "FileChangesEvent: supports multiple changes on file tree" {
    const allocator = std.testing.allocator;
    const types = [_]files.FileChangeType{ .ADDED, .UPDATED, .DELETED };
    for (types) |change_type| {
        const changes = [_]files.FileChange{
            .{ .type = change_type, .resource = "/foo/bar/updated.txt" },
            .{ .type = change_type, .resource = "/foo/bar/otherupdated.txt" },
            .{ .type = change_type, .resource = "/foo/bar" },
            .{ .type = change_type, .resource = "/foo" },
            .{ .type = change_type, .resource = "/bar" },
            .{ .type = change_type, .resource = "/bar/foo" },
        };
        var event = try files.FileChangesEvent.init(allocator, &changes, false);
        defer event.deinit();
        try std.testing.expect(event.contains("/bar", &.{change_type}));
        try std.testing.expect(event.affects("/bar", &.{change_type}));
        try std.testing.expect(event.affects("/bar/foo", &.{change_type}));
        try std.testing.expect(event.contains("/foo", &.{change_type}));
    }
}

test "FileChangesEvent: correlation" {
    const allocator = std.testing.allocator;
    var changes = [_]files.FileChange{
        .{ .type = .ADDED, .resource = "/a", .cId = 1 },
        .{ .type = .ADDED, .resource = "/b", .cId = 1 },
    };
    var event = try files.FileChangesEvent.init(allocator, &changes, true);
    defer event.deinit();
    try std.testing.expect(event.hasCorrelation());
    try std.testing.expect(event.correlates(1));
    try std.testing.expect(!event.correlates(2));

    changes[1].cId = 2;
    var mixed = try files.FileChangesEvent.init(allocator, &changes, true);
    defer mixed.deinit();
    try std.testing.expect(!mixed.hasCorrelation());
}

test "isParent: posix and ignore case" {
    if (std.fs.path.sep != '/') return;
    try std.testing.expect(files.isParent("/some/path", "/", true));
    try std.testing.expect(files.isParent("/some/path", "/some", true));
    try std.testing.expect(files.isParent("/some/path", "/some/", true));
    try std.testing.expect(files.isParent("/someöäü/path", "/someöäü", true));
    try std.testing.expect(files.isParent("/foo/bar/test.ts", "/foo/bar", true));
    try std.testing.expect(!files.isParent("/some/path", "/some/path", true));
    try std.testing.expect(!files.isParent("/foo/bar/test.ts", "/foo/barr", true));
    try std.testing.expect(files.isParent("/some/path", "/SOME", true));
    try std.testing.expect(!files.isParent("/some/path", "/SOME", false));
}
