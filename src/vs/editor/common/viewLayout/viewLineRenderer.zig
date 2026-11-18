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

pub const RenderedPart = struct {
    text: []const u8,
    foreground: u9,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    strikethrough: bool = false,
};

pub const RenderedLine = struct {
    /// Tabs-expanded UTF-8. Parts borrow slices from this buffer.
    bytes: []u8,
    parts: []RenderedPart,

    pub fn deinit(self: RenderedLine, allocator: Allocator) void {
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
};

const WhitespaceContext = struct {
    mode: RenderWhitespace,
    first_non_whitespace: usize,
    last_non_whitespace: usize,
    line_length: usize,
    offset: *usize,
};

const PartRange = struct {
    start: usize,
    end: usize,
    metadata: TokenMetadata,
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
        .selection, .none => false,
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

    var column = input.start_visible_column;
    var whitespace_offset: usize = 0;
    var whitespace = WhitespaceContext{
        .mode = input.render_whitespace,
        .first_non_whitespace = firstNonWhitespace(input.content),
        .last_non_whitespace = lastNonWhitespace(input.content),
        .line_length = input.content.len,
        .offset = &whitespace_offset,
    };
    const token_count = input.tokens.getCount();

    if (token_count == 0) {
        const start = bytes.items.len;
        try appendExpanded(&bytes, allocator, input.content, input.tab_size, &column, &whitespace);
        try ranges.append(allocator, .{
            .start = start,
            .end = bytes.items.len,
            .metadata = TokenMetadata.default,
        });
    } else {
        var offset: usize = 0;
        var index: usize = 0;
        while (index < token_count) : (index += 1) {
            const end = @min(input.tokens.getEndOffset(index), input.content.len);
            if (end <= offset) continue;
            const start = bytes.items.len;
            try appendExpanded(&bytes, allocator, input.content[offset..end], input.tab_size, &column, &whitespace);
            try ranges.append(allocator, .{
                .start = start,
                .end = bytes.items.len,
                .metadata = input.tokens.getMetadata(index),
            });
            offset = end;
        }
        if (offset < input.content.len) {
            const start = bytes.items.len;
            try appendExpanded(&bytes, allocator, input.content[offset..], input.tab_size, &column, &whitespace);
            try ranges.append(allocator, .{
                .start = start,
                .end = bytes.items.len,
                .metadata = TokenMetadata.default,
            });
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
        };
    }
    ranges.deinit(allocator);

    return .{ .bytes = owned_bytes, .parts = parts };
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
