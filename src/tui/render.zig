const std = @import("std");
const Io = std.Io;
const Editor = @import("./editor.zig").Editor;
const Screen = @import("./screen.zig").Screen;
const Style = @import("./screen.zig").Style;
const CursorColumns = @import("../vs/editor/common/core/cursorColumns.zig").CursorColumns;
const Selection = @import("../vs/editor/common/core/selection.zig").Selection;
const theme = @import("./theme.zig");
const tui = @import("./tui.zig");

pub fn render(editor: *Editor, screen: *Screen, writer: *Io.Writer) !void {
    screen.clear();
    editor.ensureTokensVisible();

    const total = editor.viewLineCount();
    const text_height = editor.textHeight();
    const gutter = editor.gutterWidth();
    const top = editor.topViewLine();
    const cursor = editor.viewCursorPosition();
    const tab_size = editor.tabSize();

    var cursor_row: usize = 1;
    var cursor_col: usize = 1;

    var row: usize = 0;
    while (row < text_height) : (row += 1) {
        const view_line = top + row;
        screen.fill(row, 0, gutter, .{ .fg = .{ 90, 90, 90 } });

        if (view_line > total) {
            if (gutter >= 2) _ = screen.putText(row, gutter - 1, "~", .{ .fg = .{ 70, 70, 70 } }, 1);
            continue;
        }

        const model_line = editor.modelLineNumber(view_line);
        const output_index = editor.outputLineIndex(view_line);
        if (output_index == 0) {
            var number_buf: [32]u8 = undefined;
            const number = std.fmt.bufPrint(&number_buf, "{d}", .{model_line}) catch "";
            if (number.len + 1 <= gutter) {
                _ = screen.putText(row, gutter - 1 - number.len, number, .{ .fg = .{ 110, 110, 110 } }, 1);
            }
        } else if (gutter >= 2) {
            _ = screen.putText(row, gutter - 2, "↪", .{ .fg = .{ 90, 90, 90 } }, 1);
        }

        const data = try editor.viewLineData(view_line);
        const selection = editor.viewSelection();
        const selected_range = selectionColumns(selection, view_line, data.content.len);

        var col = gutter;
        var byte_offset: usize = 0;
        var token_index: usize = 0;
        var token_end: usize = if (data.tokens.getCount() > 0) data.tokens.getEndOffset(0) else data.content.len;

        while (byte_offset < data.content.len and col < screen.width) {
            const seq_len = std.unicode.utf8ByteSequenceLength(data.content[byte_offset]) catch 1;
            const safe_len = @min(seq_len, data.content.len - byte_offset);
            const cp = std.unicode.utf8Decode(data.content[byte_offset .. byte_offset + safe_len]) catch @as(u21, data.content[byte_offset]);

            while (token_index + 1 < data.tokens.getCount() and byte_offset >= token_end) {
                token_index += 1;
                token_end = data.tokens.getEndOffset(token_index);
            }

            const selected = selected_range != null and
                byte_offset >= selected_range.?.start and byte_offset < selected_range.?.end;
            var style = Style{ .fg = theme.colorForToken(data.tokens.getForeground(token_index)) };
            if (view_line == cursor.lineNumber) style.bg = .{ 32, 32, 36 };
            if (selected) style.reverse = true;

            if (cp == '\t') {
                const next = gutter + CursorColumns.nextRenderTabStop(col - gutter, tab_size);
                while (col < next and col < screen.width) : (col += 1) {
                    _ = screen.putCodepoint(row, col, ' ', style);
                }
                byte_offset += 1;
            } else {
                col += screen.putCodepoint(row, col, cp, style);
                byte_offset += safe_len;
            }
        }

        if (view_line == cursor.lineNumber) {
            const visible = CursorColumns.visibleColumnFromColumn(data.content, cursor.column, tab_size);
            cursor_row = row + 1;
            cursor_col = @min(gutter + visible + 1, screen.width);
        }
    }

    const status_row = screen.height - 1;
    screen.fill(status_row, 0, screen.width, .{ .reverse = true });
    var status_buf: [1024]u8 = undefined;
    const dirty = if (editor.isDirty()) "*" else "";
    const model_pos = editor.modelCursorPosition();
    const message = editor.message();
    const status = std.fmt.bufPrint(
        &status_buf,
        " {s}{s}  Ln {d}, Col {d}  {s}  {s}  Ctrl-Q quit",
        .{ editor.path, dirty, model_pos.lineNumber, model_pos.column, editor.languageId(), message },
    ) catch status_buf[0..0];
    _ = screen.putText(status_row, 0, status, .{ .reverse = true }, 1);

    try screen.render(writer);
    try tui.moveCursor(writer, .{ .row = cursor_row, .col = cursor_col });
    try tui.showCursor(writer);
    try writer.flush();
}

fn selectionColumns(selection: Selection, view_line: usize, line_length: usize) ?struct { start: usize, end: usize } {
    if (selection.isEmpty()) return null;
    if (view_line < selection.startLineNumber or view_line > selection.endLineNumber) return null;

    var start: usize = if (view_line == selection.startLineNumber) selection.startColumn - 1 else 0;
    var end: usize = if (view_line == selection.endLineNumber) selection.endColumn - 1 else line_length;
    start = @min(start, line_length);
    end = @min(end, line_length);
    if (end <= start) return null;
    return .{ .start = start, .end = end };
}

test "render: wrapped CJK and tab line" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var editor = try Editor.createFromText(allocator, io, "abcdefghij 中\tq", "test.txt", 14, 7);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    var screen = try Screen.init(allocator, 14, 7);
    defer screen.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try render(editor, &screen, &out.writer);
    try std.testing.expect(out.written().len > 0);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "中") != null);
}
