// Port of `src/vs/editor/browser/viewParts/margin/margin.ts`.
//
// Terminal adaptation: the browser margin owns `LineNumbers`, glyph margin and
// line-decoration DOM parts. The terminal has one gutter column layout
// (`line numbers | fold | quick diff`) whose widths come from
// `editor.lineNumbers`, `editor.lineNumbersMinChars`, the folding options and
// the quick-diff marker width. This part paints the line-number / continuation
// cells, the folding control from the ported `FoldingDecorationProvider`, and
// the quick-diff marker cell from the ported `LinesDecorationsOverlay` class
// lists. Hit testing and the fold toggle stay in
// the host. A line-number map supplied by a diff snapshot can render a blank
// number for filler rows. Line-number, active-line, folding-control and
// quick-diff colors come from the terminal `Theme` bundle resolved by the TUI
// from the `editorLineNumber.*` and `editorGutter.*` ids.
//
// Folding icons follow the ported `folding.css`: expanded controls are hidden
// unless the margin overlays are hovered (`mouseover`, the upstream default) or
// the decoration selects `alwaysShowFoldIcons`; collapsed controls stay
// visible. The gutter root carries the CSS `:hover` rule as a paint-only
// `HoverStyle`, the terminal substitute for `.margin-view-overlays:hover`.
const std = @import("std");
const ui = @import("ui");

const editorBrowser = @import("../../editorBrowser.zig");
const RetainedViewPartHost = editorBrowser.RetainedViewPartHost;
const Editor = @import("../../widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const line_numbers_mod = @import("../lineNumbers/lineNumbers.zig");
const LineNumbersOverlay = line_numbers_mod.LineNumbersOverlay;
const lines_decorations_mod = @import("../linesDecorations/linesDecorations.zig");
const LinesDecorationsOverlay = lines_decorations_mod.LinesDecorationsOverlay;
const FoldingDecorationProvider = @import("../../../contrib/folding/browser/foldingDecorations.zig").FoldingDecorationProvider;
const folding_css = @import("../../../contrib/folding/browser/folding_css.zig");
const glyph_margin = @import("../glyphMargin/glyphMargin.zig");
const current_line_mod = @import("../currentLineHighlight/currentLineHighlight.zig");
const margin_decorations_mod = @import("../marginDecorations/marginDecorations.zig");
const GlyphMarginOverlay = glyph_margin.GlyphMarginOverlay;
const Glyph = glyph_margin.Glyph;

/// Terminal colors for the gutter. The TUI resolves the upstream color ids and
/// passes this bundle; the editor-layer view part keeps the defaults so a
/// standalone editor and tests need no theme service.
fn optionalColorEqual(a: ?ui.Color, b: ?ui.Color) bool {
    if (a == null or b == null) return (a == null) == (b == null);
    return a.?.eql(b.?);
}

/// Terminal mapping for the upstream `marginClassName` families. Unknown
/// classes stay invisible, like an upstream class without a CSS rule.
fn marginDecorationColor(class_name: []const u8, theme: Theme) ?ui.Color {
    if (std.mem.eql(u8, class_name, "gutter-insert")) return theme.added_primary;
    if (std.mem.eql(u8, class_name, "gutter-delete")) return theme.deleted_primary;
    if (std.mem.eql(u8, class_name, "chat-editing-last-edit")) return .{ .r = 50, .g = 90, .b = 140 };
    return null;
}

pub const Theme = struct {
    line_number: ui.Color = .{ .r = 110, .g = 110, .b = 110 },
    line_number_active: ui.Color = .{ .r = 204, .g = 204, .b = 204 },
    continuation: ui.Color = .{ .r = 90, .g = 90, .b = 90 },
    filler: ui.Color = .{ .r = 70, .g = 70, .b = 70 },
    folding_control: ui.Color = .{ .r = 110, .g = 110, .b = 110 },
    current_line_background: ui.Color = .{ .r = 40, .g = 40, .b = 40 },
    added_primary: ui.Color = .{ .r = 72, .g = 126, .b = 2 },
    modified_primary: ui.Color = .{ .r = 137, .g = 85, .b = 3 },
    deleted_primary: ui.Color = .{ .r = 173, .g = 7, .b = 7 },
    added_secondary: ui.Color = .{ .r = 47, .g = 75, .b = 6 },
    modified_secondary: ui.Color = .{ .r = 84, .g = 54, .b = 6 },
    deleted_secondary: ui.Color = .{ .r = 98, .g = 11, .b = 11 },

    pub fn dark() Theme {
        return .{};
    }
};

const QuickDiffMarker = struct {
    glyph: u8,
    color: ui.Color,
};

/// Port of the terminal-visible `Margin` paint subset.
///
/// Terminal retention: one row subtree is kept per visible view line and moved
/// with `RetainedViewPartHost.translateSubtree` when scrolling shifts it.
/// Rows entering the viewport get a subtree, leaving rows drop theirs; a row
/// whose number/fold/quick-diff paint changed rewrites its retained text nodes
/// and rebuilds only that row's box subtree. Geometry changes reset the row set.
pub const TerminalMargin = struct {
    allocator: std.mem.Allocator,
    /// Heap-owned rows: their inline text buffers are borrowed by the text
    /// nodes, so a row must not move when the list grows or swaps.
    rows: std.array_list.Managed(*Row),
    next_rows: std.array_list.Managed(*Row),
    /// Last gutter layout; a change invalidates every retained row's geometry.
    geometry_ready: bool = false,
    theme: Theme = Theme.dark(),
    theme_dirty: bool = true,
    gutter_width: usize = 0,
    number_width: usize = 0,
    fold_column: usize = 0,
    marker_width: usize = 0,

    const NumberKind = enum { blank, number, continuation };

    const FoldPaint = enum { none, collapsed, expanded };

    const Row = struct {
        view_line: usize,
        node: *ui.Node,
        highlight: *ui.Node,
        margin_highlight: bool = false,
        margin_decoration: ?ui.Color = null,
        glyph_cells: [3]*ui.Node,
        glyph_texts: [3]*ui.Node,
        number_line: *ui.Node,
        number_text: *ui.Node,
        filler_line: *ui.Node,
        filler_text: *ui.Node,
        fold_cell: *ui.Node,
        fold_text: *ui.Node,
        marker_cell: *ui.Node,
        marker_text: *ui.Node,
        painted_top: usize,
        gutter_width: usize,
        number_kind: NumberKind = .blank,
        number_active: bool = false,
        glyphs: [3]?Glyph = .{ null, null, null },
        glyph_bufs: [3][4]u8 = undefined,
        /// Owned copy of the painted number/continuation text. The text node
        /// borrows it, so a custom line-number renderer of any length is kept.
        number_owned: ?[]u8 = null,
        filler: bool = false,
        fold: FoldPaint = .none,
        /// The icon stays visible without hover (`alwaysShowFoldIcons` or a
        /// collapsed range).
        fold_visible: bool = false,
        marker: ?QuickDiffMarker = null,
        marker_buf: [1]u8 = undefined,
    };

    /// The paint inputs for one screen row, computed from the current editor
    /// and decoration state before comparing it with the retained row.
    const RowPaint = struct {
        filler: bool,
        filler_visible: bool,
        number_kind: NumberKind = .blank,
        number_active: bool = false,
        glyphs: [3]?Glyph = .{ null, null, null },
        margin_highlight: bool = false,
        margin_decoration: ?ui.Color = null,
        number_buf: [32]u8 = undefined,
        number_len: usize = 0,
        /// Text owned by the line-number overlay; only valid for the duration
        /// of this render pass, so `applyPaint` copies it into the row.
        number_borrowed: ?[]const u8 = null,
        fold: FoldPaint = .none,
        fold_visible: bool = false,
        marker: ?QuickDiffMarker = null,

        fn numberText(self: *const RowPaint) []const u8 {
            return self.number_borrowed orelse self.number_buf[0..self.number_len];
        }
    };

    fn rowNumberText(row: *const Row) []const u8 {
        return row.number_owned orelse "";
    }

    pub fn init(allocator: std.mem.Allocator) TerminalMargin {
        return .{
            .allocator = allocator,
            .rows = std.array_list.Managed(*Row).init(allocator),
            .next_rows = std.array_list.Managed(*Row).init(allocator),
        };
    }

    /// Applies the host-resolved gutter colors. The retained rows are reset on
    /// the next render so every text node picks up the new colors.
    pub fn setTheme(self: *TerminalMargin, theme: Theme) void {
        self.theme = theme;
        self.theme_dirty = true;
    }

    pub fn deinit(self: *TerminalMargin) void {
        self.resetNodes();
        self.rows.deinit();
        self.next_rows.deinit();
    }

    /// Drops the retained row pointers when the document that owns their nodes
    /// is being cleared or replaced. The nodes are not touched.
    pub fn resetNodes(self: *TerminalMargin) void {
        for (self.rows.items) |row| {
            if (row.number_owned) |owned| self.allocator.free(owned);
            self.allocator.destroy(row);
        }
        self.rows.clearRetainingCapacity();
        self.next_rows.clearRetainingCapacity();
        self.geometry_ready = false;
    }

    /// Paints the gutter rows for the current viewport.
    pub fn render(
        self: *TerminalMargin,
        doc: *ui.Document,
        root: *ui.Node,
        editor: *Editor,
        line_numbers: *const LineNumbersOverlay,
        line_decorations: *const LinesDecorationsOverlay,
        glyph_margin_overlay: ?*const GlyphMarginOverlay,
        line_highlight: ?*const current_line_mod.AbstractLineHighlightOverlay,
        margin_decorations: *const margin_decorations_mod.MarginViewLineDecorationsOverlay,
        folding: *const FoldingDecorationProvider,
        gutter: usize,
        text_height: usize,
        host: ?*RetainedViewPartHost,
    ) !void {
        const total = editor.viewLineCount();
        const top = editor.topViewLine();
        const marker_width = editor.lineDecorationsWidth();
        const fold_column = editor.foldCellColumn();
        const fold_width = editor.gutterFoldWidth();
        const number_width = editor.gutterNumberWidth();
        const glyph_width = editor.gutterGlyphWidth();

        if (self.theme_dirty) {
            try self.resetRows(doc, host);
            self.geometry_ready = false;
            self.theme_dirty = false;
        }

        if (!self.geometry_ready or self.gutter_width != gutter or
            self.number_width != number_width or
            self.fold_column != fold_column or
            self.marker_width != marker_width)
        {
            try self.resetRows(doc, host);
            self.gutter_width = gutter;
            self.number_width = number_width;
            self.fold_column = fold_column;
            self.marker_width = marker_width;
            self.geometry_ready = true;
        }

        // `.margin-view-overlays:hover .codicon` from folding.css. The root is
        // the terminal margin overlays container; when the pointer is over any
        // gutter row it is in the hover chain and its paint-only visibility
        // overlay reveals the hidden expanded icons. This never dirties layout.
        root.setHoverStyle(if (fold_width > 0) folding_css.hoverStyle() else null);

        self.next_rows.clearRetainingCapacity();
        var old_index: usize = 0;
        var screen_row: usize = 0;
        while (screen_row < text_height) : (screen_row += 1) {
            const view_line = editor.viewLineAtViewportRow(screen_row) orelse blk: {
                // A zone is not a model line, so it has no number, fold
                // control or line decoration. Leave the margin background.
                if ((try editor.viewLayout().getWhitespaceAtVerticalOffset(@floatFromInt(editor.scrollTop() + screen_row))) != null) continue;
                break :blk @max(total + 1, top + screen_row);
            };
            while (old_index < self.rows.items.len and
                self.rows.items[old_index].view_line < view_line) : (old_index += 1)
            {
                self.destroyRow(doc, host, self.rows.items[old_index]);
            }

            const paint = self.computePaint(
                editor,
                line_numbers,
                line_decorations,
                glyph_margin_overlay,
                line_highlight,
                margin_decorations,
                folding,
                view_line,
                total,
                number_width,
                glyph_width,
                fold_width,
                marker_width,
            );

            if (old_index < self.rows.items.len and
                self.rows.items[old_index].view_line == view_line)
            {
                const row = self.rows.items[old_index];
                old_index += 1;
                const changed = try applyPaint(self, row, paint);
                if (row.painted_top != screen_row) {
                    const dy = @as(f64, @floatFromInt(screen_row)) -
                        @as(f64, @floatFromInt(row.painted_top));
                    row.node.asElement().style.top = .{ .cells = @floatFromInt(screen_row) };
                    if (host) |retained| retained.translateSubtree(row.node, dy);
                    row.painted_top = screen_row;
                }
                if (changed) {
                    if (host) |retained| try retained.rebuildSubtree(row.node);
                }
                try self.next_rows.append(row);
            } else {
                const row = try self.createRow(
                    doc,
                    root,
                    paint,
                    view_line,
                    screen_row,
                    gutter,
                    number_width,
                    glyph_width,
                    fold_column,
                );
                if (host) |retained| try retained.addSubtree(row.node);
                try self.next_rows.append(row);
            }
        }

        while (old_index < self.rows.items.len) : (old_index += 1) {
            self.destroyRow(doc, host, self.rows.items[old_index]);
        }
        std.mem.swap(std.array_list.Managed(*Row), &self.rows, &self.next_rows);
    }

    fn computePaint(
        self: *const TerminalMargin,
        editor: *Editor,
        line_numbers: *const LineNumbersOverlay,
        line_decorations: *const LinesDecorationsOverlay,
        glyph_margin_overlay: ?*const GlyphMarginOverlay,
        line_highlight: ?*const current_line_mod.AbstractLineHighlightOverlay,
        margin_decorations: *const margin_decorations_mod.MarginViewLineDecorationsOverlay,
        folding: *const FoldingDecorationProvider,
        view_line: usize,
        total: usize,
        number_width: usize,
        glyph_width: usize,
        fold_width: usize,
        marker_width: usize,
    ) RowPaint {
        if (view_line > total) {
            return .{ .filler = true, .filler_visible = number_width > 0 };
        }

        var paint = RowPaint{ .filler = false, .filler_visible = false };
        const output_index = editor.outputLineIndex(view_line);
        if (output_index == 0) {
            if (glyph_width > 0) {
                if (glyph_margin_overlay) |overlay| {
                    const line_glyphs = overlay.renderedLine(view_line);
                    for (0..3) |lane| {
                        if (line_glyphs.lanes[lane]) |slot| paint.glyphs[lane] = slot.glyph;
                    }
                }
            }
            if (editor.line_number_map != null) {
                // A diff snapshot's line-number map wins; `null` entries are
                // filler rows with a blank number.
                if (editor.displayLineNumber(view_line)) |display_line| {
                    const number = std.fmt.bufPrint(&paint.number_buf, "{d}", .{display_line}) catch "";
                    paint.number_len = number.len;
                }
            } else if (line_numbers.renderedLine(view_line)) |rendered| {
                paint.number_borrowed = rendered.text;
            }
            if (paint.number_len > 0 or
                (paint.number_borrowed != null and paint.number_borrowed.?.len > 0))
            {
                paint.number_kind = .number;
            }
            if (paint.number_kind == .number) {
                paint.number_active = editor.modelLineNumber(view_line) == editor.modelCursorPosition().lineNumber;
            }

            if (fold_width > 0) {
                const model_line = editor.modelLineNumber(view_line);
                const state = editor.foldStateAtModelLine(model_line);
                if (state != .none) {
                    const option = folding.getDecorationOption(state == .collapsed, false, false);
                    paint.fold = switch (option.fold_icon) {
                        .none => .none,
                        .collapsed => .collapsed,
                        .expanded => .expanded,
                    };
                    paint.fold_visible = state == .collapsed or option.alwaysShowFoldIcons();
                }
            }

            if (marker_width > 0) {
                paint.marker = quickDiffMarkerWithTheme(line_decorations.renderedLine(view_line), self.theme) orelse
                    lineDecorationMarkerWithTheme(line_decorations.renderedLine(view_line), self.theme);
            }
        } else if (number_width > 0) {
            const glyph = "\u{21AA}";
            @memcpy(paint.number_buf[0..glyph.len], glyph);
            paint.number_len = glyph.len;
            paint.number_kind = .continuation;
        }
        if (line_highlight) |overlay| {
            if (overlay.renderedLine(view_line)) |highlight| {
                paint.margin_highlight = highlight.in_margin;
            }
        }
        if (margin_decorations.renderedLine(view_line)) |line| {
            var best_z: i32 = std.math.minInt(i32);
            for (line.getDecorations()) |decoration| {
                if (marginDecorationColor(decoration.class_name, self.theme)) |color| {
                    if (decoration.z_index >= best_z) {
                        best_z = decoration.z_index;
                        paint.margin_decoration = color;
                    }
                }
            }
        }
        return paint;
    }

    fn createRow(
        self: *TerminalMargin,
        doc: *ui.Document,
        root: *ui.Node,
        paint: RowPaint,
        view_line: usize,
        screen_row: usize,
        gutter: usize,
        number_width: usize,
        glyph_width: usize,
        fold_column: usize,
    ) !*Row {
        const row_cells: f64 = @floatFromInt(screen_row);
        const row_node = try doc.createElement(.div);
        row_node.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = 0 },
            .top = .{ .cells = row_cells },
            .width = .{ .cells = @floatFromInt(gutter) },
            .height = .{ .cells = 1 },
        });

        const highlight = try doc.createElement(.div);
        highlight.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = 0 },
            .top = .{ .cells = 0 },
            .width = .{ .cells = @floatFromInt(gutter) },
            .height = .{ .cells = 1 },
            .display = .none,
        });
        _ = try row_node.appendChild(highlight);

        var glyph_cells: [3]*ui.Node = undefined;
        var glyph_texts: [3]*ui.Node = undefined;
        for (0..3) |lane| {
            const cell = try doc.createElement(.div);
            cell.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = @floatFromInt(lane) },
                .top = .{ .cells = 0 },
                .width = .{ .cells = 1 },
                .height = .{ .cells = 1 },
                .white_space = .pre,
                .display = .none,
            });
            const text = try doc.createTextBorrowed("");
            _ = try cell.appendChild(text);
            glyph_cells[lane] = cell;
            glyph_texts[lane] = text;
        }

        const number_line = try doc.createElement(.div);
        number_line.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = @floatFromInt(glyph_width) },
            .top = .{ .cells = 0 },
            .width = .{ .cells = @floatFromInt(number_width) },
            .height = .{ .cells = 1 },
            .white_space = .pre,
            .text_align = .right,
            .display = if (paint.filler) .none else .block,
        });
        const number_text = try doc.createTextBorrowed("");
        _ = try number_line.appendChild(number_text);

        const filler_line = try doc.createElement(.div);
        filler_line.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = @floatFromInt(glyph_width) },
            .top = .{ .cells = 0 },
            .width = .{ .cells = @floatFromInt(number_width) },
            .height = .{ .cells = 1 },
            .white_space = .pre,
            .text_align = .right,
            .display = if (paint.filler_visible) .block else .none,
        });
        const filler_text = try doc.createTextBorrowed("~");
        filler_text.setStyle(.{ .color = self.theme.filler });
        _ = try filler_line.appendChild(filler_text);

        const fold_cell = try doc.createElement(.div);
        try setFoldClasses(fold_cell, paint.fold, paint.fold_visible);
        fold_cell.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = @floatFromInt(fold_column) },
            .top = .{ .cells = 0 },
            .width = .{ .cells = 1 },
            .height = .{ .cells = 1 },
            .white_space = .pre,
            .display = .none,
        });
        const fold_text = try doc.createTextBorrowed("");
        fold_text.setStyle(.{ .color = self.theme.folding_control });
        _ = try fold_cell.appendChild(fold_text);

        const marker_cell = try doc.createElement(.div);
        marker_cell.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = @floatFromInt(gutter -| 1) },
            .top = .{ .cells = 0 },
            .width = .{ .cells = 1 },
            .height = .{ .cells = 1 },
            .white_space = .pre,
            .display = .none,
        });
        const marker_text = try doc.createTextBorrowed("");
        marker_text.setStyle(.{ .color = self.theme.line_number });
        _ = try marker_cell.appendChild(marker_text);

        for (0..3) |lane| _ = try row_node.appendChild(glyph_cells[lane]);
        _ = try row_node.appendChild(number_line);
        _ = try row_node.appendChild(filler_line);
        _ = try row_node.appendChild(fold_cell);
        _ = try row_node.appendChild(marker_cell);
        _ = try root.appendChild(row_node);

        const row = try self.allocator.create(Row);
        errdefer self.allocator.destroy(row);
        row.* = .{
            .view_line = view_line,
            .node = row_node,
            .highlight = highlight,
            .glyph_cells = glyph_cells,
            .glyph_texts = glyph_texts,
            .number_line = number_line,
            .number_text = number_text,
            .filler_line = filler_line,
            .filler_text = filler_text,
            .fold_cell = fold_cell,
            .fold_text = fold_text,
            .marker_cell = marker_cell,
            .marker_text = marker_text,
            .painted_top = screen_row,
            .gutter_width = gutter,
        };
        _ = try applyPaint(self, row, paint);
        return row;
    }

    fn destroyRow(
        self: *TerminalMargin,
        doc: *ui.Document,
        host: ?*RetainedViewPartHost,
        row: *Row,
    ) void {
        if (host) |retained| retained.removeSubtree(row.node);
        doc.destroy(row.node);
        if (row.number_owned) |owned| self.allocator.free(owned);
        self.allocator.destroy(row);
    }

    fn resetRows(
        self: *TerminalMargin,
        doc: *ui.Document,
        host: ?*RetainedViewPartHost,
    ) !void {
        for (self.rows.items) |row| {
            if (host) |retained| retained.removeSubtree(row.node);
            doc.destroy(row.node);
            if (row.number_owned) |owned| self.allocator.free(owned);
            self.allocator.destroy(row);
        }
        self.rows.clearRetainingCapacity();
        self.next_rows.clearRetainingCapacity();
    }
};

fn applyPaint(self: *TerminalMargin, row: *TerminalMargin.Row, paint: TerminalMargin.RowPaint) !bool {
    var changed = false;
    if (row.filler != paint.filler) {
        row.filler = paint.filler;
        setDisplay(row.number_line, !paint.filler);
        setDisplay(row.filler_line, paint.filler_visible);
        if (paint.filler) {
            row.fold = .none;
            row.marker = null;
            setDisplay(row.fold_cell, false);
            setDisplay(row.marker_cell, false);
        }
        changed = true;
    }

    const number = paint.numberText();
    if (row.number_kind != paint.number_kind or
        row.number_active != paint.number_active or
        !std.mem.eql(u8, TerminalMargin.rowNumberText(row), number))
    {
        const copy = try self.allocator.dupe(u8, number);
        if (row.number_owned) |owned| self.allocator.free(owned);
        row.number_owned = copy;
        row.number_kind = paint.number_kind;
        row.number_active = paint.number_active;
        row.number_text.setTextBorrowed(copy);
        row.number_text.setStyle(.{ .color = switch (paint.number_kind) {
            .continuation => self.theme.continuation,
            else => if (paint.number_active) self.theme.line_number_active else self.theme.line_number,
        } });
        changed = true;
    }

    const highlight_changed = row.margin_highlight != paint.margin_highlight or
        !optionalColorEqual(row.margin_decoration, paint.margin_decoration);
    if (highlight_changed) {
        row.margin_highlight = paint.margin_highlight;
        row.margin_decoration = paint.margin_decoration;
        const background = paint.margin_decoration orelse
            (if (paint.margin_highlight) self.theme.current_line_background else null);
        if (background) |color| {
            row.highlight.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = 0 },
                .top = .{ .cells = 0 },
                .width = .{ .cells = @floatFromInt(row.gutter_width) },
                .height = .{ .cells = 1 },
                .background = color,
                .display = .block,
            });
        } else {
            setDisplay(row.highlight, false);
        }
        changed = true;
    }

    for (0..3) |lane| {
        const current = row.glyphs[lane];
        const next = paint.glyphs[lane];
        const glyph_changed = blk: {
            if (current == null or next == null) break :blk (current == null) != (next == null);
            break :blk current.?.codepoint != next.?.codepoint or !current.?.color.eql(next.?.color);
        };
        if (!glyph_changed) continue;
        row.glyphs[lane] = next;
        if (next) |glyph| {
            const len = std.unicode.utf8Encode(glyph.codepoint, &row.glyph_bufs[lane]) catch 0;
            row.glyph_texts[lane].setTextBorrowed(row.glyph_bufs[lane][0..len]);
            row.glyph_texts[lane].setStyle(.{ .color = glyph.color });
            setDisplay(row.glyph_cells[lane], true);
        } else {
            setDisplay(row.glyph_cells[lane], false);
        }
        changed = true;
    }

    if (!paint.filler and (row.fold != paint.fold or row.fold_visible != paint.fold_visible)) {
        row.fold = paint.fold;
        row.fold_visible = paint.fold_visible;
        try setFoldClasses(row.fold_cell, paint.fold, paint.fold_visible);
        if (paint.fold == .none) {
            setDisplay(row.fold_cell, false);
        } else {
            setDisplay(row.fold_cell, true);
            row.fold_text.setTextBorrowed(if (paint.fold == .collapsed) "\u{25B8}" else "\u{25BE}");
        }
        changed = true;
    }

    if (!paint.filler) {
        const marker_changed = blk: {
            const current = row.marker orelse break :blk paint.marker != null;
            const next = paint.marker orelse break :blk true;
            break :blk current.glyph != next.glyph or !current.color.eql(next.color);
        };
        if (marker_changed) {
            row.marker = paint.marker;
            if (paint.marker) |marker| {
                setDisplay(row.marker_cell, true);
                row.marker_buf[0] = marker.glyph;
                row.marker_text.setTextBorrowed(row.marker_buf[0..1]);
                row.marker_text.setStyle(.{ .color = marker.color });
                row.marker_cell.asElement().style.color = marker.color;
            } else {
                setDisplay(row.marker_cell, false);
            }
            changed = true;
        }
    }
    return changed;
}

/// Port of the folding.css visibility classes: the base codicon class hides
/// the glyph, a collapsed range and `alwaysShowFoldIcons` override it. The
/// margin hover style reveals the remaining (mouseover) expanded icons.
fn setFoldClasses(node: *ui.Node, fold: TerminalMargin.FoldPaint, always_visible: bool) !void {
    switch (fold) {
        .none => try node.setClasses(&.{folding_css.Class.codicon_folding}),
        .collapsed => try node.setClasses(&.{
            folding_css.Class.codicon_folding,
            folding_css.Class.codicon_folding_collapsed,
        }),
        .expanded => if (always_visible)
            try node.setClasses(&.{
                folding_css.Class.codicon_folding,
                folding_css.Class.always_show_fold_icons,
            })
        else
            try node.setClasses(&.{folding_css.Class.codicon_folding}),
    }
}

fn setDisplay(node: *ui.Node, visible: bool) void {
    node.asElement().style.display = if (visible) .block else .none;
}

/// Maps the upstream `dirty-diff-*` class names (see
/// `scm/browser/quickDiffDecorator.ts`) onto a terminal marker glyph and color.
/// `primary` wins over `secondary`/`pattern`; pattern and secondary variants
/// use the dimmed color because a cell has no alpha.
pub fn quickDiffMarker(decorations: ?*const @import("../glyphMargin/glyphMargin.zig").VisibleLineDecorationsToRender) ?QuickDiffMarker {
    return quickDiffMarkerWithTheme(decorations, Theme.dark());
}

/// The themed form used by the composer. The class names are the upstream
/// `dirty-diff-*` classes; the colors are the `editorGutter.*` ids.
pub fn quickDiffMarkerWithTheme(
    decorations: ?*const @import("../glyphMargin/glyphMargin.zig").VisibleLineDecorationsToRender,
    theme: Theme,
) ?QuickDiffMarker {
    const line = decorations orelse return null;
    var result: ?QuickDiffMarker = null;
    var result_primary = false;
    for (line.getDecorations()) |decoration| {
        const parsed = parseQuickDiffClass(decoration.class_name) orelse continue;
        if (result == null or (parsed.primary and !result_primary)) {
            const marker_color = switch (parsed.kind) {
                .added => if (parsed.primary and !parsed.dimmed) theme.added_primary else theme.added_secondary,
                .modified => if (parsed.primary and !parsed.dimmed) theme.modified_primary else theme.modified_secondary,
                .deleted => if (parsed.primary and !parsed.dimmed) theme.deleted_primary else theme.deleted_secondary,
            };
            result = .{ .glyph = parsed.glyph, .color = marker_color };
            result_primary = parsed.primary;
        }
    }
    return result;
}

/// Terminal mapping for the remaining upstream `linesDecorationsClassName`
/// families. Unknown classes stay invisible, like an upstream class without a
/// CSS rule.
pub fn lineDecorationMarkerWithTheme(
    decorations: ?*const @import("../glyphMargin/glyphMargin.zig").VisibleLineDecorationsToRender,
    theme: Theme,
) ?QuickDiffMarker {
    const line = decorations orelse return null;
    for (line.getDecorations()) |decoration| {
        var tokens = std.mem.tokenizeScalar(u8, decoration.class_name, ' ');
        while (tokens.next()) |token| {
            if (std.mem.eql(u8, token, "insert-sign")) return .{ .glyph = '+', .color = theme.added_primary };
            if (std.mem.eql(u8, token, "delete-sign")) return .{ .glyph = '-', .color = theme.deleted_primary };
            if (std.mem.eql(u8, token, "comment-range-glyph")) return .{ .glyph = '|', .color = theme.modified_primary };
            if (std.mem.eql(u8, token, "first-line")) return .{ .glyph = '>', .color = theme.line_number_active };
        }
    }
    return null;
}

const QuickDiffKind = enum { added, modified, deleted };

const ParsedQuickDiffClass = struct {
    glyph: u8,
    kind: QuickDiffKind,
    primary: bool,
    dimmed: bool,
};

fn parseQuickDiffClass(classes: []const u8) ?ParsedQuickDiffClass {
    var kind: ?QuickDiffKind = null;
    var primary = false;
    var dimmed = false;
    var iterator = std.mem.tokenizeScalar(u8, classes, ' ');
    while (iterator.next()) |word| {
        if (std.mem.eql(u8, word, "dirty-diff-added")) {
            kind = .added;
        } else if (std.mem.eql(u8, word, "dirty-diff-modified")) {
            kind = .modified;
        } else if (std.mem.eql(u8, word, "dirty-diff-deleted")) {
            kind = .deleted;
        } else if (std.mem.eql(u8, word, "primary")) {
            primary = true;
        } else if (std.mem.eql(u8, word, "secondary") or std.mem.eql(u8, word, "pattern")) {
            dimmed = true;
        }
    }
    const resolved = kind orelse return null;
    return .{
        .glyph = switch (resolved) {
            .added => '+',
            .modified => '~',
            .deleted => '-',
        },
        .kind = resolved,
        .primary = primary,
        .dimmed = dimmed,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const model_mod = @import("../../../common/model.zig");
const Range = @import("../../../common/core/range.zig").Range;
const TerminalViewHost = @import("../../widget/codeEditor/terminalViewHost.zig").TerminalViewHost;

fn lineWith(allocator: std.mem.Allocator, classes: []const u8) !glyph_margin.VisibleLineDecorationsToRender {
    var rendered = glyph_margin.VisibleLineDecorationsToRender.init(allocator);
    errdefer rendered.deinit();
    try rendered.add(.{
        .class_name = classes,
        .z_index = 0,
        .tooltip = null,
    });
    return rendered;
}

test "margin: quick diff marker classes map to glyph and color" {
    const allocator = testing.allocator;
    var added = try lineWith(allocator, "dirty-diff-glyph dirty-diff-added primary");
    defer added.deinit();
    const marker = quickDiffMarker(&added).?;
    try testing.expectEqual(@as(u8, '+'), marker.glyph);
    try testing.expect(marker.color.eql(Theme.dark().added_primary));

    var modified_pattern = try lineWith(allocator, "dirty-diff-glyph dirty-diff-modified primary pattern");
    defer modified_pattern.deinit();
    const pattern_marker = quickDiffMarker(&modified_pattern).?;
    try testing.expectEqual(@as(u8, '~'), pattern_marker.glyph);
    try testing.expect(pattern_marker.color.eql(Theme.dark().modified_secondary));

    var deleted = try lineWith(allocator, "dirty-diff-glyph dirty-diff-deleted secondary");
    defer deleted.deinit();
    const deleted_marker = quickDiffMarker(&deleted).?;
    try testing.expectEqual(@as(u8, '-'), deleted_marker.glyph);
    try testing.expect(deleted_marker.color.eql(Theme.dark().deleted_secondary));

    try testing.expect(quickDiffMarker(null) == null);
    var unrelated = try lineWith(allocator, "fold-glyph");
    defer unrelated.deinit();
    try testing.expect(quickDiffMarker(&unrelated) == null);
}

test "margin: primary marker wins over secondary on the same line" {
    const allocator = testing.allocator;
    var rendered = glyph_margin.VisibleLineDecorationsToRender.init(allocator);
    defer rendered.deinit();
    try rendered.add(.{ .class_name = "dirty-diff-added secondary", .z_index = 0, .tooltip = null });
    try rendered.add(.{ .class_name = "dirty-diff-modified primary", .z_index = 0, .tooltip = null });
    const marker = quickDiffMarker(&rendered).?;
    try testing.expectEqual(@as(u8, '~'), marker.glyph);
}

test "margin: theme colors the line numbers and the active line" {
    const allocator = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "a\nb", "test.txt", 20, 4);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const host = try TerminalViewHost.init(allocator, editor);
    defer host.deinit();
    try host.renderRange(1, 2);

    var doc = try ui.Document.init(allocator, .{ .cols = 20, .rows = 4 });
    defer doc.deinit();
    const root = try doc.createElement(.div);
    doc.setRoot(root);

    var margin = TerminalMargin.init(allocator);
    defer margin.deinit();
    margin.setTheme(.{
        .line_number = .{ .r = 10, .g = 20, .b = 30 },
        .line_number_active = .{ .r = 40, .g = 50, .b = 60 },
        .folding_control = .{ .r = 70, .g = 80, .b = 90 },
        .added_primary = .{ .r = 100, .g = 110, .b = 120 },
    });
    const folding = FoldingDecorationProvider{};
    try margin.render(
        &doc,
        root,
        editor,
        &host.line_numbers,
        &host.line_decorations,
        host.glyphMargin(),
        null,
        host.marginDecorations(),
        &folding,
        editor.gutterWidth(),
        editor.textHeight(),
        null,
    );

    try testing.expect(margin.rows.items.len >= 2);
    try testing.expect(margin.rows.items[0].number_text.paintStyle().?.color.?.eql(.{ .r = 40, .g = 50, .b = 60 }));
    try testing.expect(margin.rows.items[1].number_text.paintStyle().?.color.?.eql(.{ .r = 10, .g = 20, .b = 30 }));
}

test "margin: mouseover fold icons hide expanded and keep collapsed visible" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(
        allocator,
        io,
        "class A {\n  void f() {\n    x();\n  }\n}",
        "test.zig",
        40,
        8,
    );
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    editor.refreshFoldingIfDirty();

    const host = try TerminalViewHost.init(allocator, editor);
    defer host.deinit();
    try host.renderRange(1, editor.viewLineCount());

    var doc = try ui.Document.init(allocator, .{ .cols = 40, .rows = 8 });
    defer doc.deinit();
    const root = try doc.createElement(.div);
    doc.setRoot(root);
    try @import("../../../browser/editorCss.zig").register(&doc);

    var margin = TerminalMargin.init(allocator);
    defer margin.deinit();
    var folding = FoldingDecorationProvider{};
    try margin.render(
        &doc,
        root,
        editor,
        &host.line_numbers,
        &host.line_decorations,
        host.glyphMargin(),
        null,
        host.marginDecorations(),
        &folding,
        editor.gutterWidth(),
        editor.textHeight(),
        null,
    );

    // `mouseover` (the upstream default) hides the expanded control; the
    // margin container carries the hover rule that reveals it.
    try std.testing.expectEqual(TerminalMargin.FoldPaint.expanded, margin.rows.items[0].fold);
    try std.testing.expect(!margin.rows.items[0].fold_visible);
    try std.testing.expect(margin.rows.items[0].fold_cell.hasClass(folding_css.Class.codicon_folding));
    try std.testing.expect(!margin.rows.items[0].fold_cell.hasClass(folding_css.Class.always_show_fold_icons));
    try std.testing.expectEqual(
        ui.Visibility.hidden,
        margin.rows.items[0].fold_cell.computedStyle().visibility,
    );
    try std.testing.expectEqual(ui.Visibility.visible, root.asElement().hover_style.?.visibility.?);

    // `showFoldingControls: always` selects the upstream
    // `alwaysShowFoldIcons` decoration class.
    folding.show_folding_controls = .always;
    try margin.render(
        &doc,
        root,
        editor,
        &host.line_numbers,
        &host.line_decorations,
        host.glyphMargin(),
        null,
        host.marginDecorations(),
        &folding,
        editor.gutterWidth(),
        editor.textHeight(),
        null,
    );
    try std.testing.expect(margin.rows.items[0].fold_cell.hasClass(folding_css.Class.always_show_fold_icons));
    try std.testing.expectEqual(
        ui.Visibility.visible,
        margin.rows.items[0].fold_cell.computedStyle().visibility,
    );

    // A collapsed control is visible regardless of hover.
    _ = try editor.toggleFoldAtViewLine(1);
    folding.show_folding_controls = .mouseover;
    try margin.render(
        &doc,
        root,
        editor,
        &host.line_numbers,
        &host.line_decorations,
        host.glyphMargin(),
        null,
        host.marginDecorations(),
        &folding,
        editor.gutterWidth(),
        editor.textHeight(),
        null,
    );
    try std.testing.expectEqual(TerminalMargin.FoldPaint.collapsed, margin.rows.items[0].fold);
    try std.testing.expect(margin.rows.items[0].fold_cell.hasClass(folding_css.Class.codicon_folding_collapsed));
    try std.testing.expectEqual(
        ui.Visibility.visible,
        margin.rows.items[0].fold_cell.computedStyle().visibility,
    );
}

test "margin: paints the line-number map, blank filler and the quick-diff cell" {
    const allocator = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "a\nb\nc", "test.txt", 40, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    editor.setLineDecorationsWidth(1);
    const map = [_]?usize{ 10, null, 12 };
    editor.setLineNumberMap(&map);
    defer editor.clearLineNumberMap();

    const host = try TerminalViewHost.init(allocator, editor);
    defer host.deinit();

    var options = model_mod.ModelDecorationOptions.init("test", .AlwaysGrowsWhenTypingAtEdges);
    options.linesDecorationsClassName = "dirty-diff-glyph dirty-diff-added primary";
    options.isWholeLine = true;
    const delta = [_]model_mod.ModelDeltaDecoration{.{
        .range = Range.init(2, 1, 2, 1),
        .options = &options,
    }};
    const ids = try editor.model.deltaDecorations(&.{}, &delta, 7);
    defer allocator.free(ids);

    try host.renderRange(1, 3);

    var doc = try ui.Document.init(allocator, .{ .cols = 40, .rows = 5 });
    defer doc.deinit();
    const root = try doc.createElement(.div);
    doc.setRoot(root);

    var margin = TerminalMargin.init(allocator);
    defer margin.deinit();
    const folding = FoldingDecorationProvider{};
    try margin.render(
        &doc,
        root,
        editor,
        &host.line_numbers,
        &host.line_decorations,
        host.glyphMargin(),
        null,
        host.marginDecorations(),
        &folding,
        editor.gutterWidth(),
        editor.textHeight(),
        null,
    );

    // Gutter layout: numbers | fold | quick-diff marker.
    try testing.expectEqual(@as(usize, 7), editor.gutterWidth());
    try testing.expectEqual(@as(usize, 5), editor.foldCellColumn());
    try testing.expectEqual(@as(usize, 6), editor.quickDiffCellColumn());

    try testing.expectEqual(@as(?usize, 10), editor.displayLineNumber(1));
    try testing.expectEqual(@as(?usize, null), editor.displayLineNumber(2));
    try testing.expectEqual(@as(?usize, 12), editor.displayLineNumber(3));

    const text = try root.textContentAlloc(allocator);
    defer allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "10") != null);
    try testing.expect(std.mem.indexOf(u8, text, "12") != null);
    try testing.expect(std.mem.indexOf(u8, text, "11") == null);
    try testing.expect(std.mem.indexOf(u8, text, "+") != null);
}

test "margin: without a map the model line number is painted" {
    const allocator = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "a", "test.txt", 20, 3);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try testing.expectEqual(@as(?usize, 1), editor.displayLineNumber(1));
    try testing.expectEqual(@as(?usize, null), editor.displayLineNumber(2));

    editor.setLineDecorationsWidth(1);
    try testing.expectEqual(@as(usize, 7), editor.gutterWidth());
    try testing.expectEqual(@as(usize, 5), editor.foldCellColumn());
    editor.setLineDecorationsWidth(0);
    try testing.expectEqual(@as(usize, 6), editor.gutterWidth());
}
