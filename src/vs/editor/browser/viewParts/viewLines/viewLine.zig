// Port of `src/vs/editor/browser/viewParts/viewLines/viewLine.ts`.
//
// Terminal adaptation: upstream manages DOM spans and incrementally updates
// them; the terminal renders the line text into a `StringBuilder` each frame
// (the TUI repaints from that builder). Change detection uses a hash of the
// rendered text instead of retaining a second copy of every line. GPU
// rendering, DOM reading, ligatures and cursor text content are not
// applicable. Inline decorations/whitespace
// options are not consumed by the shared terminal line renderer yet; the TUI
// paints decoration cells separately.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");

const view_line_options = @import("./viewLineOptions.zig");
const view_line_renderer = @import("../../../common/viewLayout/viewLineRenderer.zig");
const line_tokens_mod = @import("../../../common/tokens/lineTokens.zig");
const LineTokens = line_tokens_mod.LineTokens;
const SliceLineTokens = line_tokens_mod.SliceLineTokens;
const line_decorations_mod = @import("../../../common/viewLayout/lineDecorations.zig");
const LineDecoration = line_decorations_mod.LineDecoration;
const inline_decorations_mod = @import("../../../common/viewModel/inlineDecorations.zig");
const InlineDecorationType = inline_decorations_mod.InlineDecorationType;
const theme = @import("../../../../platform/theme/common/theme.zig");
const viewport_data = @import("../../../common/viewLayout/viewLinesViewportData.zig");
const view_context = @import("../../../common/viewModel/viewContext.zig");
const StringBuilder = @import("../../../common/core/stringBuilder.zig").StringBuilder;
const OffsetRange = @import("../../../common/core/ranges/offsetRange.zig").OffsetRange;

const ViewLineOptions = view_line_options.ViewLineOptions;
const RenderingContext = view_context.ViewContext;

fn cloneLineTokens(allocator: Allocator, tokens: IViewLineTokens) !*LineTokens {
    const owned = try allocator.create(LineTokens);
    errdefer allocator.destroy(owned);
    switch (tokens) {
        .tokens => |line| owned.* = try line.clone(allocator),
        .slice => |slice| owned.* = try slice._source.clone(allocator),
    }
    return owned;
}

fn tokenView(original: IViewLineTokens, owned: *LineTokens) IViewLineTokens {
    return switch (original) {
        .tokens => IViewLineTokens.init(owned),
        .slice => |slice| IViewLineTokens.initSlice(SliceLineTokens.init(
            owned,
            slice._startOffset,
            slice._endOffset,
            slice._deltaOffset,
        )),
    };
}

/// Port of `ViewLine` (the `IVisibleLine` implementation used by
/// `VisibleLinesCollection`).
pub const ViewLine = struct {
    allocator: Allocator,
    context: *RenderingContext,
    options: ViewLineOptions,
    is_maybe_invalid: bool = true,
    rendered_view_line: ?RenderedViewLine = null,
    /// The retained terminal element created by `paint`. The editor view keeps
    /// it across frames and scrolls; only dirty lines rewrite its children.
    dom_node: ?*ui.Node = null,
    /// Set when a render pass produced new render input for this line.
    dom_dirty: bool = true,
    /// Set when `paint` rebuilt the line's children; consumed by the view's
    /// box-tree sync.
    children_dirty: bool = false,
    /// Hash of the per-cell flags/guides/ellipsis that produced the children.
    last_paint_key: u64 = 0,
    /// The last `top_cells` passed to `paint`.
    painted_top: f64 = 0,
    /// Width in terminal cells of the last rendered line.
    width: usize = 0,

    /// Port of upstream `RenderedViewLine`: the input that produced the last
    /// render and the terminal runs it produced.
    pub const RenderedViewLine = struct {
        input: view_line_renderer.Input,
        rendered: view_line_renderer.RenderedLine,
        /// Owned by this record; `input.content` points into it.
        content: []u8,
        /// Owned by this record; `input.tokens` points at it. Heap-allocated so
        /// the address stays valid when the containing `ViewLine` moves.
        tokens: *LineTokens,
        /// Owned by this record; `input.line_decorations` points into it.
        decorations: []LineDecoration,
        /// Owned by this record; `input.selection_ranges` points into it.
        selection_ranges: []OffsetRange,
        delta_top: f64 = 0,
        line_height: f64 = 0,

        pub fn deinit(self: *RenderedViewLine, allocator: Allocator) void {
            self.rendered.deinit(allocator);
            allocator.free(self.content);
            self.tokens.deinit();
            allocator.destroy(self.tokens);
            allocator.free(self.decorations);
            allocator.free(self.selection_ranges);
        }
    };

    pub fn init(allocator: Allocator, context: *RenderingContext, options: ViewLineOptions) ViewLine {
        return .{
            .allocator = allocator,
            .context = context,
            .options = options,
        };
    }

    pub fn deinit(self: *ViewLine, allocator: Allocator) void {
        if (self.rendered_view_line) |*rendered| rendered.deinit(allocator);
        self.rendered_view_line = null;
    }

    pub fn onContentChanged(self: *ViewLine) void {
        self.is_maybe_invalid = true;
    }

    pub fn onTokensChanged(self: *ViewLine) void {
        self.is_maybe_invalid = true;
    }

    pub fn onDecorationsChanged(self: *ViewLine) void {
        self.is_maybe_invalid = true;
    }

    pub fn onOptionsChanged(self: *ViewLine, new_options: ViewLineOptions) void {
        self.is_maybe_invalid = true;
        self.options = new_options;
    }

    /// Port of upstream `ViewLine.onSelectionChanged`: high-contrast themes
    /// paint `inline-selected-text`, and `renderWhitespace: selection` depends
    /// on the selection ranges.
    pub fn onSelectionChanged(self: *ViewLine) bool {
        if (theme.isHighContrast(self.options.theme_type) or
            self.options.render_whitespace == .selection)
        {
            self.is_maybe_invalid = true;
            return true;
        }
        return false;
    }

    pub fn layoutLine(_: *ViewLine, _: usize, _: f64, _: f64) void {}

    pub fn shouldRender(self: *const ViewLine) bool {
        return self.is_maybe_invalid;
    }

    pub fn onDidRender(self: *ViewLine) void {
        self.is_maybe_invalid = false;
    }

    /// Port of upstream `ViewLine.renderLine`: build the render input, skip
    /// when it is unchanged, render, and append the terminal text.
    pub fn renderLine(
        self: *ViewLine,
        line_number: usize,
        delta_top: f64,
        line_height: f64,
        viewport: *const viewport_data.ViewportData,
        sb: ?*StringBuilder,
    ) bool {
        const line_data = viewport.getViewLineRenderingData(line_number) catch return false;

        const actual_inline_decorations = line_decorations_mod.LineDecoration.filter(
            self.allocator,
            line_data.inlineDecorations,
            line_number,
            line_data.minColumn,
            line_data.maxColumn,
        ) catch return false;
        errdefer self.allocator.free(actual_inline_decorations);

        // High-contrast themes draw the selection as an inline decoration.
        var decorations = std.array_list.Managed(LineDecoration).init(self.allocator);
        defer decorations.deinit();
        decorations.appendSlice(actual_inline_decorations) catch return false;
        self.allocator.free(actual_inline_decorations);

        var selection_ranges = std.array_list.Managed(OffsetRange).init(self.allocator);
        defer selection_ranges.deinit();

        const render_whitespace = if (self.options.experimental_whitespace_rendering == .off)
            self.options.render_whitespace
        else
            .none;
        if (theme.isHighContrast(self.options.theme_type) or render_whitespace == .selection) {
            for (viewport.selections) |selection| {
                if (selection.endLineNumber < line_number or selection.startLineNumber > line_number) continue;
                const start_column = if (selection.startLineNumber == line_number) selection.startColumn else line_data.minColumn;
                const end_column = if (selection.endLineNumber == line_number) selection.endColumn else line_data.maxColumn;
                if (start_column >= end_column) continue;
                if (theme.isHighContrast(self.options.theme_type)) {
                    decorations.append(LineDecoration.init(start_column, end_column, "inline-selected-text", .Regular)) catch return false;
                }
                if (render_whitespace == .selection) {
                    selection_ranges.append(OffsetRange.init(start_column - 1, end_column - 1)) catch return false;
                }
            }
        }

        // Upstream compares the rendered input to avoid rebuilding the DOM.
        // The terminal renderer uses the same input equality contract.
        const owned_decorations = decorations.toOwnedSlice() catch return false;
        errdefer self.allocator.free(owned_decorations);
        const owned_selections = selection_ranges.toOwnedSlice() catch return false;
        errdefer self.allocator.free(owned_selections);

        // The view model reuses its line-content and token buffers, so a
        // retained render input must own stable copies. Without these copies
        // the host had to invalidate every visible line on every frame.
        const owned_content = self.allocator.dupe(u8, line_data.content) catch {
            self.allocator.free(owned_decorations);
            self.allocator.free(owned_selections);
            return false;
        };
        errdefer self.allocator.free(owned_content);
        const owned_tokens = cloneLineTokens(self.allocator, line_data.tokens) catch {
            self.allocator.free(owned_content);
            self.allocator.free(owned_decorations);
            self.allocator.free(owned_selections);
            return false;
        };
        errdefer {
            owned_tokens.deinit();
            self.allocator.destroy(owned_tokens);
        }

        const input = view_line_renderer.Input{
            .content = owned_content,
            .tokens = tokenView(line_data.tokens, owned_tokens),
            .tab_size = line_data.tabSize,
            .start_visible_column = line_data.startVisibleColumn,
            .render_whitespace = render_whitespace,
            .selection_ranges = owned_selections,
            .render_control_characters = self.options.render_control_characters,
            .line_decorations = owned_decorations,
            .continues_with_wrapped_line = line_data.continuesWithWrappedLine,
            .is_basic_ascii = line_data.isBasicASCII,
            .contains_rtl = line_data.containsRTL,
            .faux_indent_length = line_data.minColumn - 1,
            .stop_rendering_line_after = self.options.stop_rendering_line_after,
            .text_direction = line_data.textDirection,
        };

        if (self.rendered_view_line) |*rendered| {
            if (rendered.input.equals(&input)) {
                self.allocator.free(owned_content);
                owned_tokens.deinit();
                self.allocator.destroy(owned_tokens);
                self.allocator.free(owned_decorations);
                self.allocator.free(owned_selections);
                if (sb) |buffer| buffer.appendString(rendered.rendered.bytes) catch return false;
                return false;
            }
        }

        var rendered = view_line_renderer.renderLine(self.allocator, input) catch {
            self.allocator.free(owned_content);
            owned_tokens.deinit();
            self.allocator.destroy(owned_tokens);
            self.allocator.free(owned_decorations);
            self.allocator.free(owned_selections);
            return false;
        };
        errdefer rendered.deinit(self.allocator);

        self.width = measureCells(rendered.bytes);
        if (self.rendered_view_line) |*previous| previous.deinit(self.allocator);
        self.rendered_view_line = .{
            .input = input,
            .content = owned_content,
            .tokens = owned_tokens,
            .rendered = rendered,
            .decorations = owned_decorations,
            .selection_ranges = owned_selections,
            .delta_top = delta_top,
            .line_height = line_height,
        };
        if (sb) |buffer| buffer.appendString(rendered.bytes) catch return false;
        self.dom_dirty = true;
        return true;
    }

    pub fn takeChildrenDirty(self: *ViewLine) bool {
        const dirty = self.children_dirty;
        self.children_dirty = false;
        return dirty;
    }

    pub fn paintedTop(self: *const ViewLine) f64 {
        return self.painted_top;
    }

    pub fn getRenderedViewLine(self: *const ViewLine) ?*const RenderedViewLine {
        return if (self.rendered_view_line) |*rendered| rendered else null;
    }

    pub fn getDomNode(self: *const ViewLine) ?*ui.Node {
        return self.dom_node;
    }

    /// Terminal `ViewLine` DOM construction: upstream creates a `div.view-line`
    /// with one span per styled run. The terminal equivalent creates one `ui`
    /// element and text nodes for each run. `style_fn` is the paint-boundary
    /// adapter from token/decoration data to terminal cell attributes.
    /// A terminal indentation/bracket guide painted inside the line element.
    pub const Guide = struct {
        column: usize,
        color: ui.Color,
    };

    pub const PaintOptions = struct {
        left_cells: usize,
        top_cells: usize,
        width_cells: usize,
        height_cells: usize = 1,
        background: ?ui.Color = null,
        flags: []u32,
        decoration_bits_fn: ?*const fn (classes: []const u8) u32 = null,
        /// Upstream `inline-folded`: a collapsed region paints an ellipsis
        /// after the line's text content.
        folded_ellipsis: bool = false,
        folded_ellipsis_style: ui.Style = .{},
        guides: []const Guide = &.{},
        /// Borrow the rendered bytes for the text nodes. Retained editor lines
        /// keep their `RenderedViewLine` alive, so borrowing is safe; a
        /// temporary line (sticky scroll) must copy.
        borrow_text: bool = true,
    };

    /// Paint-boundary adapter from token/decoration data to shared paint
    /// styles (the CSS-class analogue). The context is the editor view's class
    /// cache, so equal parts reuse one style object.
    pub const PartStyleFn = struct {
        context: ?*anyopaque = null,
        apply: *const fn (context: ?*anyopaque, part: view_line_renderer.RenderedPart, flag: u32) anyerror!*const ui.style.PaintStyle,
    };

    pub fn paint(
        self: *ViewLine,
        doc: *ui.Document,
        options: PaintOptions,
        style_fn: PartStyleFn,
    ) !*ui.Node {
        const line = self.dom_node orelse try doc.createElement(.div);
        self.dom_node = line;
        line.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = @floatFromInt(options.left_cells) },
            .top = .{ .cells = @floatFromInt(options.top_cells) },
            .width = .{ .cells = @floatFromInt(options.width_cells) },
            .height = .{ .cells = @floatFromInt(options.height_cells) },
            .white_space = .pre,
            .overflow = .hidden,
            .background = options.background,
        });
        self.painted_top = @floatFromInt(options.top_cells);

        const paint_key = paintKeyOf(options);
        if (!self.dom_dirty and paint_key == self.last_paint_key) return line;
        self.last_paint_key = paint_key;
        self.dom_dirty = false;
        self.children_dirty = true;
        line.clearChildren();

        const rendered = self.rendered_view_line orelse return line;
        var part_index: usize = 0;
        var byte_in_part: usize = 0;
        var cell: usize = 0;
        var absolute: usize = 0;

        var run_start: usize = 0;
        var run_style: ?*const ui.style.PaintStyle = null;

        while (part_index < rendered.rendered.parts.len) {
            const part = rendered.rendered.parts[part_index];
            if (byte_in_part >= part.text.len) {
                part_index += 1;
                byte_in_part = 0;
                continue;
            }

            const decoded = ui.dom.decodeAt(part.text, byte_in_part);
            if (decoded.len == 0) break;
            const width = measureCellWidth(decoded.cp);

            var flag: u32 = if (cell < options.flags.len) options.flags[cell] else 0;
            if (part.decoration_class) |classes| {
                if (options.decoration_bits_fn) |bits_fn| {
                    const bits = bits_fn(classes);
                    if (bits != 0) {
                        flag |= bits;
                        if (cell < options.flags.len) options.flags[cell] |= bits;
                    }
                }
            }
            const style = try style_fn.apply(style_fn.context, part, flag);

            // Pointer equality is the terminal equivalent of equal CSS class
            // lists; the view's class cache interns each style once.
            if (run_style == null or run_style.? != style) {
                if (run_style != null and absolute > run_start) {
                    const node = if (options.borrow_text)
                        try doc.createTextBorrowed(rendered.rendered.bytes[run_start..absolute])
                    else
                        try doc.createText(rendered.rendered.bytes[run_start..absolute]);
                    node.setPaintRef(run_style.?);
                    _ = try line.appendChild(node);
                }
                run_start = absolute;
                run_style = style;
            }

            absolute += decoded.len;
            byte_in_part += decoded.len;
            cell += width;
        }

        if (run_style != null and absolute > run_start) {
            const node = if (options.borrow_text)
                try doc.createTextBorrowed(rendered.rendered.bytes[run_start..absolute])
            else
                try doc.createText(rendered.rendered.bytes[run_start..absolute]);
            node.setPaintRef(run_style.?);
            _ = try line.appendChild(node);
        }

        // Overlay decorations can cover cells past the final text run, such as
        // a collapsed marker reported at the end of a line. There is no glyph
        // to style there, so paint a styled space to carry the underline.
        var tail = cell;
        const trailing_part = view_line_renderer.RenderedPart{ .text = " ", .foreground = 0 };
        while (tail < options.flags.len) : (tail += 1) {
            const flag = options.flags[tail];
            if (flag == 0) continue;
            var end = tail + 1;
            while (end < options.flags.len and options.flags[end] == flag) : (end += 1) {}
            const count = end - tail;
            const spaces_text = try doc.arena.allocator().alloc(u8, count);
            @memset(spaces_text, ' ');
            const trailing = try doc.createTextBorrowed(spaces_text);
            const style = try style_fn.apply(style_fn.context, trailing_part, flag);
            trailing.setPaintRef(style);
            _ = try line.appendChild(trailing);
            tail = end - 1;
        }

        if (options.folded_ellipsis) {
            // `inline-folded` after-content, painted at the end of the text
            // and outside the selectable line width.
            const ellipsis = try doc.createElement(.div);
            ellipsis.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = @floatFromInt(cell) },
                .top = .{ .cells = 0 },
                .width = .{ .cells = 1 },
                .height = .{ .cells = 1 },
                .white_space = .pre,
            });
            const glyph = try doc.createText("\u{2026}");
            glyph.setStyle(options.folded_ellipsis_style);
            _ = try ellipsis.appendChild(glyph);
            _ = try line.appendChild(ellipsis);
        }

        // Indent/bracket guides are overlay paint in the browser; terminal
        // cells are children of the line so they can share its clipping.
        for (options.guides) |guide| {
            const guide_node = try doc.createElement(.div);
            guide_node.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = @floatFromInt(guide.column) },
                .top = .{ .cells = 0 },
                .width = .{ .cells = 1 },
                .height = .{ .cells = 1 },
                .white_space = .pre,
            });
            const glyph = try doc.createText("\u{2502}");
            glyph.setStyle(.{ .color = guide.color });
            _ = try guide_node.appendChild(glyph);
            _ = try line.appendChild(guide_node);
        }
        return line;
    }

    pub fn getWidth(self: *const ViewLine) usize {
        return self.width;
    }

    /// Drops the retained render input. The terminal adapter's line data
    /// buffers are reused by the view model, so input slices cannot be
    /// compared across frames; the host calls this before each render pass.
    pub fn clearRenderedInput(self: *ViewLine) void {
        if (self.rendered_view_line) |*rendered| rendered.deinit(self.allocator);
        self.rendered_view_line = null;
        self.width = 0;
        self.is_maybe_invalid = true;
    }

    /// Port of upstream `ViewLine.resetCachedWidth`: drop the measured width
    /// and force the next render to rebuild it.
    pub fn resetCachedWidth(self: *ViewLine) void {
        // The terminal width is derived from the rendered runs, so it can be
        // recomputed without invalidating the line or re-rendering it.
        if (self.rendered_view_line) |rendered| {
            self.width = measureCells(rendered.rendered.bytes);
        } else {
            self.width = 0;
        }
    }

    pub fn getHeight(self: *const ViewLine) f64 {
        return if (self.rendered_view_line) |rendered| rendered.line_height else 0;
    }

    pub fn getTop(self: *const ViewLine) f64 {
        return if (self.rendered_view_line) |rendered| rendered.delta_top else 0;
    }

    pub fn getBottom(self: *const ViewLine) f64 {
        return self.getTop() + self.getHeight();
    }

    pub fn setTop(self: *ViewLine, top: f64) void {
        if (self.rendered_view_line) |*rendered| rendered.delta_top = top;
    }

    /// Terminal `ViewLine` width in cells. The browser reads client rects; the
    /// terminal uses the same codepoint widths the renderer lays out.
    fn measureCells(text: []const u8) usize {
        const CursorColumns = @import("../../../common/core/cursorColumns.zig").CursorColumns;
        var column: usize = 0;
        var offset: usize = 0;
        while (offset < text.len) {
            const len = std.unicode.utf8ByteSequenceLength(text[offset]) catch 1;
            const safe_len = @min(len, text.len - offset);
            const cp = std.unicode.utf8Decode(text[offset .. offset + safe_len]) catch @as(u21, text[offset]);
            offset += safe_len;
            column = CursorColumns.nextVisibleColumn(cp, column, 1);
        }
        return column;
    }
};

/// Terminal cell width of a codepoint, matching the editor's visible columns.
fn paintKeyOf(options: ViewLine.PaintOptions) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.sliceAsBytes(options.flags));
    for (options.guides) |guide| {
        hasher.update(std.mem.asBytes(&guide.column));
        hasher.update(std.mem.asBytes(&guide.color));
    }
    hasher.update(&[_]u8{@intFromBool(options.folded_ellipsis)});
    return hasher.final();
}

fn measureCellWidth(cp: u21) u2 {
    const CursorColumns = @import("../../../common/core/cursorColumns.zig").CursorColumns;
    const next = CursorColumns.nextVisibleColumn(cp, 0, 1);
    return @intCast(@min(next, 2));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const view_layer = @import("../../view/viewLayer.zig");
const view_model = @import("../../../common/viewModel.zig");
const browser_config = @import("../../config/editorConfiguration.zig");
const editor_configuration = @import("../../../common/config/editorConfiguration.zig");
const actions = @import("../../../../platform/actions/common/actions.zig");
const test_stubs = @import("../../../test/common/viewModelTestStubs.zig");
const languages = @import("../../../common/languages.zig");
const line_tokens = @import("../../../common/tokens/lineTokens.zig");
const Range = @import("../../../common/core/range.zig").Range;
const Position = @import("../../../common/core/position.zig").Position;
const Selection = @import("../../../common/core/selection.zig").Selection;
const TextDirection = @import("../../../common/standalone/standaloneEnums.zig").TextDirection;
const LanguageIdCodec = languages.LanguageIdCodec;
const ViewLineRenderingData = view_model.ViewLineRenderingData;
const IViewLineTokens = line_tokens.IViewLineTokens;

fn makeLineTokens(allocator: Allocator, codec: *LanguageIdCodec, content: []const u8) !line_tokens.LineTokens {
    var owned_content = std.array_list.Managed(u8).init(allocator);
    errdefer owned_content.deinit();
    try owned_content.appendSlice(content);
    return line_tokens.LineTokens.createEmpty(allocator, owned_content, codec);
}

const Fixture = struct {
    allocator: Allocator,
    codec: LanguageIdCodec,
    tokens: line_tokens.LineTokens,
    options: browser_config.ComputedEditorOptions,
    configuration: editor_configuration.IEditorConfiguration,
    layout: test_stubs.TestViewLayout,
    view_model: test_stubs.TestViewModel,
    context: view_context.ViewContext,
    offsets: [1]f64 = .{0},
    viewport: viewport_data.ViewportData,

    fn init(self: *Fixture, allocator: Allocator, content: []const u8) !void {
        self.allocator = allocator;
        self.codec = try LanguageIdCodec.init(allocator);
        errdefer self.codec.deinit();
        self.tokens = try makeLineTokens(allocator, &self.codec, content);
        errdefer self.tokens.deinit();

        self.options = browser_config.ComputedEditorOptions.init();
        self.layout = .{};
        self.view_model = test_stubs.TestViewModel.init(self.layout.interface());
        self.view_model.view_line_data = ViewLineRenderingData.init(
            1,
            content.len + 1,
            content,
            false,
            false,
            false,
            IViewLineTokens.init(&self.tokens),
            &.{},
            4,
            0,
            TextDirection.LTR,
            false,
        );

        self.configuration = .{
            .is_simple_widget = false,
            .context_menu_id = actions.menu_ids.EditorContext,
            .options = self.options.interface(),
        };
        self.context = view_context.ViewContext.init(&self.configuration, test_stubs.TestColorTheme.dark(), self.view_model.interface());
        self.viewport = .{
            .selections = &.{},
            .startLineNumber = 1,
            .endLineNumber = 1,
            .relativeVerticalOffset = &self.offsets,
            .visibleRange = Range.init(1, 1, 1, 1),
            .bigNumbersDelta = 0,
            .whitespaceViewportData = &.{},
            .lineHeight = 19,
            ._model = self.view_model.interface(),
        };
    }

    fn deinit(self: *Fixture) void {
        self.tokens.deinit();
        self.codec.deinit();
    }
};

test "view line renders tab-expanded text and tracks invalidation" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator, "a\tb");
    defer fixture.deinit();

    const line_options = ViewLineOptions.init(&fixture.configuration, .DARK);
    var line = ViewLine.init(allocator, &fixture.context, line_options);
    defer line.deinit(allocator);

    var sb = try StringBuilder.init(allocator, 8);
    defer sb.deinit();

    try testing.expect(line.shouldRender());
    try testing.expect(line.renderLine(1, 0, 19, &fixture.viewport, &sb));
    try testing.expectEqualStrings("a   b", sb.build());
    line.onDidRender();
    try testing.expect(!line.shouldRender());

    // Rendering the same content again reports no change but still appends.
    sb.reset();
    try testing.expect(!line.renderLine(1, 0, 19, &fixture.viewport, &sb));
    try testing.expectEqualStrings("a   b", sb.build());

    // Token changes invalidate the line.
    line.onTokensChanged();
    try testing.expect(line.shouldRender());
    line.onDidRender();
    try testing.expect(!line.shouldRender());
}

test "view line renders through the visible lines collection" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator, "x\ty");
    defer fixture.deinit();

    const line_options = ViewLineOptions.init(&fixture.configuration, .DARK);
    const Factory = struct {
        allocator: Allocator,
        context: *view_context.ViewContext,
        options: ViewLineOptions,

        fn create(context: *anyopaque) anyerror!ViewLine {
            const self: *@This() = @ptrCast(@alignCast(context));
            return ViewLine.init(self.allocator, self.context, self.options);
        }
    };
    var factory = Factory{ .allocator = allocator, .context = &fixture.context, .options = line_options };
    var collection = view_layer.VisibleLinesCollection(ViewLine).init(allocator, fixture.layout.interface(), .{
        .context = &factory,
        .create = Factory.create,
    });
    defer collection.deinit();

    var sb = try StringBuilder.init(allocator, 8);
    defer sb.deinit();
    try collection.renderLines(&fixture.viewport, &sb);
    try testing.expectEqualStrings("x   y", sb.build());
    _ = collection.onFlushed(&.{});
}

test "view line: unchanged render input skips rebuilding" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator, "plain");
    defer fixture.deinit();

    const line_options = ViewLineOptions.init(&fixture.configuration, .DARK);
    var line = ViewLine.init(allocator, &fixture.context, line_options);
    defer line.deinit(allocator);

    var sb = try StringBuilder.init(allocator, 8);
    defer sb.deinit();

    try testing.expect(line.renderLine(1, 3, 19, &fixture.viewport, &sb));
    const first = line.getRenderedViewLine().?;
    try testing.expectEqual(@as(f64, 3), first.delta_top);
    try testing.expectEqual(@as(f64, 19), first.line_height);

    sb.reset();
    try testing.expect(!line.renderLine(1, 9, 19, &fixture.viewport, &sb));
    try testing.expectEqualStrings("plain", sb.build());
    // The previous render is retained when the input did not change.
    try testing.expectEqual(@as(f64, 3), line.getRenderedViewLine().?.delta_top);
}

test "view line: high contrast selection adds the inline-selected-text decoration" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator, "abcdef");
    defer fixture.deinit();

    const line_options = ViewLineOptions.init(&fixture.configuration, .HIGH_CONTRAST_DARK);
    var line = ViewLine.init(allocator, &fixture.context, line_options);
    defer line.deinit(allocator);

    const selections = [_]Selection{Selection.init(1, 2, 1, 5)};
    fixture.viewport.selections = &selections;

    var sb = try StringBuilder.init(allocator, 8);
    defer sb.deinit();
    try testing.expect(line.renderLine(1, 0, 19, &fixture.viewport, &sb));

    const rendered = line.getRenderedViewLine().?;
    var found = false;
    for (rendered.input.line_decorations) |decoration| {
        if (std.mem.eql(u8, decoration.className, "inline-selected-text")) {
            found = true;
            try testing.expectEqual(@as(usize, 2), decoration.startColumn);
            try testing.expectEqual(@as(usize, 5), decoration.endColumn);
        }
    }
    try testing.expect(found);

    // Selection changes invalidate in high contrast even without selection
    // whitespace rendering.
    try testing.expect(line.onSelectionChanged());
}

test "view line: renderWhitespace selection builds selection ranges" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator, "a b c");
    defer fixture.deinit();
    fixture.options.set(.renderWhitespace, .selection);
    fixture.options.set(.experimentalWhitespaceRendering, .off);

    const line_options = ViewLineOptions.init(&fixture.configuration, .DARK);
    var line = ViewLine.init(allocator, &fixture.context, line_options);
    defer line.deinit(allocator);

    const selections = [_]Selection{Selection.init(1, 1, 1, 4)};
    fixture.viewport.selections = &selections;

    var sb = try StringBuilder.init(allocator, 8);
    defer sb.deinit();
    try testing.expect(line.renderLine(1, 0, 19, &fixture.viewport, &sb));

    const rendered = line.getRenderedViewLine().?;
    try testing.expectEqual(@as(usize, 1), rendered.selection_ranges.len);
    try testing.expectEqual(@as(usize, 0), rendered.selection_ranges[0].start);
    try testing.expectEqual(@as(usize, 3), rendered.selection_ranges[0].endExclusive);
}

test "view line: width is measured in terminal cells" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator, "a\u{4E2D}b");
    defer fixture.deinit();

    const line_options = ViewLineOptions.init(&fixture.configuration, .DARK);
    var line = ViewLine.init(allocator, &fixture.context, line_options);
    defer line.deinit(allocator);

    var sb = try StringBuilder.init(allocator, 8);
    defer sb.deinit();
    try testing.expect(line.renderLine(1, 0, 19, &fixture.viewport, &sb));
    try testing.expectEqual(@as(usize, 4), line.getWidth());
}
