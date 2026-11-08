const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const LineRange = @import("../core/ranges/lineRange.zig").LineRange;
const Position = @import("../core/position.zig").Position;
const Range = @import("../core/range.zig").Range;
const range = @import("../core/range.zig");
const TextReplacement = @import("../core/edits/textEdit.zig").TextReplacement;
const TextEdit = @import("../core/edits/textEdit.zig").TextEdit;
const AbstractText = @import("../core/text/abstractText.zig").AbstractText;
const IChange = @import("linesDiffComputer.zig").IChange;

/// Maps a line range in the original text model to a line range in the modified
/// text model.
pub const LineRangeMapping = struct {
    const Self = @This();

    /// The line range in the original text model.
    original: LineRange,
    /// The line range in the modified text model.
    modified: LineRange,

    pub fn init(original_range: LineRange, modified_range: LineRange) Self {
        return .{ .original = original_range, .modified = modified_range };
    }

    pub fn inverse(
        allocator: Allocator,
        mapping: []const LineRangeMapping,
        original_line_count: usize,
        modified_line_count: usize,
    ) ![]LineRangeMapping {
        var result = ArrayList(LineRangeMapping).init(allocator);
        errdefer result.deinit();

        var last_original_end_line_number: usize = 1;
        var last_modified_end_line_number: usize = 1;

        for (mapping) |entry| {
            const mapping_range = LineRangeMapping.init(
                LineRange.init(last_original_end_line_number, entry.original.startLineNumber),
                LineRange.init(last_modified_end_line_number, entry.modified.startLineNumber),
            );
            if (!mapping_range.modified.isEmpty()) {
                try result.append(mapping_range);
            }
            last_original_end_line_number = entry.original.endLineNumberExclusive;
            last_modified_end_line_number = entry.modified.endLineNumberExclusive;
        }

        const last = LineRangeMapping.init(
            LineRange.init(last_original_end_line_number, original_line_count + 1),
            LineRange.init(last_modified_end_line_number, modified_line_count + 1),
        );
        if (!last.modified.isEmpty()) {
            try result.append(last);
        }
        return result.toOwnedSlice();
    }

    pub fn clip(
        allocator: Allocator,
        mapping: []const LineRangeMapping,
        original_range: LineRange,
        modified_range: LineRange,
    ) ![]LineRangeMapping {
        var result = ArrayList(LineRangeMapping).init(allocator);
        errdefer result.deinit();

        for (mapping) |entry| {
            const original = entry.original.intersect(original_range);
            const modified = entry.modified.intersect(modified_range);
            if (original != null and !original.?.isEmpty() and modified != null and !modified.?.isEmpty()) {
                try result.append(LineRangeMapping.init(original.?, modified.?));
            }
        }
        return result.toOwnedSlice();
    }

    pub fn toString(self: *const Self, writer: *Io.Writer) !void {
        try writer.writeByte('{');
        try self.original.toString(writer);
        try writer.writeAll("->");
        try self.modified.toString(writer);
        try writer.writeByte('}');
    }

    pub fn flip(self: *const Self) LineRangeMapping {
        return LineRangeMapping.init(self.modified, self.original);
    }

    pub fn join(self: *const Self, other: LineRangeMapping) LineRangeMapping {
        return LineRangeMapping.init(
            self.original.join(other.original),
            self.modified.join(other.modified),
        );
    }

    pub fn changedLineCount(self: *const Self) usize {
        return @max(self.original.length(), self.modified.length());
    }

    /// This method assumes that the mapping describes a valid diff! I.e. if one
    /// range is empty, the other range cannot be the entire document.
    pub fn toRangeMapping(self: *const Self) !RangeMapping {
        const orig_inclusive_range = self.original.toInclusiveRange();
        const mod_inclusive_range = self.modified.toInclusiveRange();
        if (orig_inclusive_range != null and mod_inclusive_range != null) {
            return RangeMapping.init(orig_inclusive_range.?, mod_inclusive_range.?);
        } else if (self.original.startLineNumber == 1 or self.modified.startLineNumber == 1) {
            if (!(self.modified.startLineNumber == 1 and self.original.startLineNumber == 1)) {
                return error.InvalidDiff;
            }
            return RangeMapping.init(
                Range.init(self.original.startLineNumber, 1, self.original.endLineNumberExclusive, 1),
                Range.init(self.modified.startLineNumber, 1, self.modified.endLineNumberExclusive, 1),
            );
        } else {
            return RangeMapping.init(
                Range.init(self.original.startLineNumber - 1, std.math.maxInt(usize), self.original.endLineNumberExclusive - 1, std.math.maxInt(usize)),
                Range.init(self.modified.startLineNumber - 1, std.math.maxInt(usize), self.modified.endLineNumberExclusive - 1, std.math.maxInt(usize)),
            );
        }
    }

    /// This method assumes that the mapping describes a valid diff!
    pub fn toRangeMapping2(self: *const Self, original: []const []const u8, modified: []const []const u8) !RangeMapping {
        if (isValidLineNumber(self.original.endLineNumberExclusive, original) and
            isValidLineNumber(self.modified.endLineNumberExclusive, modified))
        {
            return RangeMapping.init(
                Range.init(self.original.startLineNumber, 1, self.original.endLineNumberExclusive, 1),
                Range.init(self.modified.startLineNumber, 1, self.modified.endLineNumberExclusive, 1),
            );
        }

        if (!self.original.isEmpty() and !self.modified.isEmpty()) {
            return RangeMapping.init(
                range.fromPositions(
                    Position.init(self.original.startLineNumber, 1),
                    normalizePosition(Position.init(self.original.endLineNumberExclusive - 1, std.math.maxInt(usize)), original),
                ),
                range.fromPositions(
                    Position.init(self.modified.startLineNumber, 1),
                    normalizePosition(Position.init(self.modified.endLineNumberExclusive - 1, std.math.maxInt(usize)), modified),
                ),
            );
        }

        if (self.original.startLineNumber > 1 and self.modified.startLineNumber > 1) {
            return RangeMapping.init(
                range.fromPositions(
                    normalizePosition(Position.init(self.original.startLineNumber - 1, std.math.maxInt(usize)), original),
                    normalizePosition(Position.init(self.original.endLineNumberExclusive - 1, std.math.maxInt(usize)), original),
                ),
                range.fromPositions(
                    normalizePosition(Position.init(self.modified.startLineNumber - 1, std.math.maxInt(usize)), modified),
                    normalizePosition(Position.init(self.modified.endLineNumberExclusive - 1, std.math.maxInt(usize)), modified),
                ),
            );
        }

        return error.InvalidDiff;
    }
};

fn normalizePosition(position: Position, content: []const []const u8) Position {
    if (position.lineNumber < 1) {
        return Position.init(1, 1);
    }
    if (position.lineNumber > content.len) {
        return Position.init(content.len, content[content.len - 1].len + 1);
    }
    const line = content[position.lineNumber - 1];
    if (position.column > line.len + 1) {
        return Position.init(position.lineNumber, line.len + 1);
    }
    return position;
}

fn isValidLineNumber(line_number: usize, lines: []const []const u8) bool {
    return line_number >= 1 and line_number <= lines.len;
}

/// Maps a line range in the original text model to a line range in the modified
/// text model. Also contains inner range mappings.
pub const DetailedLineRangeMapping = struct {
    const Self = @This();

    original: LineRange,
    modified: LineRange,
    /// If inner changes have not been computed, this is null. Otherwise, it
    /// represents the character-level diff in this line range.
    inner_changes: ?[]const RangeMapping,

    pub fn init(original_range: LineRange, modified_range: LineRange, inner_changes: ?[]const RangeMapping) Self {
        return .{
            .original = original_range,
            .modified = modified_range,
            .inner_changes = inner_changes,
        };
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        if (self.inner_changes) |inner| {
            allocator.free(inner);
        }
        self.inner_changes = null;
    }

    pub fn toLineRangeMapping(self: *const Self) LineRangeMapping {
        return LineRangeMapping.init(self.original, self.modified);
    }

    pub fn toTextEdit(allocator: Allocator, mapping: []const DetailedLineRangeMapping, modified: *AbstractText) !TextEdit {
        var temp = std.heap.ArenaAllocator.init(allocator);
        defer temp.deinit();

        var replacements = ArrayList(TextReplacement).init(temp.allocator());
        for (mapping) |entry| {
            if (entry.inner_changes) |inner| {
                for (inner) |range_mapping| {
                    const replacement = try range_mapping.toTextEdit(temp.allocator(), modified);
                    try replacements.append(replacement);
                }
            }
        }
        const result = try TextEdit.create(allocator, replacements.items);
        for (replacements.items) |replacement| {
            modified.allocator.free(replacement.text);
        }
        return result;
    }

    pub fn fromRangeMappings(allocator: Allocator, range_mappings: []const RangeMapping) !Self {
        if (range_mappings.len == 0) {
            return error.InvalidDiff;
        }
        var original_ranges = ArrayList(LineRange).init(allocator);
        defer original_ranges.deinit();
        var modified_ranges = ArrayList(LineRange).init(allocator);
        defer modified_ranges.deinit();
        for (range_mappings) |mapping| {
            try original_ranges.append(LineRange.fromRangeInclusive(mapping.originalRange));
            try modified_ranges.append(LineRange.fromRangeInclusive(mapping.modifiedRange));
        }

        const original_range = (try LineRange.joinAll(original_ranges.items));
        const modified_range = (try LineRange.joinAll(modified_ranges.items));
        return Self.init(original_range, modified_range, try allocator.dupe(RangeMapping, range_mappings));
    }

    pub fn flip(self: *const Self, allocator: Allocator) !Self {
        const inner_changes: ?[]RangeMapping = if (self.inner_changes) |inner| blk: {
            const flipped = try allocator.alloc(RangeMapping, inner.len);
            errdefer allocator.free(flipped);
            for (inner, 0..) |mapping, i| {
                flipped[i] = mapping.flip();
            }
            break :blk flipped;
        } else null;
        return Self.init(self.modified, self.original, inner_changes);
    }

    pub fn withInnerChangesFromLineRanges(self: *const Self, allocator: Allocator) !Self {
        const inner = try allocator.alloc(RangeMapping, 1);
        errdefer allocator.free(inner);
        inner[0] = try self.toRangeMapping();
        return Self.init(self.original, self.modified, inner);
    }

    pub fn toRangeMapping(self: *const Self) !RangeMapping {
        const base = self.toLineRangeMapping();
        return base.toRangeMapping();
    }
};

/// Maps a range in the original text model to a range in the modified text
/// model.
pub const RangeMapping = struct {
    const Self = @This();

    originalRange: Range,
    modifiedRange: Range,

    pub fn init(original_range: Range, modified_range: Range) Self {
        return .{ .originalRange = original_range, .modifiedRange = modified_range };
    }

    pub fn fromEdit(allocator: Allocator, edit: *const TextEdit) ![]RangeMapping {
        const new_ranges = try edit.getNewRanges(allocator);
        defer allocator.free(new_ranges);

        const result = try allocator.alloc(RangeMapping, edit.replacements.len);
        errdefer allocator.free(result);
        for (edit.replacements, 0..) |replacement, i| {
            result[i] = Self.init(replacement.range, new_ranges[i]);
        }
        return result;
    }

    pub fn fromEditJoin(allocator: Allocator, edit: *const TextEdit) !RangeMapping {
        const mappings = try fromEdit(allocator, edit);
        defer allocator.free(mappings);
        return try joinAll(mappings);
    }

    pub fn joinAll(range_mappings: []const RangeMapping) !RangeMapping {
        if (range_mappings.len == 0) {
            return error.InvalidDiff;
        }
        var result = range_mappings[0];
        for (range_mappings[1..]) |mapping| {
            result = result.join(mapping);
        }
        return result;
    }

    pub fn assertSorted(range_mappings: []const RangeMapping) !void {
        var i: usize = 1;
        while (i < range_mappings.len) : (i += 1) {
            const previous = range_mappings[i - 1];
            const current = range_mappings[i];
            if (!(previous.originalRange.getEndPosition().isBeforeOrEqual(current.originalRange.getStartPosition()) and
                previous.modifiedRange.getEndPosition().isBeforeOrEqual(current.modifiedRange.getStartPosition())))
            {
                return error.RangeMappingsNotSorted;
            }
        }
    }

    pub fn toString(self: *const Self, writer: *Io.Writer) !void {
        try writer.writeByte('{');
        try self.originalRange.toString(writer);
        try writer.writeAll("->");
        try self.modifiedRange.toString(writer);
        try writer.writeByte('}');
    }

    pub fn flip(self: *const Self) RangeMapping {
        return RangeMapping.init(self.modifiedRange, self.originalRange);
    }

    /// Creates a single text replacement that describes the change from the
    /// original to the modified text. The returned text is owned by the caller.
    pub fn toTextEdit(self: *const Self, allocator: Allocator, modified: *AbstractText) !TextReplacement {
        _ = allocator;
        const new_text = try modified.getValueOfRange(self.modifiedRange);
        return TextReplacement.init(self.originalRange, new_text);
    }

    pub fn join(self: *const Self, other: RangeMapping) RangeMapping {
        return RangeMapping.init(
            Range.plusRange(&self.originalRange, &other.originalRange),
            Range.plusRange(&self.modifiedRange, &other.modifiedRange),
        );
    }
};

pub fn lineRangeMappingFromRangeMappings(
    allocator: Allocator,
    alignments: []const RangeMapping,
    original_lines: *AbstractText,
    modified_lines: *AbstractText,
    dont_assert_start_line: bool,
) ![]DetailedLineRangeMapping {
    var changes = ArrayList(DetailedLineRangeMapping).init(allocator);
    errdefer {
        for (changes.items) |*change| {
            change.deinit(allocator);
        }
        changes.deinit();
    }

    var group = ArrayList(RangeMapping).init(allocator);
    defer group.deinit();

    var previous_original: ?LineRange = null;
    var previous_modified: ?LineRange = null;
    var group_original: LineRange = undefined;
    var group_modified: LineRange = undefined;

    const flushGroup = struct {
        fn flush(
            out: *ArrayList(DetailedLineRangeMapping),
            alloc: Allocator,
            mappings: *ArrayList(RangeMapping),
            original_range: LineRange,
            modified_range: LineRange,
        ) !void {
            const inner = try alloc.dupe(RangeMapping, mappings.items);
            errdefer alloc.free(inner);
            try out.append(DetailedLineRangeMapping.init(original_range, modified_range, inner));
            mappings.clearRetainingCapacity();
        }
    }.flush;

    for (alignments) |alignment| {
        const mapping = getLineRangeMapping(alignment, original_lines, modified_lines);
        if (mapping.inner_changes) |inner| {
            original_lines.allocator.free(inner);
        }
        if (previous_original) |previous_original_range| {
            const previous_modified_range = previous_modified.?;
            const touches = previous_original_range.intersectsOrTouches(mapping.original) or
                previous_modified_range.intersectsOrTouches(mapping.modified);
            if (!touches) {
                try flushGroup(&changes, allocator, &group, group_original, group_modified);
                group_original = mapping.original;
                group_modified = mapping.modified;
            } else {
                group_original = group_original.join(mapping.original);
                group_modified = group_modified.join(mapping.modified);
            }
        } else {
            group_original = mapping.original;
            group_modified = mapping.modified;
        }
        try group.append(alignment);
        previous_original = mapping.original;
        previous_modified = mapping.modified;
    }

    if (group.items.len > 0) {
        try flushGroup(&changes, allocator, &group, group_original, group_modified);
    }

    if (!dont_assert_start_line and changes.items.len > 0) {
        if (changes.items[0].modified.startLineNumber != changes.items[0].original.startLineNumber) {
            return error.InvalidDiff;
        }
        const last = changes.items[changes.items.len - 1];
        const modified_lines_after = @as(isize, @intCast(modified_lines.getLength().lineCount)) - @as(isize, @intCast(last.modified.endLineNumberExclusive));
        const original_lines_after = @as(isize, @intCast(original_lines.getLength().lineCount)) - @as(isize, @intCast(last.original.endLineNumberExclusive));
        if (modified_lines_after != original_lines_after) {
            return error.InvalidDiff;
        }
    }

    // Check that changes are adjacent.
    var i: usize = 1;
    while (i < changes.items.len) : (i += 1) {
        const m1 = changes.items[i - 1];
        const m2 = changes.items[i];
        if (!(m2.original.startLineNumber - m1.original.endLineNumberExclusive ==
            m2.modified.startLineNumber - m1.modified.endLineNumberExclusive and
            m1.original.endLineNumberExclusive < m2.original.startLineNumber and
            m1.modified.endLineNumberExclusive < m2.modified.startLineNumber))
        {
            return error.InvalidDiff;
        }
    }

    return changes.toOwnedSlice();
}

pub fn getLineRangeMapping(
    range_mapping: RangeMapping,
    original_lines: *AbstractText,
    modified_lines: *AbstractText,
) DetailedLineRangeMapping {
    var line_start_delta: isize = 0;
    var line_end_delta: isize = 0;

    if (range_mapping.modifiedRange.endColumn == 1 and range_mapping.originalRange.endColumn == 1 and
        @as(isize, @intCast(range_mapping.originalRange.startLineNumber)) + line_start_delta <= @as(isize, @intCast(range_mapping.originalRange.endLineNumber)) and
        @as(isize, @intCast(range_mapping.modifiedRange.startLineNumber)) + line_start_delta <= @as(isize, @intCast(range_mapping.modifiedRange.endLineNumber)))
    {
        line_end_delta = -1;
    }

    if (range_mapping.modifiedRange.startColumn - 1 >= modified_lines.getLineLength(range_mapping.modifiedRange.startLineNumber) and
        range_mapping.originalRange.startColumn - 1 >= original_lines.getLineLength(range_mapping.originalRange.startLineNumber) and
        @as(isize, @intCast(range_mapping.originalRange.startLineNumber)) <= @as(isize, @intCast(range_mapping.originalRange.endLineNumber)) + line_end_delta and
        @as(isize, @intCast(range_mapping.modifiedRange.startLineNumber)) <= @as(isize, @intCast(range_mapping.modifiedRange.endLineNumber)) + line_end_delta)
    {
        line_start_delta = 1;
    }

    const original_line_range = LineRange.init(
        @intCast(@as(isize, @intCast(range_mapping.originalRange.startLineNumber)) + line_start_delta),
        @intCast(@as(isize, @intCast(range_mapping.originalRange.endLineNumber)) + 1 + line_end_delta),
    );
    const modified_line_range = LineRange.init(
        @intCast(@as(isize, @intCast(range_mapping.modifiedRange.startLineNumber)) + line_start_delta),
        @intCast(@as(isize, @intCast(range_mapping.modifiedRange.endLineNumber)) + 1 + line_end_delta),
    );

    const inner = original_lines.allocator.alloc(RangeMapping, 1) catch unreachable;
    inner[0] = range_mapping;
    return DetailedLineRangeMapping.init(original_line_range, modified_line_range, inner);
}

pub fn lineRangeMappingFromChange(change: IChange) LineRangeMapping {
    var original_range: LineRange = undefined;
    if (change.originalEndLineNumber == 0) {
        original_range = LineRange.init(change.originalStartLineNumber + 1, change.originalStartLineNumber + 1);
    } else {
        original_range = LineRange.init(change.originalStartLineNumber, change.originalEndLineNumber + 1);
    }

    var modified_range: LineRange = undefined;
    if (change.modifiedEndLineNumber == 0) {
        modified_range = LineRange.init(change.modifiedStartLineNumber + 1, change.modifiedStartLineNumber + 1);
    } else {
        modified_range = LineRange.init(change.modifiedStartLineNumber, change.modifiedEndLineNumber + 1);
    }

    return LineRangeMapping.init(original_range, modified_range);
}

test "RangeMapping: fromEdit and join" {
    const allocator = std.testing.allocator;
    const TextEditMod = @import("../core/edits/textEdit.zig");

    var edit = try TextEditMod.TextEdit.create(allocator, &.{
        TextReplacement.init(Range.init(1, 2, 1, 3), "XY"),
        TextReplacement.init(Range.init(1, 4, 1, 5), "Z"),
    });
    defer edit.deinit();

    const mappings = try RangeMapping.fromEdit(allocator, &edit);
    defer allocator.free(mappings);
    try std.testing.expectEqual(@as(usize, 2), mappings.len);
    try std.testing.expectEqual(Range.init(1, 2, 1, 3), mappings[0].originalRange);
    try std.testing.expectEqual(Range.init(1, 2, 1, 4), mappings[0].modifiedRange);

    const joined = try RangeMapping.joinAll(mappings);
    try std.testing.expectEqual(Range.init(1, 2, 1, 5), joined.originalRange);
    try std.testing.expectEqual(Range.init(1, 2, 1, 6), joined.modifiedRange);
}

test "RangeMapping: line range mapping from change" {
    const deletion = IChange{
        .originalStartLineNumber = 2,
        .originalEndLineNumber = 3,
        .modifiedStartLineNumber = 2,
        .modifiedEndLineNumber = 0,
    };
    const mapping = lineRangeMappingFromChange(deletion);
    try std.testing.expectEqual(LineRange.init(2, 4), mapping.original);
    try std.testing.expectEqual(LineRange.init(3, 3), mapping.modified);
}
