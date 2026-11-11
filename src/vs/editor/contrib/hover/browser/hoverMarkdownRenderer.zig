//! Terminal renderer for hover markdown.
//!
//! Upstream renders hover contents with `IMarkdownRendererService`
//! (`src/vs/platform/markdown/browser/markdownRenderer.ts`), i.e. markdown-it
//! plus an HTML sanitizer, and lays the result out with CSS. The terminal has
//! no HTML or CSS engine, so this file renders the same contents to styled
//! cells. The observable structure of hover markdown is kept: paragraphs,
//! headings, lists, block quotes, fenced code blocks, horizontal rules,
//! emphasis, inline code and links.
//!
//! Terminal substitutions, documented in `README.md` and
//! `docs/terminal-ui.md`:
//!  * a link renders its text underlined and, when the URL differs, the URL in
//!    dim text because cells cannot open a link;
//!  * tables and images render as their plain text;
//!  * raw HTML is ignored (there is no sanitizer/HTML renderer);
//!  * a soft line break is preserved instead of being joined into the
//!    paragraph, because hover contents in the TUI are already line-oriented;
//!  * a tab is expanded to four spaces so cell width and painted width agree.
//!
//! Strings are copied into the renderer's arena, so callers may drop the
//! markdown string after `parse` returns.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ui = @import("ui");
const CursorColumns = @import("../../../common/core/cursorColumns.zig").CursorColumns;

const tab_width: usize = 4;
const text_color = ui.Color{ .r = 204, .g = 204, .b = 204 };
const code_color = ui.Color{ .r = 215, .g = 186, .b = 125 };
const code_background = ui.Color{ .r = 30, .g = 30, .b = 30 };
const code_block_color = ui.Color{ .r = 212, .g = 212, .b = 212 };
const link_color = ui.Color{ .r = 55, .g = 148, .b = 255 };
const heading_color = ui.Color{ .r = 235, .g = 235, .b = 235 };
const rule_color = ui.Color{ .r = 90, .g = 90, .b = 90 };

pub const Span = struct {
    text: []const u8,
    style: ui.Style = .{},
};

pub const Line = struct {
    spans: []Span = &.{},
    /// Cells kept for the continuation of a wrapped list item or quote.
    indent: usize = 0,
    /// A horizontal rule; the widget draws it to the available width.
    rule: bool = false,

    pub fn width(self: Line) usize {
        var cells: usize = 0;
        for (self.spans) |span| cells += textWidth(span.text);
        return cells;
    }
};

pub const Content = struct {
    arena: std.heap.ArenaAllocator,
    lines: []Line,

    pub fn deinit(self: *Content) void {
        self.arena.deinit();
    }

    pub fn maxLineWidth(self: *const Content) usize {
        var width: usize = 0;
        for (self.lines) |line| width = @max(width, line.width());
        return width;
    }
};

pub fn parse(parent: Allocator, markdown: []const u8) !Content {
    var arena = std.heap.ArenaAllocator.init(parent);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    var lines = std.array_list.Managed(Line).init(allocator);

    var iterator = std.mem.splitScalar(u8, markdown, '\n');
    while (iterator.next()) |raw| {
        const line = try expandTabs(allocator, std.mem.trimEnd(u8, raw, "\r"));
        const trimmed = std.mem.trim(u8, line, " \t");

        if (fenceStart(trimmed)) |fence| {
            try parseCodeBlock(allocator, &lines, &iterator, fence);
            continue;
        }
        if (trimmed.len == 0) {
            try lines.append(.{});
            continue;
        }
        if (headingText(trimmed)) |heading| {
            var spans = std.array_list.Managed(Span).init(allocator);
            var style = ui.Style{ .bold = true, .color = heading_color };
            if (heading.level == 1) style.underline = true;
            try parseInline(allocator, &spans, heading.text, style);
            try lines.append(.{ .spans = try spans.toOwnedSlice() });
            continue;
        }
        if (isRule(trimmed)) {
            try lines.append(.{ .rule = true });
            continue;
        }
        if (quoteText(trimmed)) |quote| {
            var spans = std.array_list.Managed(Span).init(allocator);
            try spans.append(.{ .text = "│ ", .style = .{ .dim = true, .color = rule_color } });
            try parseInline(allocator, &spans, quote, .{ .color = text_color });
            try lines.append(.{ .spans = try spans.toOwnedSlice(), .indent = 2 });
            continue;
        }
        if (listItem(trimmed)) |item| {
            var spans = std.array_list.Managed(Span).init(allocator);
            const marker = if (item.bullet)
                "• "
            else
                try std.fmt.allocPrint(allocator, "{s}. ", .{item.number});
            try spans.append(.{ .text = marker, .style = .{ .color = text_color } });
            try parseInline(allocator, &spans, item.text, .{ .color = text_color });
            try lines.append(.{ .spans = try spans.toOwnedSlice(), .indent = textWidth(marker) });
            continue;
        }

        var spans = std.array_list.Managed(Span).init(allocator);
        try parseInline(allocator, &spans, line, .{ .color = text_color });
        try lines.append(.{ .spans = try spans.toOwnedSlice() });
    }

    return .{ .arena = arena, .lines = try lines.toOwnedSlice() };
}

fn expandTabs(allocator: Allocator, line: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, line, '\t') == null) return allocator.dupe(u8, line);
    var out = std.array_list.Managed(u8).init(allocator);
    for (line) |ch| {
        if (ch == '\t') {
            try out.appendNTimes(' ', tab_width);
        } else {
            try out.append(ch);
        }
    }
    return try out.toOwnedSlice();
}

const Fence = struct {
    marker: u8,
    count: usize,
};

fn fenceStart(trimmed: []const u8) ?Fence {
    if (trimmed.len < 3) return null;
    const marker = trimmed[0];
    if (marker != '`' and marker != '~') return null;
    var count: usize = 0;
    while (count < trimmed.len and trimmed[count] == marker) count += 1;
    if (count < 3) return null;
    return .{ .marker = marker, .count = count };
}

fn isFenceEnd(trimmed: []const u8, fence: Fence) bool {
    if (trimmed.len < fence.count) return false;
    var count: usize = 0;
    while (count < trimmed.len and trimmed[count] == fence.marker) count += 1;
    return count >= fence.count and std.mem.trim(u8, trimmed[count..], " \t").len == 0;
}

fn parseCodeBlock(
    allocator: Allocator,
    lines: *std.array_list.Managed(Line),
    iterator: anytype,
    fence: Fence,
) !void {
    while (iterator.next()) |raw| {
        const line = try expandTabs(allocator, std.mem.trimEnd(u8, raw, "\r"));
        if (isFenceEnd(std.mem.trim(u8, line, " \t"), fence)) return;
        var spans = std.array_list.Managed(Span).init(allocator);
        const text = try std.fmt.allocPrint(allocator, "  {s}", .{line});
        try spans.append(.{
            .text = text,
            .style = .{ .color = code_block_color, .background = code_background },
        });
        try lines.append(.{ .spans = try spans.toOwnedSlice() });
    }
}

const Heading = struct {
    level: usize,
    text: []const u8,
};

fn headingText(trimmed: []const u8) ?Heading {
    var level: usize = 0;
    while (level < trimmed.len and trimmed[level] == '#') level += 1;
    if (level == 0 or level > 6 or level >= trimmed.len or trimmed[level] != ' ') return null;
    return .{ .level = level, .text = std.mem.trim(u8, trimmed[level + 1 ..], " \t") };
}

fn isRule(trimmed: []const u8) bool {
    if (trimmed.len < 3) return false;
    const marker = trimmed[0];
    if (marker != '-' and marker != '*' and marker != '_') return false;
    for (trimmed) |ch| {
        if (ch == ' ' or ch == '\t') continue;
        if (ch != marker) return false;
    }
    return true;
}

fn quoteText(trimmed: []const u8) ?[]const u8 {
    if (trimmed.len == 0 or trimmed[0] != '>') return null;
    return std.mem.trimStart(u8, trimmed[1..], " ");
}

const ListItem = struct {
    bullet: bool,
    number: []const u8,
    text: []const u8,
};

fn listItem(trimmed: []const u8) ?ListItem {
    if (trimmed.len >= 2) {
        const marker = trimmed[0];
        if ((marker == '-' or marker == '*' or marker == '+') and trimmed[1] == ' ') {
            return .{ .bullet = true, .number = "", .text = std.mem.trimStart(u8, trimmed[2..], " ") };
        }
    }
    var digits: usize = 0;
    while (digits < trimmed.len and std.ascii.isDigit(trimmed[digits])) digits += 1;
    if (digits > 0 and digits + 1 < trimmed.len and
        (trimmed[digits] == '.' or trimmed[digits] == ')') and trimmed[digits + 1] == ' ')
    {
        return .{
            .bullet = false,
            .number = trimmed[0..digits],
            .text = std.mem.trimStart(u8, trimmed[digits + 2 ..], " "),
        };
    }
    return null;
}

/// Parses inline markdown into styled spans. Delimiters are matched only when
/// a closing delimiter exists later on the same line, which keeps literal
/// `*`/`_` in prose readable.
fn parseInline(allocator: Allocator, spans: *std.array_list.Managed(Span), text: []const u8, base: ui.Style) Allocator.Error!void {
    var plain = std.array_list.Managed(u8).init(allocator);
    var index: usize = 0;

    while (index < text.len) {
        if (try parseInlineToken(allocator, spans, &plain, text, &index, base)) continue;

        if (try flushEntity(&plain, text[index..])) |consumed| {
            index += consumed;
            continue;
        }
        const decoded = ui.dom.decodeAt(text, index);
        if (decoded.len == 0) break;
        try plain.appendSlice(text[index .. index + decoded.len]);
        index += decoded.len;
    }
    try flushPlain(allocator, spans, &plain, base);
}

fn parseInlineToken(
    allocator: Allocator,
    spans: *std.array_list.Managed(Span),
    plain: *std.array_list.Managed(u8),
    text: []const u8,
    index: *usize,
    base: ui.Style,
) Allocator.Error!bool {
    const rest = text[index.*..];

    if (rest.len >= 2 and rest[0] == '\\' and rest[1] != '\n') {
        try flushPlain(allocator, spans, plain, base);
        const decoded = ui.dom.decodeAt(text, index.* + 1);
        try spans.append(.{ .text = try allocator.dupe(u8, text[index.* + 1 .. index.* + 1 + decoded.len]), .style = base });
        index.* += 1 + decoded.len;
        return true;
    }

    if (rest[0] == '`') {
        var run: usize = 0;
        while (run < rest.len and rest[run] == '`') run += 1;
        const open = index.* + run;
        if (findBacktickClose(text, open, run)) |close| {
            try flushPlain(allocator, spans, plain, base);
            var content = text[open..close];
            if (content.len >= 2 and content[0] == ' ' and content[content.len - 1] == ' ') {
                content = content[1 .. content.len - 1];
            }
            var style = base;
            style.color = code_color;
            try spans.append(.{ .text = try allocator.dupe(u8, content), .style = style });
            index.* = close + run;
            return true;
        }
    }

    if (rest.len >= 2 and (std.mem.startsWith(u8, rest, "**") or std.mem.startsWith(u8, rest, "__"))) {
        const marker = rest[0..2];
        if (findClosingDelimiter(text, index.* + 2, marker)) |close| {
            try flushPlain(allocator, spans, plain, base);
            var style = base;
            style.bold = true;
            try parseInline(allocator, spans, text[index.* + 2 .. close], style);
            index.* = close + 2;
            return true;
        }
    }

    if (rest.len >= 2 and std.mem.startsWith(u8, rest, "~~")) {
        if (findClosingDelimiter(text, index.* + 2, "~~")) |close| {
            try flushPlain(allocator, spans, plain, base);
            var style = base;
            style.strikethrough = true;
            try parseInline(allocator, spans, text[index.* + 2 .. close], style);
            index.* = close + 2;
            return true;
        }
    }

    if (rest[0] == '*' or rest[0] == '_') {
        const marker = rest[0];
        const inside_word = marker == '_' and index.* > 0 and std.ascii.isAlphanumeric(text[index.* - 1]);
        if (!inside_word and index.* + 1 < text.len and text[index.* + 1] != ' ') {
            if (findClosingEmphasis(text, index.* + 1, marker)) |close| {
                if (close > index.* + 1) {
                    try flushPlain(allocator, spans, plain, base);
                    var style = base;
                    style.italic = true;
                    try parseInline(allocator, spans, text[index.* + 1 .. close], style);
                    index.* = close + 1;
                    return true;
                }
            }
        }
    }

    if (rest.len >= 2 and rest[0] == '!' and rest[1] == '[') {
        if (std.mem.indexOfScalarPos(u8, text, index.* + 2, ']')) |close| {
            if (close + 1 < text.len and text[close + 1] == '(') {
                if (std.mem.indexOfScalarPos(u8, text, close + 2, ')')) |close_url| {
                    try flushPlain(allocator, spans, plain, base);
                    try spans.append(.{
                        .text = try allocator.dupe(u8, text[index.* + 2 .. close]),
                        .style = .{ .dim = true, .color = text_color },
                    });
                    index.* = close_url + 1;
                    return true;
                }
            }
        }
    }

    if (rest.len >= 2 and rest[0] == '[') {
        if (std.mem.indexOfScalarPos(u8, text, index.* + 1, ']')) |close_text| {
            if (close_text + 1 < text.len and text[close_text + 1] == '(') {
                if (std.mem.indexOfScalarPos(u8, text, close_text + 2, ')')) |close_url| {
                    try flushPlain(allocator, spans, plain, base);
                    var style = base;
                    style.color = link_color;
                    style.underline = true;
                    try parseInline(allocator, spans, text[index.* + 1 .. close_text], style);
                    const url = text[close_text + 2 .. close_url];
                    const label = text[index.* + 1 .. close_text];
                    if (!std.mem.eql(u8, url, label)) {
                        try spans.append(.{
                            .text = try std.fmt.allocPrint(allocator, " ({s})", .{url}),
                            .style = .{ .dim = true, .color = link_color },
                        });
                    }
                    index.* = close_url + 1;
                    return true;
                }
            }
        }
    }

    if (rest[0] == '<') {
        if (std.mem.indexOfScalarPos(u8, text, index.* + 1, '>')) |close| {
            try flushPlain(allocator, spans, plain, base);
            // Raw HTML has no renderer in the terminal; drop the tag and keep
            // the text outside it.
            index.* = close + 1;
            return true;
        }
    }

    return false;
}

fn findBacktickClose(text: []const u8, from: usize, run: usize) ?usize {
    var index = from;
    while (index < text.len) : (index += 1) {
        if (text[index] != '`') continue;
        var count: usize = 0;
        while (index + count < text.len and text[index + count] == '`') count += 1;
        if (count == run) return index;
        index += count - 1;
    }
    return null;
}

fn findClosingDelimiter(text: []const u8, from: usize, marker: []const u8) ?usize {
    var index = from;
    while (index + marker.len <= text.len) : (index += 1) {
        if (std.mem.startsWith(u8, text[index..], marker)) return index;
    }
    return null;
}

fn findClosingEmphasis(text: []const u8, from: usize, marker: u8) ?usize {
    var index = from;
    while (index < text.len) : (index += 1) {
        if (text[index] != marker) continue;
        if (index == from) continue;
        if (text[index - 1] == ' ') continue;
        // An underscore inside a word is an identifier, not emphasis.
        if (marker == '_' and index + 1 < text.len and std.ascii.isAlphanumeric(text[index + 1])) continue;
        return index;
    }
    return null;
}

fn flushPlain(allocator: Allocator, spans: *std.array_list.Managed(Span), plain: *std.array_list.Managed(u8), base: ui.Style) Allocator.Error!void {
    if (plain.items.len == 0) return;
    try spans.append(.{ .text = try allocator.dupe(u8, plain.items), .style = base });
    plain.clearRetainingCapacity();
}

fn flushEntity(plain: *std.array_list.Managed(u8), rest: []const u8) Allocator.Error!?usize {
    const entities = [_]struct { source: []const u8, value: []const u8 }{
        .{ .source = "&amp;", .value = "&" },
        .{ .source = "&lt;", .value = "<" },
        .{ .source = "&gt;", .value = ">" },
        .{ .source = "&quot;", .value = "\"" },
        .{ .source = "&#39;", .value = "'" },
        .{ .source = "&nbsp;", .value = " " },
    };
    for (entities) |entity| {
        if (std.mem.startsWith(u8, rest, entity.source)) {
            try plain.appendSlice(entity.value);
            return entity.source.len;
        }
    }
    return null;
}

pub fn textWidth(text: []const u8) usize {
    var width: usize = 0;
    var offset: usize = 0;
    while (offset < text.len) {
        const decoded = ui.dom.decodeAt(text, offset);
        if (decoded.len == 0) break;
        width += CursorColumns.nextVisibleColumn(decoded.cp, 0, 1);
        offset += decoded.len;
    }
    return width;
}

test "markdown: headings, lists, code and inline styles" {
    const testing = std.testing;
    var content = try parse(testing.allocator,
        \\# Title
        \\- **bold** and *italic* with `code`
        \\> quoted
        \\```zig
        \\const x = 1;
        \\```
    );
    defer content.deinit();

    try testing.expectEqual(@as(usize, 4), content.lines.len);
    try testing.expect(content.lines[0].spans[0].style.bold);
    try testing.expectEqualStrings("• ", content.lines[1].spans[0].text);
    try testing.expectEqualStrings("│ ", content.lines[2].spans[0].text);
    try testing.expect(std.mem.indexOf(u8, content.lines[3].spans[0].text, "const x = 1;") != null);
    try testing.expectEqual(code_background, content.lines[3].spans[0].style.background.?);
}

test "markdown: links render their text and dim URL" {
    const testing = std.testing;
    var content = try parse(testing.allocator, "see [docs](https://example.com) now");
    defer content.deinit();

    const line = content.lines[0];
    try testing.expectEqual(@as(usize, 4), line.spans.len);
    try testing.expectEqualStrings("see ", line.spans[0].text);
    try testing.expectEqualStrings("docs", line.spans[1].text);
    try testing.expect(line.spans[1].style.underline);
    try testing.expectEqualStrings(" (https://example.com)", line.spans[2].text);
    try testing.expectEqualStrings(" now", line.spans[3].text);
}

test "markdown: identifiers keep their underscores" {
    const testing = std.testing;
    var content = try parse(testing.allocator, "call foo_bar_baz now");
    defer content.deinit();
    try testing.expectEqual(@as(usize, 1), content.lines[0].spans.len);
    try testing.expect(!content.lines[0].spans[0].style.italic);
}
