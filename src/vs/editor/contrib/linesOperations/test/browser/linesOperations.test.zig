const std = @import("std");
const Selection = @import("../../../../common/core/selection.zig").Selection;
const lines_ops = @import("../../../../contrib/linesOperations/browser/linesOperations.zig");
const support = @import("../../../../test/common/port/commandTestSupport.zig");

test "duplicate selection on empty and non-empty selections" {
    const allocator = std.testing.allocator;
    var ctx = try support.TestCommand.init(allocator, &[_][]const u8{ "first", "second" }, "nullLanguage", null);
    defer ctx.deinit();
    const selection = Selection.init(1, 1, 1, 1);
    const result = try lines_ops.duplicateSelection(allocator, ctx.model.model, &[_]Selection{selection});
    defer if (result) |value| allocator.free(value);
    try ctx.expectLines(&[_][]const u8{ "first", "first", "second" });

    var ctx2 = try support.TestCommand.init(allocator, &[_][]const u8{"abcdef"}, "nullLanguage", null);
    defer ctx2.deinit();
    const selection2 = Selection.init(1, 2, 1, 4);
    const result2 = try lines_ops.duplicateSelection(allocator, ctx2.model.model, &[_]Selection{selection2});
    defer if (result2) |value| allocator.free(value);
    try ctx2.expectValue("abcbcdef");
    try support.expectSelections(result2, &[_]Selection{Selection.init(1, 4, 1, 6)});
}

test "sortLines applies to whole document for a single-line selection" {
    const allocator = std.testing.allocator;
    var ctx = try support.TestCommand.init(allocator, &[_][]const u8{ "c", "a", "b" }, "nullLanguage", null);
    defer ctx.deinit();
    const result = try lines_ops.sortLines(allocator, ctx.model.model, &[_]Selection{Selection.init(1, 1, 1, 1)}, false);
    defer if (result) |value| allocator.free(value);
    try ctx.expectLines(&[_][]const u8{ "a", "b", "c" });
}

test "trimTrailingWhitespace removes trailing spaces" {
    const allocator = std.testing.allocator;
    var ctx = try support.TestCommand.init(allocator, &[_][]const u8{ "a   ", "b\t" }, "nullLanguage", null);
    defer ctx.deinit();
    const selection = Selection.init(2, 1, 2, 1);
    const result = try lines_ops.trimTrailingWhitespace(allocator, ctx.model.model, &[_]Selection{selection});
    defer if (result) |value| allocator.free(value);
    try ctx.expectLines(&[_][]const u8{ "a", "b" });
}

test "copyLines ignores adjacent duplicate selections" {
    const allocator = std.testing.allocator;
    var ctx = try support.TestCommand.init(allocator, &[_][]const u8{ "a", "b", "c" }, "nullLanguage", null);
    defer ctx.deinit();
    const selections = [_]Selection{ Selection.init(1, 1, 1, 1), Selection.init(2, 1, 2, 1) };
    const result = try lines_ops.copyLines(allocator, ctx.model.model, &selections, true);
    defer if (result) |value| allocator.free(value);
    try ctx.expectLines(&[_][]const u8{ "a", "a", "b", "b", "c" });
}
