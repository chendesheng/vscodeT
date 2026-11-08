const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const strings = @import("../../../base/common/strings.zig");
const AbstractText = @import("../core/text/abstractText.zig").AbstractText;
const LinesDiff = @import("linesDiffComputer.zig").LinesDiff;
const DetailedLineRangeMapping = @import("rangeMapping.zig").DetailedLineRangeMapping;

/// Whether a diff is correct: applying its inner changes to the original
/// reproduces the modified text. `unverified` if the diff has changes without
/// inner changes, which cannot be checked.
pub const LinesDiffValidity = enum {
    valid,
    invalid,
    unverified,
};

/// Checks that applying the inner changes of `diff` to the original reproduces
/// the modified text. When trim whitespace is ignored, lines only need to
/// agree after trimming.
pub fn verifyLinesDiff(
    allocator: Allocator,
    diff: LinesDiff,
    original_lines: []const []const u8,
    modified_lines: []const []const u8,
    ignore_trim_whitespace: bool,
) LinesDiffValidity {
    for (diff.changes) |change| {
        if (change.inner_changes == null) {
            return .unverified;
        }
    }

    return verifyInner(allocator, diff, original_lines, modified_lines, ignore_trim_whitespace) catch .invalid;
}

fn verifyInner(
    allocator: Allocator,
    diff: LinesDiff,
    original_lines: []const []const u8,
    modified_lines: []const []const u8,
    ignore_trim_whitespace: bool,
) !LinesDiffValidity {
    var original_text = AbstractText.initArray(allocator, original_lines);
    defer original_text.deinit();
    var modified_text = AbstractText.initArray(allocator, modified_lines);
    defer modified_text.deinit();

    var edit = try DetailedLineRangeMapping.toTextEdit(allocator, diff.changes, &modified_text);
    defer edit.deinit();

    var normalized = try edit.normalize();
    defer normalized.deinit();

    const actual = try normalized.apply(allocator, &original_text);
    defer allocator.free(actual);

    if (!ignore_trim_whitespace) {
        var expected = ArrayList(u8).init(allocator);
        defer expected.deinit();
        for (modified_lines, 0..) |line, i| {
            if (i > 0) try expected.append('\n');
            try expected.appendSlice(line);
        }
        return if (std.mem.eql(u8, actual, expected.items)) .valid else .invalid;
    }

    var actual_lines = try strings.splitLines(allocator, actual);
    defer actual_lines.deinit();
    if (actual_lines.items.len != modified_lines.len) {
        return .invalid;
    }
    for (actual_lines.items, modified_lines) |actual_line, modified_line| {
        if (!std.mem.eql(u8, std.mem.trim(u8, actual_line, " \t\r\n"), std.mem.trim(u8, modified_line, " \t\r\n"))) {
            return .invalid;
        }
    }
    return .valid;
}

test "verifyLinesDiff: valid, invalid and unverified" {
    const allocator = std.testing.allocator;
    const LineRange = @import("../core/ranges/lineRange.zig").LineRange;
    const Range = @import("../core/range.zig").Range;
    const RangeMapping = @import("rangeMapping.zig").RangeMapping;

    const original = [_][]const u8{ "a", "b" };
    const modified = [_][]const u8{ "a", "c" };

    const inner = try allocator.alloc(RangeMapping, 1);
    defer allocator.free(inner);
    inner[0] = RangeMapping.init(Range.init(2, 1, 2, 2), Range.init(2, 1, 2, 2));

    const changes = try allocator.alloc(DetailedLineRangeMapping, 1);
    defer allocator.free(changes);
    changes[0] = DetailedLineRangeMapping.init(LineRange.init(2, 3), LineRange.init(2, 3), inner);

    const valid_diff = LinesDiff.init(allocator, changes, &.{}, false);
    try std.testing.expectEqual(LinesDiffValidity.valid, verifyLinesDiff(allocator, valid_diff, &original, &modified, false));

    const invalid_inner = try allocator.alloc(RangeMapping, 1);
    defer allocator.free(invalid_inner);
    invalid_inner[0] = RangeMapping.init(Range.init(2, 1, 2, 2), Range.init(2, 2, 2, 2));
    const invalid_changes = try allocator.alloc(DetailedLineRangeMapping, 1);
    defer allocator.free(invalid_changes);
    invalid_changes[0] = DetailedLineRangeMapping.init(LineRange.init(2, 3), LineRange.init(2, 3), invalid_inner);
    const invalid_diff = LinesDiff.init(allocator, invalid_changes, &.{}, false);
    try std.testing.expectEqual(LinesDiffValidity.invalid, verifyLinesDiff(allocator, invalid_diff, &original, &modified, false));

    const unverified_changes = try allocator.alloc(DetailedLineRangeMapping, 1);
    defer allocator.free(unverified_changes);
    unverified_changes[0] = DetailedLineRangeMapping.init(LineRange.init(2, 3), LineRange.init(2, 3), null);
    const unverified_diff = LinesDiff.init(allocator, unverified_changes, &.{}, false);
    try std.testing.expectEqual(LinesDiffValidity.unverified, verifyLinesDiff(allocator, unverified_diff, &original, &modified, false));
}
