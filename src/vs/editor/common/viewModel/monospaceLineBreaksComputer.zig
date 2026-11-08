// Port of the plain-text core of
// `src/vs/editor/common/viewModel/monospaceLineBreaksComputer.ts`.
//
// The browser implementation reasons in pixels because injected text can ask
// for arbitrary `widthInEm` widths. The TUI has no injected text and a fixed
// monospace cell grid, so this port works in visible columns and uses
// `CursorColumns.nextVisibleColumn` for tab/CJK/emoji widths.
//
// Omitted from this port: injected text, fixed-width `widthInEm` ranges,
// DOM line-break strategies and `wrapOnEscapedLineFeeds`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const strings = @import("../../../base/common/strings.zig");
const CursorColumns = @import("../core/cursorColumns.zig").CursorColumns;
const CharacterClassifier = @import("../core/characterClassifier.zig").CharacterClassifier;
const WrappingIndent = @import("../config/editorOptions.zig").WrappingIndent;
const ModelLineProjectionData = @import("../modelLineProjectionData.zig").ModelLineProjectionData;
const WordBreak = @import("../modelLineProjectionData.zig").WordBreak;

pub const default_break_after_characters = " \t})]?|/&.,;¢°′″‰℃、。｡､￠，．：；？！％・･ゝゞヽヾーァィゥェォッャュョヮヵヶぁぃぅぇぉっゃゅょゎゕゖㇰㇱㇲㇳㇴㇵㇶㇷㇸㇹㇺㇻㇼㇽㇾㇿ々〻ｧｨｩｪｫｬｭｮｯｰ”〉》」』】〕）］｝｣";
pub const default_break_before_characters = "([{‘“〈《「『【〔（［｛｢£¥＄￡￥+＋";

const CharacterClass = enum(u2) {
    none = 0,
    break_before = 1,
    break_after = 2,
    break_ideographic = 3,
};

fn isIdeographic(code_point: u21) bool {
    return (code_point >= 0x3040 and code_point <= 0x30FF) or
        (code_point >= 0x3400 and code_point <= 0x4DBF) or
        (code_point >= 0x4E00 and code_point <= 0x9FFF);
}

pub const WrappingCharacterClassifier = struct {
    classifier: CharacterClassifier(CharacterClass),

    pub fn init(allocator: Allocator, break_before: []const u8, break_after: []const u8) !WrappingCharacterClassifier {
        var result = WrappingCharacterClassifier{
            .classifier = CharacterClassifier(CharacterClass).init(allocator, .none),
        };
        errdefer result.deinit();

        var i: usize = 0;
        while (i < break_before.len) {
            const decoded = decodeAt(break_before, i);
            try result.classifier.set(decoded.code_point, .break_before);
            i += decoded.len;
        }
        i = 0;
        while (i < break_after.len) {
            const decoded = decodeAt(break_after, i);
            try result.classifier.set(decoded.code_point, .break_after);
            i += decoded.len;
        }
        return result;
    }

    pub fn deinit(self: *WrappingCharacterClassifier) void {
        self.classifier.deinit();
    }

    pub fn get(self: *const WrappingCharacterClassifier, code_point: u21) CharacterClass {
        if (code_point >= 256 and isIdeographic(code_point)) return .break_ideographic;
        return self.classifier.get(code_point);
    }
};

const Decoded = struct { code_point: u21, len: usize };

fn decodeAt(text: []const u8, offset: usize) Decoded {
    if (offset >= text.len) return .{ .code_point = 0, .len = 0 };
    const len = std.unicode.utf8ByteSequenceLength(text[offset]) catch return .{ .code_point = text[offset], .len = 1 };
    if (offset + len > text.len) return .{ .code_point = text[offset], .len = 1 };
    const code_point = std.unicode.utf8Decode(text[offset .. offset + len]) catch return .{ .code_point = text[offset], .len = 1 };
    return .{ .code_point = code_point, .len = len };
}

fn charWidth(code_point: u21, visible_column: usize, tab_size: usize) usize {
    return CursorColumns.nextVisibleColumn(code_point, visible_column, tab_size) - visible_column;
}

fn computeWrappedTextIndentLength(line_text: []const u8, tab_size: usize, wrapping_column: usize, wrapping_indent: WrappingIndent) usize {
    if (wrapping_indent == .None) return 0;

    const first_non_whitespace = strings.firstNonWhitespaceIndex(line_text) orelse return 0;
    var indent_length: usize = 0;
    var offset: usize = 0;
    while (offset < first_non_whitespace) {
        const decoded = decodeAt(line_text, offset);
        indent_length += if (decoded.code_point == '\t')
            CursorColumns.nextRenderTabStop(indent_length, tab_size) - indent_length
        else
            1;
        offset += decoded.len;
    }

    const additional_tabs: usize = if (wrapping_indent == .DeepIndent) 2 else if (wrapping_indent == .Indent) 1 else 0;
    var i: usize = 0;
    while (i < additional_tabs) : (i += 1) {
        indent_length += CursorColumns.nextRenderTabStop(indent_length, tab_size) - indent_length;
    }

    // Force sticking to the beginning of the line if no character would fit
    // except for the indentation.
    if (indent_length + 2 > wrapping_column) return 0;
    return indent_length;
}

fn canBreak(prev_code_point: u21, prev_class: CharacterClass, code_point: u21, class: CharacterClass, keep_all: bool) bool {
    _ = prev_code_point;
    return code_point != ' ' and
        ((prev_class == .break_after and class != .break_after) or
            (prev_class != .break_before and class == .break_before) or
            (!keep_all and prev_class == .break_ideographic and class != .break_after) or
            (!keep_all and class == .break_ideographic and prev_class != .break_before));
}

/// Computes the wrapping of a single line. Returns null when the line fits and
/// does not need a projection.
pub fn computeLineBreaks(
    allocator: Allocator,
    classifier: *const WrappingCharacterClassifier,
    line_text: []const u8,
    tab_size: usize,
    wrapping_column: usize,
    wrapping_indent: WrappingIndent,
    word_break: WordBreak,
) !?ModelLineProjectionData {
    if (wrapping_column == 0) return null;
    if (line_text.len <= 1) return null;

    const keep_all = word_break == .keepAll;
    const wrapped_text_indent_length = computeWrappedTextIndentLength(line_text, tab_size, wrapping_column, wrapping_indent);
    const wrapped_line_break_column = wrapping_column - wrapped_text_indent_length;

    var breaking_offsets = ArrayList(usize).init(allocator);
    errdefer breaking_offsets.deinit();
    var breaking_offsets_visible_column = ArrayList(usize).init(allocator);
    errdefer breaking_offsets_visible_column.deinit();

    var breaking_column = wrapping_column;
    var break_offset: usize = 0;
    var break_offset_visible_column: usize = 0;
    var current_line_start_offset: usize = 0;

    const first = decodeAt(line_text, 0);
    var prev_code_point = first.code_point;
    var prev_class = classifier.get(first.code_point);
    var visible_column = charWidth(first.code_point, 0, tab_size);
    var offset = first.len;

    while (offset < line_text.len) {
        const decoded = decodeAt(line_text, offset);
        const code_point = decoded.code_point;
        const class = classifier.get(code_point);
        const width = charWidth(code_point, visible_column, tab_size);

        if (canBreak(prev_code_point, prev_class, code_point, class, keep_all)) {
            break_offset = offset;
            break_offset_visible_column = visible_column;
        }

        visible_column += width;

        if (visible_column > breaking_column) {
            if (break_offset == 0 or visible_column - break_offset_visible_column > wrapped_line_break_column) {
                // Cannot break at the last break opportunity; hard-break before
                // this character.
                break_offset = offset;
                break_offset_visible_column = visible_column - width;
            }

            if (break_offset > current_line_start_offset) {
                try breaking_offsets.append(break_offset);
                try breaking_offsets_visible_column.append(break_offset_visible_column);
                breaking_column = break_offset_visible_column + wrapped_line_break_column;
                current_line_start_offset = break_offset;
                break_offset = 0;
            }
        }

        prev_code_point = code_point;
        prev_class = class;
        offset += decoded.len;
    }

    if (breaking_offsets.items.len == 0) {
        breaking_offsets.deinit();
        breaking_offsets_visible_column.deinit();
        return null;
    }

    try breaking_offsets.append(line_text.len);
    try breaking_offsets_visible_column.append(visible_column);

    return ModelLineProjectionData.init(
        null,
        null,
        try breaking_offsets.toOwnedSlice(),
        try breaking_offsets_visible_column.toOwnedSlice(),
        wrapped_text_indent_length,
    );
}

test "monospace line breaks: no wrap when line fits" {
    var classifier = try WrappingCharacterClassifier.init(std.testing.allocator, default_break_before_characters, default_break_after_characters);
    defer classifier.deinit();
    try std.testing.expect((try computeLineBreaks(std.testing.allocator, &classifier, "hello", 4, 80, .None, .normal)) == null);
}

test "monospace line breaks: word wrap" {
    var classifier = try WrappingCharacterClassifier.init(std.testing.allocator, default_break_before_characters, default_break_after_characters);
    defer classifier.deinit();
    var data = (try computeLineBreaks(std.testing.allocator, &classifier, "hello world", 4, 7, .None, .normal)).?;
    defer {
        std.testing.allocator.free(data.breakOffsets);
        std.testing.allocator.free(data.breakOffsetsVisibleColumn);
    }
    try std.testing.expectEqualSlices(usize, &.{ 6, 11 }, data.breakOffsets);
    try std.testing.expectEqual(@as(usize, 2), data.getOutputLineCount());
}

test "monospace line breaks: hard break and indentation" {
    var classifier = try WrappingCharacterClassifier.init(std.testing.allocator, default_break_before_characters, default_break_after_characters);
    defer classifier.deinit();
    const data = (try computeLineBreaks(std.testing.allocator, &classifier, "    abcdefgh", 4, 8, .Same, .normal)).?;
    defer {
        std.testing.allocator.free(data.breakOffsets);
        std.testing.allocator.free(data.breakOffsetsVisibleColumn);
    }
    try std.testing.expectEqual(@as(usize, 4), data.wrappedTextIndentLength);
    try std.testing.expect(data.breakOffsets.len > 1);
}

test "monospace line breaks: CJK ideographic break" {
    var classifier = try WrappingCharacterClassifier.init(std.testing.allocator, default_break_before_characters, default_break_after_characters);
    defer classifier.deinit();
    const data = (try computeLineBreaks(std.testing.allocator, &classifier, "中文字", 4, 4, .None, .normal)).?;
    defer {
        std.testing.allocator.free(data.breakOffsets);
        std.testing.allocator.free(data.breakOffsetsVisibleColumn);
    }
    try std.testing.expectEqualSlices(usize, &.{ 6, 9 }, data.breakOffsets);
    try std.testing.expectEqualSlices(usize, &.{ 4, 6 }, data.breakOffsetsVisibleColumn);
}

test "monospace line breaks: tab width" {
    var classifier = try WrappingCharacterClassifier.init(std.testing.allocator, default_break_before_characters, default_break_after_characters);
    defer classifier.deinit();
    const data = (try computeLineBreaks(std.testing.allocator, &classifier, "a\tb\tc", 4, 4, .None, .normal)).?;
    defer {
        std.testing.allocator.free(data.breakOffsets);
        std.testing.allocator.free(data.breakOffsetsVisibleColumn);
    }
    try std.testing.expectEqualSlices(usize, &.{ 2, 4, 5 }, data.breakOffsets);
}
