// Port of `src/vs/editor/browser/widget/diffEditor/components/diffEditorViewZones/renderLines.ts`.
// Terminal adaptation: the same token/inline-decoration line renderer and
// ViewLine cell compositor produce document nodes rather than HTML. Line
// breaks use the modified editor's existing monospace projection. The result
// height and minimum width are expressed in cells.
const std = @import("std");
const ui = @import("ui");
const Editor = @import("../../../codeEditor/codeEditorWidgetTerminal.zig").Editor;
const TextModel = @import("../../../../../common/model/textModel.zig").TextModel;
const LineRange = @import("../../../../../common/core/ranges/lineRange.zig").LineRange;
const Range = @import("../../../../../common/core/range.zig").Range;
const RangeMapping = @import("../../../../../common/diff/rangeMapping.zig").RangeMapping;
const CursorColumns = @import("../../../../../common/core/cursorColumns.zig").CursorColumns;
const line_breaks = @import("../../../../../common/viewModel/monospaceLineBreaksComputer.zig");
const projection = @import("../../../../../common/modelLineProjectionData.zig");
const tokens_mod = @import("../../../../../common/tokens/lineTokens.zig");
const InlineDecoration = @import("../../../../../common/viewModel/inlineDecorations.zig").InlineDecoration;
const LineDecoration = @import("../../../../../common/viewLayout/lineDecorations.zig").LineDecoration;
const renderer = @import("../../../../../common/viewLayout/viewLineRenderer.zig");
const ViewLineRenderingData = @import("../../../../../common/viewModel.zig").ViewLineRenderingData;
const editor_options = @import("../../../../../common/config/editorOptions.zig");
const ViewLine = @import("../../../../viewParts/viewLines/viewLine.zig").ViewLine;
const RenderInfo = @import("../../../../editorBrowser.zig").IViewZone.RenderInfo;

pub const RenderOptions = struct {
    tab_size: usize,
    wrapping_column: usize,
    wrapping_indent: editor_options.WrappingIndent,
    word_break: projection.WordBreak,
    render_whitespace: editor_options.RenderWhitespace = .none,
    render_control_characters: bool = false,
    stop_rendering_line_after: i32 = -1,

    pub fn fromEditor(editor: *Editor) RenderOptions {
        return .{
            .tab_size = editor.tabSize(),
            .wrapping_column = editor.view_lines.wrapping_column,
            .wrapping_indent = editor.view_lines.wrapping_indent,
            .word_break = editor.view_lines.word_break,
        };
    }
};

pub const RenderLinesResult = struct {
    allocator: std.mem.Allocator,
    height_in_lines: usize = 0,
    min_width: usize = 0,
    view_line_offsets: []usize,

    pub fn deinit(self: *RenderLinesResult) void {
        self.allocator.free(self.view_line_offsets);
    }

    pub fn viewLineCount(self: *const RenderLinesResult, index: usize) usize {
        return self.view_line_offsets[index + 1] - self.view_line_offsets[index];
    }

    fn firstModelLineAtRow(self: *const RenderLinesResult, row: usize) usize {
        var low: usize = 0;
        var high = self.view_line_offsets.len - 1;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (self.view_line_offsets[mid + 1] <= row) low = mid + 1 else high = mid;
        }
        return low;
    }
};

fn lineBreaks(allocator: std.mem.Allocator, classifier: *const line_breaks.WrappingCharacterClassifier, text: []const u8, options: RenderOptions) !?projection.ModelLineProjectionData {
    return line_breaks.computeLineBreaks(allocator, classifier, text, options.tab_size, options.wrapping_column, options.wrapping_indent, options.word_break);
}

fn freeLineBreaks(allocator: std.mem.Allocator, data: ?projection.ModelLineProjectionData) void {
    if (data) |value| {
        allocator.free(value.breakOffsets);
        allocator.free(value.breakOffsetsVisibleColumn);
    }
}

pub fn measure(allocator: std.mem.Allocator, model: *TextModel, range: LineRange, classifier: *const line_breaks.WrappingCharacterClassifier, options: RenderOptions) !RenderLinesResult {
    var result = RenderLinesResult{
        .allocator = allocator,
        .view_line_offsets = try allocator.alloc(usize, range.length() + 1),
    };
    errdefer result.deinit();
    result.view_line_offsets[0] = 0;
    for (range.startLineNumber..range.endLineNumberExclusive, 0..) |number, index| {
        var line = try model.getLineContent(number);
        defer line.deinit();
        const breaks = try lineBreaks(allocator, classifier, line.items, options);
        defer freeLineBreaks(allocator, breaks);
        const count = if (breaks) |data| data.breakOffsets.len else 1;
        result.height_in_lines += count;
        result.view_line_offsets[index + 1] = result.height_in_lines;
        if (breaks) |data| {
            var last: usize = 0;
            for (data.breakOffsets) |end| {
                result.min_width = @max(result.min_width, CursorColumns.visibleColumnFromColumn(line.items[last..end], end - last + 1, options.tab_size));
                last = end;
            }
        } else {
            result.min_width = @max(result.min_width, CursorColumns.visibleColumnFromColumn(line.items, line.items.len + 1, options.tab_size));
        }
    }
    return result;
}

pub const PaintOptions = struct {
    colors: struct {
        line_background: ui.Color,
        text_background: ui.Color,
    },
    style_fn: ViewLine.PartStyleFn,
    decoration_bits_fn: *const fn ([]const u8) u32,
};

/// Render original model lines into a deleted-code zone using the upstream
/// LineDecoration.filter/extractWrapped -> renderViewLine -> paint pipeline.
pub fn renderLines(
    allocator: std.mem.Allocator,
    doc: *ui.Document,
    original: *TextModel,
    range: LineRange,
    inner_changes: []const RangeMapping,
    measurement: *const RenderLinesResult,
    classifier: *const line_breaks.WrappingCharacterClassifier,
    options: RenderOptions,
    paint: PaintOptions,
    info: RenderInfo,
) !*ui.Node {
    const root = try doc.createElement(.div);
    errdefer doc.destroy(root);
    root.setStyle(.{
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
        .background = paint.colors.line_background,
        .overflow = .hidden,
        .pointer = .text,
    });
    const content = try doc.createElement(.div);
    content.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = -@as(f64, @floatFromInt(info.scroll_left)) },
        .top = .{ .cells = 0 },
        .width = .{ .cells = @floatFromInt(info.width +| info.scroll_left) },
        .height = .{ .percent = 100 },
    });
    _ = try root.appendChild(content);

    var inline_decorations: std.ArrayList(InlineDecoration) = .empty;
    defer inline_decorations.deinit(allocator);
    for (inner_changes) |change| {
        try inline_decorations.append(allocator, InlineDecoration.init(change.originalRange, "char-delete", .Regular));
    }
    const visible_start = info.visible_start_row;
    const visible_end = info.visible_end_row orelse info.height;
    const first_model_line = measurement.firstModelLineAtRow(visible_start);
    if (first_model_line >= range.length()) return root;
    var row = measurement.view_line_offsets[first_model_line];
    for (range.startLineNumber + first_model_line..range.endLineNumberExclusive) |number| {
        if (row >= visible_end) break;
        var line_tokens = try original.tokenization().getLineTokens(number);
        defer line_tokens.deinit();
        const text = line_tokens.getLineContent();
        const decorations = try LineDecoration.filter(allocator, inline_decorations.items, number, 1, text.len + 1);
        defer allocator.free(decorations);
        const breaks = try lineBreaks(allocator, classifier, text, options);
        defer freeLineBreaks(allocator, breaks);
        if (breaks) |data| {
            var last: usize = 0;
            for (data.breakOffsets) |end| {
                if (row >= visible_end) break;
                if (row >= visible_start) {
                    const wrapped = try LineDecoration.extractWrapped(allocator, decorations, last, end);
                    defer allocator.free(wrapped);
                    const tokens = tokens_mod.IViewLineTokens.initSlice(line_tokens.sliceAndInflate(last, end, 0));
                    try renderOriginalLine(allocator, doc, content, row - visible_start, tokens, wrapped, inline_decorations.items.len != 0, options, paint, info);
                }
                row += 1;
                last = end;
            }
        } else {
            if (row >= visible_start) try renderOriginalLine(allocator, doc, content, row - visible_start, tokens_mod.IViewLineTokens.init(&line_tokens), decorations, inline_decorations.items.len != 0, options, paint, info);
            row += 1;
        }
    }
    return root;
}

fn renderOriginalLine(allocator: std.mem.Allocator, doc: *ui.Document, content: *ui.Node, row: usize, tokens: tokens_mod.IViewLineTokens, decorations: []const LineDecoration, has_char_changes: bool, options: RenderOptions, paint: PaintOptions, info: RenderInfo) !void {
    const text = tokens.getLineContent();
    const ascii = ViewLineRenderingData.isBasicASCIIContent(text, true);
    const input = renderer.Input{
        .content = text,
        .tokens = tokens,
        .tab_size = options.tab_size,
        .render_whitespace = options.render_whitespace,
        .render_control_characters = options.render_control_characters,
        .line_decorations = decorations,
        .stop_rendering_line_after = options.stop_rendering_line_after,
        .is_basic_ascii = ascii,
        .contains_rtl = ViewLineRenderingData.containsRTLContent(text, ascii, true),
    };
    const rendered = try renderer.renderLine(allocator, input);
    defer rendered.deinit(allocator);
    const width = info.width +| info.scroll_left;
    const flags = try allocator.alloc(u32, 0);
    defer allocator.free(flags);
    const line = try ViewLine.paintTransient(doc, &input, &rendered, .{
        .left_cells = 0,
        .top_cells = @intCast(row),
        .width_cells = width,
        .background = if (has_char_changes) paint.colors.line_background else paint.colors.text_background,
        .flags = flags,
        .decoration_bits_fn = paint.decoration_bits_fn,
    }, paint.style_fn);
    _ = try content.appendChild(line);
}

pub fn renderMargin(doc: *ui.Document, info: RenderInfo, render_indicators: bool, color: ui.Color) !*ui.Node {
    const root = try doc.createElement(.div);
    errdefer doc.destroy(root);
    root.setStyle(.{ .height = .{ .percent = 100 }, .width = .{ .percent = 100 } });
    if (!render_indicators or info.width == 0) return root;
    for (0..(info.visible_end_row orelse info.height) -| info.visible_start_row) |row| {
        const marker = try doc.createElement(.div);
        marker.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = @floatFromInt(info.width - 1) },
            .top = .{ .cells = @floatFromInt(row) },
            .width = .{ .cells = 1 },
            .height = .{ .cells = 1 },
            .color = color,
        });
        _ = try marker.appendChild(try doc.createText("-"));
        _ = try root.appendChild(marker);
    }
    return root;
}
