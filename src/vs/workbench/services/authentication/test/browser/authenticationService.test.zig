// Account enumeration regression for `src/vs/workbench/services/authentication/browser/authenticationService.ts`.
const std = @import("std");
const getAccounts = @import("../../browser/authenticationService.zig").getAccounts;

test "getAccounts returns the first session account for each label in provider order" {
    const allocator = std.testing.allocator;
    const result = try getAccounts(allocator, &.{
        .{ .id = "one", .label = "First" },
        .{ .id = "two", .label = "First" },
        .{ .id = "one", .label = "Second" },
    });
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("one", result[0].id);
    try std.testing.expectEqualStrings("First", result[0].label);
    try std.testing.expectEqualStrings("Second", result[1].label);
}
