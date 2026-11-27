// Port of incremental edit validation from the semantic-token result pipeline.
const std = @import("std");
const tokens = @import("../../common/getSemanticTokens.zig");
test "Semantic tokens: delta edits address the original data and reject invalid spans" {
    const a = std.testing.allocator;
    const original = [_]u32{ 0, 0, 1, 0, 0, 1, 2, 3, 4, 0 };
    const changed = try tokens.applyDelta(a, &original, &.{ .{ .start = 2, .delete_count = 1, .data = @constCast(&[_]u32{2}) }, .{ .start = 5, .delete_count = 5, .data = &.{} } });
    defer a.free(changed);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 2, 0, 0 }, changed);
    try std.testing.expectError(error.InvalidSemanticDelta, tokens.applyDelta(a, &original, &.{.{ .start = 12, .delete_count = 1, .data = &.{} }}));
    try std.testing.expectError(error.InvalidSemanticDelta, tokens.applyDelta(a, &original, &.{.{ .start = 2, .delete_count = 1, .data = &.{} }}));
}
