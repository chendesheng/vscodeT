// Port of `src/vs/base/common/diff/diffChange.ts`.
const std = @import("std");

/// Represents information about a specific difference between two sequences.
///
/// Indices are `isize` because the diff helpers temporarily compute
/// out-of-range values (e.g. `-1`) while walking diagonals; only changes that
/// are part of the returned result are guaranteed to be in range.
pub const DiffChange = struct {
    /// The position of the first element in the original sequence which this
    /// change affects.
    originalStart: isize,
    /// The number of elements from the original sequence which were affected.
    originalLength: isize,
    /// The position of the first element in the modified sequence which this
    /// change affects.
    modifiedStart: isize,
    /// The number of elements from the modified sequence which were affected
    /// (added).
    modifiedLength: isize,

    pub fn init(original_start: isize, original_length: isize, modified_start: isize, modified_length: isize) DiffChange {
        return .{
            .originalStart = original_start,
            .originalLength = original_length,
            .modifiedStart = modified_start,
            .modifiedLength = modified_length,
        };
    }

    /// The end point (exclusive) of the change in the original sequence.
    pub fn getOriginalEnd(self: DiffChange) isize {
        return self.originalStart + self.originalLength;
    }

    /// The end point (exclusive) of the change in the modified sequence.
    pub fn getModifiedEnd(self: DiffChange) isize {
        return self.modifiedStart + self.modifiedLength;
    }

    pub fn eql(self: DiffChange, other: DiffChange) bool {
        return self.originalStart == other.originalStart and
            self.originalLength == other.originalLength and
            self.modifiedStart == other.modifiedStart and
            self.modifiedLength == other.modifiedLength;
    }
};

test "DiffChange" {
    const change = DiffChange.init(1, 2, 3, 4);
    try std.testing.expectEqual(@as(isize, 3), change.getOriginalEnd());
    try std.testing.expectEqual(@as(isize, 7), change.getModifiedEnd());
    try std.testing.expect(change.eql(DiffChange.init(1, 2, 3, 4)));
    try std.testing.expect(!change.eql(DiffChange.init(1, 2, 3, 5)));
}
