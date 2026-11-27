// UTF-16/UTF-8 API conversion, shared with semantic tokens.
const std = @import("std");
const positions = @import("../../../base/common/utf16Position.zig");
pub const utf16OffsetForColumn = positions.utf16OffsetForColumn;
pub const columnForUtf16Offset = positions.columnForUtf16Offset;
pub const LineIndex = positions.LineIndex;

test "position converter: ASCII" {
    try std.testing.expectEqual(@as(usize, 1), utf16OffsetForColumn("hello", 1));
    try std.testing.expectEqual(@as(usize, 4), utf16OffsetForColumn("hello", 4));
    try std.testing.expectEqual(@as(usize, 6), utf16OffsetForColumn("hello", 6));
    try std.testing.expectEqual(@as(usize, 4), columnForUtf16Offset("hello", 4));
}

test "position converter: accents and emoji" {
    const line = "aé😀b";
    // a=1, é=2, 😀=2 UTF-16 units but 4 UTF-8 bytes, b.
    try std.testing.expectEqual(@as(usize, 1), utf16OffsetForColumn(line, 1));
    try std.testing.expectEqual(@as(usize, 2), utf16OffsetForColumn(line, 2));
    try std.testing.expectEqual(@as(usize, 3), utf16OffsetForColumn(line, 4));
    try std.testing.expectEqual(@as(usize, 5), utf16OffsetForColumn(line, 8));
    try std.testing.expectEqual(@as(usize, 6), utf16OffsetForColumn(line, 9));

    try std.testing.expectEqual(@as(usize, 1), columnForUtf16Offset(line, 1));
    try std.testing.expectEqual(@as(usize, 2), columnForUtf16Offset(line, 2));
    try std.testing.expectEqual(@as(usize, 4), columnForUtf16Offset(line, 3));
    try std.testing.expectEqual(@as(usize, 8), columnForUtf16Offset(line, 5));
    try std.testing.expectEqual(@as(usize, 9), columnForUtf16Offset(line, 6));
}

test "position converter: clamps beyond the line" {
    try std.testing.expectEqual(@as(usize, 6), utf16OffsetForColumn("hello", 99));
    try std.testing.expectEqual(@as(usize, 6), columnForUtf16Offset("hello", 99));
}

test "batched symbol columns match individual conversions including surrogate interiors" {
    const line = "a☼é😀𐀀z";
    const index = try LineIndex.init(std.testing.allocator, line);
    defer std.testing.allocator.free(index.entries);
    for (0..20) |offset| try std.testing.expectEqual(columnForUtf16Offset(line, offset + 1), index.column(offset));
}
