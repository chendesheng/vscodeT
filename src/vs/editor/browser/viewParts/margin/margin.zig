// Port of `src/vs/editor/browser/viewParts/margin/margin.ts`.
//
// Terminal adaptation: the browser margin owns `LineNumbers`, glyph margin and
// line-decoration DOM parts. The terminal has one gutter column, so this part
// paints the line-number/continuation cells and the folding control from the
// ported `LineNumbersOverlay` and `FoldingDecorationProvider`. Hit testing and
// the fold toggle stay in the host.

const std = @import("std");
const ui = @import("ui");

const Editor = @import("../../widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const line_numbers_mod = @import("../lineNumbers/lineNumbers.zig");
const LineNumbersOverlay = line_numbers_mod.LineNumbersOverlay;
const FoldingDecorationProvider = @import("../../../contrib/folding/browser/foldingDecorations.zig").FoldingDecorationProvider;

const gutter_color = [3]u8{ 110, 110, 110 };
const continuation_color = [3]u8{ 90, 90, 90 };
const tilde_color = [3]u8{ 70, 70, 70 };

/// Port of the terminal-visible `Margin` paint subset.
pub const TerminalMargin = struct {
    /// Paints the gutter rows for the current viewport.
    pub fn render(
        self: *TerminalMargin,
        doc: *ui.Document,
        root: *ui.Node,
        editor: *Editor,
        line_numbers: *const LineNumbersOverlay,
        folding: *const FoldingDecorationProvider,
        gutter: usize,
        text_height: usize,
    ) !void {
        _ = self;
        const total = editor.viewLineCount();
        const top = editor.topViewLine();

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
                .width = .{ .cells = @floatFromInt(gutter - 1) },
                .height = .{ .cells = 1 },
                .white_space = .pre,
                .text_align = .right,
            });

            if (output_index == 0) {
                const line_number = line_numbers.renderedLine(view_line);
                const number = if (line_number) |rendered|
                    rendered.text
                else
                    std.fmt.bufPrint(&number_buf, "{d}", .{model_line}) catch "";
                if (number.len > 0) {
                    const node = try doc.createText(number);
                    node.setStyle(.{ .color = color(gutter_color) });
                    _ = try gutter_line.appendChild(node);
                }
            } else if (gutter >= 2) {
                const node = try doc.createText("\u{21AA}");
                node.setStyle(.{ .color = color(continuation_color) });
                _ = try gutter_line.appendChild(node);
            }
            _ = try root.appendChild(gutter_line);

            if (output_index == 0 and gutter >= 2) {
                const state = editor.foldStateAtModelLine(model_line);
                if (state != .none) {
                    const option = folding.getDecorationOption(state == .collapsed, false, false);
                    if (option.fold_icon != .none) {
                        const fold_cell = try doc.createElement(.div);
                        fold_cell.setStyle(.{
                            .position = .absolute,
                            .left = .{ .cells = @floatFromInt(gutter - 1) },
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
        }
    }

    var number_buf: [32]u8 = undefined;
};

fn color(rgb: [3]u8) ui.Color {
    return .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
}
