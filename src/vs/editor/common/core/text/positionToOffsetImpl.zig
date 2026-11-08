// Port of `src/vs/editor/common/core/text/positionToOffsetImpl.ts`.
//
// Divergences from the TypeScript module:
//
//  * There is no `Deps` indirection: it exists upstream only to break a cyclic
//    module dependency, and Zig handles the import graph fine.
//  * The abstract `PositionOffsetTransformerBase` is a "struct of function
//    pointers" with an explicit `context`.
//  * `text` is a `[]const u8`; offsets are byte offsets.
const std = @import("std");
const Allocator = std.mem.Allocator;

const arrays_find = @import("../../../../base/common/arraysFind.zig");

const position_module = @import("../position.zig");
const Position = position_module.Position;
const range_module = @import("../range.zig");
const Range = range_module.Range;

const offset_range_module = @import("../ranges/offsetRange.zig");
const OffsetRange = offset_range_module.OffsetRange;

const string_edit_module = @import("../edits/stringEdit.zig");
const StringEdit = string_edit_module.StringEdit;
const StringReplacement = string_edit_module.StringReplacement;

const text_edit_module = @import("../edits/textEdit.zig");
const TextEdit = text_edit_module.TextEdit;
const TextReplacement = text_edit_module.TextReplacement;

const text_length_module = @import("../text/textLength.zig");
const TextLength = text_length_module.TextLength;

/// Transforms between positions and offsets.
pub const PositionOffsetTransformerBase = struct {
    context: *anyopaque,
    getOffsetFn: *const fn (context: *anyopaque, position: Position) usize,
    getPositionFn: *const fn (context: *anyopaque, offset: usize) Position,

    pub fn getOffset(self: PositionOffsetTransformerBase, position: Position) usize {
        return self.getOffsetFn(self.context, position);
    }

    pub fn getOffsetRange(self: PositionOffsetTransformerBase, range: Range) OffsetRange {
        return OffsetRange.init(
            self.getOffset(range.getStartPosition()),
            self.getOffset(range.getEndPosition()),
        );
    }

    pub fn getPosition(self: PositionOffsetTransformerBase, offset: usize) Position {
        return self.getPositionFn(self.context, offset);
    }

    pub fn getRange(self: PositionOffsetTransformerBase, offset_range: OffsetRange) Range {
        return range_module.fromPositions(
            self.getPosition(offset_range.start),
            self.getPosition(offset_range.endExclusive),
        );
    }

    pub fn getStringEdit(self: PositionOffsetTransformerBase, allocator: Allocator, edit: *const TextEdit) !StringEdit {
        var replacements = std.array_list.Managed(StringReplacement).init(allocator);
        defer replacements.deinit();
        try replacements.ensureTotalCapacity(edit.replacements.len);
        for (edit.replacements) |replacement| {
            replacements.appendAssumeCapacity(self.getStringReplacement(replacement));
        }
        return StringEdit.create(allocator, replacements.items);
    }

    pub fn getStringReplacement(self: PositionOffsetTransformerBase, edit: TextReplacement) StringReplacement {
        return StringReplacement.init(self.getOffsetRange(edit.range), edit.text);
    }

    pub fn getTextReplacement(self: PositionOffsetTransformerBase, edit: StringReplacement) TextReplacement {
        return TextReplacement.init(self.getRange(edit.replaceRange), edit.newText);
    }

    pub fn getTextEdit(self: PositionOffsetTransformerBase, allocator: Allocator, edit: *const StringEdit) !TextEdit {
        var replacements = std.array_list.Managed(TextReplacement).init(allocator);
        defer replacements.deinit();
        try replacements.ensureTotalCapacity(edit.replacements.len);
        for (edit.replacements) |replacement| {
            replacements.appendAssumeCapacity(self.getTextReplacement(replacement));
        }
        return TextEdit.create(allocator, replacements.items);
    }
};

/// Transforms between positions and offsets for a plain text string.
pub const PositionOffsetTransformer = struct {
    allocator: Allocator,
    text: []const u8,
    line_start_offset_by_line_idx: ?[]usize,
    line_end_offset_by_line_idx: ?[]usize,

    pub fn init(allocator: Allocator, text: []const u8) PositionOffsetTransformer {
        return .{
            .allocator = allocator,
            .text = text,
            .line_start_offset_by_line_idx = null,
            .line_end_offset_by_line_idx = null,
        };
    }

    pub fn deinit(self: *PositionOffsetTransformer) void {
        if (self.line_start_offset_by_line_idx) |line_start_offsets| {
            self.allocator.free(line_start_offsets);
        }
        if (self.line_end_offset_by_line_idx) |line_end_offsets| {
            self.allocator.free(line_end_offsets);
        }
        self.line_start_offset_by_line_idx = null;
        self.line_end_offset_by_line_idx = null;
    }

    fn getLineStartOffsets(self: *PositionOffsetTransformer) []const usize {
        if (self.line_start_offset_by_line_idx == null) {
            self.computeLineOffsets() catch unreachable;
        }
        return self.line_start_offset_by_line_idx.?;
    }

    fn getLineEndOffsets(self: *PositionOffsetTransformer) []const usize {
        if (self.line_end_offset_by_line_idx == null) {
            self.computeLineOffsets() catch unreachable;
        }
        return self.line_end_offset_by_line_idx.?;
    }

    fn computeLineOffsets(self: *PositionOffsetTransformer) !void {
        var line_start_offsets = std.array_list.Managed(usize).init(self.allocator);
        errdefer line_start_offsets.deinit();
        var line_end_offsets = std.array_list.Managed(usize).init(self.allocator);
        errdefer line_end_offsets.deinit();

        try line_start_offsets.append(0);
        for (self.text, 0..) |character, i| {
            if (character == '\n') {
                try line_start_offsets.append(i + 1);
                if (i > 0 and self.text[i - 1] == '\r') {
                    try line_end_offsets.append(i - 1);
                } else {
                    try line_end_offsets.append(i);
                }
            }
        }
        try line_end_offsets.append(self.text.len);

        self.line_start_offset_by_line_idx = try line_start_offsets.toOwnedSlice();
        self.line_end_offset_by_line_idx = try line_end_offsets.toOwnedSlice();
    }

    pub fn getOffset(self: *PositionOffsetTransformer, position: Position) usize {
        const valid_position = self.validatePosition(position);
        return self.getLineStartOffsets()[valid_position.lineNumber - 1] + valid_position.column - 1;
    }

    fn validatePosition(self: *PositionOffsetTransformer, position: Position) Position {
        if (position.lineNumber < 1) {
            return Position.init(1, 1);
        }
        const line_count = self.textLength().lineCount + 1;
        if (position.lineNumber > line_count) {
            const line_length = self.getLineLength(line_count);
            return Position.init(line_count, line_length + 1);
        }
        if (position.column < 1) {
            return Position.init(position.lineNumber, 1);
        }
        const line_length = self.getLineLength(position.lineNumber);
        if (position.column - 1 > line_length) {
            return Position.init(position.lineNumber, line_length + 1);
        }
        return position;
    }

    pub fn getPosition(self: *PositionOffsetTransformer, offset: usize) Position {
        const line_start_offsets = self.getLineStartOffsets();
        const idx = arrays_find.findLastIdxMonotonous(
            usize,
            line_start_offsets,
            offset,
            struct {
                fn lessThanOrEqual(threshold: usize, value: usize) bool {
                    return value <= threshold;
                }
            }.lessThanOrEqual,
            0,
            line_start_offsets.len,
        );
        return Position.init(idx + 1, offset - line_start_offsets[idx] + 1);
    }

    pub fn getTextLength(self: *PositionOffsetTransformer, offset_range: OffsetRange) TextLength {
        return TextLength.ofRange(self.getRange(offset_range));
    }

    pub fn textLength(self: *PositionOffsetTransformer) TextLength {
        const line_start_offsets = self.getLineStartOffsets();
        const line_idx = line_start_offsets.len - 1;
        return .{
            .lineCount = line_idx,
            .columnCount = self.text.len - line_start_offsets[line_idx],
        };
    }

    pub fn getLineLength(self: *PositionOffsetTransformer, line_number: usize) usize {
        return self.getLineEndOffsets()[line_number - 1] - self.getLineStartOffsets()[line_number - 1];
    }

    /// The `PositionOffsetTransformerBase` view of this transformer.
    pub fn asBase(self: *PositionOffsetTransformer) PositionOffsetTransformerBase {
        return .{
            .context = self,
            .getOffsetFn = struct {
                fn call(context: *anyopaque, position: Position) usize {
                    const transformer: *PositionOffsetTransformer = @ptrCast(@alignCast(context));
                    return transformer.getOffset(position);
                }
            }.call,
            .getPositionFn = struct {
                fn call(context: *anyopaque, offset: usize) Position {
                    const transformer: *PositionOffsetTransformer = @ptrCast(@alignCast(context));
                    return transformer.getPosition(offset);
                }
            }.call,
        };
    }
};

test "PositionOffsetTransformer: offsets round-trip with positions" {
    const allocator = std.testing.allocator;

    var transformer = PositionOffsetTransformer.init(allocator, "ab\ncd\r\nef");
    defer transformer.deinit();

    try std.testing.expectEqual(@as(usize, 0), transformer.getOffset(Position.init(1, 1)));
    try std.testing.expectEqual(@as(usize, 1), transformer.getOffset(Position.init(1, 2)));
    try std.testing.expectEqual(@as(usize, 3), transformer.getOffset(Position.init(2, 1)));
    try std.testing.expectEqual(@as(usize, 7), transformer.getOffset(Position.init(3, 1)));

    try std.testing.expectEqual(Position.init(3, 1), transformer.getPosition(7));
    try std.testing.expectEqual(Position.init(3, 2), transformer.getPosition(8));
    try std.testing.expectEqual(Position.init(2, 2), transformer.getPosition(4));
}

test "PositionOffsetTransformer: line lengths ignore the line separators" {
    const allocator = std.testing.allocator;

    var transformer = PositionOffsetTransformer.init(allocator, "ab\ncd\r\nef");
    defer transformer.deinit();

    try std.testing.expectEqual(@as(usize, 2), transformer.getLineLength(1));
    try std.testing.expectEqual(@as(usize, 2), transformer.getLineLength(2));
    try std.testing.expectEqual(@as(usize, 2), transformer.getLineLength(3));

    const length = transformer.textLength();
    try std.testing.expectEqual(@as(usize, 2), length.lineCount);
    try std.testing.expectEqual(@as(usize, 2), length.columnCount);
}

test "PositionOffsetTransformer: clamps out of range positions" {
    const allocator = std.testing.allocator;

    var transformer = PositionOffsetTransformer.init(allocator, "ab\ncd");
    defer transformer.deinit();

    try std.testing.expectEqual(@as(usize, 0), transformer.getOffset(Position.init(0, 0)));
    try std.testing.expectEqual(@as(usize, 0), transformer.getOffset(Position.init(1, 0)));
    // Column past the end of the line clamps to the line length + 1.
    try std.testing.expectEqual(@as(usize, 2), transformer.getOffset(Position.init(1, 100)));
    // Line past the end clamps to the last line.
    try std.testing.expectEqual(@as(usize, 5), transformer.getOffset(Position.init(100, 100)));
}

test "PositionOffsetTransformerBase: converts ranges" {
    const allocator = std.testing.allocator;

    var transformer = PositionOffsetTransformer.init(allocator, "hello world");
    defer transformer.deinit();

    const base = transformer.asBase();

    const offset_range = base.getOffsetRange(Range.init(1, 7, 1, 12));
    try std.testing.expectEqual(@as(usize, 6), offset_range.start);
    try std.testing.expectEqual(@as(usize, 11), offset_range.endExclusive);

    const range = base.getRange(OffsetRange.init(0, 5));
    try std.testing.expectEqual(@as(usize, 1), range.startColumn);
    try std.testing.expectEqual(@as(usize, 6), range.endColumn);
}

test "PositionOffsetTransformerBase: converts text edits to string edits" {
    const allocator = std.testing.allocator;

    var transformer = PositionOffsetTransformer.init(allocator, "hello world");
    defer transformer.deinit();

    const base = transformer.asBase();

    var text_edit = try TextEdit.create(allocator, &.{
        TextReplacement.init(Range.init(1, 1, 1, 6), "hi"),
    });
    defer text_edit.deinit();

    var string_edit = try base.getStringEdit(allocator, &text_edit);
    defer string_edit.deinit();

    try std.testing.expectEqual(@as(usize, 1), string_edit.replacements.len);
    try std.testing.expectEqual(@as(usize, 0), string_edit.replacements[0].replaceRange.start);
    try std.testing.expectEqual(@as(usize, 5), string_edit.replacements[0].replaceRange.endExclusive);
    try std.testing.expectEqualStrings("hi", string_edit.replacements[0].newText);

    var round_tripped = try base.getTextEdit(allocator, &string_edit);
    defer round_tripped.deinit();
    try std.testing.expectEqual(@as(usize, 1), round_tripped.replacements.len);
    try std.testing.expectEqual(@as(usize, 1), round_tripped.replacements[0].range.startLineNumber);
    try std.testing.expectEqual(@as(usize, 6), round_tripped.replacements[0].range.endColumn);
    try std.testing.expectEqualStrings("hi", round_tripped.replacements[0].text);
}
