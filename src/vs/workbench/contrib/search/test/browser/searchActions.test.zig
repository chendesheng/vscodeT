// Adapted from `src/vs/workbench/contrib/search/test/browser/searchActions.test.ts`.
//
// The six upstream focus-restoration cases are kept. The notebook/search-view
// setup is replaced with a small text result tree and the ported
// `mockSearchTree.zig` viewer.

const std = @import("std");
const search = @import("../../../../services/search/common/search.zig");
const tree = @import("../../browser/searchTreeModel/searchTreeCommon.zig");
const actions = @import("../../browser/searchActionsRemoveReplace.zig");
const mock = @import("mockSearchTree.zig");

const Fixture = struct {
    allocator: std.mem.Allocator,
    query: search.TextQuery,
    result: *tree.SearchResult,

    fn init(allocator: std.mem.Allocator) !Fixture {
        const query = try search.TextQuery.init(allocator, "abc", &.{"/root"}, "", "", &.{});
        errdefer {
            var mutable = query;
            mutable.deinit();
        }
        const result = try tree.SearchResult.create(allocator, std.testing.io);
        result.setQuery(&query);
        return .{ .allocator = allocator, .query = query, .result = result };
    }

    fn deinit(self: *Fixture) void {
        self.result.deinit();
        self.query.deinit();
    }

    fn addFile(self: *Fixture, path: []const u8, match_count: usize) !*tree.FileMatch {
        const ranges = try self.allocator.alloc(search.SearchRange, match_count);
        defer self.allocator.free(ranges);
        var text = std.array_list.Managed(u8).init(self.allocator);
        defer text.deinit();
        for (ranges, 0..) |*range, index| {
            range.* = search.SearchRange.init(index, 0, index, 3);
        }
        try text.appendSlice("abc");
        const raw_match = try search.TextSearchMatch.init(self.allocator, text.items, ranges, .{ .match_lines = 1, .chars_per_line = 1000 });
        var raw_file = search.SearchFileResult{
            .allocator = self.allocator,
            .resource = try self.allocator.dupe(u8, path),
            .results = try self.allocator.alloc(search.TextSearchMatch, 1),
        };
        raw_file.results[0] = raw_match;
        defer {
            for (raw_file.results) |*item| item.deinit();
            self.allocator.free(raw_file.results);
            self.allocator.free(raw_file.resource);
        }
        try self.result.add(&.{raw_file}, false);

        const files = try self.result.matches(self.allocator);
        defer self.allocator.free(files);
        for (files) |file| {
            if (std.mem.eql(u8, file.path, path)) return file;
        }
        return error.FileNotFound;
    }
};

test "Search Actions: focus after removing a match with a next sibling file" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const file1 = try fixture.addFile("/root/a.txt", 2);
    const file2 = try fixture.addFile("/root/b.txt", 2);
    const data = [_]tree.Node{
        .{ .file = file1 },
        .{ .match = file1.matches()[0] },
        .{ .match = file1.matches()[1] },
        .{ .file = file2 },
        .{ .match = file2.matches()[0] },
        .{ .match = file2.matches()[1] },
    };
    const viewer = try mock.MockObjectTree.init(std.testing.allocator, @constCast(&data));
    defer viewer.deinit();
    const target = data[2];
    const actual = actions.getElementToFocusAfterRemoved(viewer.interface(), target, &.{target});
    try std.testing.expect(actual != null);
    try std.testing.expect(tree.nodeEql(actual.?, data[4]));
}

test "Search Actions: focus after removing the only match" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const file1 = try fixture.addFile("/root/a.txt", 1);
    const match = file1.matches()[0];
    const data = [_]tree.Node{ .{ .file = file1 }, .{ .match = match } };
    const viewer = try mock.MockObjectTree.init(std.testing.allocator, @constCast(&data));
    defer viewer.deinit();
    const target = data[1];
    const actual = actions.getElementToFocusAfterRemoved(viewer.interface(), target, &.{target});
    try std.testing.expect(actual == null);
}

test "Search Actions: focus after removing a file with a next sibling" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const file1 = try fixture.addFile("/root/a.txt", 1);
    const file2 = try fixture.addFile("/root/b.txt", 1);
    const file3 = try fixture.addFile("/root/c.txt", 1);
    const data = [_]tree.Node{
        .{ .file = file1 },
        .{ .match = file1.matches()[0] },
        .{ .file = file2 },
        .{ .match = file2.matches()[0] },
        .{ .file = file3 },
        .{ .match = file3.matches()[0] },
    };
    const viewer = try mock.MockObjectTree.init(std.testing.allocator, @constCast(&data));
    defer viewer.deinit();
    const target = data[2];
    const actual = actions.getElementToFocusAfterRemoved(viewer.interface(), target, &.{});
    try std.testing.expect(actual != null);
    try std.testing.expect(tree.nodeEql(actual.?, data[4]));
}

test "Search Actions: find the last file match in the tree" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const file1 = try fixture.addFile("/root/a.txt", 1);
    const file2 = try fixture.addFile("/root/b.txt", 1);
    const file3 = try fixture.addFile("/root/c.txt", 1);
    const data = [_]tree.Node{
        .{ .file = file1 },
        .{ .match = file1.matches()[0] },
        .{ .file = file2 },
        .{ .match = file2.matches()[0] },
        .{ .file = file3 },
        .{ .match = file3.matches()[0] },
    };
    const viewer = try mock.MockObjectTree.init(std.testing.allocator, @constCast(&data));
    defer viewer.deinit();
    const actual = actions.getLastNodeFromSameType(viewer.interface(), data[0]);
    try std.testing.expect(actual != null);
    try std.testing.expect(tree.nodeEql(actual.?, data[4]));
}

test "Search Actions: find the last match in the tree" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const file1 = try fixture.addFile("/root/a.txt", 1);
    const file2 = try fixture.addFile("/root/b.txt", 1);
    const file3 = try fixture.addFile("/root/c.txt", 1);
    const data = [_]tree.Node{
        .{ .file = file1 },
        .{ .match = file1.matches()[0] },
        .{ .file = file2 },
        .{ .match = file2.matches()[0] },
        .{ .file = file3 },
        .{ .match = file3.matches()[0] },
    };
    const viewer = try mock.MockObjectTree.init(std.testing.allocator, @constCast(&data));
    defer viewer.deinit();
    const actual = actions.getLastNodeFromSameType(viewer.interface(), data[1]);
    try std.testing.expect(actual != null);
    try std.testing.expect(tree.nodeEql(actual.?, data[5]));
}

test "Search Actions: focus after removing the only file" {
    var fixture = try Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const file1 = try fixture.addFile("/root/a.txt", 1);
    const data = [_]tree.Node{ .{ .file = file1 }, .{ .match = file1.matches()[0] } };
    const viewer = try mock.MockObjectTree.init(std.testing.allocator, @constCast(&data));
    defer viewer.deinit();
    const actual = actions.getElementToFocusAfterRemoved(viewer.interface(), data[0], &.{});
    try std.testing.expect(actual == null);
}
