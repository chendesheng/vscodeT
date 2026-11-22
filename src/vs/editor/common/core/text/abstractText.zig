// Port of `src/vs/editor/common/core/text/abstractText.ts`.
//
// Zig adaptation: upstream's `AbstractText` class hierarchy (`LineBasedText`,
// `ArrayText`, `StringText`) is represented by one tagged union. Text and
// columns remain UTF-8 bytes; no UTF-16 conversion happens here.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const strings = @import("../../../../base/common/strings.zig");
const Position = @import("../position.zig").Position;
const Range = @import("../range.zig").Range;
const LineRange = @import("../ranges/lineRange.zig").LineRange;
const OffsetRange = @import("../ranges/offsetRange.zig").OffsetRange;
const TextLength = @import("textLength.zig").TextLength;
const PositionOffsetTransformer = @import("positionToOffset.zig").PositionOffsetTransformer;

pub const StringText = struct {
    value: []const u8,

    pub fn init(value: []const u8) StringText {
        return .{ .value = value };
    }
};

/// A text backed by an array of lines. Line numbers are 1-based.
pub const ArrayText = struct {
    lines: []const []const u8,

    pub fn init(lines: []const []const u8) ArrayText {
        return .{ .lines = lines };
    }
};

/// A text backed by callbacks, e.g. a text model.
pub const LineBasedText = struct {
    context: *anyopaque,
    getLineContent: *const fn (context: *anyopaque, lineNumber: usize) []const u8,
    lineCount: usize,

    pub fn init(
        context: *anyopaque,
        lineCount: usize,
        getLineContent: *const fn (context: *anyopaque, lineNumber: usize) []const u8,
    ) LineBasedText {
        return .{
            .context = context,
            .getLineContent = getLineContent,
            .lineCount = lineCount,
        };
    }
};

pub const AbstractText = struct {
    allocator: Allocator,
    kind: Kind,
    transformer: ?*PositionOffsetTransformer = null,
    cached_value: ?[]u8 = null,

    pub const Kind = union(enum) {
        string: StringText,
        array: ArrayText,
        line_based: LineBasedText,
    };

    pub fn initString(allocator: Allocator, value: []const u8) AbstractText {
        return .{ .allocator = allocator, .kind = .{ .string = StringText.init(value) } };
    }

    pub fn initArray(allocator: Allocator, lines: []const []const u8) AbstractText {
        return .{ .allocator = allocator, .kind = .{ .array = ArrayText.init(lines) } };
    }

    pub fn initLineBased(allocator: Allocator, line_based: LineBasedText) AbstractText {
        return .{ .allocator = allocator, .kind = .{ .line_based = line_based } };
    }

    pub fn deinit(self: *AbstractText) void {
        if (self.transformer) |transformer| {
            transformer.deinit();
            self.allocator.destroy(transformer);
        }
        if (self.cached_value) |value| {
            self.allocator.free(value);
        }
    }

    pub fn endPositionExclusive(self: *AbstractText) Position {
        return self.getLength().addToPosition(Position.init(1, 1));
    }

    pub fn lineRange(self: *AbstractText) LineRange {
        return self.getLength().toLineRange();
    }

    pub fn getValue(self: *AbstractText) ![]const u8 {
        if (self.cached_value == null) {
            self.cached_value = try self.computeValue();
        }
        return self.cached_value.?;
    }

    pub fn getValueOfRange(self: *AbstractText, range: Range) ![]u8 {
        return switch (self.kind) {
            .string => |text| self.getValueOfRangeString(text, range),
            .array => {
                const array_text = self.kind.array;
                return self.getValueOfRangeArray(&array_text, range);
            },
            .line_based => |text| self.getValueOfRangeLineBased(text, range),
        };
    }

    pub fn getValueOfOffsetRange(self: *AbstractText, range: OffsetRange) ![]u8 {
        const transformer = try self.getTransformer();
        return self.getValueOfRange(transformer.getRange(range));
    }

    pub fn getLineLength(self: *AbstractText, lineNumber: usize) usize {
        return switch (self.kind) {
            .string => |text| lineLengthInString(text.value, lineNumber),
            .array => |text| if (lineNumber - 1 < text.lines.len) text.lines[lineNumber - 1].len else 0,
            .line_based => |text| text.getLineContent(text.context, lineNumber).len,
        };
    }

    pub fn getTransformer(self: *AbstractText) !*PositionOffsetTransformer {
        if (self.transformer == null) {
            const transformer = try self.allocator.create(PositionOffsetTransformer);
            errdefer self.allocator.destroy(transformer);
            const value = try self.getValue();
            transformer.* = PositionOffsetTransformer.init(self.allocator, value);
            self.transformer = transformer;
        }
        return self.transformer.?;
    }

    pub fn getLineAt(self: *AbstractText, lineNumber: usize) ![]u8 {
        return self.getValueOfRange(Range.init(lineNumber, 1, lineNumber, std.math.maxInt(usize)));
    }

    pub fn getLines(self: *AbstractText) !ArrayList([]const u8) {
        return strings.splitLines(self.allocator, try self.getValue());
    }

    pub fn getLinesOfRange(self: *AbstractText, range: LineRange) !ArrayList([]u8) {
        var result = ArrayList([]u8).init(self.allocator);
        errdefer {
            for (result.items) |line| self.allocator.free(line);
            result.deinit();
        }
        var lineNumber = range.startLineNumber;
        while (lineNumber < range.endLineNumberExclusive) : (lineNumber += 1) {
            try result.append(try self.getLineAt(lineNumber));
        }
        return result;
    }

    pub fn equals(self: *AbstractText, other: *AbstractText) bool {
        const a = self.getValue() catch return false;
        const b = other.getValue() catch return false;
        return std.mem.eql(u8, a, b);
    }

    pub fn getLength(self: *AbstractText) TextLength {
        return switch (self.kind) {
            .string => |text| TextLength.ofText(text.value),
            .array => |text| blk: {
                if (text.lines.len == 0) break :blk TextLength{ .lineCount = 0, .columnCount = 0 };
                const lastLine = text.lines[text.lines.len - 1];
                break :blk TextLength{ .lineCount = text.lines.len - 1, .columnCount = lastLine.len };
            },
            .line_based => |text| blk: {
                if (text.lineCount == 0) break :blk TextLength{ .lineCount = 0, .columnCount = 0 };
                const lastLine = text.getLineContent(text.context, text.lineCount);
                break :blk TextLength{ .lineCount = text.lineCount - 1, .columnCount = lastLine.len };
            },
        };
    }

    fn computeValue(self: *AbstractText) ![]u8 {
        return self.getValueOfRange(self.getLength().toRange());
    }

    fn getValueOfRangeString(self: *AbstractText, text: StringText, range: Range) ![]u8 {
        const offsets = rangeToOffsets(text.value, range);
        return std.fmt.allocPrint(self.allocator, "{s}", .{text.value[offsets.start..offsets.endExclusive]});
    }

    fn getValueOfRangeArray(self: *AbstractText, text: *const ArrayText, range: Range) ![]u8 {
        return self.getValueOfRangeLineBased(.{
            .context = @ptrCast(@constCast(text)),
            .getLineContent = arrayLineContent,
            .lineCount = text.lines.len,
        }, range);
    }

    fn getValueOfRangeLineBased(self: *AbstractText, text: LineBasedText, range: Range) ![]u8 {
        const lineCount = text.lineCount;
        if (lineCount == 0) {
            return self.allocator.alloc(u8, 0);
        }

        const startLine = @min(@max(range.startLineNumber, 1), lineCount);
        const endLine = @min(@max(range.endLineNumber, startLine), lineCount);

        var result = ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        if (startLine == endLine) {
            const line = text.getLineContent(text.context, startLine);
            const startColumn = @min(@max(range.startColumn, 1), line.len + 1);
            const endColumn = @min(@max(range.endColumn, startColumn), line.len + 1);
            try result.appendSlice(line[startColumn - 1 .. endColumn - 1]);
            return result.toOwnedSlice();
        }

        const firstLine = text.getLineContent(text.context, startLine);
        const firstStart = @min(@max(range.startColumn, 1), firstLine.len + 1);
        try result.appendSlice(firstLine[firstStart - 1 ..]);

        var lineNumber = startLine + 1;
        while (lineNumber < endLine) : (lineNumber += 1) {
            try result.append('\n');
            try result.appendSlice(text.getLineContent(text.context, lineNumber));
        }

        try result.append('\n');
        const lastLine = text.getLineContent(text.context, endLine);
        const lastEnd = @min(@max(range.endColumn, 1), lastLine.len + 1);
        try result.appendSlice(lastLine[0 .. lastEnd - 1]);

        return result.toOwnedSlice();
    }
};

fn arrayLineContent(context: *anyopaque, lineNumber: usize) []const u8 {
    const text: *ArrayText = @ptrCast(@alignCast(context));
    if (lineNumber - 1 < text.lines.len) {
        return text.lines[lineNumber - 1];
    }
    return "";
}

fn lineLengthInString(text: []const u8, lineNumber: usize) usize {
    var currentLine: usize = 1;
    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len and currentLine < lineNumber) : (i += 1) {
        if (text[i] == '\n') {
            currentLine += 1;
            start = i + 1;
        }
    }
    if (currentLine != lineNumber) {
        return 0;
    }
    var end = start;
    while (end < text.len and text[end] != '\n') : (end += 1) {}
    if (end > start and text[end - 1] == '\r') {
        end -= 1;
    }
    return end - start;
}

fn rangeToOffsets(text: []const u8, range: Range) OffsetRange {
    const start = offsetAt(text, range.startLineNumber, range.startColumn);
    const end = offsetAt(text, range.endLineNumber, range.endColumn);
    return OffsetRange.init(@min(start, end), @min(@max(start, end), text.len));
}

fn offsetAt(text: []const u8, lineNumber: usize, column: usize) usize {
    var currentLine: usize = 1;
    var offset: usize = 0;
    while (currentLine < lineNumber and offset < text.len) : (offset += 1) {
        if (text[offset] == '\n') {
            currentLine += 1;
        }
    }
    if (currentLine != lineNumber) {
        return text.len;
    }
    var lineEnd = offset;
    while (lineEnd < text.len and text[lineEnd] != '\n') : (lineEnd += 1) {}
    // Match PositionOffsetTransformer: the line ends before a CR of a CRLF pair.
    if (lineEnd > offset and text[lineEnd - 1] == '\r') {
        lineEnd -= 1;
    }
    // Avoid overflow for callers that pass `maxInt(usize)` as the column.
    const column_delta = column - 1;
    if (column_delta > lineEnd - offset) {
        return lineEnd;
    }
    return offset + column_delta;
}

test "abstractText: string value and ranges" {
    const allocator = std.testing.allocator;
    var text = AbstractText.initString(allocator, "hello\nworld");
    defer text.deinit();

    try std.testing.expectEqualStrings("hello\nworld", try text.getValue());
    try std.testing.expectEqual(@as(usize, 1), text.getLength().lineCount);
    try std.testing.expectEqual(@as(usize, 5), text.getLength().columnCount);

    const slice = try text.getValueOfRange(Range.init(1, 2, 1, 5));
    defer allocator.free(slice);
    try std.testing.expectEqualStrings("ell", slice);

    const across = try text.getValueOfRange(Range.init(1, 4, 2, 3));
    defer allocator.free(across);
    try std.testing.expectEqualStrings("lo\nwo", across);

    try std.testing.expectEqual(@as(usize, 5), text.getLineLength(1));
    try std.testing.expectEqual(@as(usize, 5), text.getLineLength(2));

    try std.testing.expectEqual(Position.init(2, 6), text.endPositionExclusive());

    const line2 = try text.getLineAt(2);
    defer allocator.free(line2);
    try std.testing.expectEqualStrings("world", line2);

    const offset_value = try text.getValueOfOffsetRange(OffsetRange.init(1, 5));
    defer allocator.free(offset_value);
    try std.testing.expectEqualStrings("ello", offset_value);
}

test "abstractText: array text" {
    const allocator = std.testing.allocator;
    const lines = [_][]const u8{ "alpha", "beta", "gamma" };
    var text = AbstractText.initArray(allocator, &lines);
    defer text.deinit();

    try std.testing.expectEqualStrings("alpha\nbeta\ngamma", try text.getValue());
    try std.testing.expectEqual(@as(usize, 2), text.getLength().lineCount);
    try std.testing.expectEqual(@as(usize, 5), text.getLength().columnCount);

    const line = try text.getLineAt(2);
    defer allocator.free(line);
    try std.testing.expectEqualStrings("beta", line);

    const slice = try text.getValueOfRange(Range.init(2, 2, 3, 3));
    defer allocator.free(slice);
    try std.testing.expectEqualStrings("eta\nga", slice);

    const lineRange = LineRange.ofLength(2, 2);
    var rangeLines = try text.getLinesOfRange(lineRange);
    defer {
        for (rangeLines.items) |rangeLine| allocator.free(rangeLine);
        rangeLines.deinit();
    }
    try std.testing.expectEqual(@as(usize, 2), rangeLines.items.len);
    try std.testing.expectEqualStrings("beta", rangeLines.items[0]);
    try std.testing.expectEqualStrings("gamma", rangeLines.items[1]);
}

test "abstractText: line based text" {
    const allocator = std.testing.allocator;
    const Context = struct {
        lines: []const []const u8,

        fn getLineContent(context: *anyopaque, lineNumber: usize) []const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (lineNumber - 1 < self.lines.len) {
                return self.lines[lineNumber - 1];
            }
            return "";
        }
    };

    const context = Context{ .lines = &[_][]const u8{ "one", "two" } };
    const line_based = LineBasedText.init(@constCast(&context), 2, Context.getLineContent);
    var text = AbstractText.initLineBased(allocator, line_based);
    defer text.deinit();

    try std.testing.expectEqualStrings("one\ntwo", try text.getValue());
    try std.testing.expectEqual(@as(usize, 3), text.getLineLength(2));

    const transformer = try text.getTransformer();
    try std.testing.expectEqual(Position.init(2, 2), transformer.getPosition(5));
}

test "abstractText: CRLF columns are clamped before the CR" {
    const allocator = std.testing.allocator;
    var text = AbstractText.initString(allocator, "ab\r\ncd");
    defer text.deinit();

    const value = try text.getValueOfRange(Range.init(1, 1, 1, 4));
    defer allocator.free(value);
    try std.testing.expectEqualStrings("ab", value);

    const line = try text.getLineAt(1);
    defer allocator.free(line);
    try std.testing.expectEqualStrings("ab", line);
}

test "abstractText: equals" {
    const allocator = std.testing.allocator;
    var a = AbstractText.initString(allocator, "same");
    var b = AbstractText.initString(allocator, "same");
    var c = AbstractText.initString(allocator, "different");
    defer a.deinit();
    defer b.deinit();
    defer c.deinit();

    try std.testing.expect(a.equals(&b));
    try std.testing.expect(!a.equals(&c));
}
