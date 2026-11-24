//! Terminal renderer for hover and document-preview markdown.
//!
//! Hover contents are rendered with `IMarkdownRendererService`
//! (`src/vs/platform/markdown/browser/markdownRenderer.ts`), which is a
//! VS Code-owned wrapper around the vendored marked parser: it applies custom
//! renderers, converts the result to HTML, sanitizes it and inserts it into the
//! DOM. The terminal has no HTML or CSS engine, so this file parses with the
//! pinned third-party `markdown-zig` CommonMark + GFM library (`mdast`) and
//! renders the same structure to styled cells. The observable structure of
//! hover markdown is kept: paragraphs, headings, nested and task lists, block
//! quotes, fenced and indented code blocks, tables, thematic breaks, emphasis,
//! strikethrough, inline code and links. Fenced code blocks are tokenized with
//! the editor's TextMate grammars when the fence language is known.
//!
//! Terminal substitutions, documented in `README.md` and
//! `docs/terminal-ui.md`:
//!  * a link renders its text underlined and, when the URL differs, the URL in
//!    dim text because cells cannot open a link;
//!  * images render their alt text (there is no image protocol);
//!  * tables render as box-drawing grids with width-capped columns;
//!  * raw HTML is dropped (there is no sanitizer/HTML renderer);
//!  * a soft line break is preserved instead of being joined into the
//!    paragraph, because hover contents in the TUI are already line-oriented;
//!  * a tab is expanded to four spaces so cell width and painted width agree;
//!  * one blank line separates sibling blocks, substituting for the margins of
//!    the browser's block elements.
//!
//! `Mode.document` additionally stamps `data-line`-style block metadata and
//! heading anchors and joins soft line breaks, mirroring the Markdown preview's
//! `code-line` output. The metadata is ignored by hover. Strings are copied
//! into the renderer's arena, so callers may drop the markdown string after
//! `parse` returns.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ui = @import("ui");
const markdown = @import("markdown");
const CursorColumns = @import("../core/cursorColumns.zig").CursorColumns;
const IState = @import("../languages.zig").IState;
const TokenPacked = @import("../tokens/lineTokens.zig").TokenPacked;
const TokenMetadata = @import("../encodedTokenAttributes.zig").TokenMetadata;
const textMateTokenizer = @import("../model/tokens/textMateTokenizer.zig");
const TokenizationRegistry = @import("../tokenizationRegistry.zig").TokenizationRegistry;
const slugify = @import("slugify.zig");

const Node = markdown.Node;
const NodeData = markdown.NodeData;
const Align = markdown.node.Align;

const tab_width: usize = 4;
const text_color = ui.Color{ .r = 204, .g = 204, .b = 204 };
const code_color = ui.Color{ .r = 215, .g = 186, .b = 125 };
/// Test fixture only; production code resolves `textCodeBlock.background` from
/// the active theme (see `ParseOptions.code_background`).
const test_code_background = ui.Color{ .r = 30, .g = 30, .b = 30 };
const code_block_color = ui.Color{ .r = 212, .g = 212, .b = 212 };
const link_color = ui.Color{ .r = 55, .g = 148, .b = 255 };
const heading_color = ui.Color{ .r = 235, .g = 235, .b = 235 };
const rule_color = ui.Color{ .r = 90, .g = 90, .b = 90 };

/// Nesting guards. `markdown-zig` already bounds block nesting at 512; the
/// renderer caps its own recursion so a hostile document cannot exhaust the
/// terminal stack while painting.
const max_block_depth: usize = 64;
const max_inline_depth: usize = 64;

/// Tables are laid out without knowing the hover width. Columns are capped so
/// a single long cell cannot make the natural width unbounded; the participant
/// clips a table that is still wider than the hover box.
const max_table_column_width: usize = 24;
const max_table_width: usize = 96;

const RenderError = Allocator.Error;

/// A document-mode image reference. The text of the span is the alt text so a
/// renderer without image support still shows readable content.
pub const Image = struct {
    url: []const u8,
    alt: []const u8,
    title: ?[]const u8 = null,
};

pub const Span = struct {
    text: []const u8,
    style: ui.Style = .{},
    /// Fenced/indented code. Wrapping keeps leading spaces for code spans even
    /// when the theme leaves their background transparent.
    is_code: bool = false,
    /// Present on link text so the document preview can hit-test `#fragment`
    /// links. Hover ignores it.
    link: ?[]const u8 = null,
    /// Present on document-mode image spans. The preview document layout
    /// replaces the alt text with an image block when the file is displayable.
    image: ?Image = null,
};

pub const Mode = enum { hover, document };

/// HTML-like block kinds used by the terminal document preview. Upstream
/// attaches `class="code-line" data-line="..."` to the corresponding tokens.
pub const BlockKind = enum(u8) {
    none,
    heading1,
    heading2,
    heading3,
    heading4,
    heading5,
    heading6,
    paragraph,
    block_quote,
    list_item,
    code_block,
    table,
    table_row,
    thematic_break,
    footnote,
};

pub const BlockInfo = struct {
    /// Zero means no block (blank separator rows).
    id: u32 = 0,
    source_line: usize = 0,
    source_end_line: ?usize = null,
    kind: BlockKind = .none,
    depth: u16 = 0,
    anchor: ?[]const u8 = null,
};

pub const Line = struct {
    spans: []Span = &.{},
    /// Prefix spans repeated on wrapped continuation rows (block-quote bars,
    /// list indentation). Empty for unindented prose.
    continuation: []Span = &.{},
    /// Cells kept for the continuation of a wrapped line. For a rule line this
    /// is the width of `spans`; the widget draws the rule after the prefix.
    indent: usize = 0,
    /// A horizontal rule; the widget draws it to the available width.
    rule: bool = false,
    /// A table row: keep it on one physical row and clip it instead of wrapping.
    no_wrap: bool = false,
    /// Document-mode source/block metadata. Hover leaves this at the default.
    block: BlockInfo = .{},

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

const Definition = struct {
    url: []const u8,
    title: ?[]const u8,
};

const ParseState = struct {
    next_block_id: u32 = 1,
    slugs: slugify.SlugBuilder,
};

pub const DiagramRenderer = struct {
    context: *anyopaque,
    lookup: *const fn (*anyopaque, []const u8) ?[]const u8,
};

const Context = struct {
    mermaid: ?DiagramRenderer = null,
    prefix: []const u8 = "",
    prefix_style: ui.Style = .{},
    /// Language used for a fenced code block without an info string.
    code_fence_fallback_language: []const u8 = "plaintext",
    /// Theme-resolved `textCodeBlock.background`; null keeps the surface
    /// background (hover popup, preview row) visible.
    code_background: ?ui.Color = null,
    mode: Mode = .hover,
    /// Upstream `markdown.preview.breaks`: render soft line breaks as rows.
    preview_breaks: bool = false,
    block: BlockInfo = .{},
    state: ?*ParseState = null,

    fn withoutBlock(self: Context) Context {
        var result = self;
        result.block = .{};
        return result;
    }

    fn withBlock(self: Context, block: BlockInfo) Context {
        var result = self;
        result.block = block;
        return result;
    }

    fn withPrefix(self: Context, prefix: []const u8, style: ui.Style) Context {
        var result = self;
        result.prefix = prefix;
        result.prefix_style = style;
        return result;
    }
};

pub const ParseOptions = struct {
    mermaid: ?DiagramRenderer = null,
    /// Upstream falls back to the editor's language when a fence has no info
    /// string. The participant supplies the model language here.
    code_fence_fallback_language: []const u8 = "plaintext",
    /// Theme-resolved `textCodeBlock.background`. Null leaves code spans
    /// transparent so the hover widget background shows through.
    code_background: ?ui.Color = null,
    mode: Mode = .hover,
    /// Document mode only: render source soft breaks as hard rows.
    preview_breaks: bool = false,
};

pub fn parse(parent: Allocator, source: []const u8) !Content {
    return parseWithOptions(parent, source, .{});
}

/// Parses with the document metadata used by the Markdown preview.
pub fn parseDocument(parent: Allocator, source: []const u8, options: ParseOptions) !Content {
    var document_options = options;
    document_options.mode = .document;
    return parseWithOptions(parent, source, document_options);
}

pub fn parseWithOptions(parent: Allocator, source: []const u8, options: ParseOptions) !Content {
    var arena = std.heap.ArenaAllocator.init(parent);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    const root = markdown.parse(allocator, source, .{ .gfm = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Invalid UTF-8 and pathological nesting are not worth failing a
        // hover over; keep the text readable instead.
        else => {
            const fallback_lines = try plainText(allocator, source);
            return .{ .arena = arena, .lines = fallback_lines };
        },
    };

    var definitions = std.StringHashMap(Definition).init(allocator);
    try collectDefinitions(&definitions, root);

    var state = ParseState{ .slugs = slugify.SlugBuilder.init(allocator) };
    var lines = std.array_list.Managed(Line).init(allocator);
    try renderBlocks(allocator, &lines, &definitions, root, .{
        .mermaid = options.mermaid,
        .code_fence_fallback_language = options.code_fence_fallback_language,
        .code_background = options.code_background,
        .mode = options.mode,
        .preview_breaks = options.preview_breaks,
        .state = &state,
    }, true, 0);
    const owned_lines = try lines.toOwnedSlice();
    return .{ .arena = arena, .lines = owned_lines };
}

fn plainText(allocator: Allocator, source: []const u8) ![]Line {
    var lines = std.array_list.Managed(Line).init(allocator);
    var iterator = std.mem.splitScalar(u8, source, '\n');
    while (iterator.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const expanded = try expandTabs(allocator, line);
        var spans = std.array_list.Managed(Span).init(allocator);
        if (expanded.len > 0) {
            try spans.append(.{ .text = expanded, .style = .{ .color = text_color } });
        }
        try lines.append(.{ .spans = spans.items });
    }
    return lines.items;
}

fn collectDefinitions(definitions: *std.StringHashMap(Definition), node: *const Node) RenderError!void {
    if (node.data == .definition) {
        const definition = node.data.definition;
        const entry = try definitions.getOrPut(definition.identifier);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{ .url = definition.url, .title = definition.title };
        }
    }
    var child = node.first_child;
    while (child) |current| : (child = current.next) {
        try collectDefinitions(definitions, current);
    }
}

fn nextBlock(ctx: Context, node: *const Node, kind: BlockKind, depth: usize) BlockInfo {
    if (ctx.mode != .document) return .{};
    const state = ctx.state orelse return .{};
    const id = state.next_block_id;
    state.next_block_id += 1;
    const position = node.position orelse return .{
        .id = id,
        .kind = kind,
        .depth = @intCast(@min(depth, std.math.maxInt(u16))),
    };
    const start: usize = position.start.line -| 1;
    const end: usize = @max(start, position.end.line -| 1);
    return .{
        .id = id,
        .source_line = start,
        .source_end_line = end,
        .kind = kind,
        .depth = @intCast(@min(depth, std.math.maxInt(u16))),
    };
}

fn headingKind(depth: u8) BlockKind {
    return switch (depth) {
        1 => .heading1,
        2 => .heading2,
        3 => .heading3,
        4 => .heading4,
        5 => .heading5,
        else => .heading6,
    };
}

fn headingStyle(kind: BlockKind) ui.Style {
    var style = ui.Style{ .bold = true, .color = heading_color };
    if (kind == .heading1) style.underline = true;
    if (kind == .heading5 or kind == .heading6) style.dim = true;
    return style;
}

fn headingAnchor(ctx: Context, node: *const Node) !?[]const u8 {
    if (ctx.mode != .document) return null;
    const state = ctx.state orelse return null;
    var text = std.array_list.Managed(u8).init(ctx.state.?.slugs.allocator);
    defer text.deinit();
    try flattenText(&text, node);
    const trimmed = std.mem.trim(u8, text.items, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try state.slugs.add(trimmed);
}

fn isDocument(ctx: Context) bool {
    return ctx.mode == .document;
}

fn makeLine(
    allocator: Allocator,
    ctx: Context,
    spans: []const Span,
    extra_indent: usize,
    rule: bool,
    no_wrap: bool,
) !Line {
    var all = std.array_list.Managed(Span).init(allocator);
    var continuation = std.array_list.Managed(Span).init(allocator);
    if (ctx.prefix.len > 0) {
        const prefix = Span{ .text = ctx.prefix, .style = ctx.prefix_style };
        try all.append(prefix);
        try continuation.append(prefix);
    }
    try all.appendSlice(spans);
    return .{
        .spans = try all.toOwnedSlice(),
        .continuation = try continuation.toOwnedSlice(),
        .indent = textWidth(ctx.prefix) + extra_indent,
        .rule = rule,
        .no_wrap = no_wrap,
        .block = ctx.block,
    };
}

fn prependSpan(allocator: Allocator, line: *Line, text: []const u8, style: ui.Style) !void {
    if (text.len == 0) return;
    const spans = try allocator.alloc(Span, line.spans.len + 1);
    spans[0] = .{ .text = text, .style = style };
    @memcpy(spans[1..], line.spans);
    line.spans = spans;
}

fn prependContinuation(allocator: Allocator, line: *Line, text: []const u8, style: ui.Style) !void {
    if (text.len == 0) return;
    const spans = try allocator.alloc(Span, line.continuation.len + 1);
    spans[0] = .{ .text = text, .style = style };
    @memcpy(spans[1..], line.continuation);
    line.continuation = spans;
}

fn spaces(allocator: Allocator, count: usize) ![]const u8 {
    const result = try allocator.alloc(u8, count);
    @memset(result, ' ');
    return result;
}

fn expandTabs(allocator: Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '\t') == null) {
        return try allocator.dupe(u8, text);
    }
    var out = std.array_list.Managed(u8).init(allocator);
    for (text) |ch| {
        if (ch == '\t') {
            try out.appendNTimes(' ', tab_width);
        } else {
            try out.append(ch);
        }
    }
    return try out.toOwnedSlice();
}

fn renderBlocks(
    allocator: Allocator,
    out: *std.array_list.Managed(Line),
    definitions: *const std.StringHashMap(Definition),
    parent: *const Node,
    ctx: Context,
    separate_blocks: bool,
    depth: usize,
) RenderError!void {
    if (depth > max_block_depth) return;
    var emitted: usize = 0;
    var child = parent.first_child;
    while (child) |node| : (child = node.next) {
        var block_lines = std.array_list.Managed(Line).init(allocator);
        try renderBlock(allocator, &block_lines, definitions, node, ctx, depth);
        if (block_lines.items.len == 0) continue;
        if (emitted > 0 and separate_blocks) {
            try out.append(try makeLine(allocator, ctx, &.{}, 0, false, false));
        }
        try out.appendSlice(block_lines.items);
        emitted += 1;
    }
}

fn renderBlock(
    allocator: Allocator,
    out: *std.array_list.Managed(Line),
    definitions: *const std.StringHashMap(Definition),
    node: *const Node,
    ctx: Context,
    depth: usize,
) RenderError!void {
    if (depth > max_block_depth) return;
    switch (node.data) {
        .paragraph => try renderParagraph(allocator, out, definitions, node, ctx, depth),
        .heading => try renderHeading(allocator, out, definitions, node, ctx, depth),
        .code => try renderCode(allocator, out, node, ctx, depth),
        .thematic_break => {
            const block = nextBlock(ctx, node, .thematic_break, depth);
            try out.append(try makeLine(allocator, ctx.withBlock(block), &.{}, 0, true, false));
        },
        .blockquote => try renderQuote(allocator, out, definitions, node, ctx, depth),
        .list => try renderList(allocator, out, definitions, node, ctx, depth),
        .table => try renderTable(allocator, out, definitions, node, ctx, depth),
        .footnote_definition => try renderFootnoteDefinition(allocator, out, definitions, node, ctx, depth),
        .html, .definition, .yaml, .toml, .math => {},
        .mdx_flow_expression, .mdx_text_expression, .mdx_jsx_flow_element, .mdx_jsx_text_element => {},
        else => {},
    }
}

fn renderParagraph(
    allocator: Allocator,
    out: *std.array_list.Managed(Line),
    definitions: *const std.StringHashMap(Definition),
    node: *const Node,
    ctx: Context,
    depth: usize,
) !void {
    const block_ctx = ctx.withBlock(nextBlock(ctx, node, .paragraph, depth));
    var builder = InlineBuilder.init(allocator, block_ctx, out);
    try renderInlineChildren(allocator, &builder, node, .{ .color = text_color }, definitions, depth);
    try builder.finish();
}

fn renderHeading(
    allocator: Allocator,
    out: *std.array_list.Managed(Line),
    definitions: *const std.StringHashMap(Definition),
    node: *const Node,
    ctx: Context,
    depth: usize,
) !void {
    const kind = headingKind(node.data.heading.depth);
    var block = nextBlock(ctx, node, kind, depth);
    block.anchor = try headingAnchor(ctx, node);
    const block_ctx = ctx.withBlock(block);
    var builder = InlineBuilder.init(allocator, block_ctx, out);
    try renderInlineChildren(allocator, &builder, node, headingStyle(kind), definitions, depth);
    try builder.finish();
    if (isDocument(ctx) and (kind == .heading1 or kind == .heading2)) {
        try out.append(try makeLine(allocator, block_ctx, &.{}, 0, true, false));
    }
}

fn renderCode(
    allocator: Allocator,
    out: *std.array_list.Managed(Line),
    node: *const Node,
    ctx: Context,
    depth: usize,
) RenderError!void {
    const code = node.data.code;
    var value = code.value;
    if (std.mem.endsWith(u8, value, "\n")) value = value[0 .. value.len - 1];
    if (value.len == 0) return;

    var block = nextBlock(ctx, node, .code_block, depth);
    if (block.id != 0) {
        var line_count: usize = 1;
        for (value) |byte| {
            if (byte == '\n') line_count += 1;
        }
        block.source_end_line = block.source_line + line_count - 1;
    }
    const block_ctx = ctx.withBlock(block);

    const language = resolveCodeFenceLanguage(code.lang, ctx.code_fence_fallback_language);
    if (ctx.mode == .document and std.ascii.eqlIgnoreCase(code.lang orelse "", "mermaid")) {
        if (ctx.mermaid) |renderer| {
            if (renderer.lookup(renderer.context, value)) |diagram| {
                var rows = std.mem.splitScalar(u8, std.mem.trimEnd(u8, diagram, "\r\n"), '\n');
                while (rows.next()) |row| try appendPlainCodeLine(allocator, out, block_ctx, row);
                return;
            }
        }
    }
    const support_opt = textMateTokenizer.create(allocator, language) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    defer if (support_opt) |support| support.dispose();

    var state: ?IState = null;
    if (support_opt) |support| {
        state = support.getInitialState(allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
    }
    var use_highlight = state != null;

    var iterator = std.mem.splitScalar(u8, value, '\n');
    while (iterator.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const expanded = try expandTabs(allocator, line);
        if (use_highlight) {
            const support = support_opt.?;
            const result = support.tokenizeEncoded(allocator, expanded, false, state.?) catch {
                use_highlight = false;
                try appendPlainCodeLine(allocator, out, block_ctx, expanded);
                continue;
            };
            state = result.endState;
            try appendHighlightedCodeLine(allocator, out, block_ctx, expanded, result.tokens);
        } else {
            try appendPlainCodeLine(allocator, out, block_ctx, expanded);
        }
    }
}

fn appendPlainCodeLine(
    allocator: Allocator,
    out: *std.array_list.Managed(Line),
    ctx: Context,
    expanded: []const u8,
) !void {
    const text = try std.mem.concat(allocator, u8, &.{ "  ", expanded });
    const spans = try allocator.alloc(Span, 1);
    spans[0] = .{ .text = text, .style = codeBlockStyle(ctx), .is_code = true };
    try out.append(try makeLine(allocator, ctx, spans, 0, false, false));
}

fn appendHighlightedCodeLine(
    allocator: Allocator,
    out: *std.array_list.Managed(Line),
    ctx: Context,
    expanded: []const u8,
    tokens: []const TokenPacked,
) !void {
    var spans = std.array_list.Managed(Span).init(allocator);
    try spans.append(.{ .text = "  ", .style = codeBlockStyle(ctx), .is_code = true });

    var start: usize = 0;
    for (tokens, 0..) |token, index| {
        const next = if (index + 1 < tokens.len) tokens[index + 1].endOffset else expanded.len;
        const end = @min(@max(start, next), expanded.len);
        if (end > start) {
            try spans.append(.{
                .text = expanded[start..end],
                .style = tokenStyle(ctx, token.metadata),
                .is_code = true,
            });
        }
        start = end;
    }
    if (start < expanded.len) {
        try spans.append(.{ .text = expanded[start..], .style = codeBlockStyle(ctx), .is_code = true });
    }

    try out.append(try makeLine(allocator, ctx, try spans.toOwnedSlice(), 0, false, false));
}

fn codeBlockStyle(ctx: Context) ui.Style {
    return .{ .color = code_block_color, .background = ctx.code_background };
}

fn tokenStyle(ctx: Context, metadata: TokenMetadata) ui.Style {
    return .{
        .color = tokenColor(metadata.foreground) orelse code_block_color,
        .background = ctx.code_background,
        .bold = metadata.fontStyle.bold,
        .italic = metadata.fontStyle.italic,
        .underline = metadata.fontStyle.underline,
        .strikethrough = metadata.fontStyle.strikethrough,
    };
}

/// Resolves a token color through the active theme's color map. The fixed
/// palette is only a fallback for tools that run without a theme.
fn tokenColor(foreground: u9) ?ui.Color {
    if (TokenizationRegistry.instance.getColorMap()) |color_map| {
        if (foreground >= color_map.len) return null;
        const color = color_map[foreground];
        return .{ .r = color.r, .g = color.g, .b = color.b };
    }
    const rgb = switch (foreground) {
        5 => [3]u8{ 106, 153, 85 }, // comment
        6 => [3]u8{ 206, 145, 120 }, // string
        7 => [3]u8{ 209, 105, 105 }, // regexp/invalid
        8 => [3]u8{ 197, 134, 192 }, // keyword/storage
        9 => [3]u8{ 181, 206, 168 }, // constant
        10 => [3]u8{ 220, 220, 170 }, // function
        11 => [3]u8{ 78, 201, 176 }, // type
        12 => [3]u8{ 156, 220, 254 }, // variable
        else => return null,
    };
    return .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
}

fn resolveCodeFenceLanguage(raw: ?[]const u8, fallback: []const u8) []const u8 {
    const raw_trimmed = if (raw) |value| std.mem.trim(u8, value, " \t\r\n") else "";
    const source = if (raw_trimmed.len == 0) fallback else raw_trimmed;
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (trimmed.len == 0) return "plaintext";
    var end: usize = 0;
    while (end < trimmed.len and trimmed[end] != ' ' and trimmed[end] != '\t') : (end += 1) {}
    const name = trimmed[0..end];

    const aliases = .{
        .{ "zig", "zig" },
        .{ "json", "json" },
        .{ "jsonc", "jsonc" },
        .{ "javascript", "javascript" },
        .{ "js", "javascript" },
        .{ "mjs", "javascript" },
        .{ "cjs", "javascript" },
        .{ "jsx", "javascriptreact" },
        .{ "javascriptreact", "javascriptreact" },
        .{ "typescript", "typescript" },
        .{ "ts", "typescript" },
        .{ "mts", "typescript" },
        .{ "cts", "typescript" },
        .{ "tsx", "typescriptreact" },
        .{ "typescriptreact", "typescriptreact" },
        .{ "python", "python" },
        .{ "py", "python" },
        .{ "python3", "python" },
        .{ "rust", "rust" },
        .{ "rs", "rust" },
        .{ "go", "go" },
        .{ "golang", "go" },
        .{ "c", "c" },
        .{ "h", "c" },
        .{ "cpp", "cpp" },
        .{ "c++", "cpp" },
        .{ "cc", "cpp" },
        .{ "cxx", "cpp" },
        .{ "hpp", "cpp" },
        .{ "java", "java" },
        .{ "html", "html" },
        .{ "htm", "html" },
        .{ "css", "css" },
        .{ "scss", "scss" },
        .{ "markdown", "markdown" },
        .{ "md", "markdown" },
        .{ "mdown", "markdown" },
        .{ "yaml", "yaml" },
        .{ "yml", "yaml" },
        .{ "toml", "toml" },
        .{ "shellscript", "shellscript" },
        .{ "sh", "shellscript" },
        .{ "bash", "shellscript" },
        .{ "shell", "shellscript" },
        .{ "zsh", "shellscript" },
    };
    inline for (aliases) |entry| {
        if (std.ascii.eqlIgnoreCase(entry[0], name)) return entry[1];
    }
    return "plaintext";
}

fn renderQuote(
    allocator: Allocator,
    out: *std.array_list.Managed(Line),
    definitions: *const std.StringHashMap(Definition),
    node: *const Node,
    ctx: Context,
    depth: usize,
) RenderError!void {
    const prefix = try std.mem.concat(allocator, u8, &.{ ctx.prefix, "│ " });
    const child_ctx = ctx.withPrefix(prefix, .{ .dim = true, .color = rule_color });
    var lines = std.array_list.Managed(Line).init(allocator);
    try renderBlocks(allocator, &lines, definitions, node, child_ctx, true, depth + 1);
    if (lines.items.len == 0) {
        const block = nextBlock(ctx, node, .block_quote, depth);
        try out.append(try makeLine(allocator, child_ctx.withBlock(block), &.{}, 0, false, false));
    } else {
        try out.appendSlice(lines.items);
    }
}

fn renderList(
    allocator: Allocator,
    out: *std.array_list.Managed(Line),
    definitions: *const std.StringHashMap(Definition),
    node: *const Node,
    ctx: Context,
    depth: usize,
) RenderError!void {
    const list = node.data.list;
    var item_index: usize = 0;
    var child = node.first_child;
    while (child) |item| : (child = item.next) {
        if (item.data != .list_item) {
            // markdown-zig can keep a block that follows the list (for example
            // a block quote) as a child of the list container. Render it as a
            // sibling block after the items instead of dropping it.
            var extra_lines = std.array_list.Managed(Line).init(allocator);
            try renderBlock(allocator, &extra_lines, definitions, item, ctx, depth);
            if (extra_lines.items.len == 0) continue;
            if (out.items.len > 0) {
                try out.append(try makeLine(allocator, ctx, &.{}, 0, false, false));
            }
            try out.appendSlice(extra_lines.items);
            continue;
        }

        if (item_index > 0 and list.spread) {
            try out.append(try makeLine(allocator, ctx.withoutBlock(), &.{}, 0, false, false));
        }

        const item_block = nextBlock(ctx, item, .list_item, depth + 1);
        const item_ctx = ctx.withBlock(item_block);
        const item_data = item.data.list_item;
        const marker: []const u8 = if (item_data.checked) |checked|
            (if (checked) "[x] " else "[ ] ")
        else if (list.ordered)
            try std.fmt.allocPrint(allocator, "{d}. ", .{(list.start orelse 1) + item_index})
        else
            "• ";
        const marker_width = textWidth(marker);
        const marker_style = ui.Style{ .color = text_color };

        var item_lines = std.array_list.Managed(Line).init(allocator);
        try renderBlocks(allocator, &item_lines, definitions, item, ctx, list.spread, depth + 1);
        for (item_lines.items) |*line| {
            if (line.block.id == 0) line.block = item_block;
        }

        if (item_lines.items.len == 0) {
            const spans = try allocator.alloc(Span, 1);
            spans[0] = .{ .text = marker, .style = marker_style };
            try out.append(try makeLine(allocator, item_ctx, spans, marker_width, false, false));
            item_index += 1;
            continue;
        }

        const marker_spaces = try spaces(allocator, marker_width);
        const first_is_list = item.first_child != null and item.first_child.?.data == .list;
        if (first_is_list) {
            // A list item may start directly with a nested list. Put the outer
            // marker on its own line so the nested marker is not doubled.
            const marker_spans = try allocator.alloc(Span, 1);
            marker_spans[0] = .{ .text = marker, .style = marker_style };
            try out.append(try makeLine(allocator, item_ctx, marker_spans, marker_width, false, false));
            for (item_lines.items) |*line| {
                try prependSpan(allocator, line, marker_spaces, .{});
                try prependContinuation(allocator, line, marker_spaces, .{});
                line.indent += marker_width;
            }
        } else {
            for (item_lines.items, 0..) |*line, line_index| {
                if (line_index == 0) {
                    try prependSpan(allocator, line, marker, marker_style);
                } else {
                    try prependSpan(allocator, line, marker_spaces, .{});
                }
                try prependContinuation(allocator, line, marker_spaces, .{});
                line.indent += marker_width;
            }
        }

        try out.appendSlice(item_lines.items);
        item_index += 1;
    }
}

fn renderFootnoteDefinition(
    allocator: Allocator,
    out: *std.array_list.Managed(Line),
    definitions: *const std.StringHashMap(Definition),
    node: *const Node,
    ctx: Context,
    depth: usize,
) RenderError!void {
    const definition = node.data.footnote_definition;
    const prefix = try std.fmt.allocPrint(allocator, "{s}[^{s}]: ", .{ ctx.prefix, definition.label });
    const child_ctx = ctx.withPrefix(prefix, .{ .dim = true, .color = text_color });
    const block = nextBlock(ctx, node, .footnote, depth);
    var lines = std.array_list.Managed(Line).init(allocator);
    try renderBlocks(allocator, &lines, definitions, node, child_ctx, false, depth + 1);
    if (lines.items.len == 0) {
        try out.append(try makeLine(allocator, child_ctx.withBlock(block), &.{}, 0, false, false));
    } else {
        for (lines.items) |*line| {
            if (line.block.id == 0) line.block = block;
        }
        try out.appendSlice(lines.items);
    }
}

const Cell = struct {
    spans: []Span,
    width: usize,
};

fn renderTable(
    allocator: Allocator,
    out: *std.array_list.Managed(Line),
    definitions: *const std.StringHashMap(Definition),
    node: *const Node,
    ctx: Context,
    depth: usize,
) RenderError!void {
    const alignments = node.data.table.align_;

    var rows = std.array_list.Managed([]Cell).init(allocator);
    var row_nodes = std.array_list.Managed(*const Node).init(allocator);
    var row_node = node.first_child;
    while (row_node) |row| : (row_node = row.next) {
        if (row.data != .table_row) continue;
        try row_nodes.append(row);
        var cells = std.array_list.Managed(Cell).init(allocator);
        var cell_node = row.first_child;
        while (cell_node) |cell| : (cell_node = cell.next) {
            if (cell.data != .table_cell) continue;
            var scratch = std.array_list.Managed(Line).init(allocator);
            var builder = InlineBuilder.init(allocator, .{}, &scratch);
            builder.replace_newline = true;
            try renderInlineChildren(allocator, &builder, cell, .{ .color = text_color }, definitions, depth);
            const spans = try builder.takeSpans();
            try cells.append(.{ .spans = spans, .width = spansWidth(spans) });
        }
        try rows.append(try cells.toOwnedSlice());
    }

    if (rows.items.len == 0) return;
    const column_count = rows.items[0].len;
    if (column_count == 0) return;

    var widths = try allocator.alloc(usize, column_count);
    @memset(widths, 1);
    for (rows.items) |row| {
        for (row, 0..) |cell, column| {
            if (column >= column_count) break;
            widths[column] = @max(widths[column], @min(cell.width, max_table_column_width));
        }
    }
    shrinkTable(widths);

    const table_block = nextBlock(ctx, node, .table, depth);
    const table_ctx = ctx.withBlock(table_block);
    const header_block = nextBlock(ctx, row_nodes.items[0], .table_row, depth + 1);
    try out.append(try makeLine(allocator, table_ctx, try borderSpans(allocator, "┌", "┬", "┐", widths), 0, false, true));
    try out.append(try makeLine(allocator, ctx.withBlock(header_block), try rowSpans(allocator, rows.items[0], widths, alignments, true), 0, false, true));
    try out.append(try makeLine(allocator, table_ctx, try borderSpans(allocator, "├", "┼", "┤", widths), 0, false, true));
    for (rows.items[1..], 1..) |row, row_index| {
        const block = if (row_index < row_nodes.items.len)
            nextBlock(ctx, row_nodes.items[row_index], .table_row, depth + 1)
        else
            table_block;
        try out.append(try makeLine(allocator, ctx.withBlock(block), try rowSpans(allocator, row, widths, alignments, false), 0, false, true));
    }
    try out.append(try makeLine(allocator, table_ctx, try borderSpans(allocator, "└", "┴", "┘", widths), 0, false, true));
}

fn spansWidth(spans: []const Span) usize {
    var width: usize = 0;
    for (spans) |span| width += textWidth(span.text);
    return width;
}

fn tableWidth(widths: []const usize) usize {
    var total: usize = 1; // left border
    for (widths) |width| total += width + 2; // one space on each side
    total += widths.len - 1; // column separators
    total += 1; // right border
    return total;
}

fn shrinkTable(widths: []usize) void {
    while (tableWidth(widths) > max_table_width) {
        var widest: ?usize = null;
        var widest_width: usize = 1;
        for (widths, 0..) |width, index| {
            if (width > widest_width) {
                widest_width = width;
                widest = index;
            }
        }
        const index = widest orelse break;
        widths[index] -= 1;
    }
}

fn borderSpans(
    allocator: Allocator,
    left: []const u8,
    middle: []const u8,
    right: []const u8,
    widths: []const usize,
) ![]Span {
    var text = std.array_list.Managed(u8).init(allocator);
    try text.appendSlice(left);
    for (widths, 0..) |width, index| {
        var count: usize = 0;
        while (count < width + 2) : (count += 1) try text.appendSlice("─");
        if (index + 1 < widths.len) try text.appendSlice(middle);
    }
    try text.appendSlice(right);

    const spans = try allocator.alloc(Span, 1);
    spans[0] = .{ .text = try text.toOwnedSlice(), .style = .{ .color = rule_color } };
    return spans;
}

fn rowSpans(
    allocator: Allocator,
    cells: []const Cell,
    widths: []const usize,
    alignments: []const Align,
    header: bool,
) ![]Span {
    const border_style = ui.Style{ .color = rule_color };
    var spans = std.array_list.Managed(Span).init(allocator);
    try spans.append(.{ .text = "│", .style = border_style });

    for (widths, 0..) |width, column| {
        const cell = if (column < cells.len) cells[column] else Cell{ .spans = &.{}, .width = 0 };
        const clipped = try truncateSpans(allocator, cell.spans, width);
        const clipped_width = spansWidth(clipped);
        const padding = width -| clipped_width;
        const alignment: Align = if (column < alignments.len) alignments[column] else .none;
        const left_padding = switch (alignment) {
            .right => padding,
            .center => padding / 2,
            else => 0,
        };
        const right_padding = padding - left_padding;

        try spans.append(.{ .text = " ", .style = border_style });
        if (left_padding > 0) {
            try spans.append(.{ .text = try spaces(allocator, left_padding), .style = .{ .color = text_color } });
        }
        for (clipped) |span| {
            var style = span.style;
            if (header) style.bold = true;
            try spans.append(.{ .text = span.text, .style = style });
        }
        if (right_padding > 0) {
            try spans.append(.{ .text = try spaces(allocator, right_padding), .style = .{ .color = text_color } });
        }
        try spans.append(.{ .text = " ", .style = border_style });
        try spans.append(.{ .text = "│", .style = border_style });
    }

    return try spans.toOwnedSlice();
}

fn truncateSpans(allocator: Allocator, spans: []const Span, limit: usize) ![]Span {
    var result = std.array_list.Managed(Span).init(allocator);
    var used: usize = 0;
    for (spans) |span| {
        if (used >= limit) break;
        const remaining = limit - used;
        const take = splitAtWidth(span.text, remaining);
        if (take == 0) break;
        if (take < span.text.len) {
            // Reserve one cell for the ellipsis so a truncated cell ends in
            // "…" instead of silently losing its last glyph.
            const reserve: usize = if (remaining > 1) 1 else 0;
            const cut = splitAtWidth(span.text, remaining - reserve);
            if (cut > 0) {
                try result.append(.{ .text = span.text[0..cut], .style = span.style });
                used += textWidth(span.text[0..cut]);
            }
            if (reserve == 1 and used < limit) {
                try result.append(.{ .text = "…", .style = .{ .dim = true, .color = text_color } });
            }
            break;
        }
        try result.append(span);
        used += textWidth(span.text);
    }
    return try result.toOwnedSlice();
}

const InlineBuilder = struct {
    allocator: Allocator,
    ctx: Context,
    out: *std.array_list.Managed(Line),
    replace_newline: bool = false,
    link: ?[]const u8 = null,
    spans: std.array_list.Managed(Span),

    fn init(allocator: Allocator, ctx: Context, out: *std.array_list.Managed(Line)) InlineBuilder {
        return .{
            .allocator = allocator,
            .ctx = ctx,
            .out = out,
            .spans = std.array_list.Managed(Span).init(allocator),
        };
    }

    fn appendText(self: *InlineBuilder, text: []const u8, style: ui.Style) !void {
        var index: usize = 0;
        while (index < text.len) {
            if (std.mem.indexOfScalarPos(u8, text, index, '\n')) |line_end| {
                if (line_end > index) try self.appendChunk(text[index..line_end], style);
                try self.softBreak(style);
                index = line_end + 1;
                continue;
            }
            try self.appendChunk(text[index..], style);
            return;
        }
    }

    fn appendChunk(self: *InlineBuilder, text: []const u8, style: ui.Style) !void {
        const expanded = try expandTabs(self.allocator, text);
        if (expanded.len == 0) return;
        try self.spans.append(.{ .text = expanded, .style = style, .link = self.link });
    }

    fn appendImage(self: *InlineBuilder, url: []const u8, alt: []const u8, title: ?[]const u8) !void {
        const expanded_alt = try expandTabs(self.allocator, alt);
        try self.spans.append(.{
            .text = expanded_alt,
            .style = .{ .dim = true, .color = text_color },
            .image = .{ .url = url, .alt = expanded_alt, .title = title },
        });
    }

    fn softBreak(self: *InlineBuilder, style: ui.Style) !void {
        if (self.replace_newline or (self.ctx.mode == .document and !self.ctx.preview_breaks)) {
            try self.spans.append(.{ .text = " ", .style = style, .link = self.link });
            return;
        }
        try self.flush();
    }

    fn hardBreak(self: *InlineBuilder) !void {
        if (self.replace_newline) {
            try self.spans.append(.{ .text = " ", .style = .{ .color = text_color } });
            return;
        }
        try self.flush();
    }

    fn flush(self: *InlineBuilder) !void {
        try self.out.append(try makeLine(self.allocator, self.ctx, self.spans.items, 0, false, false));
        self.spans.clearRetainingCapacity();
    }

    fn finish(self: *InlineBuilder) !void {
        if (self.spans.items.len == 0 and self.out.items.len > 0) return;
        try self.flush();
    }

    fn takeSpans(self: *InlineBuilder) ![]Span {
        return try self.spans.toOwnedSlice();
    }
};

fn renderInlineChildren(
    allocator: Allocator,
    builder: *InlineBuilder,
    node: *const Node,
    style: ui.Style,
    definitions: *const std.StringHashMap(Definition),
    depth: usize,
) RenderError!void {
    if (depth > max_inline_depth) return;
    var child = node.first_child;
    while (child) |current| : (child = current.next) {
        try renderInline(allocator, builder, current, style, definitions, depth + 1);
    }
}

fn renderInline(
    allocator: Allocator,
    builder: *InlineBuilder,
    node: *const Node,
    style: ui.Style,
    definitions: *const std.StringHashMap(Definition),
    depth: usize,
) RenderError!void {
    if (depth > max_inline_depth) return;
    switch (node.data) {
        .text => |text| try builder.appendText(text, style),
        .emphasis => {
            var nested = style;
            nested.italic = true;
            try renderInlineChildren(allocator, builder, node, nested, definitions, depth);
        },
        .strong => {
            var nested = style;
            nested.bold = true;
            try renderInlineChildren(allocator, builder, node, nested, definitions, depth);
        },
        .delete => {
            var nested = style;
            nested.strikethrough = true;
            try renderInlineChildren(allocator, builder, node, nested, definitions, depth);
        },
        .inline_code => |code| try builder.appendText(code, withColor(style, code_color)),
        .link => |link| {
            var link_style = style;
            link_style.color = link_color;
            link_style.underline = true;
            const previous = builder.link;
            builder.link = link.url;
            try renderInlineChildren(allocator, builder, node, link_style, definitions, depth);
            builder.link = previous;
            if (!isDocument(builder.ctx)) try appendLinkUrl(allocator, builder, node, link.url);
        },
        .link_reference => |reference| {
            if (definitions.get(reference.identifier)) |definition| {
                var link_style = style;
                link_style.color = link_color;
                link_style.underline = true;
                const previous = builder.link;
                builder.link = definition.url;
                try renderInlineChildren(allocator, builder, node, link_style, definitions, depth);
                builder.link = previous;
                if (!isDocument(builder.ctx)) try appendLinkUrl(allocator, builder, node, definition.url);
            } else {
                try renderInlineChildren(allocator, builder, node, style, definitions, depth);
            }
        },
        .image => |image| {
            if (isDocument(builder.ctx)) {
                try builder.appendImage(image.url, image.alt, image.title);
            } else if (image.alt.len > 0) {
                try builder.appendText(image.alt, .{ .dim = true, .color = text_color });
            }
        },
        .image_reference => |image| {
            if (isDocument(builder.ctx)) {
                if (definitions.get(image.identifier)) |definition| {
                    try builder.appendImage(definition.url, image.alt, definition.title);
                } else if (image.alt.len > 0) {
                    try builder.appendText(image.alt, .{ .dim = true, .color = text_color });
                }
            } else if (image.alt.len > 0) {
                try builder.appendText(image.alt, .{ .dim = true, .color = text_color });
            }
        },
        .break_ => try builder.hardBreak(),
        .footnote_reference => |reference| {
            const text = try std.fmt.allocPrint(allocator, "[^{s}]", .{reference.label});
            try builder.appendText(text, .{ .dim = true, .color = text_color });
        },
        .inline_math => |math| try builder.appendText(math, withColor(style, code_color)),
        .html, .mdx_text_expression, .mdx_jsx_text_element => {},
        else => try renderInlineChildren(allocator, builder, node, style, definitions, depth),
    }
}

fn withColor(style: ui.Style, color: ui.Color) ui.Style {
    var result = style;
    result.color = color;
    return result;
}

fn appendLinkUrl(
    allocator: Allocator,
    builder: *InlineBuilder,
    node: *const Node,
    url: []const u8,
) !void {
    var label = std.array_list.Managed(u8).init(allocator);
    try flattenText(&label, node);
    if (std.mem.eql(u8, url, label.items)) return;
    const suffix = try std.fmt.allocPrint(allocator, " ({s})", .{url});
    try builder.appendText(suffix, .{ .dim = true, .color = link_color });
}

fn flattenText(out: *std.array_list.Managed(u8), node: *const Node) RenderError!void {
    switch (node.data) {
        .text => |text| try out.appendSlice(text),
        .inline_code => |code| try out.appendSlice(code),
        .image => |image| try out.appendSlice(image.alt),
        .break_ => try out.append(' '),
        else => {},
    }
    var child = node.first_child;
    while (child) |current| : (child = current.next) {
        try flattenText(out, current);
    }
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

/// Byte offset of the largest prefix of `text` that fits in `width` cells.
pub fn splitAtWidth(text: []const u8, width: usize) usize {
    var offset: usize = 0;
    var cells: usize = 0;
    while (offset < text.len) {
        const decoded = ui.dom.decodeAt(text, offset);
        if (decoded.len == 0) break;
        const next = CursorColumns.nextVisibleColumn(decoded.cp, cells, 1);
        if (next > width) break;
        cells = next;
        offset += decoded.len;
    }
    return offset;
}

const Token = struct {
    text: []const u8,
    style: ui.Style,
    width: usize,
    is_space: bool = false,
    is_code: bool = false,
    link: ?[]const u8 = null,
};

pub fn wrapLine(allocator: Allocator, line: Line, width: usize) ![]const []const Span {
    const limit = @max(width, 1);
    var rows = std.array_list.Managed([]const Span).init(allocator);
    var row = std.array_list.Managed(Span).init(allocator);
    var row_width: usize = 0;

    var tokens = std.array_list.Managed(Token).init(allocator);
    for (line.spans) |span| try tokenize(&tokens, span);
    if (tokens.items.len == 0) {
        try rows.append(try row.toOwnedSlice());
        return try rows.toOwnedSlice();
    }

    var index: usize = 0;
    while (index < tokens.items.len) : (index += 1) {
        const token = tokens.items[index];
        const active_limit = if (rows.items.len == 0)
            limit
        else
            limit -| @min(line.indent, limit - 1);

        if (token.is_space) {
            if (row_width == 0) {
                // Keep indentation at the start of a row (code blocks rely on
                // it), but do not start a wrapped prose row with a space.
                if (token.is_code) {
                    try row.append(.{ .text = token.text, .style = token.style, .link = token.link });
                    row_width += token.width;
                }
                continue;
            }
            const next_width = if (index + 1 < tokens.items.len) tokens.items[index + 1].width else 0;
            if (row_width + token.width + next_width > active_limit) {
                try rows.append(try row.toOwnedSlice());
                row = std.array_list.Managed(Span).init(allocator);
                row_width = 0;
                continue;
            }
            try row.append(.{ .text = token.text, .style = token.style, .link = token.link });
            row_width += token.width;
            continue;
        }

        if (token.width <= active_limit -| row_width) {
            try row.append(.{ .text = token.text, .style = token.style, .link = token.link });
            row_width += token.width;
            continue;
        }

        if (row_width > 0) {
            try rows.append(try row.toOwnedSlice());
            row = std.array_list.Managed(Span).init(allocator);
            row_width = 0;
        }

        // A single word wider than a row is split at cell boundaries; the
        // style is preserved for every piece.
        const split_limit = if (rows.items.len == 0)
            limit
        else
            limit -| @min(line.indent, limit - 1);
        var remaining = token.text;
        while (remaining.len > 0) {
            const split = splitAtWidth(remaining, split_limit);
            if (split == 0) break;
            try row.append(.{ .text = remaining[0..split], .style = token.style, .link = token.link });
            remaining = remaining[split..];
            try rows.append(try row.toOwnedSlice());
            row = std.array_list.Managed(Span).init(allocator);
            row_width = 0;
        }
    }

    if (row.items.len > 0) try rows.append(try row.toOwnedSlice());
    if (rows.items.len == 0) try rows.append(&.{});
    return try rows.toOwnedSlice();
}

fn tokenize(tokens: *std.array_list.Managed(Token), span: Span) !void {
    var index: usize = 0;
    const text = span.text;
    while (index < text.len) {
        const space = text[index] == ' ' or text[index] == '\t';
        const start = index;
        while (index < text.len and ((text[index] == ' ' or text[index] == '\t') == space)) {
            const decoded = ui.dom.decodeAt(text, index);
            if (decoded.len == 0) break;
            index += decoded.len;
        }
        try tokens.append(.{
            .text = text[start..index],
            .style = span.style,
            .width = textWidth(text[start..index]),
            .is_space = space,
            .is_code = span.is_code,
            .link = span.link,
        });
    }
}

fn findLine(content: *const Content, needle: []const u8) ?Line {
    for (content.lines) |line| {
        for (line.spans) |span| {
            if (std.mem.indexOf(u8, span.text, needle) != null) return line;
        }
    }
    return null;
}

fn lineContains(allocator: Allocator, line: Line, needle: []const u8) bool {
    var text = std.array_list.Managed(u8).init(allocator);
    defer text.deinit();
    for (line.spans) |span| text.appendSlice(span.text) catch return false;
    return std.mem.indexOf(u8, text.items, needle) != null;
}

fn findTextLine(allocator: Allocator, content: *const Content, needle: []const u8) ?Line {
    for (content.lines) |line| {
        if (lineContains(allocator, line, needle)) return line;
    }
    return null;
}

test "markdown: headings, nested lists and code blocks" {
    const testing = std.testing;
    var content = try parseWithOptions(testing.allocator,
        \\# Title
        \\- one
        \\  - nested
        \\- [x] done
        \\- [ ] todo
        \\```zig
        \\const x = 1;
        \\```
    , .{ .code_background = test_code_background });
    defer content.deinit();

    const heading = findLine(&content, "Title").?;
    try testing.expect(heading.spans[0].style.bold == true);
    try testing.expect(heading.spans[0].style.underline == true);

    try testing.expect(findTextLine(testing.allocator, &content, "• nested") != null);
    try testing.expect(findTextLine(testing.allocator, &content, "• one") != null);
    try testing.expect(findTextLine(testing.allocator, &content, "[x] done") != null);
    try testing.expect(findTextLine(testing.allocator, &content, "[ ] todo") != null);

    const code = findTextLine(testing.allocator, &content, "const x = 1;").?;
    try testing.expectEqual(test_code_background, code.spans[0].style.background.?);
}

test "markdown: GFM table renders a clipped box grid" {
    const testing = std.testing;
    var content = try parse(testing.allocator,
        \\| name | value |
        \\|:-----|------:|
        \\| alpha | 1 |
        \\| beta | this-value-is-too-long-for-the-column-cap |
    );
    defer content.deinit();

    try testing.expect(findLine(&content, "┌") != null);
    try testing.expect(findLine(&content, "┬") != null);
    try testing.expect(findLine(&content, "├") != null);
    try testing.expect(findLine(&content, "└") != null);
    try testing.expect(findLine(&content, "name") != null);
    try testing.expect(findLine(&content, "alpha") != null);

    const header = findLine(&content, "name").?;
    try testing.expect(header.no_wrap);
    var saw_bold = false;
    for (header.spans) |span| {
        if (std.mem.indexOf(u8, span.text, "name") != null) saw_bold = span.style.bold orelse false;
    }
    try testing.expect(saw_bold);
    try testing.expect(findLine(&content, "alpha").?.no_wrap);
    try testing.expect(findTextLine(testing.allocator, &content, "…") != null);
}

test "markdown: thematic breaks keep their block prefix" {
    const testing = std.testing;
    var content = try parse(testing.allocator,
        \\---
        \\
        \\> ---
    );
    defer content.deinit();

    var saw_top_level = false;
    var saw_quoted = false;
    for (content.lines) |line| {
        if (!line.rule) continue;
        if (line.indent == 0 and line.spans.len == 0) saw_top_level = true;
        if (line.indent == 2 and line.spans.len == 1 and std.mem.eql(u8, line.spans[0].text, "│ ")) saw_quoted = true;
    }
    try testing.expect(saw_top_level);
    try testing.expect(saw_quoted);
}

test "markdown: setext headings and indented code" {
    const testing = std.testing;
    var content = try parse(testing.allocator,
        \\Heading
        \\=======
        \\
        \\    indented code
    );
    defer content.deinit();

    const heading = findLine(&content, "Heading").?;
    try testing.expect(heading.spans[0].style.bold == true);
    try testing.expect(heading.spans[0].style.underline == true);

    const code = findLine(&content, "indented code").?;
    try testing.expectEqual(@as(?ui.Color, null), code.spans[0].style.background);
}

test "markdown: links, autolinks and reference links" {
    const testing = std.testing;
    var content = try parse(testing.allocator,
        \\see [docs](https://example.com) and <https://example.org>
        \\
        \\[ref][id]
        \\
        \\[id]: https://example.net
    );
    defer content.deinit();

    const link_line = findTextLine(testing.allocator, &content, "docs").?;
    var saw_url = false;
    for (link_line.spans) |span| {
        if (std.mem.indexOf(u8, span.text, "(https://example.com)") != null) saw_url = span.style.dim orelse false;
    }
    try testing.expect(saw_url);

    const autolink = findTextLine(testing.allocator, &content, "https://example.org").?;
    var url_spans: usize = 0;
    for (autolink.spans) |span| {
        if (std.mem.indexOf(u8, span.text, "https://example.org") != null) url_spans += 1;
    }
    try testing.expectEqual(@as(usize, 1), url_spans);

    const reference = findTextLine(testing.allocator, &content, "ref").?;
    var saw_reference_url = false;
    for (reference.spans) |span| {
        if (std.mem.indexOf(u8, span.text, "(https://example.net)") != null) saw_reference_url = true;
    }
    try testing.expect(saw_reference_url);
}

test "markdown: images use alt text and raw HTML is dropped" {
    const testing = std.testing;
    var content = try parse(testing.allocator,
        \\![alt text](https://example.com/x.png)
        \\
        \\<span>hidden?</span> visible
        \\
        \\<div>block html</div>
    );
    defer content.deinit();

    try testing.expect(findLine(&content, "alt text") != null);
    try testing.expect(findLine(&content, "visible") != null);
    try testing.expect(findLine(&content, "hidden?") != null);
    try testing.expect(findLine(&content, "block html") == null);
}

test "markdown: soft breaks, tabs, entities and escapes" {
    const testing = std.testing;
    var content = try parse(testing.allocator, "first\nsecond\n\nA\tB &amp; C \\*literal\\*");
    defer content.deinit();

    try testing.expect(findLine(&content, "first") != null);
    try testing.expect(findLine(&content, "second") != null);
    try testing.expect(findTextLine(testing.allocator, &content, "A    B") != null);
    try testing.expect(findTextLine(testing.allocator, &content, "& C *literal*") != null);
}

test "markdown: invalid UTF-8 falls back to text" {
    const testing = std.testing;
    var content = try parse(testing.allocator, "ok \xff bad");
    defer content.deinit();
    try testing.expect(content.lines.len > 0);
}

test "markdown: fenced code uses TextMate token colors" {
    const testing = std.testing;
    var content = try parse(testing.allocator,
        \\```zig
        \\const answer = 42; // comment
        \\```
    );
    defer content.deinit();

    var saw_keyword = false;
    var saw_comment = false;
    for (content.lines) |line| {
        for (line.spans) |span| {
            if (!span.is_code) continue;
            const color = span.style.color orelse continue;
            if (color.r == 197 and color.g == 134 and color.b == 192) saw_keyword = true;
            if (color.r == 106 and color.g == 153 and color.b == 85) saw_comment = true;
        }
    }
    try testing.expect(saw_keyword);
    try testing.expect(saw_comment);
}

test "markdown: unknown fenced language stays plain" {
    const testing = std.testing;
    var content = try parse(testing.allocator,
        \\```not-a-language
        \\const answer = 42;
        \\```
    );
    defer content.deinit();

    for (content.lines) |line| {
        for (line.spans) |span| {
            if (!span.is_code) continue;
            try testing.expectEqual(code_block_color, span.style.color.?);
        }
    }
}

test "markdown: fenced code fallback language highlights" {
    const testing = std.testing;
    var content = try parseWithOptions(testing.allocator,
        \\```
        \\const answer = 42;
        \\```
    , .{ .code_fence_fallback_language = "zig" });
    defer content.deinit();

    var saw_keyword = false;
    for (content.lines) |line| {
        for (line.spans) |span| {
            const color = span.style.color orelse continue;
            if (color.r == 197 and color.g == 134 and color.b == 192) saw_keyword = true;
        }
    }
    try testing.expect(saw_keyword);
}

test "markdown: many blank-separated paragraphs" {
    const testing = std.testing;
    var content = try parse(testing.allocator, "one\n\ntwo\n\nthree\n\nfour\n\nfive\n\nsix\n\nseven\n\neight\n\nnine\n\nten");
    defer content.deinit();
    try testing.expect(content.lines.len >= 10);
}

test "markdown: empty and definition-only input render nothing" {
    const testing = std.testing;

    var empty = try parse(testing.allocator, "");
    defer empty.deinit();
    try testing.expectEqual(@as(usize, 0), empty.lines.len);

    var definitions = try parse(testing.allocator, "[id]: https://example.com");
    defer definitions.deinit();
    try testing.expectEqual(@as(usize, 0), definitions.lines.len);
}

test "markdown: quote and list continuations keep their prefix" {
    const testing = std.testing;
    var content = try parse(testing.allocator,
        \\> quoted text
        \\
        \\- listed text
    );
    defer content.deinit();

    const quote = findLine(&content, "quoted").?;
    try testing.expectEqual(@as(usize, 2), quote.indent);
    var quote_continuation = std.array_list.Managed(u8).init(testing.allocator);
    defer quote_continuation.deinit();
    for (quote.continuation) |span| try quote_continuation.appendSlice(span.text);
    try testing.expectEqualStrings("│ ", quote_continuation.items);

    const list = findTextLine(testing.allocator, &content, "listed").?;
    try testing.expectEqual(@as(usize, 2), list.indent);
    var list_continuation = std.array_list.Managed(u8).init(testing.allocator);
    defer list_continuation.deinit();
    for (list.continuation) |span| try list_continuation.appendSlice(span.text);
    try testing.expectEqualStrings("  ", list_continuation.items);
}

test "markdown: blockquote after a list is not dropped" {
    const testing = std.testing;
    var content = try parse(testing.allocator, "- item\n\n> quote");
    defer content.deinit();
    try testing.expect(findLine(&content, "quote") != null);
}

test "markdown: splitAtWidth keeps UTF-8 intact" {
    const testing = std.testing;
    const text = "a宽b";
    const split = splitAtWidth(text, 3);
    try testing.expect(std.unicode.utf8ValidateSlice(text[0..split]));
    try testing.expectEqual(@as(usize, 3), textWidth(text[0..split]));
}

test "markdown: document mode keeps image URLs for the preview layout" {
    const allocator = std.testing.allocator;
    var content = try parseDocument(allocator, "before ![shot](images/a.png) after\n\n![ref][id]\n\n[id]: b.jpg", .{});
    defer content.deinit();
    var saw_direct = false;
    var saw_reference = false;
    for (content.lines) |line| {
        for (line.spans) |span| {
            const image = span.image orelse continue;
            if (std.mem.eql(u8, image.url, "images/a.png")) {
                saw_direct = true;
                try std.testing.expectEqualStrings("shot", span.text);
            }
            if (std.mem.eql(u8, image.url, "b.jpg")) saw_reference = true;
        }
    }
    try std.testing.expect(saw_direct);
    try std.testing.expect(saw_reference);
}

test "document preview replaces only Mermaid fences and retains their source block" {
    const renderer = struct {
        fn lookup(_: *anyopaque, text: []const u8) ?[]const u8 {
            return if (std.mem.eql(u8, text, "A --> B")) "A → B" else null;
        }
    };
    var document = try parseDocument(std.testing.allocator, "```mermaid\nA --> B\n```\n\n```text\nA --> B\n```", .{
        .mermaid = .{ .context = undefined, .lookup = renderer.lookup },
    });
    defer document.deinit();
    try std.testing.expect(findTextLine(std.testing.allocator, &document, "A → B") != null);
    try std.testing.expect(findTextLine(std.testing.allocator, &document, "A --> B") != null);
}
