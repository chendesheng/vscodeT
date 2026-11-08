const std = @import("std");
pub const LinePartMetadata = struct {
    pub const IS_WHITESPACE: u8 = 1;
    pub const PSEUDO_BEFORE: u8 = 2;
    pub const PSEUDO_AFTER: u8 = 4;
    pub const IS_WHITESPACE_MASK: u8 = 0b001;
    pub const PSEUDO_BEFORE_MASK: u8 = 0b010;
    pub const PSEUDO_AFTER_MASK: u8 = 0b100;
};

pub const LinePart = struct {
    endIndex: usize,
    type: []const u8,
    metadata: u8,
    containsRTL: bool,

    pub fn init(endIndex: usize, part_type: []const u8, metadata: u8, containsRTL: bool) LinePart {
        return .{ .endIndex = endIndex, .type = part_type, .metadata = metadata, .containsRTL = containsRTL };
    }

    pub fn isWhitespace(self: LinePart) bool {
        return (self.metadata & LinePartMetadata.IS_WHITESPACE_MASK) != 0;
    }

    pub fn isPseudoAfter(self: LinePart) bool {
        return (self.metadata & LinePartMetadata.PSEUDO_AFTER_MASK) != 0;
    }
};

test "linePart: metadata checks" {
    const part = LinePart.init(4, "type", LinePartMetadata.IS_WHITESPACE, false);
    try std.testing.expect(part.isWhitespace());
    try std.testing.expect(!part.isPseudoAfter());
}
