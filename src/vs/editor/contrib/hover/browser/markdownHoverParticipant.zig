// Port of `src/vs/editor/contrib/hover/browser/markdownHoverParticipant.ts`.
//
// Terminal adaptation: hover contents are parsed by the pinned `markdown-zig`
// CommonMark + GFM package and rendered to `ui` nodes by
// `markdownTerminalRenderer.zig` instead of the DOM markdown renderer. Providers
// are called through the existing `getHover.zig` aggregation; async hover
// computation is synchronous in this port.
//
// Not ported, because the corresponding infrastructure does not exist in the
// TUI (documented in `README.md` and `docs/terminal-ui.md`):
//  * hover verbosity actions (they need the command/keybinding services),
//  * the accessible view and screen-reader announcements,
//  * images from markdown (no image protocol in the cell renderer).
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const ui = @import("ui");

const Range = @import("../../../common/core/range.zig").Range;
const ModelDecoration = @import("../../../common/model.zig").ModelDecoration;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const languages = @import("../../../common/languages.zig");
const IMarkdownString = languages.IMarkdownString;
const Hover = languages.Hover;
const HoverProvider = languages.HoverProvider;
const CancellationToken = @import("../../../../base/common/cancellation.zig").CancellationToken;

const hoverTypes = @import("./hoverTypes.zig");
const HoverAnchor = hoverTypes.HoverAnchor;
const HoverAnchorType = hoverTypes.HoverAnchorType;
const HoverStartSource = hoverTypes.HoverStartSource;
const IHoverPart = hoverTypes.IHoverPart;
const IRenderedHoverPart = hoverTypes.IRenderedHoverPart;
const IEditorHoverParticipant = hoverTypes.IEditorHoverParticipant;
const IEditorHoverRenderContext = hoverTypes.IEditorHoverRenderContext;
const getHover = @import("./getHover.zig");
const markdown = @import("../../../common/markdown/markdownTerminalRenderer.zig");

/// VS Code's defaults for `editor.stopRenderingLineAfter` and
/// `editor.maxTokenizationLineLength`. The TUI has no configuration service
/// yet, so the two long-line guards use the upstream defaults.
const stop_rendering_line_after: usize = 10000;
const max_tokenization_line_length: usize = 20000;
const show_long_line_warning = true;

const long_line_warning = "Rendering paused for long line for performance reasons. This can be configured via `editor.stopRenderingLineAfter`. [Don't Show Again](command:editor.action.hideLongLineWarningHover)";
const long_tokenization_warning = "Tokenization is skipped for long lines for performance reasons. This can be configured via `editor.maxTokenizationLineLength`. [Don't Show Again](command:editor.action.hideLongLineWarningHover)";

const rule_color = ui.Color{ .r = 90, .g = 90, .b = 90 };

/// Port of `MarkdownHover`. The `IHoverPart`'s `data` points at this value.
const MarkdownHover = struct {
    range: Range,
    contents: []const IMarkdownString,
    ordinal: usize,
    is_before_content: bool,
};

pub const MarkdownHoverParticipant = struct {
    allocator: Allocator,
    model: *TextModel,
    providers: []const HoverProvider,
    registry: ?*@import("../../../common/languageFeatureRegistry.zig").LanguageFeatureRegistry(HoverProvider) = null,
    hover_ordinal: i32 = 3,

    /// Payloads of the current computation (parts and copied markdown). Reset
    /// at the start of each async pass, which is the first pass of a cycle.
    parts_arena: std.heap.ArenaAllocator,
    /// Parsed markdown of the currently rendered hover.
    rendered_arena: std.heap.ArenaAllocator,
    rendered: []const IRenderedHoverPart = &.{},

    pub fn init(allocator: Allocator, model: *TextModel, providers: []const HoverProvider) MarkdownHoverParticipant {
        return initWithRegistry(allocator, model, providers, null);
    }

    pub fn initWithRegistry(allocator: Allocator, model: *TextModel, providers: []const HoverProvider, registry: ?*@import("../../../common/languageFeatureRegistry.zig").LanguageFeatureRegistry(HoverProvider)) MarkdownHoverParticipant {
        return .{
            .allocator = allocator,
            .model = model,
            .providers = providers,
            .registry = registry,
            .parts_arena = std.heap.ArenaAllocator.init(allocator),
            .rendered_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *MarkdownHoverParticipant) void {
        self.parts_arena.deinit();
        self.rendered_arena.deinit();
    }

    pub fn interface(self: *MarkdownHoverParticipant) IEditorHoverParticipant {
        return .{
            .context = self,
            .hover_ordinal = self.hover_ordinal,
            .compute_sync = computeSync,
            .compute_async = computeAsync,
            .render_hover_parts = renderHoverParts,
            .get_accessible_content = getAccessibleContent,
            .handle_hide = handleHide,
        };
    }

    fn computeSync(
        context: *anyopaque,
        anchor: *const HoverAnchor,
        line_decorations: []const ModelDecoration,
        source: HoverStartSource,
    ) []const IHoverPart {
        _ = source;
        const self: *MarkdownHoverParticipant = @ptrCast(@alignCast(context));
        return self.computeSyncParts(anchor, line_decorations) catch &.{};
    }

    fn computeSyncParts(
        self: *MarkdownHoverParticipant,
        anchor: *const HoverAnchor,
        line_decorations: []const ModelDecoration,
    ) ![]const IHoverPart {
        if (anchor.getType() != .range) return &.{};

        const allocator = self.parts_arena.allocator();
        var result = ArrayList(IHoverPart).init(allocator);

        const anchor_range = anchor.getRange();
        const line_number = anchor_range.startLineNumber;
        if (line_number > self.model.getLineCount()) return &.{};
        const max_column = self.model.getLineMaxColumn(line_number);
        const line_length = self.model.getLineLength(line_number);

        var index: usize = 1000;
        var stop_rendering_message = false;
        if (line_length > stop_rendering_line_after and anchor_range.startColumn >= stop_rendering_line_after) {
            stop_rendering_message = true;
            if (show_long_line_warning) {
                try result.append(try self.createMarkdownHover(
                    allocator,
                    anchor_range,
                    &.{long_line_warning},
                    false,
                    index,
                ));
                index += 1;
            }
        }
        if (!stop_rendering_message and line_length >= max_tokenization_line_length) {
            if (show_long_line_warning) {
                try result.append(try self.createMarkdownHover(
                    allocator,
                    anchor_range,
                    &.{long_tokenization_warning},
                    false,
                    index,
                ));
                index += 1;
            }
        }

        var is_before_content = false;
        for (line_decorations) |decoration| {
            const start_column = if (decoration.range.startLineNumber == line_number) decoration.range.startColumn else 1;
            const end_column = if (decoration.range.endLineNumber == line_number) decoration.range.endColumn else max_column;

            const hover_message = decoration.options.hoverMessage orelse continue;
            if (isEmptyMarkdownString(hover_message)) continue;

            if (decoration.options.beforeContentClassName != null) {
                is_before_content = true;
            }

            const range = Range.init(anchor_range.startLineNumber, start_column, anchor_range.startLineNumber, end_column);
            try result.append(try self.createMarkdownHover(
                allocator,
                range,
                &.{hover_message},
                is_before_content,
                index,
            ));
            index += 1;
        }

        return try result.toOwnedSlice();
    }

    fn computeAsync(
        context: *anyopaque,
        anchor: *const HoverAnchor,
        line_decorations: []const ModelDecoration,
        source: HoverStartSource,
        token: CancellationToken,
    ) []const IHoverPart {
        const self: *MarkdownHoverParticipant = @ptrCast(@alignCast(context));
        _ = line_decorations;
        _ = source;
        return self.computeAsyncParts(anchor, token) catch &.{};
    }

    fn computeAsyncParts(
        self: *MarkdownHoverParticipant,
        anchor: *const HoverAnchor,
        token: CancellationToken,
    ) ![]const IHoverPart {
        // The arena is not reset per computation: a visible result may be
        // filtered and re-rendered while a new computation is in flight, and
        // its part payloads must stay valid until the hover is hidden.
        if (anchor.getType() != .range) return &.{};
        const providers = if (self.registry) |registry|
            registry.ordered(self.parts_arena.allocator(), self.model, false) catch &.{}
        else
            self.providers;
        if (providers.len == 0) return &.{};

        const anchor_range = anchor.getRange();
        const position = anchor_range.getStartPosition();
        const results = try getHover.getHoverProviderResults(
            self.parts_arena.allocator(),
            providers,
            self.model,
            position,
            token,
            null,
        );

        var result = ArrayList(IHoverPart).init(self.parts_arena.allocator());
        for (results) |item| {
            if (isEmptyHover(item.hover)) continue;
            const range = item.hover.range orelse anchor_range;
            try result.append(try self.createMarkdownHoverFromHover(
                self.parts_arena.allocator(),
                range,
                item.hover,
                false,
                item.ordinal,
            ));
        }
        return try result.toOwnedSlice();
    }

    fn createMarkdownHover(
        self: *MarkdownHoverParticipant,
        allocator: Allocator,
        range: Range,
        contents: []const []const u8,
        is_before_content: bool,
        ordinal: usize,
    ) !IHoverPart {
        const hover = try allocator.create(MarkdownHover);
        const markdown_strings = try allocator.alloc(IMarkdownString, contents.len);
        for (contents, 0..) |content, index| {
            markdown_strings[index] = .{ .value = try allocator.dupe(u8, content) };
        }
        hover.* = .{
            .range = range,
            .contents = markdown_strings,
            .ordinal = ordinal,
            .is_before_content = is_before_content,
        };
        return .{
            .owner = self,
            .range = range,
            .is_before_content = is_before_content,
            .data = hover,
            .is_valid_for_hover_anchor = isValidForHoverAnchor,
        };
    }

    fn createMarkdownHoverFromHover(
        self: *MarkdownHoverParticipant,
        allocator: Allocator,
        range: Range,
        hover: Hover,
        is_before_content: bool,
        ordinal: usize,
    ) !IHoverPart {
        const markdown_hover = try allocator.create(MarkdownHover);
        const markdown_strings = try allocator.alloc(IMarkdownString, hover.contents.len);
        for (hover.contents, 0..) |content, index| {
            markdown_strings[index] = .{
                .value = try allocator.dupe(u8, content.value),
                .is_trusted = content.is_trusted,
                .support_theme_icons = content.support_theme_icons,
                .support_html = content.support_html,
            };
        }
        markdown_hover.* = .{
            .range = range,
            .contents = markdown_strings,
            .ordinal = ordinal,
            .is_before_content = is_before_content,
        };
        return .{
            .owner = self,
            .range = range,
            .is_before_content = is_before_content,
            .data = markdown_hover,
            .is_valid_for_hover_anchor = isValidForHoverAnchor,
        };
    }

    fn isValidForHoverAnchor(part: *const IHoverPart, anchor: *const HoverAnchor) bool {
        // Only the range is needed; `part.data` may already belong to an older
        // computation by the time the wrapper filters an adopted hover.
        if (anchor.getType() != .range) return false;
        const anchor_range = anchor.getRange();
        return part.range.startColumn <= anchor_range.startColumn and
            part.range.endColumn >= anchor_range.endColumn;
    }

    fn renderHoverParts(
        context: *anyopaque,
        render_context: *const IEditorHoverRenderContext,
        hover_parts: []const IHoverPart,
    ) ![]const IRenderedHoverPart {
        const self: *MarkdownHoverParticipant = @ptrCast(@alignCast(context));
        _ = render_context;
        _ = self.rendered_arena.reset(.retain_capacity);
        const allocator = self.rendered_arena.allocator();

        const sorted = try allocator.dupe(IHoverPart, hover_parts);
        std.mem.sort(IHoverPart, sorted, {}, lessThanOrdinal);

        var rendered = ArrayList(IRenderedHoverPart).init(allocator);
        for (sorted) |part| {
            const hover: *const MarkdownHover = @ptrCast(@alignCast(part.data orelse continue));
            var contents = ArrayList(markdown.Content).init(allocator);
            for (hover.contents) |content| {
                if (isEmptyMarkdownString(content.value)) continue;
                try contents.append(try markdown.parseWithOptions(allocator, content.value, .{
                    .code_fence_fallback_language = self.model.getLanguageId(),
                }));
            }
            if (contents.items.len == 0) continue;

            const state = try allocator.create(RenderedMarkdownHover);
            state.* = .{
                .hover_part = part,
                .contents = try contents.toOwnedSlice(),
                .allocator = self.allocator,
            };
            state.accessible = try accessibleText(allocator, state.contents);

            try rendered.append(.{
                .hover_part = part,
                .context = state,
                .measure = measureRenderedMarkdown,
                .height = heightRenderedMarkdown,
                .build = buildRenderedMarkdown,
                .accessible_content = state.accessible,
            });
        }
        self.rendered = try rendered.toOwnedSlice();
        return self.rendered;
    }

    fn handleHide(context: *anyopaque) void {
        const self: *MarkdownHoverParticipant = @ptrCast(@alignCast(context));
        _ = self.parts_arena.reset(.retain_capacity);
        _ = self.rendered_arena.reset(.retain_capacity);
        self.rendered = &.{};
    }

    fn getAccessibleContent(context: *anyopaque, hover_part: *const IHoverPart) []const u8 {
        const self: *MarkdownHoverParticipant = @ptrCast(@alignCast(context));
        for (self.rendered) |rendered| {
            if (rendered.hover_part.range.equalsRange(hover_part.range)) {
                return rendered.accessible_content;
            }
        }
        return "";
    }
};

const RenderedMarkdownHover = struct {
    hover_part: IHoverPart,
    contents: []markdown.Content,
    allocator: Allocator,
    accessible: []const u8 = "",
};

fn lessThanOrdinal(_: void, left: IHoverPart, right: IHoverPart) bool {
    const left_hover: *const MarkdownHover = @ptrCast(@alignCast(left.data orelse return false));
    const right_hover: *const MarkdownHover = @ptrCast(@alignCast(right.data orelse return true));
    return left_hover.ordinal < right_hover.ordinal;
}

fn measureRenderedMarkdown(context: *const anyopaque, max_width: usize) usize {
    const state: *const RenderedMarkdownHover = @ptrCast(@alignCast(context));
    var width: usize = 1;
    for (state.contents) |content| {
        width = @max(width, @min(content.maxLineWidth(), max_width));
    }
    return width;
}

fn heightRenderedMarkdown(context: *const anyopaque, width: usize) usize {
    const state: *const RenderedMarkdownHover = @ptrCast(@alignCast(context));
    var rows: usize = 0;
    for (state.contents, 0..) |content, content_index| {
        if (content_index > 0) rows += 1;
        for (content.lines) |line| {
            if (line.rule or line.no_wrap) {
                rows += 1;
                continue;
            }
            var scratch = std.heap.ArenaAllocator.init(state.allocator);
            defer scratch.deinit();
            const wrapped = markdown.wrapLine(scratch.allocator(), line, width) catch {
                rows += 1;
                continue;
            };
            rows += wrapped.len;
        }
    }
    return @max(rows, 1);
}

fn buildRenderedMarkdown(
    context: *const anyopaque,
    doc: *ui.Document,
    parent: *ui.Node,
    width: usize,
    top: usize,
) !usize {
    const state: *const RenderedMarkdownHover = @ptrCast(@alignCast(context));
    var scratch = std.heap.ArenaAllocator.init(doc.allocator);
    defer scratch.deinit();
    const allocator = scratch.allocator();

    var row = top;
    for (state.contents, 0..) |content, content_index| {
        if (content_index > 0) row += 1; // blank separator between hover rows
        for (content.lines) |line| {
            if (line.rule) {
                const rule_row = try appendRow(doc, parent, row);
                row += 1;
                for (line.spans) |span| {
                    if (span.text.len == 0) continue;
                    const prefix = try doc.createText(span.text);
                    prefix.setStyle(span.style);
                    _ = try rule_row.appendChild(prefix);
                }
                const rule_width = width -| line.indent;
                if (rule_width > 0) {
                    const text = try doc.createText(try repeat(allocator, "─", rule_width));
                    text.setStyle(.{ .color = rule_color });
                    _ = try rule_row.appendChild(text);
                }
                continue;
            }

            if (line.no_wrap) {
                const line_row = try appendRow(doc, parent, row);
                row += 1;
                try appendClippedSpans(doc, line_row, line.spans, width);
                continue;
            }

            const rows = try markdown.wrapLine(allocator, line, width);
            for (rows, 0..) |wrapped, index| {
                const line_row = try appendRow(doc, parent, row);
                row += 1;
                if (index > 0) {
                    var continuation_width: usize = 0;
                    for (line.continuation) |span| {
                        if (span.text.len == 0) continue;
                        const prefix = try doc.createText(span.text);
                        prefix.setStyle(span.style);
                        _ = try line_row.appendChild(prefix);
                        continuation_width += markdown.textWidth(span.text);
                    }
                    const padding = line.indent -| continuation_width;
                    if (padding > 0) {
                        const indent_text = try doc.createText(try spaces(allocator, padding));
                        _ = try line_row.appendChild(indent_text);
                    }
                }
                for (wrapped) |span| {
                    if (span.text.len == 0) continue;
                    const span_node = try doc.createText(span.text);
                    span_node.setStyle(span.style);
                    _ = try line_row.appendChild(span_node);
                }
            }
        }
    }
    return row - top;
}

fn appendRow(doc: *ui.Document, parent: *ui.Node, row: usize) !*ui.Node {
    const node = try doc.createElement(.div);
    node.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = @floatFromInt(row) },
        .width = .{ .percent = 100 },
        .height = .{ .cells = 1 },
        .white_space = .pre,
    });
    _ = try parent.appendChild(node);
    return node;
}

fn appendClippedSpans(
    doc: *ui.Document,
    row: *ui.Node,
    spans: []const markdown.Span,
    width: usize,
) !void {
    var used: usize = 0;
    for (spans) |span| {
        if (used >= width) break;
        if (span.text.len == 0) continue;
        const take = markdown.splitAtWidth(span.text, width - used);
        if (take == 0) break;
        const text = try doc.createText(span.text[0..take]);
        text.setStyle(span.style);
        _ = try row.appendChild(text);
        used += markdown.textWidth(span.text[0..take]);
    }
}
fn spaces(allocator: Allocator, count: usize) ![]const u8 {
    const result = try allocator.alloc(u8, count);
    @memset(result, ' ');
    return result;
}

fn repeat(allocator: Allocator, text: []const u8, count: usize) ![]const u8 {
    const result = try allocator.alloc(u8, text.len * count);
    var index: usize = 0;
    while (index < count) : (index += 1) {
        @memcpy(result[index * text.len ..][0..text.len], text);
    }
    return result;
}

fn accessibleText(allocator: Allocator, contents: []const markdown.Content) ![]const u8 {
    var out = ArrayList(u8).init(allocator);
    for (contents, 0..) |content, content_index| {
        if (content_index > 0) try out.append('\n');
        for (content.lines) |line| {
            if (line.rule) {
                try out.appendSlice("---");
            } else {
                for (line.spans) |span| try out.appendSlice(span.text);
            }
            try out.append('\n');
        }
    }
    return try out.toOwnedSlice();
}

fn isEmptyMarkdownString(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n").len == 0;
}

fn isEmptyHover(hover: Hover) bool {
    for (hover.contents) |content| {
        if (!isEmptyMarkdownString(content.value)) return false;
    }
    return true;
}
