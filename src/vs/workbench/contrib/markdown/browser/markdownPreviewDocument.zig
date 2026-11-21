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

const ui = @import("ui");
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

/// One displayable image from the preview's catalog. `image_id` is the kitty
/// image id the view registered for this file.
pub const ImageSpec = struct {
    url: []const u8,
    width: usize,
    height: usize,
    image_id: u32,
};

pub const CellSize = struct {
    width_px: usize = 8,
    height_px: usize = 16,
};

pub const BuildOptions = struct {
    images: []const ImageSpec = &.{},
    cell: CellSize = .{},
    /// The protocol's row/column diacritics address at most this many cells.
    max_grid: usize = 297,
};

/// A block of rows reserved for an image. `row` is the document row of the
/// image's top-left cell; placeholders use the full `cols x rows` grid so a
/// partially scrolled image still lines up.
pub const ImagePlacement = struct {
    row: usize,
    col: usize = 0,
    cols: usize,
    rows: usize,
    image_id: u32,
};

pub const Document = struct {
    arena: *std.heap.ArenaAllocator,
    rows: []Row,
    elements: []Element,
    links: []LinkHit,
    images: []ImagePlacement,
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

pub fn build(
    parent: Allocator,
    content: *const markdown.Content,
    width: usize,
    options: BuildOptions,
) !Document {
    const arena = try parent.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(parent);
    errdefer {
        arena.deinit();
        parent.destroy(arena);
    }
    const allocator = arena.allocator();

    var rows = std.array_list.Managed(Row).init(allocator);
    var links = std.array_list.Managed(LinkHit).init(allocator);
    var images = std.array_list.Managed(ImagePlacement).init(allocator);
    for (content.lines) |line| {
        try appendLineRows(allocator, &rows, &links, &images, line, @max(width, 1), options);
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
        .images = try images.toOwnedSlice(),
        .anchors = anchors,
        .source_map = SourceLineMap(Element).init(owned_elements),
        .width = @max(width, 1),
    };
}

fn appendLineRows(
    allocator: Allocator,
    rows: *std.array_list.Managed(Row),
    links: *std.array_list.Managed(LinkHit),
    images: *std.array_list.Managed(ImagePlacement),
    line: Line,
    width: usize,
    options: BuildOptions,
) !void {
    if (!line.rule and !line.no_wrap and hasDisplayableImage(line, options.images)) {
        try appendLineSegments(allocator, rows, links, images, line, width, options);
        return;
    }
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

fn hasDisplayableImage(line: Line, specs: []const ImageSpec) bool {
    for (line.spans) |span| {
        const image = span.image orelse continue;
        if (findSpec(specs, image.url) != null) return true;
    }
    return false;
}

fn findSpec(specs: []const ImageSpec, url: []const u8) ?*const ImageSpec {
    for (specs) |*spec| {
        if (std.mem.eql(u8, spec.url, url)) return spec;
    }
    return null;
}

/// Splits a line at displayable images: text before an image wraps as usual,
/// the image reserves a block of blank rows at the content left edge, and text
/// after it continues on the next row. The browser flows an `<img>` inline; a
/// terminal cell grid has no replaced inline element, so the preview uses a
/// block substitution (documented in README.md and docs/terminal-ui.md).
fn appendLineSegments(
    allocator: Allocator,
    rows: *std.array_list.Managed(Row),
    links: *std.array_list.Managed(LinkHit),
    images: *std.array_list.Managed(ImagePlacement),
    line: Line,
    width: usize,
    options: BuildOptions,
) !void {
    var segment = std.array_list.Managed(Span).init(allocator);
    defer segment.deinit();

    for (line.spans) |span| {
        if (span.image) |image| {
            if (findSpec(options.images, image.url)) |spec| {
                if (segment.items.len > 0) {
                    try flushLineSegment(allocator, rows, links, line, segment.items, width);
                    segment.clearRetainingCapacity();
                }
                try appendImageBlock(rows, images, line, spec, width, options);
                continue;
            }
        }
        try segment.append(span);
    }
    if (segment.items.len > 0) {
        try flushLineSegment(allocator, rows, links, line, segment.items, width);
    }
}

fn flushLineSegment(
    allocator: Allocator,
    rows: *std.array_list.Managed(Row),
    links: *std.array_list.Managed(LinkHit),
    line: Line,
    spans: []const Span,
    width: usize,
) !void {
    var segment_line = line;
    segment_line.spans = try allocator.dupe(Span, spans);
    segment_line.rule = false;
    segment_line.no_wrap = false;
    const wrapped = try markdown.wrapLine(allocator, segment_line, width);
    for (wrapped, 0..) |row_spans, row_index_in_line| {
        const row_spans_final = if (row_index_in_line == 0)
            row_spans
        else
            try continuationRow(allocator, segment_line, row_spans);
        const row_index = rows.items.len;
        try rows.append(.{
            .spans = row_spans_final,
            .continuation = segment_line.continuation,
            .indent = segment_line.indent,
            .block = segment_line.block,
        });
        try collectLinks(allocator, links, row_index, row_spans_final);
    }
}

fn appendImageBlock(
    rows: *std.array_list.Managed(Row),
    images: *std.array_list.Managed(ImagePlacement),
    line: Line,
    spec: *const ImageSpec,
    width: usize,
    options: BuildOptions,
) !void {
    const cells = imageCells(spec, width, options);
    const start_row = rows.items.len;
    var index: usize = 0;
    while (index < cells.rows) : (index += 1) {
        try rows.append(.{
            .spans = &.{},
            .block = line.block,
        });
    }
    try images.append(.{
        .row = start_row,
        .col = 0,
        .cols = cells.cols,
        .rows = cells.rows,
        .image_id = spec.image_id,
    });
}

const ImageCells = struct { cols: usize, rows: usize };

fn imageCells(spec: *const ImageSpec, width: usize, options: BuildOptions) ImageCells {
    const cell_width = @max(options.cell.width_px, 1);
    const cell_height = @max(options.cell.height_px, 1);
    const max_grid = @max(@min(options.max_grid, ui.image.max_grid_index + 1), 1);
    const image_width = @max(spec.width, 1);
    const image_height = @max(spec.height, 1);
    const available = @max(width, 1);

    const natural_cols = @max((image_width + cell_width - 1) / cell_width, 1);
    var cols = @min(@min(available, natural_cols), max_grid);
    cols = @max(cols, 1);

    const scaled_width_px: f64 = @floatFromInt(cols * cell_width);
    const natural_width_px: f64 = @floatFromInt(image_width);
    const natural_height_px: f64 = @floatFromInt(image_height);
    const cell_height_px: f64 = @floatFromInt(cell_height);
    const rows_float = (natural_height_px * scaled_width_px / natural_width_px) / cell_height_px;
    var rows: usize = @intFromFloat(@max(1, @ceil(rows_float)));
    rows = @min(@max(rows, 1), max_grid);
    return .{ .cols = cols, .rows = rows };
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

    var document = try build(std.testing.allocator, &content, 40, .{});
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
    var document = try build(std.testing.allocator, &content, 14, .{});
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
    var document = try build(std.testing.allocator, &content, 10, .{});
    defer document.deinit();
    try std.testing.expect(document.rowCount() > 1);
    try std.testing.expect(document.elements[1].height > 1);
}

test "previewDocument: displayable images reserve block rows and placements" {
    var content = try markdown.parseDocument(std.testing.allocator,
        \\before ![shot](images/shot.png) after
        \\
        \\paragraph
    , .{});
    defer content.deinit();

    const specs = [_]ImageSpec{.{
        .url = "images/shot.png",
        .width = 80,
        .height = 40,
        .image_id = 7,
    }};
    var document = try build(std.testing.allocator, &content, 40, .{
        .images = &specs,
        .cell = .{ .width_px = 8, .height_px = 16 },
    });
    defer document.deinit();

    try std.testing.expectEqual(@as(usize, 1), document.images.len);
    const placement = document.images[0];
    try std.testing.expectEqual(@as(u32, 7), placement.image_id);
    try std.testing.expectEqual(@as(usize, 10), placement.cols);
    try std.testing.expectEqual(@as(usize, 3), placement.rows);
    try std.testing.expect(placement.row > 0);

    // The text before and after the image survives on separate rows, and the
    // image rows carry the paragraph block for source-line mapping.
    var saw_before = false;
    var saw_after = false;
    for (document.rows, 0..) |row, index| {
        for (row.spans) |span| {
            if (std.mem.indexOf(u8, span.text, "before") != null) saw_before = true;
            if (std.mem.indexOf(u8, span.text, "after") != null) saw_after = true;
        }
        if (index >= placement.row and index < placement.row + placement.rows) {
            try std.testing.expectEqual(placement.row > 0, row.block.id != 0);
        }
    }
    try std.testing.expect(saw_before);
    try std.testing.expect(saw_after);
}

test "previewDocument: images without a catalog spec keep their alt text" {
    var content = try markdown.parseDocument(std.testing.allocator, "![alttext](missing.png)", .{});
    defer content.deinit();
    var document = try build(std.testing.allocator, &content, 40, .{});
    defer document.deinit();
    try std.testing.expectEqual(@as(usize, 0), document.images.len);
    var saw_alt = false;
    for (document.rows) |row| {
        for (row.spans) |span| {
            if (std.mem.indexOf(u8, span.text, "alttext") != null) saw_alt = true;
        }
    }
    try std.testing.expect(saw_alt);
}
