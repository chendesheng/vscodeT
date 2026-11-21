// Port of `src/vs/editor/browser/viewParts/margin/margin.ts`.
//
// Terminal adaptation: the browser margin owns `LineNumbers`, glyph margin and
// line-decoration DOM parts. The terminal has one gutter column layout
// (`line numbers | fold | quick diff`), so this part paints the line-number /
// continuation cells, the folding control from the ported
// `FoldingDecorationProvider`, and the quick-diff marker cell from the ported
// `LinesDecorationsOverlay` class lists. Hit testing and the fold toggle stay in
// the host. A line-number map supplied by a diff snapshot can render a blank
// number for filler rows.
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

const gutter_color = [3]u8{ 110, 110, 110 };
const continuation_color = [3]u8{ 90, 90, 90 };
const tilde_color = [3]u8{ 70, 70, 70 };

/// Terminal defaults for the upstream `editorGutter.addedBackground`,
/// `modifiedBackground` and `deletedBackground` theme colors, composited over
/// the dark editor background because terminal cells have no alpha.
const added_primary_color = [3]u8{ 72, 126, 2 };
const modified_primary_color = [3]u8{ 137, 85, 3 };
const deleted_primary_color = [3]u8{ 173, 7, 7 };
const added_secondary_color = [3]u8{ 47, 75, 6 };
const modified_secondary_color = [3]u8{ 84, 54, 6 };
const deleted_secondary_color = [3]u8{ 98, 11, 11 };

const QuickDiffMarker = struct {
    glyph: u8,
    color: [3]u8,
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
    gutter_width: usize = 0,
    number_width: usize = 0,
    fold_column: usize = 0,
    marker_width: usize = 0,

    const NumberKind = enum { blank, number, continuation };

    const FoldPaint = enum { none, collapsed, expanded };

    const Row = struct {
        view_line: usize,
        node: *ui.Node,
        number_line: *ui.Node,
        number_text: *ui.Node,
        filler_line: *ui.Node,
        filler_text: *ui.Node,
        fold_cell: *ui.Node,
        fold_text: *ui.Node,
        marker_cell: *ui.Node,
        marker_text: *ui.Node,
        painted_top: usize,
        number_kind: NumberKind = .blank,
        /// Owned copy of the painted number/continuation text. The text node
        /// borrows it, so a custom line-number renderer of any length is kept.
        number_owned: ?[]u8 = null,
        filler: bool = false,
        fold: FoldPaint = .none,
        marker: ?QuickDiffMarker = null,
        marker_buf: [1]u8 = undefined,
    };

    /// The paint inputs for one screen row, computed from the current editor
    /// and decoration state before comparing it with the retained row.
    const RowPaint = struct {
        filler: bool,
        filler_visible: bool,
        number_kind: NumberKind = .blank,
        number_buf: [32]u8 = undefined,
        number_len: usize = 0,
        /// Text owned by the line-number overlay; only valid for the duration
        /// of this render pass, so `applyPaint` copies it into the row.
        number_borrowed: ?[]const u8 = null,
        fold: FoldPaint = .none,
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
        folding: *const FoldingDecorationProvider,
        gutter: usize,
        text_height: usize,
        host: ?*RetainedViewPartHost,
    ) !void {
        const total = editor.viewLineCount();
        const top = editor.topViewLine();
        const marker_width = editor.lineDecorationsWidth();
        const fold_column = editor.foldCellColumn();
        const number_width = fold_column;

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

        self.next_rows.clearRetainingCapacity();
        var old_index: usize = 0;
        var screen_row: usize = 0;
        while (screen_row < text_height) : (screen_row += 1) {
            const view_line = top + screen_row;
            while (old_index < self.rows.items.len and
                self.rows.items[old_index].view_line < view_line) : (old_index += 1)
            {
                self.destroyRow(doc, host, self.rows.items[old_index]);
            }

            const paint = self.computePaint(
                editor,
                line_numbers,
                line_decorations,
                folding,
                view_line,
                total,
                gutter,
                fold_column,
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
        folding: *const FoldingDecorationProvider,
        view_line: usize,
        total: usize,
        gutter: usize,
        fold_column: usize,
        marker_width: usize,
    ) RowPaint {
        _ = self;
        if (view_line > total) {
            return .{ .filler = true, .filler_visible = gutter >= 2 };
        }

        var paint = RowPaint{ .filler = false, .filler_visible = false };
        const output_index = editor.outputLineIndex(view_line);
        if (output_index == 0) {
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
            if (paint.number_len > 0) paint.number_kind = .number;

            if (fold_column < gutter) {
                const model_line = editor.modelLineNumber(view_line);
                const state = editor.foldStateAtModelLine(model_line);
                if (state != .none) {
                    const option = folding.getDecorationOption(state == .collapsed, false, false);
                    paint.fold = switch (option.fold_icon) {
                        .none => .none,
                        .collapsed => .collapsed,
                        .expanded => .expanded,
                    };
                }
            }

            if (marker_width > 0) {
                paint.marker = quickDiffMarker(line_decorations.renderedLine(view_line));
            }
        } else if (gutter >= 2) {
            const glyph = "\u{21AA}";
            @memcpy(paint.number_buf[0..glyph.len], glyph);
            paint.number_len = glyph.len;
            paint.number_kind = .continuation;
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

        const number_line = try doc.createElement(.div);
        number_line.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = 0 },
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
            .left = .{ .cells = 0 },
            .top = .{ .cells = 0 },
            .width = .{ .cells = @floatFromInt(gutter -| 1) },
            .height = .{ .cells = 1 },
            .white_space = .pre,
            .text_align = .right,
            .display = if (paint.filler_visible) .block else .none,
        });
        const filler_text = try doc.createTextBorrowed("~");
        filler_text.setStyle(.{ .color = color(tilde_color) });
        _ = try filler_line.appendChild(filler_text);

        const fold_cell = try doc.createElement(.div);
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
        fold_text.setStyle(.{ .color = color(gutter_color) });
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
        marker_text.setStyle(.{ .color = color(gutter_color) });
        _ = try marker_cell.appendChild(marker_text);

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
            .number_line = number_line,
            .number_text = number_text,
            .filler_line = filler_line,
            .filler_text = filler_text,
            .fold_cell = fold_cell,
            .fold_text = fold_text,
            .marker_cell = marker_cell,
            .marker_text = marker_text,
            .painted_top = screen_row,
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
    if (row.number_kind != paint.number_kind or !std.mem.eql(u8, TerminalMargin.rowNumberText(row), number)) {
        const copy = try self.allocator.dupe(u8, number);
        if (row.number_owned) |owned| self.allocator.free(owned);
        row.number_owned = copy;
        row.number_kind = paint.number_kind;
        row.number_text.setTextBorrowed(copy);
        row.number_text.setStyle(.{ .color = switch (paint.number_kind) {
            .continuation => color(continuation_color),
            else => color(gutter_color),
        } });
        changed = true;
    }

    if (row.fold != paint.fold and !paint.filler) {
        row.fold = paint.fold;
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
            break :blk current.glyph != next.glyph or
                !std.mem.eql(u8, current.color[0..], next.color[0..]);
        };
        if (marker_changed) {
            row.marker = paint.marker;
            if (paint.marker) |marker| {
                setDisplay(row.marker_cell, true);
                row.marker_buf[0] = marker.glyph;
                row.marker_text.setTextBorrowed(row.marker_buf[0..1]);
                row.marker_text.setStyle(.{ .color = color(marker.color) });
                row.marker_cell.asElement().style.color = color(marker.color);
            } else {
                setDisplay(row.marker_cell, false);
            }
            changed = true;
        }
    }
    return changed;
}

fn setDisplay(node: *ui.Node, visible: bool) void {
    node.asElement().style.display = if (visible) .block else .none;
}

/// Maps the upstream `dirty-diff-*` class names (see
/// `scm/browser/quickDiffDecorator.ts`) onto a terminal marker glyph and color.
/// `primary` wins over `secondary`/`pattern`; pattern and secondary variants
/// use the dimmed color because a cell has no alpha.
pub fn quickDiffMarker(decorations: ?*const @import("../glyphMargin/glyphMargin.zig").VisibleLineDecorationsToRender) ?QuickDiffMarker {
    const line = decorations orelse return null;
    var result: ?QuickDiffMarker = null;
    var result_primary = false;
    for (line.getDecorations()) |decoration| {
        const parsed = parseQuickDiffClass(decoration.class_name) orelse continue;
        if (result == null or (parsed.primary and !result_primary)) {
            result = .{ .glyph = parsed.glyph, .color = parsed.color };
            result_primary = parsed.primary;
        }
    }
    return result;
}

const ParsedQuickDiffClass = struct {
    glyph: u8,
    color: [3]u8,
    primary: bool,
};

fn parseQuickDiffClass(classes: []const u8) ?ParsedQuickDiffClass {
    var kind: enum { none, added, modified, deleted } = .none;
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
    return switch (kind) {
        .none => null,
        .added => .{
            .glyph = '+',
            .color = if (primary and !dimmed) added_primary_color else added_secondary_color,
            .primary = primary,
        },
        .modified => .{
            .glyph = '~',
            .color = if (primary and !dimmed) modified_primary_color else modified_secondary_color,
            .primary = primary,
        },
        .deleted => .{
            .glyph = '-',
            .color = if (primary and !dimmed) deleted_primary_color else deleted_secondary_color,
            .primary = primary,
        },
    };
}

fn color(rgb: [3]u8) ui.Color {
    return .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const glyph_margin = @import("../glyphMargin/glyphMargin.zig");
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
    try testing.expectEqual(added_primary_color, marker.color);

    var modified_pattern = try lineWith(allocator, "dirty-diff-glyph dirty-diff-modified primary pattern");
    defer modified_pattern.deinit();
    const pattern_marker = quickDiffMarker(&modified_pattern).?;
    try testing.expectEqual(@as(u8, '~'), pattern_marker.glyph);
    try testing.expectEqual(modified_secondary_color, pattern_marker.color);

    var deleted = try lineWith(allocator, "dirty-diff-glyph dirty-diff-deleted secondary");
    defer deleted.deinit();
    const deleted_marker = quickDiffMarker(&deleted).?;
    try testing.expectEqual(@as(u8, '-'), deleted_marker.glyph);
    try testing.expectEqual(deleted_secondary_color, deleted_marker.color);

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
        &folding,
        editor.gutterWidth(),
        editor.textHeight(),
        null,
    );

    // Gutter layout: numbers | fold | quick-diff marker.
    try testing.expectEqual(@as(usize, 4), editor.gutterWidth());
    try testing.expectEqual(@as(usize, 2), editor.foldCellColumn());
    try testing.expectEqual(@as(usize, 3), editor.quickDiffCellColumn());

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
    try testing.expectEqual(@as(usize, 4), editor.gutterWidth());
    try testing.expectEqual(@as(usize, 2), editor.foldCellColumn());
    editor.setLineDecorationsWidth(0);
    try testing.expectEqual(@as(usize, 3), editor.gutterWidth());
}
