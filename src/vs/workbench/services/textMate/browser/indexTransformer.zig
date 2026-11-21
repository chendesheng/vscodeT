// Port of `src/vs/workbench/services/textMate/browser/indexTransformer.ts`.
//
// Adaptation: upstream works on `AnyEdit`; the controller builds `LengthEdit`
// values (`linesLengthEditFromModelContentChange`), so this port consumes
// those replacements directly.
const std = @import("std");
const Allocator = std.mem.Allocator;
const LengthEdit = @import("../../../../editor/common/core/edits/lengthEdit.zig").LengthEdit;
const LengthReplacement = @import("../../../../editor/common/core/edits/lengthEdit.zig").LengthReplacement;

pub const MonotonousIndexTransformer = struct {
    replacements: []const LengthReplacement,
    idx: usize = 0,
    offset: isize = 0,

    pub fn init(edit: *const LengthEdit) MonotonousIndexTransformer {
        return .{ .replacements = edit.replacements };
    }

    /// Can only be called with increasing values of `index`.
    pub fn transform(self: *MonotonousIndexTransformer, index: usize) ?usize {
        var next_change: ?*const LengthReplacement = if (self.idx < self.replacements.len) &self.replacements[self.idx] else null;
        while (next_change) |change| {
            if (change.replaceRange.endExclusive > index) break;
            self.offset += change.getLengthDelta();
            self.idx += 1;
            next_change = if (self.idx < self.replacements.len) &self.replacements[self.idx] else null;
        }

        if (next_change) |change| {
            if (change.replaceRange.start <= index) {
                // The line was touched by the change.
                return null;
            }
        }

        const result = @as(isize, @intCast(index)) + self.offset;
        if (result < 0) return null;
        return @intCast(result);
    }
};

/// Builds one transformer per pending model change, like
/// `MonotonousIndexTransformer.fromMany`. The caller owns the returned slice
/// and the edits it points to.
pub fn fromMany(allocator: Allocator, edits: []const *const LengthEdit) ![]MonotonousIndexTransformer {
    const result = try allocator.alloc(MonotonousIndexTransformer, edits.len);
    errdefer allocator.free(result);
    for (edits, 0..) |edit, i| result[i] = MonotonousIndexTransformer.init(edit);
    return result;
}

/// Applies the transformers in sequence. Once a transformer reports `null`
/// the line was touched and the result stays `null`.
pub fn transformMany(transformers: []MonotonousIndexTransformer, index: usize) ?usize {
    var current = index;
    for (transformers) |*transformer| {
        current = transformer.transform(current) orelse return null;
    }
    return current;
}

test "monotonous index transformer: unchanged lines keep their index" {
    var edit = LengthEdit.create(std.testing.allocator, &.{}) catch unreachable;
    defer edit.deinit();
    var transformer = MonotonousIndexTransformer.init(&edit);
    try std.testing.expectEqual(@as(?usize, 0), transformer.transform(0));
    try std.testing.expectEqual(@as(?usize, 12), transformer.transform(12));
}

test "monotonous index transformer: inserted lines shift and touched lines are skipped" {
    const OffsetRange = @import("../../../../editor/common/core/ranges/offsetRange.zig").OffsetRange;
    var edit = LengthEdit.create(std.testing.allocator, &.{
        LengthReplacement.init(OffsetRange.init(2, 3), 4),
    }) catch unreachable;
    defer edit.deinit();
    var transformer = MonotonousIndexTransformer.init(&edit);
    try std.testing.expectEqual(@as(?usize, 0), transformer.transform(0));
    try std.testing.expectEqual(@as(?usize, 1), transformer.transform(1));
    try std.testing.expectEqual(@as(?usize, null), transformer.transform(2));
    try std.testing.expectEqual(@as(?usize, 6), transformer.transform(3));
    try std.testing.expectEqual(@as(?usize, 8), transformer.transform(5));
}
