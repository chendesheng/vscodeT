// Port of `src/vs/editor/test/common/core/stringBuilder.test.ts`.
const std = @import("std");
const string_builder = @import("../../../common/core/stringBuilder.zig");

test "basic" {
    const allocator = std.testing.allocator;
    var sb = try string_builder.StringBuilder.init(allocator, 100);
    defer sb.deinit();
    try sb.appendASCIICharCode('A');
    try sb.appendASCIICharCode(' ');
    try sb.appendString("😊");
    try std.testing.expectEqualStrings("A 😊", sb.build());
}
