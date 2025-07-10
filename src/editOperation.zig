const Range = @import("range.zig").Range;

pub const SingleEditOperation = struct {
    // The range to replace. This can be empty to emulate a simple insert.
    range: Range,
    // The text to replace with. This can be null to emulate a simple delete.
    text: ?[]const u8,
    // This indicates that this operation has "insert" semantics.
    // i.e. forceMoveMarkers = true => if `range` is collapsed, all markers at the position will be moved.
    forceMoveMarkers: bool,
};
