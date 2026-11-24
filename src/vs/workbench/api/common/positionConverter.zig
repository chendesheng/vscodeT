// UTF-16/UTF-8 position boundary for the extension host.
//
// The terminal editor model stores columns as 1-based UTF-8 byte offsets while
// VS Code's extension API and language servers use 1-based UTF-16 code units.
// Every RPC that carries a position crosses this boundary explicitly.
const std = @import("std");

/// Converts a 1-based UTF-8 byte column to a 1-based UTF-16 code-unit offset.
pub fn utf16OffsetForColumn(line: []const u8, column: usize) usize {
    if (column <= 1) return 1;
    const target = column - 1;
    var index: usize = 0;
    var units: usize = 1;
    while (index < line.len and index < target) {
        const sequence = nextSequence(line, index);
        if (index + sequence.len > target) break;
        index += sequence.len;
        units += sequence.units;
    }
    return units;
}

/// Converts a 1-based UTF-16 code-unit offset to a 1-based UTF-8 byte column.
pub fn columnForUtf16Offset(line: []const u8, offset: usize) usize {
    if (offset <= 1) return 1;
    const target = offset - 1;
    var index: usize = 0;
    var units: usize = 0;
    while (index < line.len and units < target) {
        const sequence = nextSequence(line, index);
        units += sequence.units;
        index += sequence.len;
    }
    return index + 1;
}

/// Batch conversion of server positions on one line. Only multibyte
/// sequences change the byte/UTF-16 delta. An ASCII line has no entries.
pub const LineIndex = struct {
    const Entry = struct { end_units: usize, end_bytes: usize, surrogate: bool };
    entries: []const Entry,
    byte_len: usize,

    pub fn init(allocator: std.mem.Allocator, line: []const u8) !LineIndex {
        var entries: std.ArrayList(Entry) = .empty;
        errdefer entries.deinit(allocator);
        var bytes: usize = 0;
        var units: usize = 0;
        while (bytes < line.len) {
            if (line[bytes] < 128) {
                bytes += 1;
                units += 1;
                continue;
            }
            const seq = nextSequence(line, bytes);
            bytes += seq.len;
            units += seq.units;
            if (seq.len != seq.units) try entries.append(allocator, .{ .end_units = units, .end_bytes = bytes, .surrogate = seq.units == 2 });
        }
        return .{ .entries = try entries.toOwnedSlice(allocator), .byte_len = line.len };
    }

    pub fn column(self: LineIndex, zero_based_units: usize) usize {
        var low: usize = 0;
        var high = self.entries.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (self.entries[mid].end_units <= zero_based_units) low = mid + 1 else high = mid;
        }
        const delta = if (low == 0) 0 else self.entries[low - 1].end_bytes - self.entries[low - 1].end_units;
        if (low < self.entries.len) {
            const next = self.entries[low];
            // An offset between surrogate halves rounds to the character end.
            if (next.surrogate and zero_based_units + 1 == next.end_units) return next.end_bytes + 1;
        }
        return @min(self.byte_len, zero_based_units + delta) + 1;
    }
};

const Sequence = struct { len: usize, units: usize };

fn nextSequence(line: []const u8, index: usize) Sequence {
    const len = std.unicode.utf8ByteSequenceLength(line[index]) catch return .{ .len = 1, .units = 1 };
    if (index + len > line.len) return .{ .len = 1, .units = 1 };
    const codepoint = std.unicode.utf8Decode(line[index .. index + len]) catch return .{ .len = 1, .units = 1 };
    return .{ .len = len, .units = if (codepoint > 0xFFFF) 2 else 1 };
}

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
