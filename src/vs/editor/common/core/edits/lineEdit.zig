const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const strings = @import("../../../../base/common/strings.zig");
const Position = @import("../position.zig").Position;
const Range = @import("../range.zig").Range;
const range = @import("../range.zig");
const LineRange = @import("../ranges/lineRange.zig").LineRange;
const OffsetRange = @import("../ranges/offsetRange.zig").OffsetRange;
const AbstractText = @import("../text/abstractText.zig").AbstractText;
const StringEdit = @import("stringEdit.zig").StringEdit;
const StringReplacement = @import("stringEdit.zig").StringReplacement;
const TextEdit = @import("textEdit.zig").TextEdit;
const TextReplacement = @import("textEdit.zig").TextReplacement;
const rangeEquals = @import("textEdit.zig").rangeEquals;

/// Warning: Be careful when changing this type, as it is used for serialization!
pub const SerializedLineReplacement = struct {
    startLineNumber: usize,
    endLineNumberExclusive: usize,
    newLines: []const []const u8,
};

/// Warning: Be careful when changing this type, as it is used for serialization!
pub const SerializedLineEdit = []const SerializedLineReplacement;

/// A replacement of a range of lines with new lines.
pub const LineReplacement = struct {
    const Self = @This();

    lineRange: LineRange,
    newLines: []const []const u8,

    pub fn init(line_range: LineRange, new_lines: []const []const u8) Self {
        return .{ .lineRange = line_range, .newLines = new_lines };
    }

    pub fn deserialize(data: SerializedLineReplacement) Self {
        return Self.init(
            LineRange.init(data.startLineNumber, data.endLineNumberExclusive),
            data.newLines,
        );
    }

    pub fn fromSingleTextEdit(allocator: Allocator, edit: TextReplacement, initial_value: *AbstractText) !Self {
        const transformer = try initial_value.getTransformer();

        var new_lines = ArrayList([]const u8).init(allocator);
        const split = try strings.splitLines(allocator, edit.text);
        defer split.deinit();
        try new_lines.appendSlice(split.items);

        var start_line_number = edit.range.startLineNumber;
        const surviving_first_line_text = try initial_value.getValueOfRange(range.fromPositions(
            Position.init(edit.range.startLineNumber, 1),
            edit.range.getStartPosition(),
        ));
        new_lines.items[0] = try concat2(allocator, surviving_first_line_text, new_lines.items[0]);
        allocator.free(surviving_first_line_text);

        var end_line_number_ex = edit.range.endLineNumber + 1;
        const edit_end_line_number_max_column = transformer.getLineLength(edit.range.endLineNumber) + 1;
        const surviving_end_line_text = try initial_value.getValueOfRange(range.fromPositions(
            edit.range.getEndPosition(),
            Position.init(edit.range.endLineNumber, edit_end_line_number_max_column),
        ));
        const last_index = new_lines.items.len - 1;
        new_lines.items[last_index] = try concat2(allocator, new_lines.items[last_index], surviving_end_line_text);
        allocator.free(surviving_end_line_text);

        // Replacing [startLineNumber, endLineNumberEx) with newLines would be
        // correct, however it might not be minimal.
        const start_before_new_line = edit.range.startColumn == transformer.getLineLength(edit.range.startLineNumber) + 1;
        const end_after_new_line = edit.range.endColumn == 1;

        if (start_before_new_line and new_lines.items[0].len == surviving_first_line_text.len) {
            // The replacement would not delete any text on the first line.
            start_line_number += 1;
            _ = new_lines.orderedRemove(0);
        }

        if (new_lines.items.len > 0 and start_line_number < end_line_number_ex and end_after_new_line and
            new_lines.items[new_lines.items.len - 1].len == surviving_end_line_text.len)
        {
            // The replacement would not delete any text on the last line.
            end_line_number_ex -= 1;
            _ = new_lines.pop();
        }

        return Self.init(LineRange.init(start_line_number, end_line_number_ex), new_lines.items);
    }

    pub fn equals(self: Self, other: Self) bool {
        if (!self.lineRange.equals(other.lineRange) or self.newLines.len != other.newLines.len) {
            return false;
        }
        for (self.newLines, other.newLines) |a, b| {
            if (!std.mem.eql(u8, a, b)) {
                return false;
            }
        }
        return true;
    }

    pub fn clone(self: Self, allocator: Allocator) !Self {
        const new_lines = try allocator.alloc([]const u8, self.newLines.len);
        for (self.newLines, 0..) |line, i| {
            new_lines[i] = try allocator.dupe(u8, line);
        }
        return Self.init(self.lineRange, new_lines);
    }

    pub fn toSingleTextEdit(self: Self, allocator: Allocator, initial_value: *AbstractText) !TextReplacement {
        const transformer = try initial_value.getTransformer();

        if (self.newLines.len == 0) {
            // Deletion.
            const text_length = transformer.textLength();
            if (self.lineRange.endLineNumberExclusive == text_length.lineCount + 2) {
                var start_pos: Position = undefined;
                if (self.lineRange.startLineNumber > 1) {
                    const start_line_number = self.lineRange.startLineNumber - 1;
                    const start_column = transformer.getLineLength(start_line_number) + 1;
                    start_pos = Position.init(start_line_number, start_column);
                } else {
                    // Delete everything. A string always has 1 line (which can be empty).
                    start_pos = Position.init(1, 1);
                }

                const last_position = text_length.addToPosition(Position.init(1, 1));
                return TextReplacement.init(range.fromPositions(start_pos, last_position), "");
            }
            return TextReplacement.init(
                Range.init(self.lineRange.startLineNumber, 1, self.lineRange.endLineNumberExclusive, 1),
                "",
            );
        }

        if (self.lineRange.isEmpty()) {
            // Insertion.
            const insertion_line = self.lineRange.startLineNumber;
            var end_line_number: usize = undefined;
            var column: usize = undefined;
            var text = ArrayList(u8).init(allocator);
            errdefer text.deinit();

            if (insertion_line == transformer.textLength().lineCount + 2) {
                end_line_number = insertion_line - 1;
                column = transformer.getLineLength(end_line_number) + 1;
                for (self.newLines) |line| {
                    try text.append('\n');
                    try text.appendSlice(line);
                }
            } else {
                end_line_number = insertion_line;
                column = 1;
                for (self.newLines) |line| {
                    try text.appendSlice(line);
                    try text.append('\n');
                }
            }
            return TextReplacement.init(
                range.fromPositions(Position.init(end_line_number, column), null),
                try text.toOwnedSlice(),
            );
        }

        const end_line_number = self.lineRange.endLineNumberExclusive - 1;
        const end_line_number_max_column = transformer.getLineLength(end_line_number) + 1;
        const text_range = Range.init(
            self.lineRange.startLineNumber,
            1,
            end_line_number,
            end_line_number_max_column,
        );

        var text = ArrayList(u8).init(allocator);
        errdefer text.deinit();
        for (self.newLines, 0..) |line, i| {
            if (i > 0) try text.append('\n');
            try text.appendSlice(line);
        }
        return TextReplacement.init(text_range, try text.toOwnedSlice());
    }

    pub fn toSingleEdit(self: Self, allocator: Allocator, initial_value: *AbstractText) !StringReplacement {
        const text_edit = try self.toSingleTextEdit(allocator, initial_value);
        const transformer = try initial_value.getTransformer();
        return StringReplacement.init(transformer.getOffsetRange(text_edit.range), text_edit.text);
    }

    pub fn toString(self: Self, writer: *Io.Writer) !void {
        try self.lineRange.toString(writer);
        try writer.print("->[", .{});
        for (self.newLines, 0..) |line, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.print("\"{s}\"", .{line});
        }
        try writer.writeByte(']');
    }

    pub fn serialize(self: Self) SerializedLineReplacement {
        return .{
            .startLineNumber = self.lineRange.startLineNumber,
            .endLineNumberExclusive = self.lineRange.endLineNumberExclusive,
            .newLines = self.newLines,
        };
    }

    pub fn removeCommonSuffixPrefixLines(self: Self, allocator: Allocator, initial_value: *AbstractText) !Self {
        var start_line_number = self.lineRange.startLineNumber;
        var end_line_number_ex = self.lineRange.endLineNumberExclusive;

        var trim_start_count: usize = 0;
        while (start_line_number < end_line_number_ex and trim_start_count < self.newLines.len and
            try lineEquals(allocator, try initial_value.getLineAt(start_line_number), self.newLines[trim_start_count]))
        {
            start_line_number += 1;
            trim_start_count += 1;
        }

        var trim_end_count: usize = 0;
        while (start_line_number < end_line_number_ex and trim_end_count + trim_start_count < self.newLines.len and
            try lineEquals(allocator, try initial_value.getLineAt(end_line_number_ex - 1), self.newLines[self.newLines.len - 1 - trim_end_count]))
        {
            end_line_number_ex -= 1;
            trim_end_count += 1;
        }

        if (trim_start_count == 0 and trim_end_count == 0) {
            return self;
        }
        return Self.init(
            LineRange.init(start_line_number, end_line_number_ex),
            try allocator.dupe([]const u8, self.newLines[trim_start_count .. self.newLines.len - trim_end_count]),
        );
    }

    pub fn toLineEdit(self: Self, allocator: Allocator) !LineEdit {
        return LineEdit.create(allocator, &.{self});
    }
};

fn concat2(allocator: Allocator, a: []const u8, b: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, a.len + b.len);
    @memcpy(result[0..a.len], a);
    @memcpy(result[a.len..], b);
    return result;
}

fn lineEquals(allocator: Allocator, line: []u8, other: []const u8) !bool {
    defer allocator.free(line);
    return std.mem.eql(u8, line, other);
}

/// A set of replacements of line ranges with new lines.
pub const LineEdit = struct {
    const Self = @This();

    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    replacements: []LineReplacement,

    pub fn empty(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .replacements = &.{},
        };
    }

    pub fn create(allocator: Allocator, replacements: []const LineReplacement) !Self {
        var result = Self.empty(allocator);
        errdefer result.deinit();

        var previous_end: ?usize = null;
        for (replacements) |replacement| {
            if (previous_end) |end| {
                if (end > replacement.lineRange.startLineNumber) {
                    return error.InvalidEdit;
                }
            }
            previous_end = replacement.lineRange.endLineNumberExclusive;
        }

        const arena_allocator = result.arena.allocator();
        result.replacements = try arena_allocator.alloc(LineReplacement, replacements.len);
        for (replacements, 0..) |replacement, i| {
            result.replacements[i] = try replacement.clone(arena_allocator);
        }
        return result;
    }

    pub fn createFromUnsorted(allocator: Allocator, replacements: []const LineReplacement) !Self {
        const sorted = try allocator.dupe(LineReplacement, replacements);
        defer allocator.free(sorted);
        std.mem.sort(LineReplacement, sorted, {}, struct {
            fn lessThan(_: void, a: LineReplacement, b: LineReplacement) bool {
                return a.lineRange.startLineNumber < b.lineRange.startLineNumber;
            }
        }.lessThan);
        return Self.create(allocator, sorted);
    }

    pub fn deserialize(allocator: Allocator, data: SerializedLineEdit) !Self {
        const replacements = try allocator.alloc(LineReplacement, data.len);
        defer allocator.free(replacements);
        for (data, 0..) |replacement, i| {
            replacements[i] = LineReplacement.deserialize(replacement);
        }
        return Self.create(allocator, replacements);
    }

    pub fn clone(self: *const Self) !Self {
        return Self.create(self.allocator, self.replacements);
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    pub fn fromStringEdit(allocator: Allocator, edit: *const StringEdit, initial_value: *AbstractText) !Self {
        var text_edit = try TextEdit.fromStringEdit(allocator, edit, initial_value);
        defer text_edit.deinit();
        return fromTextEdit(allocator, &text_edit, initial_value);
    }

    pub fn fromTextEdit(allocator: Allocator, edit: *const TextEdit, initial_value: *AbstractText) !Self {
        var temp = std.heap.ArenaAllocator.init(allocator);
        defer temp.deinit();
        const temp_allocator = temp.allocator();

        var result = ArrayList(LineReplacement).init(temp_allocator);
        var current_edits = ArrayList(TextReplacement).init(temp_allocator);

        for (edit.replacements, 0..) |replacement, i| {
            try current_edits.append(replacement);

            const next_edit_range: ?TextReplacement = if (i + 1 < edit.replacements.len) edit.replacements[i + 1] else null;
            if (next_edit_range != null and next_edit_range.?.range.startLineNumber == replacement.range.endLineNumber) {
                continue;
            }

            const single_edit = try TextReplacement.joinReplacements(temp_allocator, current_edits.items, initial_value);
            current_edits.clearRetainingCapacity();

            const single_line_edit = try LineReplacement.fromSingleTextEdit(temp_allocator, single_edit, initial_value);
            try result.append(single_line_edit);
        }

        return Self.create(allocator, result.items);
    }

    pub fn isEmpty(self: *const Self) bool {
        return self.replacements.len == 0;
    }

    pub fn toEdit(self: *const Self, allocator: Allocator, initial_value: *AbstractText) !StringEdit {
        var temp = std.heap.ArenaAllocator.init(allocator);
        defer temp.deinit();
        const temp_allocator = temp.allocator();

        var edits = ArrayList(StringReplacement).init(temp_allocator);
        try edits.ensureTotalCapacity(self.replacements.len);
        for (self.replacements) |replacement| {
            edits.appendAssumeCapacity(try replacement.toSingleEdit(temp_allocator, initial_value));
        }
        return StringEdit.create(allocator, edits.items);
    }

    pub fn format(self: *const Self, writer: *Io.Writer) !void {
        for (self.replacements, 0..) |replacement, i| {
            if (i > 0) try writer.writeByte(',');
            try replacement.toString(writer);
        }
    }

    pub fn serialize(self: *const Self, allocator: Allocator) !SerializedLineEdit {
        const result = try allocator.alloc(SerializedLineReplacement, self.replacements.len);
        for (self.replacements, 0..) |replacement, i| {
            result[i] = replacement.serialize();
        }
        return result;
    }

    pub fn getNewLineRanges(self: *const Self, allocator: Allocator) ![]LineRange {
        const ranges = try allocator.alloc(LineRange, self.replacements.len);
        errdefer allocator.free(ranges);

        var offset: isize = 0;
        for (self.replacements, 0..) |replacement, i| {
            ranges[i] = LineRange.ofLength(
                @intCast(@as(isize, @intCast(replacement.lineRange.startLineNumber)) + offset),
                replacement.newLines.len,
            );
            offset += @as(isize, @intCast(replacement.newLines.len)) - @as(isize, @intCast(replacement.lineRange.length()));
        }
        return ranges;
    }

    pub fn mapLineNumber(self: *const Self, line_number: usize) usize {
        var line_delta: isize = 0;
        for (self.replacements) |replacement| {
            if (replacement.lineRange.endLineNumberExclusive > line_number) {
                break;
            }
            line_delta += @as(isize, @intCast(replacement.newLines.len)) - @as(isize, @intCast(replacement.lineRange.length()));
        }
        return @intCast(@as(isize, @intCast(line_number)) + line_delta);
    }

    pub fn mapLineRange(self: *const Self, line_range: LineRange) LineRange {
        return LineRange.init(
            self.mapLineNumber(line_range.startLineNumber),
            self.mapLineNumber(line_range.endLineNumberExclusive),
        );
    }

    pub fn mapBackLineRange(self: *const Self, allocator: Allocator, line_range: LineRange, original_lines: []const []const u8) !LineRange {
        var inversed = try self.inverse(allocator, original_lines);
        defer inversed.deinit();
        return inversed.mapLineRange(line_range);
    }

    pub fn touches(self: *const Self, other: *const Self) bool {
        for (self.replacements) |a| {
            for (other.replacements) |b| {
                if (a.lineRange.intersect(b.lineRange) != null) {
                    return true;
                }
            }
        }
        return false;
    }

    pub fn rebase(self: *const Self, base: *const Self) !Self {
        var result = ArrayList(LineReplacement).init(self.allocator);
        defer result.deinit();
        try result.ensureTotalCapacity(self.replacements.len);
        for (self.replacements) |replacement| {
            result.appendAssumeCapacity(LineReplacement.init(
                base.mapLineRange(replacement.lineRange),
                replacement.newLines,
            ));
        }
        return Self.create(self.allocator, result.items);
    }

    pub fn humanReadablePatch(self: *const Self, allocator: Allocator, original_lines: []const []const u8) ![]u8 {
        var result = ArrayList(u8).init(allocator);
        errdefer result.deinit();

        var line_delta: isize = 0;
        var first = true;

        const pushLine = struct {
            fn call(
                out: *ArrayList(u8),
                original_line_number: ?usize,
                modified_line_number: ?usize,
                kind: u8,
                content: ?[]const u8,
            ) !void {
                try out.append(kind);
                try out.append(' ');
                if (original_line_number) |number| {
                    try padNumber(out, number);
                } else {
                    try out.appendSlice("   ");
                }
                try out.append(' ');
                if (modified_line_number) |number| {
                    try padNumber(out, number);
                } else {
                    try out.appendSlice("   ");
                }
                try out.append(' ');
                if (content) |value| {
                    try out.appendSlice(value);
                } else {
                    try out.appendSlice("[[[[[ WARNING: LINE DOES NOT EXIST ]]]]]");
                }
                try out.append('\n');
            }
        }.call;

        var group_start: usize = 0;
        while (group_start < self.replacements.len) {
            var group_end = group_start + 1;
            while (group_end < self.replacements.len and
                self.replacements[group_end - 1].lineRange.distanceToRange(self.replacements[group_end].lineRange) <= 5)
            {
                group_end += 1;
            }

            if (!first) {
                try result.appendSlice("---\n");
            } else {
                first = false;
            }

            var last_line_number: isize = @as(isize, @intCast(self.replacements[group_start].lineRange.startLineNumber)) - 2;

            for (self.replacements[group_start..group_end]) |replacement| {
                var line_number: isize = @max(1, last_line_number);
                while (line_number < @as(isize, @intCast(replacement.lineRange.startLineNumber))) : (line_number += 1) {
                    if (line_number >= 1 and @as(usize, @intCast(line_number)) <= original_lines.len) {
                        try pushLine(&result, @intCast(line_number), @intCast(line_number + line_delta), ' ', original_lines[@as(usize, @intCast(line_number)) - 1]);
                    }
                }

                var replace_line_number = replacement.lineRange.startLineNumber;
                while (replace_line_number < replacement.lineRange.endLineNumberExclusive) : (replace_line_number += 1) {
                    const line = if (replace_line_number >= 1 and replace_line_number <= original_lines.len) original_lines[replace_line_number - 1] else null;
                    try pushLine(&result, replace_line_number, null, '-', line);
                }

                for (replacement.newLines, 0..) |line, i| {
                    try pushLine(
                        &result,
                        null,
                        @intCast(@as(isize, @intCast(replacement.lineRange.startLineNumber)) + line_delta + @as(isize, @intCast(i))),
                        '+',
                        line,
                    );
                }

                last_line_number = @intCast(replacement.lineRange.endLineNumberExclusive);
                line_delta += @as(isize, @intCast(replacement.newLines.len)) - @as(isize, @intCast(replacement.lineRange.length()));
            }

            const last_limit = @min(last_line_number + 2, @as(isize, @intCast(original_lines.len)));
            var i = last_line_number;
            while (i <= last_limit) : (i += 1) {
                if (i >= 1) {
                    try pushLine(&result, @intCast(i), @intCast(i + line_delta), ' ', original_lines[@as(usize, @intCast(i)) - 1]);
                }
            }

            group_start = group_end;
        }

        return result.toOwnedSlice();
    }

    pub fn apply(self: *const Self, allocator: Allocator, lines: []const []const u8) ![]const []const u8 {
        var result = ArrayList([]const u8).init(allocator);
        errdefer result.deinit();

        var current_line_index: usize = 0;
        for (self.replacements) |replacement| {
            while (current_line_index < replacement.lineRange.startLineNumber - 1) {
                try result.append(lines[current_line_index]);
                current_line_index += 1;
            }
            try result.appendSlice(replacement.newLines);
            current_line_index = replacement.lineRange.endLineNumberExclusive - 1;
        }
        while (current_line_index < lines.len) {
            try result.append(lines[current_line_index]);
            current_line_index += 1;
        }
        return result.toOwnedSlice();
    }

    pub fn inverse(self: *const Self, allocator: Allocator, original_lines: []const []const u8) !Self {
        const new_ranges = try self.getNewLineRanges(allocator);
        defer allocator.free(new_ranges);

        var replacements = ArrayList(LineReplacement).init(allocator);
        defer replacements.deinit();
        try replacements.ensureTotalCapacity(self.replacements.len);
        for (self.replacements, 0..) |replacement, idx| {
            const start = replacement.lineRange.startLineNumber - 1;
            const end = replacement.lineRange.endLineNumberExclusive - 1;
            replacements.appendAssumeCapacity(LineReplacement.init(
                new_ranges[idx],
                original_lines[start..end],
            ));
        }
        return Self.create(allocator, replacements.items);
    }
};

fn padNumber(out: *ArrayList(u8), number: usize) !void {
    var buffer: [20]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{d}", .{number});
    if (text.len < 3) {
        try out.appendNTimes(' ', 3 - text.len);
    }
    try out.appendSlice(text);
}

test "LineEdit: fromTextEdit, toEdit round trip" {
    const allocator = std.testing.allocator;

    var text = AbstractText.initString(allocator, "line1\nline2\nline3\nline4");
    defer text.deinit();

    var text_edit = try TextEdit.create(allocator, &.{
        TextReplacement.init(Range.init(2, 1, 3, 6), "new2\nnew3"),
    });
    defer text_edit.deinit();

    var line_edit = try LineEdit.fromTextEdit(allocator, &text_edit, &text);
    defer line_edit.deinit();
    try std.testing.expectEqual(@as(usize, 1), line_edit.replacements.len);
    try std.testing.expectEqual(LineRange.init(2, 4), line_edit.replacements[0].lineRange);

    var string_edit = try line_edit.toEdit(allocator, &text);
    defer string_edit.deinit();

    var round_trip = try LineEdit.fromStringEdit(allocator, &string_edit, &text);
    defer round_trip.deinit();
    try std.testing.expectEqual(@as(usize, 1), round_trip.replacements.len);
    try std.testing.expectEqual(LineRange.init(2, 4), round_trip.replacements[0].lineRange);
}

test "LineEdit: apply" {
    const allocator = std.testing.allocator;

    var line_edit = try LineEdit.create(allocator, &.{
        LineReplacement.init(LineRange.init(2, 3), &.{"X"}),
        LineReplacement.init(LineRange.init(4, 4), &.{ "Y", "Z" }),
    });
    defer line_edit.deinit();

    const lines = [_][]const u8{ "a", "b", "c" };
    const applied = try line_edit.apply(allocator, &lines);
    defer allocator.free(applied);

    try std.testing.expectEqual(@as(usize, 5), applied.len);
    try std.testing.expectEqualStrings("a", applied[0]);
    try std.testing.expectEqualStrings("X", applied[1]);
    try std.testing.expectEqualStrings("c", applied[2]);
    try std.testing.expectEqualStrings("Y", applied[3]);
    try std.testing.expectEqualStrings("Z", applied[4]);
}

test "LineEdit: mapLineNumber and mapLineRange" {
    const allocator = std.testing.allocator;

    var line_edit = try LineEdit.create(allocator, &.{
        LineReplacement.init(LineRange.init(2, 3), &.{ "X", "Y" }),
        LineReplacement.init(LineRange.init(5, 6), &.{}),
    });
    defer line_edit.deinit();

    try std.testing.expectEqual(@as(usize, 1), line_edit.mapLineNumber(1));
    try std.testing.expectEqual(@as(usize, 2), line_edit.mapLineNumber(2));
    try std.testing.expectEqual(@as(usize, 4), line_edit.mapLineNumber(3));
    try std.testing.expectEqual(@as(usize, 5), line_edit.mapLineNumber(4));
    try std.testing.expectEqual(LineRange.init(1, 4), line_edit.mapLineRange(LineRange.init(1, 3)));

    var touching = try LineEdit.create(allocator, &.{LineReplacement.init(LineRange.init(3, 4), &.{})});
    defer touching.deinit();
    try std.testing.expect(line_edit.touches(&touching));
}

test "LineEdit: inverse" {
    const allocator = std.testing.allocator;

    var line_edit = try LineEdit.create(allocator, &.{
        LineReplacement.init(LineRange.init(2, 3), &.{"X"}),
    });
    defer line_edit.deinit();

    const original = [_][]const u8{ "a", "b", "c" };
    var inversed = try line_edit.inverse(allocator, &original);
    defer inversed.deinit();

    try std.testing.expectEqual(1, inversed.replacements.len);
    try std.testing.expectEqual(LineRange.init(2, 3), inversed.replacements[0].lineRange);
    try std.testing.expectEqual(@as(usize, 1), inversed.replacements[0].newLines.len);
    try std.testing.expectEqualStrings("b", inversed.replacements[0].newLines[0]);
}

test "LineEdit: deserialize and serialize" {
    const allocator = std.testing.allocator;

    const data = [_]SerializedLineReplacement{
        .{ .startLineNumber = 1, .endLineNumberExclusive = 2, .newLines = &.{ "x", "y" } },
    };
    var line_edit = try LineEdit.deserialize(allocator, &data);
    defer line_edit.deinit();

    const serialized = try line_edit.serialize(allocator);
    defer allocator.free(serialized);
    try std.testing.expectEqual(@as(usize, 1), serialized.len);
    try std.testing.expectEqual(@as(usize, 1), serialized[0].startLineNumber);
    try std.testing.expectEqualStrings("y", serialized[0].newLines[1]);
}
