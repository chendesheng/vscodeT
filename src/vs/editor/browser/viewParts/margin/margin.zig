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
pub const TerminalMargin = struct {
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
    ) !void {
        _ = self;
        const total = editor.viewLineCount();
        const top = editor.topViewLine();
        const marker_width = editor.lineDecorationsWidth();
        const fold_column = editor.foldCellColumn();
        const number_width = fold_column;

        var row: usize = 0;
        while (row < text_height) : (row += 1) {
            const view_line = top + row;
            const row_cells: f64 = @floatFromInt(row);

            if (view_line > total) {
                if (gutter >= 2) {
                    const filler = try doc.createElement(.div);
                    filler.setStyle(.{
                        .position = .absolute,
                        .left = .{ .cells = 0 },
                        .top = .{ .cells = row_cells },
                        .width = .{ .cells = @floatFromInt(gutter - 1) },
                        .height = .{ .cells = 1 },
                        .white_space = .pre,
                        .text_align = .right,
                    });
                    const tilde = try doc.createText("~");
                    tilde.setStyle(.{ .color = color(tilde_color) });
                    _ = try filler.appendChild(tilde);
                    _ = try root.appendChild(filler);
                }
                continue;
            }

            const model_line = editor.modelLineNumber(view_line);
            const output_index = editor.outputLineIndex(view_line);

            const gutter_line = try doc.createElement(.div);
            gutter_line.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = 0 },
                .top = .{ .cells = row_cells },
                .width = .{ .cells = @floatFromInt(number_width) },
                .height = .{ .cells = 1 },
                .white_space = .pre,
                .text_align = .right,
            });

            if (output_index == 0) {
                if (editor.line_number_map != null) {
                    // A diff snapshot's line-number map wins; `null` entries are
                    // filler rows with a blank number.
                    if (editor.displayLineNumber(view_line)) |display_line| {
                        const number = std.fmt.bufPrint(&number_buf, "{d}", .{display_line}) catch "";
                        if (number.len > 0) {
                            const node = try doc.createText(number);
                            node.setStyle(.{ .color = color(gutter_color) });
                            _ = try gutter_line.appendChild(node);
                        }
                    }
                } else if (line_numbers.renderedLine(view_line)) |rendered| {
                    if (rendered.text.len > 0) {
                        const node = try doc.createText(rendered.text);
                        node.setStyle(.{ .color = color(gutter_color) });
                        _ = try gutter_line.appendChild(node);
                    }
                }
            } else if (gutter >= 2) {
                const node = try doc.createText("\u{21AA}");
                node.setStyle(.{ .color = color(continuation_color) });
                _ = try gutter_line.appendChild(node);
            }
            _ = try root.appendChild(gutter_line);

            if (output_index == 0 and fold_column < gutter) {
                const state = editor.foldStateAtModelLine(model_line);
                if (state != .none) {
                    const option = folding.getDecorationOption(state == .collapsed, false, false);
                    if (option.fold_icon != .none) {
                        const fold_cell = try doc.createElement(.div);
                        fold_cell.setStyle(.{
                            .position = .absolute,
                            .left = .{ .cells = @floatFromInt(fold_column) },
                            .top = .{ .cells = row_cells },
                            .width = .{ .cells = 1 },
                            .height = .{ .cells = 1 },
                            .white_space = .pre,
                        });
                        const glyph = try doc.createText(if (option.fold_icon == .collapsed) "\u{25B8}" else "\u{25BE}");
                        glyph.setStyle(.{ .color = color(gutter_color) });
                        _ = try fold_cell.appendChild(glyph);
                        _ = try root.appendChild(fold_cell);
                    }
                }
            }

            if (output_index == 0 and marker_width > 0) {
                if (quickDiffMarker(line_decorations.renderedLine(view_line))) |marker| {
                    const marker_cell = try doc.createElement(.div);
                    marker_cell.setStyle(.{
                        .position = .absolute,
                        .left = .{ .cells = @floatFromInt(gutter -| 1) },
                        .top = .{ .cells = row_cells },
                        .width = .{ .cells = 1 },
                        .height = .{ .cells = 1 },
                        .white_space = .pre,
                    });
                    const glyph = try doc.createText(&[_]u8{marker.glyph});
                    glyph.setStyle(.{ .color = color(marker.color) });
                    _ = try marker_cell.appendChild(glyph);
                    _ = try root.appendChild(marker_cell);
                }
            }
        }
    }

    var number_buf: [32]u8 = undefined;
};

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

    var margin: TerminalMargin = .{};
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
