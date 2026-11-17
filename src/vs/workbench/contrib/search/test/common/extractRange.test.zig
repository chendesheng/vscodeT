// Adapted from `src/vs/workbench/contrib/search/test/common/extractRange.test.ts`.

const std = @import("std");
const search = @import("../../common/search.zig");

fn expectRange(filter: []const u8, start_line: usize, start_column: usize, end_line: usize, end_column: usize) !void {
    const result = try search.extractRangeFromFilter(std.testing.allocator, filter, &.{});
    defer if (result) |value| std.testing.allocator.free(value.filter);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(start_line, result.?.range.startLineNumber);
    try std.testing.expectEqual(start_column, result.?.range.startColumn);
    try std.testing.expectEqual(end_line, result.?.range.endLineNumber);
    try std.testing.expectEqual(end_column, result.?.range.endColumn);
}

fn expectNoRange(filter: []const u8) !void {
    const result = try search.extractRangeFromFilter(std.testing.allocator, filter, &.{});
    defer if (result) |value| std.testing.allocator.free(value.filter);
    try std.testing.expect(result == null);
}

test "extractRangeFromFilter: basics" {
    try expectNoRange("");
    try expectNoRange("/some/path");
    try expectNoRange("/some/path/file.txt");
    for ([_][]const u8{ ":", "#", "(", ":line " }) |line_sep| {
        for ([_][]const u8{ ":", "#", "," }) |column_sep| {
            const base = "/some/path/file.txt";
            var buffer: [128]u8 = undefined;
            try expectRange(
                try std.fmt.bufPrint(&buffer, "{s}{s}20", .{ base, line_sep }),
                20,
                1,
                20,
                1,
            );
            try expectRange(
                try std.fmt.bufPrint(&buffer, "{s}{s}20{s}", .{ base, line_sep, column_sep }),
                20,
                1,
                20,
                1,
            );
            try expectRange(
                try std.fmt.bufPrint(&buffer, "{s}{s}20{s}3", .{ base, line_sep, column_sep }),
                20,
                3,
                20,
                3,
            );
        }
    }
}

test "extractRangeFromFilter: space and ranges" {
    try expectRange("/some/path/file.txt (19,20)", 19, 20, 19, 20);
    try expectRange("/some/path/file.txt:20-40", 20, 1, 40, 1);
    try expectRange("/some/path/file.txt:20:3-40:5", 20, 3, 40, 5);
    try expectRange("/some/path/file.txt:20:3-40", 20, 3, 40, 1);
    try expectRange("/some/path/file.txt#20#3-40,5", 20, 3, 40, 5);
    try expectRange("/some/path/file.txt(20,3-40,5)", 20, 3, 40, 5);
    try expectRange("/some/path/file.txt:20-", 20, 1, 20, 1);
}

test "extractRangeFromFilter: hyphen in path and unless" {
    try expectNoRange("/some/path/my-file.txt");
    try expectNoRange("/some/path/file-2.txt");
    try expectNoRange("/some/path/file.txt@alphasymbol");

    const result = try search.extractRangeFromFilter(
        std.testing.allocator,
        "/some/@path/file.txt (19,20)",
        &.{"@"},
    );
    defer std.testing.allocator.free(result.?.filter);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("/some/@path/file.txt", result.?.filter);
}
