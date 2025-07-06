const Range = @import("range.zig").Range;

pub const ModelContentChange = struct {
    range: Range,
    rangeOffset: usize,
    rangeLength: usize,
    text: []const u8,
};
