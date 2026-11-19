// Port of the terminal-facing part of
// `src/vs/editor/common/viewLayout/viewLineRenderer.ts`.
//
// The browser renderer produces HTML and relies on CSS for token colors and
// font styles. This port produces a flat list of runs with the token metadata
// intact, so the terminal preview can assign direct `ui.Style` values. Tabs are
// expanded here because the terminal has fixed tab stops and no CSS `tab-size`.
//
// The POC does not yet implement decorated parts, RTL isolation, whitespace or
// control-character rendering; those stay in the upstream renderer and are
// noted as follow-ups.

const std = @import("std");
const Allocator = std.mem.Allocator;

const CursorColumns = @import("../core/cursorColumns.zig").CursorColumns;
const tokens_mod = @import("../tokens/lineTokens.zig");
const IViewLineTokens = tokens_mod.IViewLineTokens;
const TokenMetadata = @import("../encodedTokenAttributes.zig").TokenMetadata;
const RenderWhitespace = @import("../config/editorOptions.zig").RenderWhitespace;
const OffsetRange = @import("../core/ranges/offsetRange.zig").OffsetRange;
const line_decorations_mod = @import("./lineDecorations.zig");
const LineDecoration = line_decorations_mod.LineDecoration;
const DecorationSegment = line_decorations_mod.DecorationSegment;
const LineDecorationsNormalizer = line_decorations_mod.LineDecorationsNormalizer;

pub const RenderedPart = struct {
    text: []const u8,
    foreground: u9,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    strikethrough: bool = false,
    /// Normalized inline-decoration classes covering this part, if any. The
    /// slice is owned by the `RenderedLine` that produced the part.
    decoration_class: ?[]const u8 = null,
};

pub const RenderedLine = struct {
    /// Tabs-expanded UTF-8. Parts borrow slices from this buffer.
    bytes: []u8,
    parts: []RenderedPart,
    /// Normalized decoration segments; `RenderedPart.decoration_class` borrows
    /// their owned class-name strings.
    segments: []DecorationSegment = &.{},

    pub fn deinit(self: RenderedLine, allocator: Allocator) void {
        for (self.segments) |*segment| segment.deinit(allocator);
        allocator.free(self.segments);
        allocator.free(self.bytes);
        allocator.free(self.parts);
    }
};

pub const Input = struct {
    content: []const u8,
    tokens: IViewLineTokens,
    tab_size: usize = 4,
    start_visible_column: usize = 0,
    render_whitespace: RenderWhitespace = .none,
    /// Absolute byte ranges (within `content`) of the current selections.
    selection_ranges: []const OffsetRange = &.{},
    render_control_characters: bool = false,
    /// Inline decorations in model columns for this line. The renderer sorts
    /// and normalizes them; the caller keeps ownership.
    line_decorations: []const LineDecoration = &.{},
};

const WhitespaceContext = struct {
    mode: RenderWhitespace,
    first_non_whitespace: usize,
    last_non_whitespace: usize,
    line_length: usize,
    selection_ranges: []const OffsetRange,
    render_control_characters: bool,
    offset: *usize,
};

const PartRange = struct {
    start: usize,
    end: usize,
    metadata: TokenMetadata,
    decoration_class: ?[]const u8 = null,
};

/// Expands tabs in `content` for a terminal with `tab_size` columns.
pub fn expandTabs(
    allocator: Allocator,
    content: []const u8,
    tab_size: usize,
    start_column: usize,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var column = start_column;
    var offset: usize = 0;
    var whitespace = WhitespaceContext{
        .mode = .none,
        .first_non_whitespace = 0,
        .last_non_whitespace = 0,
        .line_length = content.len,
        .selection_ranges = &.{},
        .render_control_characters = false,
        .offset = &offset,
    };
    try appendExpanded(&out, allocator, content, tab_size, &column, &whitespace);
    return out.toOwnedSlice(allocator);
}

fn appendExpanded(
    out: *std.ArrayList(u8),
    allocator: Allocator,
    text: []const u8,
    tab_size: usize,
    column: *usize,
    whitespace: *WhitespaceContext,
) !void {
    var offset: usize = 0;
    while (offset < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[offset]) catch 1;
        const safe_len = @min(len, text.len - offset);
        const cp = std.unicode.utf8Decode(text[offset .. offset + safe_len]) catch @as(u21, text[offset]);
        const absolute = whitespace.offset.*;
        const render_whitespace = shouldRenderWhitespace(whitespace, absolute);
        if (cp == '\t') {
            const next = CursorColumns.nextRenderTabStop(column.*, tab_size);
            var spaces = next - column.*;
            if (render_whitespace) {
                try out.appendSlice(allocator, "\xE2\x86\x92");
                spaces -= 1;
            }
            while (spaces > 0) : (spaces -= 1) try out.append(allocator, ' ');
            column.* = next;
        } else if (cp == ' ' and render_whitespace) {
            try out.appendSlice(allocator, "\xC2\xB7");
            column.* += 1;
        } else if (whitespace.render_control_characters and cp < 0x20 and cp != '\t' and cp != '\r' and cp != '\n') {
            var control: [4]u8 = undefined;
            const encoded = std.unicode.utf8Encode(0x2400 + cp, &control) catch {
                try out.appendSlice(allocator, text[offset .. offset + safe_len]);
                whitespace.offset.* += safe_len;
                offset += safe_len;
                continue;
            };
            try out.appendSlice(allocator, control[0..encoded]);
            column.* += 1;
        } else {
            try out.appendSlice(allocator, text[offset .. offset + safe_len]);
            column.* = CursorColumns.nextVisibleColumn(cp, column.*, tab_size);
        }
        whitespace.offset.* += safe_len;
        offset += safe_len;
    }
}

fn shouldRenderWhitespace(context: *const WhitespaceContext, absolute_index: usize) bool {
    return switch (context.mode) {
        .all => true,
        .boundary => absolute_index < context.first_non_whitespace or absolute_index > context.last_non_whitespace,
        .trailing => absolute_index > context.last_non_whitespace,
        // Selection-only rendering needs selection ranges, which are not part
        // of the shared terminal renderer yet.
        .selection => blk: {
            for (context.selection_ranges) |range| {
                if (absolute_index >= range.start and absolute_index < range.endExclusive) break :blk true;
            }
            break :blk false;
        },
        .none => false,
    };
}

fn firstNonWhitespace(content: []const u8) usize {
    for (content, 0..) |byte, index| {
        if (byte != ' ' and byte != '\t' and byte != '\r' and byte != '\n') return index;
    }
    return content.len;
}

fn lastNonWhitespace(content: []const u8) usize {
    var index = content.len;
    while (index > 0) {
        index -= 1;
        const byte = content[index];
        if (byte != ' ' and byte != '\t' and byte != '\r' and byte != '\n') return index;
    }
    return content.len;
}

pub fn renderLine(allocator: Allocator, input: Input) !RenderedLine {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    var ranges: std.ArrayList(PartRange) = .empty;
    errdefer ranges.deinit(allocator);

    // Upstream `_applyInlineDecorations` sorts and normalizes the line
    // decorations before merging them into the token parts.
    var segments: []DecorationSegment = &.{};
    errdefer {
        for (segments) |*segment| segment.deinit(allocator);
        allocator.free(segments);
    }
    if (input.line_decorations.len > 0) {
        const sorted = try allocator.dupe(LineDecoration, input.line_decorations);
        defer allocator.free(sorted);
        std.mem.sort(LineDecoration, sorted, {}, LineDecoration.lessThan);
        var normalized = try LineDecorationsNormalizer.normalize(allocator, input.content, sorted);
        segments = try normalized.toOwnedSlice();
    }

    var column = input.start_visible_column;
    var whitespace_offset: usize = 0;
    var whitespace = WhitespaceContext{
        .mode = input.render_whitespace,
        .first_non_whitespace = firstNonWhitespace(input.content),
        .last_non_whitespace = lastNonWhitespace(input.content),
        .line_length = input.content.len,
        .selection_ranges = input.selection_ranges,
        .render_control_characters = input.render_control_characters,
        .offset = &whitespace_offset,
    };
    const token_count = input.tokens.getCount();

    if (token_count == 0) {
        try appendSpan(
            &bytes,
            &ranges,
            allocator,
            input.content,
            0,
            input.content.len,
            TokenMetadata.default,
            segments,
            input.tab_size,
            &column,
            &whitespace,
        );
    } else {
        var offset: usize = 0;
        var index: usize = 0;
        while (index < token_count) : (index += 1) {
            const end = @min(input.tokens.getEndOffset(index), input.content.len);
            if (end <= offset) continue;
            try appendSpan(
                &bytes,
                &ranges,
                allocator,
                input.content,
                offset,
                end,
                input.tokens.getMetadata(index),
                segments,
                input.tab_size,
                &column,
                &whitespace,
            );
            offset = end;
        }
        if (offset < input.content.len) {
            try appendSpan(
                &bytes,
                &ranges,
                allocator,
                input.content,
                offset,
                input.content.len,
                TokenMetadata.default,
                segments,
                input.tab_size,
                &column,
                &whitespace,
            );
        }
    }

    const parts = try allocator.alloc(RenderedPart, ranges.items.len);
    errdefer allocator.free(parts);
    const owned_bytes = try bytes.toOwnedSlice(allocator);
    errdefer allocator.free(owned_bytes);

    for (ranges.items, 0..) |range, i| {
        const metadata = range.metadata;
        parts[i] = .{
            .text = owned_bytes[range.start..range.end],
            .foreground = metadata.foreground,
            .bold = metadata.fontStyle.bold,
            .italic = metadata.fontStyle.italic,
            .underline = metadata.fontStyle.underline,
            .strikethrough = metadata.fontStyle.strikethrough,
            .decoration_class = range.decoration_class,
        };
    }
    ranges.deinit(allocator);

    return .{ .bytes = owned_bytes, .parts = parts, .segments = segments };
}

/// Appends one content span, split at normalized decoration boundaries, as
/// rendered parts. This is the run-based counterpart of upstream
/// `_applyInlineDecorations`: each output part carries the merged class names
/// of the decorations active over its content range.
fn appendSpan(
    bytes: *std.ArrayList(u8),
    ranges: *std.ArrayList(PartRange),
    allocator: Allocator,
    content: []const u8,
    span_start: usize,
    span_end: usize,
    metadata: TokenMetadata,
    segments: []const DecorationSegment,
    tab_size: usize,
    column: *usize,
    whitespace: *WhitespaceContext,
) !void {
    var position = span_start;
    var segment_index: usize = 0;
    while (position < span_end) {
        while (segment_index < segments.len and segments[segment_index].endOffset + 1 <= position) {
            segment_index += 1;
        }

        var piece_end = span_end;
        var decoration_class: ?[]const u8 = null;
        if (segment_index < segments.len) {
            const segment = segments[segment_index];
            if (segment.startOffset <= position) {
                piece_end = @min(span_end, segment.endOffset + 1);
                decoration_class = segment.className;
                if (piece_end == segment.endOffset + 1 and piece_end < span_end) {
                    segment_index += 1;
                }
            } else if (segment.startOffset < piece_end) {
                piece_end = segment.startOffset;
            }
        }

        const output_start = bytes.items.len;
        try appendExpanded(bytes, allocator, content[position..piece_end], tab_size, column, whitespace);
        try ranges.append(allocator, .{
            .start = output_start,
            .end = bytes.items.len,
            .metadata = metadata,
            .decoration_class = decoration_class,
        });
        position = piece_end;
    }
}

test "expandTabs: tab stops are relative to the visible column" {
    const allocator = std.testing.allocator;
    const text = try expandTabs(allocator, "a\tb", 4, 0);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("a   b", text);

    const shifted = try expandTabs(allocator, "\tx", 4, 2);
    defer allocator.free(shifted);
    try std.testing.expectEqualStrings("  x", shifted);
}

test "expandTabs: CJK advances two columns" {
    const allocator = std.testing.allocator;
    const text = try expandTabs(allocator, "中\tx", 4, 0);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("中  x", text);
}

fn renderTestLine(allocator: Allocator, content: []const u8, mode: RenderWhitespace) ![]u8 {
    const languages = @import("../languages.zig");
    const line_tokens = @import("../tokens/lineTokens.zig");
    var codec = try languages.LanguageIdCodec.init(allocator);
    defer codec.deinit();
    var owned = std.array_list.Managed(u8).init(allocator);
    errdefer owned.deinit();
    try owned.appendSlice(content);
    var tokens = try line_tokens.LineTokens.createEmpty(allocator, owned, &codec);
    defer tokens.deinit();
    const rendered = try renderLine(allocator, .{
        .content = content,
        .tokens = line_tokens.IViewLineTokens.init(&tokens),
        .tab_size = 4,
        .render_whitespace = mode,
    });
    defer rendered.deinit(allocator);
    return allocator.dupe(u8, rendered.bytes);
}

test "renderLine: visible whitespace modes" {
    const allocator = std.testing.allocator;

    const all = try renderTestLine(allocator, "  a b  ", .all);
    defer allocator.free(all);
    try std.testing.expectEqualStrings("\u{00B7}\u{00B7}a\u{00B7}b\u{00B7}\u{00B7}", all);

    const boundary = try renderTestLine(allocator, "  a b  ", .boundary);
    defer allocator.free(boundary);
    try std.testing.expectEqualStrings("\u{00B7}\u{00B7}a b\u{00B7}\u{00B7}", boundary);

    const trailing = try renderTestLine(allocator, "  a b  ", .trailing);
    defer allocator.free(trailing);
    try std.testing.expectEqualStrings("  a b\u{00B7}\u{00B7}", trailing);

    const tabs = try renderTestLine(allocator, "a\tb", .all);
    defer allocator.free(tabs);
    try std.testing.expectEqualStrings("a\u{2192}  b", tabs);

    const none = try renderTestLine(allocator, "a\tb", .none);
    defer allocator.free(none);
    try std.testing.expectEqualStrings("a   b", none);
}

test "renderLine: selection-only whitespace" {
    const allocator = std.testing.allocator;
    const languages = @import("../languages.zig");
    const line_tokens = @import("../tokens/lineTokens.zig");
    var codec = try languages.LanguageIdCodec.init(allocator);
    defer codec.deinit();
    var owned = std.array_list.Managed(u8).init(allocator);
    errdefer owned.deinit();
    try owned.appendSlice("  a  ");
    var tokens = try line_tokens.LineTokens.createEmpty(allocator, owned, &codec);
    defer tokens.deinit();

    const ranges = [_]OffsetRange{OffsetRange.init(0, 1)};
    const rendered = try renderLine(allocator, .{
        .content = "  a  ",
        .tokens = line_tokens.IViewLineTokens.init(&tokens),
        .tab_size = 4,
        .render_whitespace = .selection,
        .selection_ranges = &ranges,
    });
    defer rendered.deinit(allocator);
    try std.testing.expectEqualStrings("\u{00B7} a  ", rendered.bytes);
}

test "renderLine: control characters become Unicode control pictures" {
    const allocator = std.testing.allocator;
    const languages = @import("../languages.zig");
    const line_tokens = @import("../tokens/lineTokens.zig");
    var codec = try languages.LanguageIdCodec.init(allocator);
    defer codec.deinit();
    var owned = std.array_list.Managed(u8).init(allocator);
    errdefer owned.deinit();
    try owned.appendSlice("a\x01b");
    var tokens = try line_tokens.LineTokens.createEmpty(allocator, owned, &codec);
    defer tokens.deinit();

    const rendered = try renderLine(allocator, .{
        .content = "a\x01b",
        .tokens = line_tokens.IViewLineTokens.init(&tokens),
        .render_control_characters = true,
    });
    defer rendered.deinit(allocator);
    try std.testing.expectEqualStrings("a\u{2401}b", rendered.bytes);
}

test "renderLine: inline decorations split parts and merge classes" {
    const allocator = std.testing.allocator;
    const languages = @import("../languages.zig");
    const line_tokens = @import("../tokens/lineTokens.zig");
    const inline_mod = @import("../viewModel/inlineDecorations.zig");
    const Range = @import("../core/range.zig").Range;

    var codec = try languages.LanguageIdCodec.init(allocator);
    defer codec.deinit();
    var owned = std.array_list.Managed(u8).init(allocator);
    errdefer owned.deinit();
    try owned.appendSlice("abcabc");
    var tokens = try line_tokens.LineTokens.createEmpty(allocator, owned, &codec);
    defer tokens.deinit();

    const inline_decorations = [_]inline_mod.InlineDecoration{
        inline_mod.InlineDecoration.init(Range.init(1, 1, 1, 4), "c1", .Regular),
        inline_mod.InlineDecoration.init(Range.init(1, 3, 1, 4), "c2", .Regular),
    };
    const line_decorations = try LineDecoration.filter(allocator, &inline_decorations, 1, 1, 500);
    defer allocator.free(line_decorations);

    const rendered = try renderLine(allocator, .{
        .content = "abcabc",
        .tokens = line_tokens.IViewLineTokens.init(&tokens),
        .tab_size = 4,
        .line_decorations = line_decorations,
    });
    defer rendered.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), rendered.parts.len);
    try std.testing.expectEqualStrings("ab", rendered.parts[0].text);
    try std.testing.expectEqualStrings("c1", rendered.parts[0].decoration_class.?);
    try std.testing.expectEqualStrings("c", rendered.parts[1].text);
    try std.testing.expectEqualStrings("c1 c2", rendered.parts[1].decoration_class.?);
    try std.testing.expectEqualStrings("abc", rendered.parts[2].text);
    try std.testing.expect(rendered.parts[2].decoration_class == null);
}
