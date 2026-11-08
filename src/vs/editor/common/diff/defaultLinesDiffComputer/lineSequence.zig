const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const CharCode = @import("../../../../base/common/charCode.zig").CharCode;
const diff = @import("algorithms/diffAlgorithm.zig");

/// A line-based sequence used by the diff algorithms.
pub const LineSequence = struct {
    const Self = @This();

    trimmed_hash: []const u64,
    lines: []const []const u8,

    pub fn init(trimmed_hash: []const u64, lines: []const []const u8) Self {
        return .{ .trimmed_hash = trimmed_hash, .lines = lines };
    }

    pub fn getElement(self: *const Self, offset: usize) u64 {
        return self.trimmed_hash[offset];
    }

    pub fn length(self: *const Self) usize {
        return self.trimmed_hash.len;
    }

    pub fn getBoundaryScore(self: *const Self, sequence_length: usize) isize {
        const indentation_before: isize = if (sequence_length == 0) 0 else @intCast(getIndentation(self.lines[sequence_length - 1]));
        const indentation_after: isize = if (sequence_length == self.lines.len) 0 else @intCast(getIndentation(self.lines[sequence_length]));
        return 1000 - (indentation_before + indentation_after);
    }

    pub fn getText(self: *const Self, allocator: Allocator, range: @import("../../core/ranges/offsetRange.zig").OffsetRange) ![]u8 {
        var result = ArrayList(u8).init(allocator);
        errdefer result.deinit();
        for (self.lines[range.start..range.endExclusive], 0..) |line, i| {
            if (i > 0) try result.append('\n');
            try result.appendSlice(line);
        }
        return result.toOwnedSlice();
    }

    pub fn isStronglyEqual(self: *const Self, offset1: usize, offset2: usize) bool {
        return std.mem.eql(u8, self.lines[offset1], self.lines[offset2]);
    }

    fn getElementAny(context: *anyopaque, offset: usize) u64 {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.getElement(offset);
    }

    fn getLengthAny(context: *anyopaque) usize {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.length();
    }

    fn getBoundaryScoreAny(context: *anyopaque, sequence_length: usize) isize {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.getBoundaryScore(sequence_length);
    }

    fn isStronglyEqualAny(context: *anyopaque, offset1: usize, offset2: usize) bool {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.isStronglyEqual(offset1, offset2);
    }

    pub fn sequence(self: *Self) diff.ISequence {
        return diff.ISequence.init(
            self,
            &getElementAny,
            &getLengthAny,
            &getBoundaryScoreAny,
            &isStronglyEqualAny,
        );
    }
};

fn getIndentation(str: []const u8) usize {
    var i: usize = 0;
    while (i < str.len and (str[i] == CharCode.Space or str[i] == CharCode.Tab)) {
        i += 1;
    }
    return i;
}

test "LineSequence: boundary score and text" {
    const allocator = std.testing.allocator;

    const lines = [_][]const u8{ "abc", "  def", "\tghi" };
    const hashes = [_]u64{ 1, 2, 3 };
    var sequence = LineSequence.init(&hashes, &lines);

    try std.testing.expectEqual(@as(usize, 3), sequence.length());
    try std.testing.expectEqual(@as(u64, 2), sequence.getElement(1));
    try std.testing.expectEqual(@as(isize, 1000), sequence.getBoundaryScore(0));
    try std.testing.expectEqual(@as(isize, 998), sequence.getBoundaryScore(1));
    try std.testing.expectEqual(@as(isize, 997), sequence.getBoundaryScore(2));

    const OffsetRange = @import("../../core/ranges/offsetRange.zig").OffsetRange;
    const text = try sequence.getText(allocator, OffsetRange.init(0, 2));
    defer allocator.free(text);
    try std.testing.expectEqualStrings("abc\n  def", text);
}
