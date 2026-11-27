// Shared Zig UTF-16/UTF-8 position boundary for the editor and extension host.
//
// The terminal editor model stores columns as 1-based UTF-8 byte offsets while
// VS Code's extension API and language servers use 1-based UTF-16 code units.
// Provider wire DTOs cross this boundary explicitly.
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

    pub fn deinit(self: *LineIndex, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        self.* = undefined;
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
