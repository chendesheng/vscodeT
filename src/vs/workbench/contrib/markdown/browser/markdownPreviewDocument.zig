//! Terminal layout projection for the Markdown preview.
//!
//! The portable source of this behavior is
//! `vscode/extensions/markdown-language-features/preview/documentRenderer.ts`
//! plus the block geometry used by `preview-src/scroll-sync.ts`. Upstream
//! renders HTML blocks with `code-line`/`data-line` attributes and reads their
//! DOM rectangles. Here the renderer's block metadata is wrapped into cell rows
//! and grouped into `Element`s with the same geometry contract: `top`,
//! `height`, `line`, and code content bounds.

const std = @import("std");
const Allocator = std.mem.Allocator;

const markdown = @import("../../../../editor/common/markdown/markdownTerminalRenderer.zig");
const Span = markdown.Span;
const Line = markdown.Line;
const BlockInfo = markdown.BlockInfo;
const BlockKind = markdown.BlockKind;
const SourceLineMap = @import("./sourceLineMap.zig").SourceLineMap;

pub const Row = struct {
    spans: []const Span = &.{},
    continuation: []const Span = &.{},
    indent: usize = 0,
    rule: bool = false,
    no_wrap: bool = false,
    block: BlockInfo = .{},
};

pub const Element = struct {
    /// Body sentinel has `line = -1`.
    line: f64,
    top: f64,
    height: f64,
    content_top: f64,
    content_height: f64,
    source_end_line: f64,
    block_id: u32,
    code: bool = false,
    kind: BlockKind = .none,
    anchor: ?[]const u8 = null,
};

pub const LinkHit = struct {
    row: usize,
    start: usize,
    end: usize,
    href: []const u8,
};

pub const Document = struct {
    arena: *std.heap.ArenaAllocator,
    rows: []Row,
    elements: []Element,
    links: []LinkHit,
    anchors: std.StringHashMap(usize),
    source_map: SourceLineMap(Element),
    width: usize,

    pub fn deinit(self: *Document) void {
        const parent = self.arena.child_allocator;
        self.arena.deinit();
        parent.destroy(self.arena);
    }

    pub fn rowCount(self: *const Document) usize {
        return self.rows.len;
    }

    pub fn maxScroll(self: *const Document, viewport_rows: usize, scroll_beyond_last_line: bool) usize {
        if (scroll_beyond_last_line) return self.rows.len -| 1;
        return self.rows.len -| viewport_rows;
    }

    pub fn anchorElement(self: *const Document, fragment: []const u8) ?*const Element {
        const value = if (fragment.len > 0 and fragment[0] == '#') fragment[1..] else fragment;
        if (value.len == 0) return null;
        var iterator = self.anchors.iterator();
        while (iterator.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, value)) {
                return &self.elements[entry.value_ptr.*];
            }
        }
        return null;
    }

    pub fn linkAt(self: *const Document, row: usize, column: usize) ?[]const u8 {
        for (self.links) |link| {
            if (link.row == row and column >= link.start and column < link.end) return link.href;
        }
        return null;
    }
};

pub fn build(parent: Allocator, content: *const markdown.Content, width: usize) !Document {
    const arena = try parent.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(parent);
    errdefer {
        arena.deinit();
        parent.destroy(arena);
    }
    const allocator = arena.allocator();

    var rows = std.array_list.Managed(Row).init(allocator);
    var links = std.array_list.Managed(LinkHit).init(allocator);
    for (content.lines) |line| {
        try appendLineRows(allocator, &rows, &links, line, @max(width, 1));
    }

    var elements = std.array_list.Managed(Element).init(allocator);
    try elements.append(.{
        .line = -1,
        .top = 0,
        .height = 0,
        .content_top = 0,
        .content_height = 0,
        .source_end_line = -1,
        .block_id = 0,
    });

    var index: usize = 0;
    while (index < rows.items.len) {
        const block = rows.items[index].block;
        if (block.id == 0) {
            index += 1;
            continue;
        }
        const start = index;
        while (index < rows.items.len and rows.items[index].block.id == block.id) : (index += 1) {}
        const end = index;
        const source_line: f64 = @floatFromInt(block.source_line);
        const source_end: f64 = @floatFromInt(block.source_end_line orelse block.source_line);
        try elements.append(.{
            .line = source_line,
            .top = @floatFromInt(start),
            .height = @floatFromInt(end - start),
            .content_top = @floatFromInt(start),
            .content_height = @floatFromInt(end - start),
            .source_end_line = source_end,
            .block_id = block.id,
            .code = block.kind == .code_block,
            .kind = block.kind,
            .anchor = block.anchor,
        });
    }

    const owned_elements = try elements.toOwnedSlice();
    var anchors = std.StringHashMap(usize).init(allocator);
    for (owned_elements, 0..) |element, element_index| {
        if (element.anchor) |anchor| {
            const entry = try anchors.getOrPut(anchor);
            if (!entry.found_existing) entry.value_ptr.* = element_index;
        }
    }

    return .{
        .arena = arena,
        .rows = try rows.toOwnedSlice(),
        .elements = owned_elements,
        .links = try links.toOwnedSlice(),
        .anchors = anchors,
        .source_map = SourceLineMap(Element).init(owned_elements),
        .width = @max(width, 1),
    };
}

fn appendLineRows(
    allocator: Allocator,
    rows: *std.array_list.Managed(Row),
    links: *std.array_list.Managed(LinkHit),
    line: Line,
    width: usize,
) !void {
    if (line.rule) {
        const row_index = rows.items.len;
        try rows.append(.{
            .spans = line.spans,
            .continuation = line.continuation,
            .indent = line.indent,
            .rule = true,
            .block = line.block,
        });
        try collectLinks(allocator, links, row_index, line.spans);
        return;
    }
    if (line.no_wrap) {
        const row_index = rows.items.len;
        try rows.append(.{
            .spans = line.spans,
            .continuation = line.continuation,
            .indent = line.indent,
            .no_wrap = true,
            .block = line.block,
        });
        try collectLinks(allocator, links, row_index, line.spans);
        return;
    }

    const wrapped = try markdown.wrapLine(allocator, line, width);
    for (wrapped, 0..) |spans, row_index_in_line| {
        const row_spans = if (row_index_in_line == 0)
            spans
        else
            try continuationRow(allocator, line, spans);
        const row_index = rows.items.len;
        try rows.append(.{
            .spans = row_spans,
            .continuation = line.continuation,
            .indent = line.indent,
            .block = line.block,
        });
        try collectLinks(allocator, links, row_index, row_spans);
    }
}

fn continuationRow(allocator: Allocator, line: Line, spans: []const Span) ![]const Span {
    var result = std.array_list.Managed(Span).init(allocator);
    try result.appendSlice(line.continuation);
    var continuation_width: usize = 0;
    for (line.continuation) |span| continuation_width += markdown.textWidth(span.text);
    const padding = line.indent -| continuation_width;
    if (padding > 0) {
        const spaces = try allocator.alloc(u8, padding);
        @memset(spaces, ' ');
        try result.append(.{ .text = spaces });
    }
    try result.appendSlice(spans);
    return try result.toOwnedSlice();
}

fn collectLinks(
    allocator: Allocator,
    links: *std.array_list.Managed(LinkHit),
    row: usize,
    spans: []const Span,
) !void {
    var column: usize = 0;
    for (spans) |span| {
        const width = markdown.textWidth(span.text);
        if (span.link) |href| {
            if (href.len > 0) {
                try links.append(.{
                    .row = row,
                    .start = column,
                    .end = column + width,
                    .href = try allocator.dupe(u8, href),
                });
            }
        }
        column += width;
    }
}

test "previewDocument: blocks map to rows and source lines" {
    var content = try markdown.parseDocument(std.testing.allocator,
        \\# Title
        \\
        \\paragraph
        \\
        \\- item
    , .{});
    defer content.deinit();

    var document = try build(std.testing.allocator, &content, 40);
    defer document.deinit();

    try std.testing.expect(document.rowCount() > 0);
    try std.testing.expect(document.elements.len >= 4);
    const heading = document.elements[1];
    try std.testing.expectEqual(@as(f64, 0), heading.line);
    try std.testing.expectEqualStrings("title", heading.anchor.?);
}

test "previewDocument: links survive wrapping and heading anchors are indexed" {
    var content = try markdown.parseDocument(std.testing.allocator, "# Usage\n\nsee [the section](#usage) for details", .{});
    defer content.deinit();
    var document = try build(std.testing.allocator, &content, 14);
    defer document.deinit();

    try std.testing.expect(document.anchors.contains("usage"));
    var saw_link = false;
    for (document.links) |link| {
        if (std.mem.eql(u8, link.href, "#usage")) saw_link = true;
    }
    try std.testing.expect(saw_link);
    try std.testing.expect(document.anchorElement("#USAGE") != null);
}

test "previewDocument: long lines wrap and keep block geometry" {
    var content = try markdown.parseDocument(std.testing.allocator, "one two three four five six seven eight nine ten", .{});
    defer content.deinit();
    var document = try build(std.testing.allocator, &content, 10);
    defer document.deinit();
    try std.testing.expect(document.rowCount() > 1);
    try std.testing.expect(document.elements[1].height > 1);
}
