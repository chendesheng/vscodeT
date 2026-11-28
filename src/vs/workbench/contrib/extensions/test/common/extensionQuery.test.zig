// Port of `src/vs/workbench/contrib/extensions/test/common/extensionQuery.test.ts`.
//
// `Query.suggestions` is omitted because the gallery manifest and the
// extension-feature registry are not ported; the remaining cases match
// upstream.
const std = @import("std");
const query_mod = @import("../../common/extensionQuery.zig");
const Query = query_mod.Query;
const testing = std.testing;

test "Extension query parse" {
    const allocator = testing.allocator;
    const Cases = struct { input: []const u8, value: []const u8, sort_by: []const u8 };
    const cases = [_]Cases{
        .{ .input = "", .value = "", .sort_by = "" },
        .{ .input = "hello", .value = "hello", .sort_by = "" },
        .{ .input = "   hello world ", .value = "hello world", .sort_by = "" },
        .{ .input = "@sort", .value = "@sort", .sort_by = "" },
        .{ .input = "@sort:", .value = "@sort:", .sort_by = "" },
        .{ .input = "  @sort:  ", .value = "@sort:", .sort_by = "" },
        .{ .input = "@sort:installs", .value = "", .sort_by = "installs" },
        .{ .input = "   @sort:installs   ", .value = "", .sort_by = "installs" },
        .{ .input = "@sort:installs-", .value = "", .sort_by = "installs" },
        .{ .input = "@sort:installs-foo", .value = "", .sort_by = "installs" },
        .{ .input = "vs @sort:installs", .value = "vs", .sort_by = "installs" },
        .{ .input = "vs @sort:installs code", .value = "vs  code", .sort_by = "installs" },
        .{ .input = "@sort:installs @sort:ratings", .value = "", .sort_by = "ratings" },
    };
    for (cases) |case| {
        var query = try Query.parse(allocator, case.input);
        defer query.deinit(allocator);
        try testing.expectEqualStrings(case.value, query.value);
        try testing.expectEqualStrings(case.sort_by, query.sort_by);
    }
}

test "Extension query toString" {
    const allocator = testing.allocator;
    const Cases = struct { value: []const u8, sort_by: []const u8, expected: []const u8 };
    const cases = [_]Cases{
        .{ .value = "hello", .sort_by = "", .expected = "hello" },
        .{ .value = "hello world", .sort_by = "", .expected = "hello world" },
        .{ .value = "  hello    ", .sort_by = "", .expected = "hello" },
        .{ .value = "", .sort_by = "installs", .expected = "@sort:installs" },
        .{ .value = "hello", .sort_by = "installs", .expected = "hello @sort:installs" },
        .{ .value = "  hello      ", .sort_by = "installs", .expected = "hello @sort:installs" },
    };
    for (cases) |case| {
        var query = try Query.init(allocator, case.value, case.sort_by);
        defer query.deinit(allocator);
        const text = try query.toString(allocator);
        defer allocator.free(text);
        try testing.expectEqualStrings(case.expected, text);
    }
}

test "Extension query isValid" {
    const allocator = testing.allocator;
    var valid = try Query.init(allocator, "hello", "");
    defer valid.deinit(allocator);
    try testing.expect(valid.isValid());
    var outdated = try Query.init(allocator, "@outdated", "");
    defer outdated.deinit(allocator);
    try testing.expect(!outdated.isValid());
}

test "Extension query containsMcpTerm" {
    const allocator = testing.allocator;
    const Cases = struct { value: []const u8, expected: bool };
    const cases = [_]Cases{
        .{ .value = "mcp", .expected = true },
        .{ .value = "MCP server", .expected = true },
        .{ .value = "azure-mcp", .expected = true },
        .{ .value = "(mcp)", .expected = true },
        .{ .value = "mcp.server", .expected = true },
        .{ .value = "amcp", .expected = false },
        .{ .value = "mcps", .expected = false },
        .{ .value = "mcp_server", .expected = false },
        .{ .value = "myMcpExtension", .expected = false },
    };
    for (cases) |case| {
        var query = try Query.init(allocator, case.value, "");
        defer query.deinit(allocator);
        try testing.expectEqual(case.expected, query.containsMcpTerm());
    }
}

test "Extension query equals" {
    const allocator = testing.allocator;
    var first = try Query.init(allocator, "hello", "");
    defer first.deinit(allocator);
    var same = try Query.init(allocator, "hello", "");
    defer same.deinit(allocator);
    try testing.expect(first.equals(&same));
    var different = try Query.init(allocator, "hello world", "");
    defer different.deinit(allocator);
    try testing.expect(!first.equals(&different));
    var sorted = try Query.init(allocator, "hello", "installs");
    defer sorted.deinit(allocator);
    try testing.expect(!first.equals(&sorted));
}

test "Extension query suggestions hide duplicate filters and completed sort/category" {
    const allocator = testing.allocator;
    const suggestions = try Query.suggestions(allocator, "@installed @sort:name @category:\"themes\"", true);
    defer {
        for (suggestions) |item| allocator.free(item);
        allocator.free(suggestions);
    }
    var builtin = false;
    for (suggestions) |item| {
        try testing.expect(!std.mem.startsWith(u8, item, "@installed"));
        try testing.expect(!std.mem.startsWith(u8, item, "@sort:"));
        try testing.expect(!std.mem.startsWith(u8, item, "@category:"));
        if (std.mem.eql(u8, item, "@builtin ")) builtin = true;
    }
    try testing.expect(builtin);
}

test "Extension query lone sort token is an installed query" {
    try testing.expect(Query.isSortInstalled("@sort:updateDate"));
    try testing.expect(Query.isSortInstalled(" @SORT:name "));
    try testing.expect(!Query.isSortInstalled("@sort:name foo"));
    try testing.expect(!Query.isSortInstalled("foo @sort:name"));
}
