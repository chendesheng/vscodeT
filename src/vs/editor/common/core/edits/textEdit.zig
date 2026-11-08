const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const strings = @import("../../../../base/common/strings.zig");
const Position = @import("../position.zig").Position;
const Range = @import("../range.zig").Range;
const range = @import("../range.zig");
const TextLength = @import("../text/textLength.zig").TextLength;
const AbstractText = @import("../text/abstractText.zig").AbstractText;
const StringText = @import("../text/abstractText.zig").StringText;
const ISingleEditOperation = @import("../editOperation.zig").ISingleEditOperation;
const StringEdit = @import("stringEdit.zig").StringEdit;
const StringReplacement = @import("stringEdit.zig").StringReplacement;
const OffsetRange = @import("../ranges/offsetRange.zig").OffsetRange;

/// Either a position or a range.
pub const PositionOrRange = union(enum) {
    position: Position,
    range: Range,
};

pub fn rangeEquals(a: Range, b: Range) bool {
    return a.startLineNumber == b.startLineNumber and a.startColumn == b.startColumn and
        a.endLineNumber == b.endLineNumber and a.endColumn == b.endColumn;
}

/// A replacement of a range of a text with new text.
pub const TextReplacement = struct {
    const Self = @This();

    range: Range,
    text: []const u8,

    pub fn init(text_range: Range, text: []const u8) Self {
        return .{ .range = text_range, .text = text };
    }

    pub fn delete(text_range: Range) Self {
        return Self.init(text_range, "");
    }

    pub fn fromStringReplacement(initial_state: *AbstractText, replacement: StringReplacement) !Self {
        const transformer = try initial_state.getTransformer();
        return Self.init(transformer.getRange(replacement.replaceRange), replacement.newText);
    }

    pub fn joinReplacements(allocator: Allocator, replacements: []const TextReplacement, initial_value: *AbstractText) !Self {
        if (replacements.len == 0) {
            return error.InvalidEdit;
        }
        if (replacements.len == 1) {
            return replacements[0].clone(allocator);
        }

        const start_pos = replacements[0].range.getStartPosition();
        const end_pos = replacements[replacements.len - 1].range.getEndPosition();

        var new_text = ArrayList(u8).init(allocator);
        errdefer new_text.deinit();

        for (replacements, 0..) |replacement, i| {
            try new_text.appendSlice(replacement.text);
            if (i < replacements.len - 1) {
                const next_edit = replacements[i + 1];
                const gap_range = range.fromPositions(replacement.range.getEndPosition(), next_edit.range.getStartPosition());
                const gap_text = try initial_value.getValueOfRange(gap_range);
                defer allocator.free(gap_text);
                try new_text.appendSlice(gap_text);
            }
        }

        return Self.init(
            range.fromPositions(start_pos, end_pos),
            try new_text.toOwnedSlice(),
        );
    }

    pub fn isEmpty(self: Self) bool {
        return self.range.isEmpty() and self.text.len == 0;
    }

    pub fn equals(self: Self, other: Self) bool {
        return rangeEquals(self.range, other.range) and std.mem.eql(u8, self.text, other.text);
    }

    pub fn clone(self: Self, allocator: Allocator) !Self {
        return Self.init(self.range, try allocator.dupe(u8, self.text));
    }

    pub fn toSingleEditOperation(self: Self) ISingleEditOperation {
        return .{ .range = self.range, .text = self.text };
    }

    pub fn toEdit(self: Self, allocator: Allocator) !TextEdit {
        return TextEdit.create(allocator, &.{self});
    }

    pub fn extendToCoverRange(self: Self, allocator: Allocator, cover_range: Range, initial_value: *AbstractText) !Self {
        if (self.range.containsRange(&cover_range)) {
            return self;
        }

        const new_range = Range.plusRange(&self.range, &cover_range);
        const before_range = range.fromPositions(new_range.getStartPosition(), self.range.getStartPosition());
        const after_range = range.fromPositions(self.range.getEndPosition(), new_range.getEndPosition());
        const text_before = try initial_value.getValueOfRange(before_range);
        defer allocator.free(text_before);
        const text_after = try initial_value.getValueOfRange(after_range);
        defer allocator.free(text_after);

        var new_text = ArrayList(u8).init(allocator);
        errdefer new_text.deinit();
        try new_text.appendSlice(text_before);
        try new_text.appendSlice(self.text);
        try new_text.appendSlice(text_after);
        return Self.init(new_range, try new_text.toOwnedSlice());
    }

    pub fn extendToFullLine(self: Self, allocator: Allocator, initial_value: *AbstractText) !Self {
        const transformer = try initial_value.getTransformer();
        const new_range = Range.init(
            self.range.startLineNumber,
            1,
            self.range.endLineNumber,
            transformer.getLineLength(self.range.endLineNumber) + 1,
        );
        return self.extendToCoverRange(allocator, new_range, initial_value);
    }

    pub fn removeCommonPrefixAndSuffix(self: Self, allocator: Allocator, text: *AbstractText) !Self {
        var temp = std.heap.ArenaAllocator.init(allocator);
        defer temp.deinit();
        const without_prefix = try self.removeCommonPrefix(temp.allocator(), text);
        return without_prefix.removeCommonSuffix(allocator, text);
    }

    pub fn removeCommonPrefix(self: Self, allocator: Allocator, text: *AbstractText) !Self {
        const range_text = try text.getValueOfRange(self.range);
        defer allocator.free(range_text);

        const normalized_original_text = try normalizeCRLF(allocator, range_text);
        defer allocator.free(normalized_original_text);
        const normalized_modified_text = try normalizeCRLF(allocator, self.text);
        defer allocator.free(normalized_modified_text);

        const common_prefix_len = strings.commonPrefixLength(normalized_original_text, normalized_modified_text);
        const start = TextLength.ofText(normalized_original_text[0..common_prefix_len])
            .addToPosition(self.range.getStartPosition());

        return Self.init(
            range.fromPositions(start, self.range.getEndPosition()),
            try allocator.dupe(u8, normalized_modified_text[common_prefix_len..]),
        );
    }

    pub fn removeCommonSuffix(self: Self, allocator: Allocator, text: *AbstractText) !Self {
        const range_text = try text.getValueOfRange(self.range);
        defer allocator.free(range_text);

        const normalized_original_text = try normalizeCRLF(allocator, range_text);
        defer allocator.free(normalized_original_text);
        const normalized_modified_text = try normalizeCRLF(allocator, self.text);
        defer allocator.free(normalized_modified_text);

        const common_suffix_len = strings.commonSuffixLength(normalized_original_text, normalized_modified_text);
        const end = TextLength.ofText(normalized_original_text[0 .. normalized_original_text.len - common_suffix_len])
            .addToPosition(self.range.getStartPosition());

        return Self.init(
            range.fromPositions(self.range.getStartPosition(), end),
            try allocator.dupe(u8, normalized_modified_text[0 .. normalized_modified_text.len - common_suffix_len]),
        );
    }

    pub fn isEffectiveDeletion(self: Self, allocator: Allocator, text: *AbstractText) !bool {
        const range_text = try text.getValueOfRange(self.range);
        defer allocator.free(range_text);

        const normalized_new_text = try normalizeCRLF(allocator, self.text);
        defer allocator.free(normalized_new_text);
        const normalized_existing_text = try normalizeCRLF(allocator, range_text);
        defer allocator.free(normalized_existing_text);

        const prefix_len = strings.commonPrefixLength(normalized_new_text, normalized_existing_text);
        const new_without_prefix = normalized_new_text[prefix_len..];
        const existing_without_prefix = normalized_existing_text[prefix_len..];
        const suffix_len = strings.commonSuffixLength(new_without_prefix, existing_without_prefix);
        const new_without_suffix = new_without_prefix[0 .. new_without_prefix.len - suffix_len];

        return new_without_suffix.len == 0;
    }

    pub fn toString(self: Self, writer: *Io.Writer) !void {
        const start = self.range.getStartPosition();
        const end = self.range.getEndPosition();
        try writer.print("({d},{d} -> {d},{d}): \"{s}\"", .{
            start.lineNumber, start.column,
            end.lineNumber,   end.column,
            self.text,
        });
    }
};

fn normalizeCRLF(allocator: Allocator, text: []const u8) ![]u8 {
    var result = ArrayList(u8).init(allocator);
    errdefer result.deinit();

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\r' and i + 1 < text.len and text[i + 1] == '\n') {
            try result.append('\n');
            i += 2;
        } else {
            try result.append(text[i]);
            i += 1;
        }
    }
    return result.toOwnedSlice();
}

/// A set of replacements to a text. All these replacements are applied at once.
pub const TextEdit = struct {
    const Self = @This();

    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    replacements: []TextReplacement,

    pub fn empty(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .replacements = &.{},
        };
    }

    pub fn create(allocator: Allocator, replacements: []const TextReplacement) !Self {
        var result = Self.empty(allocator);
        errdefer result.deinit();

        var previous_end: ?Position = null;
        for (replacements) |replacement| {
            if (previous_end) |end| {
                if (!end.isBeforeOrEqual(replacement.range.getStartPosition())) {
                    return error.InvalidEdit;
                }
            }
            previous_end = replacement.range.getEndPosition();
        }

        const arena_allocator = result.arena.allocator();
        result.replacements = try arena_allocator.alloc(TextReplacement, replacements.len);
        for (replacements, 0..) |replacement, i| {
            result.replacements[i] = try replacement.clone(arena_allocator);
        }
        return result;
    }

    pub fn single(allocator: Allocator, replacement: TextReplacement) !Self {
        return Self.create(allocator, &.{replacement});
    }

    pub fn clone(self: *const Self) !Self {
        return Self.create(self.allocator, self.replacements);
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    pub fn fromStringEdit(allocator: Allocator, string_edit: *const StringEdit, initial_state: *AbstractText) !Self {
        var edits = ArrayList(TextReplacement).init(allocator);
        defer edits.deinit();
        try edits.ensureTotalCapacity(string_edit.replacements.len);
        for (string_edit.replacements) |replacement| {
            edits.appendAssumeCapacity(try TextReplacement.fromStringReplacement(initial_state, replacement));
        }
        return Self.create(allocator, edits.items);
    }

    pub fn replace(allocator: Allocator, original_range: Range, new_text: []const u8) !Self {
        return Self.single(allocator, TextReplacement.init(original_range, new_text));
    }

    pub fn delete(allocator: Allocator, original_range: Range) !Self {
        return Self.single(allocator, TextReplacement.init(original_range, ""));
    }

    pub fn insert(allocator: Allocator, position: Position, new_text: []const u8) !Self {
        return Self.single(allocator, TextReplacement.init(range.fromPositions(position, position), new_text));
    }

    pub fn fromParallelReplacementsUnsorted(allocator: Allocator, replacements: []const TextReplacement) !Self {
        const sorted = try allocator.dupe(TextReplacement, replacements);
        defer allocator.free(sorted);
        std.mem.sort(TextReplacement, sorted, {}, struct {
            fn lessThan(_: void, a: TextReplacement, b: TextReplacement) bool {
                return range.compareRangesUsingStarts(&a.range, &b.range) < 0;
            }
        }.lessThan);
        return Self.create(allocator, sorted);
    }

    /// Joins touching edits and removes empty edits.
    pub fn normalize(self: *const Self) !Self {
        var temp = std.heap.ArenaAllocator.init(self.allocator);
        defer temp.deinit();
        const temp_allocator = temp.allocator();

        var replacements = ArrayList(TextReplacement).init(temp_allocator);
        for (self.replacements) |replacement| {
            if (replacements.items.len > 0) {
                const last = replacements.items[replacements.items.len - 1];
                if (last.range.getEndPosition().equals(replacement.range.getStartPosition())) {
                    var joined_text = ArrayList(u8).init(temp_allocator);
                    try joined_text.appendSlice(last.text);
                    try joined_text.appendSlice(replacement.text);
                    replacements.items[replacements.items.len - 1] = TextReplacement.init(
                        Range.plusRange(&last.range, &replacement.range),
                        try joined_text.toOwnedSlice(),
                    );
                    continue;
                }
            }
            if (!replacement.isEmpty()) {
                try replacements.append(replacement);
            }
        }
        return Self.create(self.allocator, replacements.items);
    }

    pub fn mapPosition(self: *const Self, position: Position) PositionOrRange {
        var line_delta: isize = 0;
        var current_line: usize = 0;
        var column_delta_in_current_line: isize = 0;

        for (self.replacements) |replacement| {
            const start = replacement.range.getStartPosition();

            if (position.isBeforeOrEqual(start)) {
                break;
            }

            const end = replacement.range.getEndPosition();
            const len = TextLength.ofText(replacement.text);
            if (position.isBefore(end)) {
                const current_line_signed = @as(isize, @intCast(start.lineNumber)) + line_delta;
                const start_pos = Position.init(
                    @intCast(current_line_signed),
                    @intCast(@as(isize, @intCast(start.column)) +
                        if (current_line_signed == @as(isize, @intCast(current_line))) column_delta_in_current_line else 0),
                );
                const end_pos = len.addToPosition(start_pos);
                return .{ .range = range.fromPositions(start_pos, end_pos) };
            }

            if (@as(isize, @intCast(start.lineNumber)) + line_delta != @as(isize, @intCast(current_line))) {
                column_delta_in_current_line = 0;
            }

            line_delta += @as(isize, @intCast(len.lineCount)) - @as(isize, @intCast(replacement.range.endLineNumber - replacement.range.startLineNumber));

            if (len.lineCount == 0) {
                if (end.lineNumber != start.lineNumber) {
                    column_delta_in_current_line += @as(isize, @intCast(len.columnCount)) - @as(isize, @intCast(end.column - 1));
                } else {
                    column_delta_in_current_line += @as(isize, @intCast(len.columnCount)) - @as(isize, @intCast(end.column - start.column));
                }
            } else {
                column_delta_in_current_line = @intCast(len.columnCount);
            }
            current_line = @intCast(@as(isize, @intCast(end.lineNumber)) + line_delta);
        }

        const final_line_signed = @as(isize, @intCast(position.lineNumber)) + line_delta;
        return .{ .position = Position.init(
            @intCast(final_line_signed),
            @intCast(@as(isize, @intCast(position.column)) +
                if (final_line_signed == @as(isize, @intCast(current_line))) column_delta_in_current_line else 0),
        ) };
    }

    pub fn mapRange(self: *const Self, input_range: Range) Range {
        const start = switch (self.mapPosition(input_range.getStartPosition())) {
            .position => |p| p,
            .range => |r| r.getStartPosition(),
        };
        const end = switch (self.mapPosition(input_range.getEndPosition())) {
            .position => |p| p,
            .range => |r| r.getEndPosition(),
        };
        return range.fromPositions(start, end);
    }

    pub fn inverseMapPosition(self: *const Self, allocator: Allocator, position_after_edit: Position, doc: *AbstractText) !PositionOrRange {
        var inversed = try self.inverse(allocator, doc);
        defer inversed.deinit();
        return inversed.mapPosition(position_after_edit);
    }

    pub fn inverseMapRange(self: *const Self, allocator: Allocator, input_range: Range, doc: *AbstractText) !Range {
        var inversed = try self.inverse(allocator, doc);
        defer inversed.deinit();
        return inversed.mapRange(input_range);
    }

    pub fn apply(self: *const Self, allocator: Allocator, text: *AbstractText) ![]u8 {
        var result = ArrayList(u8).init(allocator);
        errdefer result.deinit();

        var last_edit_end = Position.init(1, 1);
        for (self.replacements) |replacement| {
            const edit_range = replacement.range;
            const edit_start = edit_range.getStartPosition();
            const edit_end = edit_range.getEndPosition();

            const r = range.fromPositions(last_edit_end, edit_start);
            if (!r.isEmpty()) {
                const value = try text.getValueOfRange(r);
                defer allocator.free(value);
                try result.appendSlice(value);
            }
            try result.appendSlice(replacement.text);
            last_edit_end = edit_end;
        }
        const r = range.fromPositions(last_edit_end, text.endPositionExclusive());
        if (!r.isEmpty()) {
            const value = try text.getValueOfRange(r);
            defer allocator.free(value);
            try result.appendSlice(value);
        }
        return result.toOwnedSlice();
    }

    pub fn applyToString(self: *const Self, allocator: Allocator, str: []const u8) ![]u8 {
        var text = AbstractText.initString(allocator, str);
        defer text.deinit();
        return self.apply(allocator, &text);
    }

    pub fn inverse(self: *const Self, allocator: Allocator, doc: *AbstractText) !Self {
        const new_ranges = try self.getNewRanges(allocator);
        defer allocator.free(new_ranges);

        var replacements = ArrayList(TextReplacement).init(allocator);
        defer replacements.deinit();
        try replacements.ensureTotalCapacity(self.replacements.len);
        for (self.replacements, 0..) |replacement, idx| {
            replacements.appendAssumeCapacity(TextReplacement.init(
                new_ranges[idx],
                try doc.getValueOfRange(replacement.range),
            ));
        }

        const result = try Self.create(allocator, replacements.items);
        for (replacements.items) |replacement| {
            allocator.free(replacement.text);
        }
        return result;
    }

    pub fn getNewRanges(self: *const Self, allocator: Allocator) ![]Range {
        const new_ranges = try allocator.alloc(Range, self.replacements.len);
        errdefer allocator.free(new_ranges);

        var previous_edit_end_line_number: usize = 0;
        var line_offset: isize = 0;
        var column_offset: isize = 0;
        for (self.replacements, 0..) |replacement, i| {
            const text_length = TextLength.ofText(replacement.text);
            const new_range_start = Position.init(
                @intCast(@as(isize, @intCast(replacement.range.startLineNumber)) + line_offset),
                @intCast(@as(isize, @intCast(replacement.range.startColumn)) +
                    (if (replacement.range.startLineNumber == previous_edit_end_line_number) column_offset else 0)),
            );
            const new_range = text_length.createRange(new_range_start);
            new_ranges[i] = new_range;
            line_offset = @as(isize, @intCast(new_range.endLineNumber)) - @as(isize, @intCast(replacement.range.endLineNumber));
            column_offset = @as(isize, @intCast(new_range.endColumn)) - @as(isize, @intCast(replacement.range.endColumn));
            previous_edit_end_line_number = replacement.range.endLineNumber;
        }
        return new_ranges;
    }

    pub fn toReplacement(self: *const Self, allocator: Allocator, text: *AbstractText) !TextReplacement {
        if (self.replacements.len == 0) {
            return error.InvalidEdit;
        }
        if (self.replacements.len == 1) {
            return self.replacements[0].clone(allocator);
        }

        const start_pos = self.replacements[0].range.getStartPosition();
        const end_pos = self.replacements[self.replacements.len - 1].range.getEndPosition();

        var new_text = ArrayList(u8).init(allocator);
        errdefer new_text.deinit();

        for (self.replacements, 0..) |current_edit, i| {
            try new_text.appendSlice(current_edit.text);
            if (i < self.replacements.len - 1) {
                const next_edit = self.replacements[i + 1];
                const gap_range = range.fromPositions(current_edit.range.getEndPosition(), next_edit.range.getStartPosition());
                const gap_text = try text.getValueOfRange(gap_range);
                defer allocator.free(gap_text);
                try new_text.appendSlice(gap_text);
            }
        }
        return TextReplacement.init(range.fromPositions(start_pos, end_pos), try new_text.toOwnedSlice());
    }

    pub fn equals(self: *const Self, other: *const Self) bool {
        if (self.replacements.len != other.replacements.len) {
            return false;
        }
        for (self.replacements, other.replacements) |a, b| {
            if (!a.equals(b)) {
                return false;
            }
        }
        return true;
    }

    /// Combines two edits into one with the same effect.
    pub fn compose(self: *const Self, other: *const Self) !Self {
        var edits1 = try self.normalize();
        defer edits1.deinit();
        var edits2 = try other.normalize();
        defer edits2.deinit();

        if (edits1.replacements.len == 0) {
            return edits2.clone();
        }
        if (edits2.replacements.len == 0) {
            return edits1.clone();
        }

        var temp = std.heap.ArenaAllocator.init(self.allocator);
        defer temp.deinit();
        const temp_allocator = temp.allocator();

        var composer = Composer{
            .edits1 = &edits1,
            .result = ArrayList(TextReplacement).init(temp_allocator),
        };
        for (edits2.replacements) |r2| {
            try composer.composeReplacement(r2);
        }
        try composer.drain();

        var composed = try Self.create(self.allocator, composer.result.items);
        defer composed.deinit();
        return composed.normalize();
    }

    pub fn format(self: *const Self, allocator: Allocator, writer: *Io.Writer, text: ?*AbstractText) !void {
        if (text == null) {
            for (self.replacements, 0..) |replacement, i| {
                if (i > 0) try writer.writeByte('\n');
                try replacement.toString(writer);
            }
            return;
        }

        if (self.replacements.len == 0) {
            return;
        }

        const doc = text.?;
        const max_length: usize = 10;
        for (self.replacements, 0..) |replacement, i| {
            if (i > 0) try writer.writeByte('\n');

            const original_text = try doc.getValueOfRange(replacement.range);
            defer allocator.free(original_text);

            const before_range = range.fromPositions(
                Position.init(if (replacement.range.startLineNumber > 1) replacement.range.startLineNumber - 1 else 1, 1),
                replacement.range.getStartPosition(),
            );
            var before_text = try doc.getValueOfRange(before_range);
            defer allocator.free(before_text);
            if (before_text.len > max_length) {
                try writer.writeAll("...");
                before_text = before_text[before_text.len - max_length ..];
            }
            try writer.writeAll(before_text);

            const after_range = range.fromPositions(
                replacement.range.getEndPosition(),
                Position.init(replacement.range.endLineNumber + 1, 1),
            );
            var after_text = try doc.getValueOfRange(after_range);
            defer allocator.free(after_text);
            if (after_text.len > max_length) {
                after_text = after_text[0..max_length];
            }

            try writer.writeAll("\u{2770}");
            if (original_text.len == 0) {
                try writer.writeAll(replacement.text);
                try writer.writeAll("\u{2771}");
                try writer.writeAll(after_text);
                continue;
            }

            if (original_text.len > max_length) {
                const half_max = max_length / 2;
                try writer.writeAll(original_text[0..half_max]);
                try writer.writeAll("...");
                try writer.writeAll(original_text[original_text.len - half_max ..]);
            } else {
                try writer.writeAll(original_text);
            }
            try writer.writeAll("\u{21a6}");
            if (replacement.text.len > max_length) {
                const half_max = max_length / 2;
                try writer.writeAll(replacement.text[0..half_max]);
                try writer.writeAll("...");
                try writer.writeAll(replacement.text[replacement.text.len - half_max ..]);
            } else {
                try writer.writeAll(replacement.text);
            }
            try writer.writeAll("\u{2771}");
            try writer.writeAll(after_text);
        }
    }
};

const Composer = struct {
    edits1: *const TextEdit,
    result: ArrayList(TextReplacement),
    edit1_idx: usize = 0,
    last_edit1_end_s0_line: usize = 1,
    last_edit1_end_s0_col: usize = 1,
    head_src_start_line: usize = 0,
    head_src_start_col: usize = 0,
    head_src_end_line: usize = 0,
    head_src_end_col: usize = 0,
    head_text: ?[]const u8 = null,
    head_length_line: usize = 0,
    head_length_col: usize = 0,
    head_has_value: bool = false,
    head_is_infinite: bool = false,
    current_pos_line: usize = 1,
    current_pos_col: usize = 1,

    fn ensureHead(self: *Composer) !void {
        if (self.head_has_value) {
            return;
        }

        if (self.edit1_idx < self.edits1.replacements.len) {
            const next_edit = self.edits1.replacements[self.edit1_idx];
            const next_edit_start = next_edit.range.getStartPosition();

            const gap_is_empty = self.last_edit1_end_s0_line == next_edit_start.lineNumber and self.last_edit1_end_s0_col == next_edit_start.column;

            if (!gap_is_empty) {
                self.head_src_start_line = self.last_edit1_end_s0_line;
                self.head_src_start_col = self.last_edit1_end_s0_col;
                self.head_src_end_line = next_edit_start.lineNumber;
                self.head_src_end_col = next_edit_start.column;

                self.head_text = null;

                if (self.last_edit1_end_s0_line == next_edit_start.lineNumber) {
                    self.head_length_line = 0;
                    self.head_length_col = next_edit_start.column - self.last_edit1_end_s0_col;
                } else {
                    self.head_length_line = next_edit_start.lineNumber - self.last_edit1_end_s0_line;
                    self.head_length_col = next_edit_start.column - 1;
                }

                self.head_has_value = true;
                self.last_edit1_end_s0_line = next_edit_start.lineNumber;
                self.last_edit1_end_s0_col = next_edit_start.column;
            } else {
                const next_edit_end = next_edit.range.getEndPosition();
                self.head_src_start_line = next_edit_start.lineNumber;
                self.head_src_start_col = next_edit_start.column;
                self.head_src_end_line = next_edit_end.lineNumber;
                self.head_src_end_col = next_edit_end.column;

                self.head_text = next_edit.text;

                const length = TextLength.ofText(next_edit.text);
                self.head_length_line = length.lineCount;
                self.head_length_col = length.columnCount;

                self.head_has_value = true;
                self.last_edit1_end_s0_line = next_edit_end.lineNumber;
                self.last_edit1_end_s0_col = next_edit_end.column;
                self.edit1_idx += 1;
            }
        } else {
            self.head_is_infinite = true;
            self.head_src_start_line = self.last_edit1_end_s0_line;
            self.head_src_start_col = self.last_edit1_end_s0_col;
            self.head_has_value = true;
        }
    }

    fn headEndInS1(self: *const Composer) Position {
        if (self.head_length_line == 0) {
            return Position.init(self.current_pos_line, self.current_pos_col + self.head_length_col);
        }
        return Position.init(self.current_pos_line + self.head_length_line, self.head_length_col + 1);
    }

    fn currentPos(self: *const Composer) Position {
        return Position.init(self.current_pos_line, self.current_pos_col);
    }

    fn distanceTo(composer: *const Composer, target: Position) TextLength {
        const current = composer.currentPos();
        if (current.lineNumber == target.lineNumber) {
            return .{ .lineCount = 0, .columnCount = target.column - current.column };
        }
        return .{ .lineCount = target.lineNumber - current.lineNumber, .columnCount = target.column - 1 };
    }

    fn splitLen(composer: *const Composer, target: Position) TextLength {
        return distanceTo(composer, target);
    }

    fn remainingLength(composer: *const Composer, split: TextLength) TextLength {
        if (split.lineCount == composer.head_length_line) {
            return .{ .lineCount = 0, .columnCount = composer.head_length_col - split.columnCount };
        }
        return .{ .lineCount = composer.head_length_line - split.lineCount, .columnCount = composer.head_length_col };
    }

    fn splitPosition(composer: *const Composer, split: TextLength) Position {
        if (split.lineCount == 0) {
            return Position.init(composer.head_src_start_line, composer.head_src_start_col + split.columnCount);
        }
        return Position.init(composer.head_src_start_line + split.lineCount, split.columnCount + 1);
    }

    fn headSourceRange(composer: *const Composer) Range {
        return Range.init(
            composer.head_src_start_line,
            composer.head_src_start_col,
            composer.head_src_end_line,
            composer.head_src_end_col,
        );
    }

    fn composeReplacement(self: *Composer, r2: TextReplacement) !void {
        const r2_start = r2.range.getStartPosition();
        const r2_end = r2.range.getEndPosition();

        while (true) {
            if (self.current_pos_line == r2_start.lineNumber and self.current_pos_col == r2_start.column) {
                break;
            }
            try self.ensureHead();

            if (self.head_is_infinite) {
                const dist = distanceTo(self, r2_start);

                self.current_pos_line = r2_start.lineNumber;
                self.current_pos_col = r2_start.column;

                if (dist.lineCount == 0) {
                    self.head_src_start_col += dist.columnCount;
                } else {
                    self.head_src_start_line += dist.lineCount;
                    self.head_src_start_col = dist.columnCount + 1;
                }
                break;
            }

            const head_end_in_s1 = self.headEndInS1();
            const r2_start_is_before_head_end = r2_start.isBefore(head_end_in_s1);

            if (r2_start_is_before_head_end) {
                const split = splitLen(self, r2_start);
                const remaining = remainingLength(self, split);

                if (self.head_text) |head_text| {
                    const parts = try splitText(head_text, split);
                    try self.result.append(TextReplacement.init(self.headSourceRange(), parts[0]));

                    self.head_text = parts[1];
                    self.head_length_line = remaining.lineCount;
                    self.head_length_col = remaining.columnCount;

                    self.head_src_start_line = self.head_src_end_line;
                    self.head_src_start_col = self.head_src_end_col;
                } else {
                    const split_pos = splitPosition(self, split);
                    self.head_src_start_line = split_pos.lineNumber;
                    self.head_src_start_col = split_pos.column;

                    self.head_length_line = remaining.lineCount;
                    self.head_length_col = remaining.columnCount;
                }
                self.current_pos_line = r2_start.lineNumber;
                self.current_pos_col = r2_start.column;
                break;
            }

            if (self.head_text) |head_text| {
                try self.result.append(TextReplacement.init(self.headSourceRange(), head_text));
            }
            self.current_pos_line = head_end_in_s1.lineNumber;
            self.current_pos_col = head_end_in_s1.column;
            self.head_has_value = false;
        }

        var consumed_start: ?Position = null;
        var consumed_end: ?Position = null;

        while (true) {
            if (self.current_pos_line == r2_end.lineNumber and self.current_pos_col == r2_end.column) {
                break;
            }
            try self.ensureHead();

            if (self.head_is_infinite) {
                const dist = distanceTo(self, r2_end);

                const range_in_s0_end: Position = if (dist.lineCount == 0)
                    Position.init(self.head_src_start_line, self.head_src_start_col + dist.columnCount)
                else
                    Position.init(self.head_src_start_line + dist.lineCount, dist.columnCount + 1);

                if (consumed_start == null) {
                    consumed_start = Position.init(self.head_src_start_line, self.head_src_start_col);
                }
                consumed_end = range_in_s0_end;

                self.current_pos_line = r2_end.lineNumber;
                self.current_pos_col = r2_end.column;

                self.head_src_start_line = range_in_s0_end.lineNumber;
                self.head_src_start_col = range_in_s0_end.column;
                break;
            }

            const head_end_in_s1 = self.headEndInS1();
            const r2_end_is_before_head_end = r2_end.isBefore(head_end_in_s1);

            if (r2_end_is_before_head_end) {
                const split = splitLen(self, r2_end);
                const remaining = remainingLength(self, split);

                if (self.head_text) |head_text| {
                    if (consumed_start == null) {
                        consumed_start = Position.init(self.head_src_start_line, self.head_src_start_col);
                    }
                    consumed_end = Position.init(self.head_src_end_line, self.head_src_end_col);

                    const parts = try splitText(head_text, split);
                    self.head_text = parts[1];
                    self.head_length_line = remaining.lineCount;
                    self.head_length_col = remaining.columnCount;

                    self.head_src_start_line = self.head_src_end_line;
                    self.head_src_start_col = self.head_src_end_col;
                } else {
                    const split_pos = splitPosition(self, split);
                    if (consumed_start == null) {
                        consumed_start = Position.init(self.head_src_start_line, self.head_src_start_col);
                    }
                    consumed_end = split_pos;

                    self.head_src_start_line = split_pos.lineNumber;
                    self.head_src_start_col = split_pos.column;

                    self.head_length_line = remaining.lineCount;
                    self.head_length_col = remaining.columnCount;
                }
                self.current_pos_line = r2_end.lineNumber;
                self.current_pos_col = r2_end.column;
                break;
            }

            if (consumed_start == null) {
                consumed_start = Position.init(self.head_src_start_line, self.head_src_start_col);
            }
            consumed_end = Position.init(self.head_src_end_line, self.head_src_end_col);

            self.current_pos_line = head_end_in_s1.lineNumber;
            self.current_pos_col = head_end_in_s1.column;
            self.head_has_value = false;
        }

        if (consumed_start) |start| {
            const end = consumed_end.?;
            try self.result.append(TextReplacement.init(
                Range.init(start.lineNumber, start.column, end.lineNumber, end.column),
                r2.text,
            ));
        } else {
            try self.ensureHead();
            const insert_pos = Position.init(self.head_src_start_line, self.head_src_start_col);
            try self.result.append(TextReplacement.init(
                Range.init(insert_pos.lineNumber, insert_pos.column, insert_pos.lineNumber, insert_pos.column),
                r2.text,
            ));
        }
    }

    fn drain(self: *Composer) !void {
        while (true) {
            try self.ensureHead();
            if (self.head_is_infinite) {
                break;
            }
            if (self.head_text) |head_text| {
                try self.result.append(TextReplacement.init(self.headSourceRange(), head_text));
            }
            self.head_has_value = false;
        }
    }
};

fn splitText(text: []const u8, split: TextLength) ![2][]const u8 {
    if (split.lineCount == 0 and split.columnCount == 0) {
        return .{ "", text };
    }

    var line: usize = 0;
    var offset: usize = 0;
    while (line < split.lineCount) : (line += 1) {
        const idx = std.mem.indexOfScalarPos(u8, text, offset, '\n') orelse return error.TextLengthMismatch;
        offset = idx + 1;
    }
    offset += split.columnCount;
    if (offset > text.len) {
        return error.TextLengthMismatch;
    }
    return .{ text[0..offset], text[offset..] };
}

test "TextEdit: apply and inverse" {
    const allocator = std.testing.allocator;

    var text = AbstractText.initString(allocator, "line1\nline2\nline3");
    defer text.deinit();

    var text_edit = try TextEdit.create(allocator, &.{
        TextReplacement.init(Range.init(1, 2, 1, 4), "XY"),
        TextReplacement.init(Range.init(2, 1, 2, 2), "Z"),
    });
    defer text_edit.deinit();

    const applied = try text_edit.apply(allocator, &text);
    defer allocator.free(applied);
    try std.testing.expectEqualStrings("lXYe1\nZine2\nline3", applied);

    var applied_text = AbstractText.initString(allocator, applied);
    defer applied_text.deinit();

    var inversed = try text_edit.inverse(allocator, &text);
    defer inversed.deinit();
    const reverted = try inversed.apply(allocator, &applied_text);
    defer allocator.free(reverted);
    try std.testing.expectEqualStrings("line1\nline2\nline3", reverted);
}

test "TextEdit: normalize" {
    const allocator = std.testing.allocator;

    var text_edit = try TextEdit.create(allocator, &.{
        TextReplacement.init(Range.init(1, 1, 1, 2), "a"),
        TextReplacement.init(Range.init(1, 2, 1, 3), "b"),
    });
    defer text_edit.deinit();

    var normalized = try text_edit.normalize();
    defer normalized.deinit();
    try std.testing.expectEqual(1, normalized.replacements.len);
    try std.testing.expectEqualStrings("ab", normalized.replacements[0].text);
    try std.testing.expectEqual(Range.init(1, 1, 1, 3), normalized.replacements[0].range);
}

test "TextEdit: mapPosition" {
    const allocator = std.testing.allocator;

    var text_edit = try TextEdit.create(allocator, &.{
        TextReplacement.init(Range.init(1, 2, 1, 4), "X"),
        TextReplacement.init(Range.init(2, 1, 2, 1), "YZ"),
    });
    defer text_edit.deinit();

    // Before the first edit.
    try std.testing.expectEqualDeep(PositionOrRange{ .position = Position.init(1, 1) }, text_edit.mapPosition(Position.init(1, 1)));
    // Position inside the first edit maps to the replacement range.
    try std.testing.expectEqualDeep(PositionOrRange{ .range = Range.init(1, 2, 1, 3) }, text_edit.mapPosition(Position.init(1, 3)));
    // After both edits.
    try std.testing.expectEqualDeep(PositionOrRange{ .position = Position.init(3, 1) }, text_edit.mapPosition(Position.init(3, 1)));
}

test "TextEdit: toReplacement" {
    const allocator = std.testing.allocator;

    var text = AbstractText.initString(allocator, "abcdef");
    defer text.deinit();

    var text_edit = try TextEdit.create(allocator, &.{
        TextReplacement.init(Range.init(1, 2, 1, 3), "X"),
        TextReplacement.init(Range.init(1, 4, 1, 5), "Y"),
    });
    defer text_edit.deinit();

    const replacement = try text_edit.toReplacement(allocator, &text);
    defer allocator.free(replacement.text);
    try std.testing.expectEqual(Range.init(1, 2, 1, 5), replacement.range);
    try std.testing.expectEqualStrings("XcY", replacement.text);
}

test "TextEdit: fromStringEdit" {
    const allocator = std.testing.allocator;
    const string_edit_mod = @import("stringEdit.zig");

    var text = AbstractText.initString(allocator, "abcdef");
    defer text.deinit();

    var string_edit = try string_edit_mod.create(allocator, &.{
        string_edit_mod.StringReplacement.replace(OffsetRange.init(1, 3), "XY"),
    });
    defer string_edit.deinit();

    var text_edit = try TextEdit.fromStringEdit(allocator, &string_edit, &text);
    defer text_edit.deinit();
    try std.testing.expectEqual(Range.init(1, 2, 1, 4), text_edit.replacements[0].range);
    try std.testing.expectEqualStrings("XY", text_edit.replacements[0].text);
}

test "TextEdit: compose" {
    const allocator = std.testing.allocator;

    var e1 = try TextEdit.create(allocator, &.{
        TextReplacement.init(Range.init(1, 2, 1, 3), "XY"),
    });
    defer e1.deinit();
    var e2 = try TextEdit.create(allocator, &.{
        TextReplacement.init(Range.init(1, 3, 1, 4), "Z"),
    });
    defer e2.deinit();

    var composed = try e1.compose(&e2);
    defer composed.deinit();

    const applied = try composed.applyToString(allocator, "abcdef");
    defer allocator.free(applied);

    const first = try e1.applyToString(allocator, "abcdef");
    defer allocator.free(first);
    const chained = try e2.applyToString(allocator, first);
    defer allocator.free(chained);
    try std.testing.expectEqualStrings(chained, applied);
}
