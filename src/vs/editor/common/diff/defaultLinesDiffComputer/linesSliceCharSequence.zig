const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const CharCode = @import("../../../../base/common/charCode.zig").CharCode;
const utils = @import("../../../../base/common/utils.zig");
const OffsetRange = @import("../../core/ranges/offsetRange.zig").OffsetRange;
const Position = @import("../../core/position.zig").Position;
const Range = @import("../../core/range.zig").Range;
const range = @import("../../core/range.zig");
const diff = @import("algorithms/diffAlgorithm.zig");
const isSpace = @import("utils.zig").isSpace;

const CharBoundaryCategory = enum(u8) {
    WordLower,
    WordUpper,
    WordNumber,
    End,
    Other,
    Separator,
    Space,
    LineBreakCR,
    LineBreakLF,
};

/// A character-level sequence over a slice of lines.
pub const LinesSliceCharSequence = struct {
    const Self = @This();

    allocator: Allocator,
    lines: []const []const u8,
    range: Range,
    consider_whitespace_changes: bool,
    elements: ArrayList(u32),
    first_element_offset_by_line_idx: ArrayList(usize),
    line_start_offsets: ArrayList(usize),
    trimmed_ws_lengths_by_line_idx: ArrayList(usize),

    pub fn init(
        allocator: Allocator,
        lines: []const []const u8,
        slice_range: Range,
        consider_whitespace_changes: bool,
    ) !Self {
        var self = Self{
            .allocator = allocator,
            .lines = lines,
            .range = slice_range,
            .consider_whitespace_changes = consider_whitespace_changes,
            .elements = ArrayList(u32).init(allocator),
            .first_element_offset_by_line_idx = ArrayList(usize).init(allocator),
            .line_start_offsets = ArrayList(usize).init(allocator),
            .trimmed_ws_lengths_by_line_idx = ArrayList(usize).init(allocator),
        };
        errdefer self.deinit();

        try self.first_element_offset_by_line_idx.append(0);

        var line_number = slice_range.startLineNumber;
        while (line_number <= slice_range.endLineNumber) : (line_number += 1) {
            var line = lines[line_number - 1];
            var line_start_offset: usize = 0;
            if (line_number == slice_range.startLineNumber and slice_range.startColumn > 1) {
                line_start_offset = slice_range.startColumn - 1;
                line = line[line_start_offset..];
            }
            try self.line_start_offsets.append(line_start_offset);

            var trimmed_ws_length: usize = 0;
            if (!consider_whitespace_changes) {
                const trimmed = std.mem.trim(u8, line, " \t\r\n");
                trimmed_ws_length = line.len - trimmed.len;
                line = trimmed;
            }
            try self.trimmed_ws_lengths_by_line_idx.append(trimmed_ws_length);

            var line_length: usize = line.len;
            if (line_number == slice_range.endLineNumber) {
                const end_offset: isize = @as(isize, @intCast(slice_range.endColumn)) - 1 -
                    @as(isize, @intCast(line_start_offset)) -
                    @as(isize, @intCast(trimmed_ws_length));
                line_length = @min(if (end_offset < 0) 0 else @as(usize, @intCast(end_offset)), line.len);
            }

            for (0..line_length) |i| {
                try self.elements.append(line[i]);
            }

            if (line_number < slice_range.endLineNumber) {
                try self.elements.append(CharCode.LineFeed);
                try self.first_element_offset_by_line_idx.append(self.elements.items.len);
            }
        }
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.elements.deinit();
        self.first_element_offset_by_line_idx.deinit();
        self.line_start_offsets.deinit();
        self.trimmed_ws_lengths_by_line_idx.deinit();
    }

    pub fn getText(self: *const Self, allocator: Allocator, text_range: OffsetRange) ![]u8 {
        var result = try allocator.alloc(u8, text_range.length());
        for (self.elements.items[text_range.start..text_range.endExclusive], 0..) |element, i| {
            result[i] = @intCast(element);
        }
        return result;
    }

    pub fn text(self: *const Self, allocator: Allocator) ![]u8 {
        return self.getText(allocator, OffsetRange.ofLength(self.length()));
    }

    pub fn getElement(self: *const Self, offset: usize) u64 {
        return self.elements.items[offset];
    }

    pub fn length(self: *const Self) usize {
        return self.elements.items.len;
    }

    pub fn getBoundaryScore(self: *const Self, sequence_length: usize) isize {
        //   a   b   c   ,           d   e   f
        // 11  0   0   12  15  6   13  0   0   11
        const prev_category = getCategory(if (sequence_length > 0) @intCast(self.elements.items[sequence_length - 1]) else -1);
        const next_category = getCategory(if (sequence_length < self.elements.items.len) @intCast(self.elements.items[sequence_length]) else -1);

        if (prev_category == .LineBreakCR and next_category == .LineBreakLF) {
            // Don't break between \r and \n.
            return 0;
        }
        if (prev_category == .LineBreakLF) {
            // Prefer the linebreak before the change.
            return 150;
        }

        var score: isize = 0;
        if (prev_category != next_category) {
            score += 10;
            if (prev_category == .WordLower and next_category == .WordUpper) {
                score += 1;
            }
        }

        score += categoryBoundaryScore(prev_category);
        score += categoryBoundaryScore(next_category);
        return score;
    }

    pub const Preference = enum { left, right };

    pub fn translateOffset(self: *const Self, offset: usize, preference: Preference) Position {
        const index = utils.findLastIdxMonotonous(
            usize,
            self.first_element_offset_by_line_idx.items,
            offset,
            struct {
                fn lessThanOrEqual(value: usize, target: usize) bool {
                    return value <= target;
                }
            }.lessThanOrEqual,
            0,
            self.first_element_offset_by_line_idx.items.len,
        ) orelse 0;

        const line_offset = offset - self.first_element_offset_by_line_idx.items[index];
        const trimmed_ws_length = self.trimmed_ws_lengths_by_line_idx.items[index];
        const extra = if (line_offset == 0 and preference == .left) 0 else trimmed_ws_length;
        return Position.init(
            self.range.startLineNumber + index,
            1 + self.line_start_offsets.items[index] + line_offset + extra,
        );
    }

    pub fn translateRange(self: *const Self, offset_range: OffsetRange) Range {
        const pos1 = self.translateOffset(offset_range.start, .right);
        const pos2 = self.translateOffset(offset_range.endExclusive, .left);
        if (pos2.isBefore(pos1)) {
            return range.fromPositions(pos2, pos2);
        }
        return range.fromPositions(pos1, pos2);
    }

    /// Finds the word that contains the character at the given offset.
    pub fn findWordContaining(self: *const Self, offset: usize) ?OffsetRange {
        if (offset >= self.elements.items.len) {
            return null;
        }
        if (!isWordChar(self.elements.items[offset])) {
            return null;
        }

        var start = offset;
        while (start > 0 and isWordChar(self.elements.items[start - 1])) {
            start -= 1;
        }

        var end = offset;
        while (end < self.elements.items.len and isWordChar(self.elements.items[end])) {
            end += 1;
        }
        return OffsetRange.init(start, end);
    }

    /// `fooBar` has the two sub-words `foo` and `bar`.
    pub fn findSubWordContaining(self: *const Self, offset: usize) ?OffsetRange {
        if (offset >= self.elements.items.len) {
            return null;
        }
        if (!isWordChar(self.elements.items[offset])) {
            return null;
        }

        var start = offset;
        while (start > 0 and isWordChar(self.elements.items[start - 1]) and !isUpperCase(self.elements.items[start])) {
            start -= 1;
        }

        var end = offset;
        while (end < self.elements.items.len and isWordChar(self.elements.items[end]) and !isUpperCase(self.elements.items[end])) {
            end += 1;
        }
        return OffsetRange.init(start, end);
    }

    pub fn countLinesIn(self: *const Self, offset_range: OffsetRange) usize {
        return self.translateOffset(offset_range.endExclusive, .right).lineNumber -
            self.translateOffset(offset_range.start, .right).lineNumber;
    }

    pub fn isStronglyEqual(self: *const Self, offset1: usize, offset2: usize) bool {
        return self.elements.items[offset1] == self.elements.items[offset2];
    }

    pub fn extendToFullLines(self: *const Self, offset_range: OffsetRange) OffsetRange {
        const start = utils.findLastMonotonous(
            usize,
            self.first_element_offset_by_line_idx.items,
            offset_range.start,
            struct {
                fn lessThanOrEqual(value: usize, target: usize) bool {
                    return value <= target;
                }
            }.lessThanOrEqual,
        ) orelse 0;
        const end = utils.findFirstMonotonous(
            usize,
            self.first_element_offset_by_line_idx.items,
            offset_range.endExclusive,
            struct {
                fn greaterThanOrEqual(value: usize, target: usize) bool {
                    return value >= target;
                }
            }.greaterThanOrEqual,
        ) orelse self.elements.items.len;
        return OffsetRange.init(start, end);
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

fn isWordChar(char_code: u32) bool {
    return (char_code >= CharCode.a and char_code <= CharCode.z) or
        (char_code >= CharCode.A and char_code <= CharCode.Z) or
        (char_code >= CharCode.Digit0 and char_code <= CharCode.Digit9);
}

fn isUpperCase(char_code: u32) bool {
    return char_code >= CharCode.A and char_code <= CharCode.Z;
}

fn categoryBoundaryScore(category: CharBoundaryCategory) isize {
    return switch (category) {
        .WordLower, .WordUpper, .WordNumber => 0,
        .End, .LineBreakCR, .LineBreakLF => 10,
        .Other => 2,
        .Separator => 30,
        .Space => 3,
    };
}

fn getCategory(char_code: isize) CharBoundaryCategory {
    const code = char_code;
    const cc = struct {
        fn value(v: u32) isize {
            return @intCast(v);
        }
    }.value;
    if (code == cc(CharCode.LineFeed)) {
        return .LineBreakLF;
    } else if (code == cc(CharCode.CarriageReturn)) {
        return .LineBreakCR;
    } else if (code >= 0 and isSpace(@intCast(code))) {
        return .Space;
    } else if (code >= cc(CharCode.a) and code <= cc(CharCode.z)) {
        return .WordLower;
    } else if (code >= cc(CharCode.A) and code <= cc(CharCode.Z)) {
        return .WordUpper;
    } else if (code >= cc(CharCode.Digit0) and code <= cc(CharCode.Digit9)) {
        return .WordNumber;
    } else if (code == -1) {
        return .End;
    } else if (code == cc(CharCode.Comma) or code == cc(CharCode.Semicolon)) {
        return .Separator;
    }
    return .Other;
}

test "LinesSliceCharSequence: construction and translation" {
    const allocator = std.testing.allocator;

    const lines = [_][]const u8{ "abc", "  def", "ghi" };
    var sequence = try LinesSliceCharSequence.init(allocator, &lines, Range.init(1, 1, 3, 4), false);
    defer sequence.deinit();

    // abc \n def \n ghi, with leading whitespace trimmed on lines 2.
    try std.testing.expectEqual(@as(usize, 11), sequence.length());
    try std.testing.expectEqualDeep(Position.init(1, 1), sequence.translateOffset(0, .right));
    try std.testing.expectEqualDeep(Position.init(2, 3), sequence.translateOffset(4, .right));
    try std.testing.expectEqualDeep(Position.init(2, 1), sequence.translateOffset(4, .left));

    const text = try sequence.text(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("abc\ndef\nghi", text);
}

test "LinesSliceCharSequence: words and boundary scores" {
    const allocator = std.testing.allocator;

    const lines = [_][]const u8{"fooBar baz"};
    var sequence = try LinesSliceCharSequence.init(allocator, &lines, Range.init(1, 1, 1, 12), true);
    defer sequence.deinit();

    try std.testing.expectEqual(OffsetRange.init(0, 6), sequence.findWordContaining(1).?);
    try std.testing.expectEqual(OffsetRange.init(0, 3), sequence.findSubWordContaining(1).?);
    try std.testing.expectEqual(OffsetRange.init(3, 6), sequence.findSubWordContaining(4).?);
    try std.testing.expectEqual(@as(isize, 20), sequence.getBoundaryScore(0));
    try std.testing.expectEqual(OffsetRange.init(0, 10), sequence.extendToFullLines(OffsetRange.init(2, 5)));
}
