//! The editor view, rendered through the standalone `ui` library.
//!
//! This replaces the hand-written `Screen`/`render.zig` path with a
//! `ui.Document`: one absolutely positioned element per view line, a gutter
//! element, inline token runs painted by `viewLineRenderer`, a status bar and a
//! hardware cursor cell. It is a deliberate terminal adaptation of
//! `src/vs/editor/browser/view/`, not a literal port: the browser view parts
//! (viewLayer, viewLines, selections, cursors) are collapsed into this file
//! until the view model is ported.
//!
//! The document is rebuilt from the editor when `refresh` is called (after a
//! key, an edit or a resize). `Document.clear` keeps the arena and the
//! `Surface` frame so the renderer still emits only the changed cells.

const std = @import("std");
const ui = @import("ui");

const Editor = @import("./editor.zig").Editor;
const theme = @import("./theme.zig");
const CursorColumns = @import("../vs/editor/common/core/cursorColumns.zig").CursorColumns;
const CursorState = @import("../vs/editor/common/cursorCommon.zig").CursorState;
const line_renderer = @import("../vs/editor/common/viewLayout/viewLineRenderer.zig");
const editorBrowser = @import("../vs/editor/browser/editorBrowser.zig");

const gutter_color = [3]u8{ 110, 110, 110 };
const continuation_color = [3]u8{ 90, 90, 90 };
const tilde_color = [3]u8{ 70, 70, 70 };
const current_line_background = [3]u8{ 32, 32, 36 };
const secondary_cursor_background = [3]u8{ 110, 90, 30 };

/// A cell position, 0-based, ready for `tui.moveCursor` after adding one.
pub const Cell = struct {
    row: usize,
    col: usize,
};

const CellFlag = struct {
    const normal: u8 = 0;
    const selected: u8 = 1 << 0;
    const secondary_cursor: u8 = 1 << 1;
    const find_match: u8 = 1 << 2;
    const current_find_match: u8 = 1 << 3;
    const find_scope: u8 = 1 << 4;
};

const find_match_background = [3]u8{ 80, 70, 20 };
const current_find_match_background = [3]u8{ 200, 120, 0 };
const current_find_match_foreground = [3]u8{ 0, 0, 0 };
const find_scope_background = [3]u8{ 40, 50, 70 };

pub const View = struct {
    allocator: std.mem.Allocator,
    editor: *Editor,
    surface: ui.Surface,
    /// Overlay widgets anchored to an editor corner, painted above the lines
    /// and the status row.
    overlays: std.array_list.Managed(editorBrowser.IOverlayWidget),
    /// Model ranges highlighted by contributions such as find.
    decorations: std.array_list.Managed(editorBrowser.Decoration),
    /// The line element under the primary cursor, filled in while building.
    cursor_line: ?*ui.Node = null,
    /// Cells between the start of that line's content and the caret.
    cursor_offset: usize = 0,

    pub fn init(allocator: std.mem.Allocator, editor: *Editor) !*View {
        const self = try allocator.create(View);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .editor = editor,
            .surface = undefined,
            .overlays = std.array_list.Managed(editorBrowser.IOverlayWidget).init(allocator),
            .decorations = std.array_list.Managed(editorBrowser.Decoration).init(allocator),
        };
        errdefer self.overlays.deinit();
        errdefer self.decorations.deinit();
        self.surface = try ui.Surface.init(allocator, .{
            .cols = editor.screen_width,
            .rows = editor.screen_height,
            .tab_size = editor.tabSize(),
            .measure_width = measureCodepoint,
        });
        errdefer self.surface.deinit();
        try self.rebuild();
        return self;
    }

    pub fn deinit(self: *View) void {
        self.decorations.deinit();
        self.overlays.deinit();
        self.surface.deinit();
        self.allocator.destroy(self);
    }

    /// Registers an overlay widget. The caller owns the widget struct and must
    /// keep its context alive until it is removed or the view is destroyed.
    pub fn addOverlayWidget(self: *View, widget: editorBrowser.IOverlayWidget) !void {
        try self.overlays.append(widget);
        try self.refresh();
    }

    /// Replaces the highlighted model ranges (find matches, current match,
    /// find scope) and rebuilds the view.
    pub fn setDecorations(self: *View, decorations: []const editorBrowser.Decoration) !void {
        self.decorations.clearRetainingCapacity();
        try self.decorations.appendSlice(decorations);
    }

    pub fn clearDecorations(self: *View) !void {
        try self.setDecorations(&.{});
    }

    pub fn removeOverlayWidget(self: *View, id: []const u8) !void {
        var index: usize = 0;
        while (index < self.overlays.items.len) : (index += 1) {
            const widget = self.overlays.items[index];
            if (std.mem.eql(u8, widget.get_id(widget.context), id)) {
                _ = self.overlays.orderedRemove(index);
                try self.refresh();
                return;
            }
        }
    }

    /// Sends the event through the widget document when a widget owns focus.
    /// Returns true when a listener consumed it, so the editor must not also
    /// handle the key.
    pub fn dispatchKey(self: *View, event: *ui.KeyEvent) bool {
        const doc = self.surface.document();
        if (doc.active_element == null) return false;
        doc.dispatchEvent(event);
        return event.default_prevented or event.propagation_stopped;
    }

    /// Recreates the surface at the editor's current viewport size. The caller
    /// clears the screen because the new surface starts a fresh frame.
    pub fn resize(self: *View) !void {
        const width = self.editor.screen_width;
        const height = self.editor.screen_height;
        if (self.surface.document().cols == width and self.surface.document().rows == height) {
            return self.refresh();
        }

        const replacement = try ui.Surface.init(self.allocator, .{
            .cols = width,
            .rows = height,
            .tab_size = self.editor.tabSize(),
            .measure_width = measureCodepoint,
        });

        var previous = self.surface;
        self.surface = replacement;
        previous.deinit();
        try self.rebuild();
    }

    /// Rebuilds the whole document from the editor state.
    pub fn refresh(self: *View) !void {
        try self.rebuild();
    }

    pub fn render(self: *View, writer: *std.Io.Writer) !void {
        try self.surface.render(writer, .{ .synchronized = true });
    }

    /// The hardware cursor cell, valid after `render` has laid the tree out.
    /// Returns null when the caret is outside the text area.
    pub fn cursorCell(self: *View) ?Cell {
        // A focused widget paints its own block caret; the hardware cursor
        // belongs to the editor.
        if (self.surface.document().active_element != null) return null;
        const line = self.cursor_line orelse return null;
        const rows = self.surface.document().rows;
        const cols = self.surface.document().cols;
        const rect = line.asElement().rect;
        const row = ui.cell.snap(rect.y);
        if (row >= rows) return null;
        const col = @min(ui.cell.snap(rect.x) + self.cursor_offset, cols -| 1);
        return .{ .row = row, .col = col };
    }

    fn rebuild(self: *View) !void {
        const editor = self.editor;
        editor.ensureTokensVisible();
        editor.ensureCursorVisible();

        const doc = self.surface.document();
        doc.clear();
        self.cursor_line = null;
        self.cursor_offset = 0;

        const cols = doc.cols;
        const rows = doc.rows;
        const gutter = @min(editor.gutterWidth(), cols);
        const text_width = @max(@as(usize, 1), cols -| gutter);
        const text_height = editor.textHeight();
        const total = editor.viewLineCount();
        const top = editor.topViewLine();
        const tab_size = editor.tabSize();

        const root = try doc.createElement(.div);
        root.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = 0 },
            .top = .{ .cells = 0 },
            .width = .{ .percent = 100 },
            .height = .{ .percent = 100 },
            .overflow = .hidden,
        });
        doc.setRoot(root);

        const states = try editor.viewCursorStates();
        defer editor.allocator.free(states);
        const cursor = states[0].viewState.position;

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
                        .width = .{ .cells = @floatFromInt(gutter) },
                        .height = .{ .cells = 1 },
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

            // Gutter: the model line number on the first view line, a
            // continuation arrow on the rest.
            const gutter_line = try doc.createElement(.div);
            gutter_line.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = 0 },
                .top = .{ .cells = row_cells },
                .width = .{ .cells = @floatFromInt(gutter) },
                .height = .{ .cells = 1 },
                .text_align = .right,
            });

            if (output_index == 0) {
                var number_buf: [32]u8 = undefined;
                const number = std.fmt.bufPrint(&number_buf, "{d}", .{model_line}) catch "";
                const node = try doc.createText(number);
                node.setStyle(.{ .color = color(gutter_color) });
                _ = try gutter_line.appendChild(node);
            } else if (gutter >= 2) {
                const node = try doc.createText("↪");
                node.setStyle(.{ .color = color(continuation_color) });
                _ = try gutter_line.appendChild(node);
            }
            _ = try root.appendChild(gutter_line);

            const is_cursor_line = view_line == cursor.lineNumber;
            const line = try doc.createElement(.div);
            line.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = @floatFromInt(gutter) },
                .top = .{ .cells = row_cells },
                .width = .{ .cells = @floatFromInt(text_width) },
                .height = .{ .cells = 1 },
                .overflow = .hidden,
                .background = if (is_cursor_line) color(current_line_background) else null,
            });

            const data = try editor.viewLineData(view_line);
            const rendered = try line_renderer.renderLine(self.allocator, .{
                .content = data.content,
                .tokens = data.tokens,
                .tab_size = tab_size,
                .start_visible_column = data.startVisibleColumn,
            });
            defer rendered.deinit(self.allocator);

            const model_content = try editor.model.getLineContent(model_line);
            defer model_content.deinit();

            const line_width = doc.measureText(rendered.bytes);
            const flags = try self.allocator.alloc(u8, @max(line_width, 1));
            defer self.allocator.free(flags);
            @memset(flags, CellFlag.normal);

            markSelections(
                states,
                view_line,
                model_content.items,
                tab_size,
                data.startVisibleColumn,
                line_width,
                flags,
            );
            self.markDecorations(
                model_line,
                data.minColumn,
                data.maxColumn,
                model_content.items,
                tab_size,
                data.startVisibleColumn,
                line_width,
                flags,
            );

            try appendRuns(doc, line, rendered, flags);

            if (is_cursor_line) {
                self.cursor_line = line;
                self.cursor_offset = visibleOffset(
                    model_content.items,
                    cursor.column,
                    tab_size,
                    data.startVisibleColumn,
                );
            }

            _ = try root.appendChild(line);
        }

        try appendStatus(self, doc, root, rows);
        try self.buildOverlays(doc, root, cols, text_height);
    }

    fn markDecorations(
        self: *View,
        model_line: usize,
        min_column: usize,
        max_column: usize,
        model_content: []const u8,
        tab_size: usize,
        start_visible_column: usize,
        line_width: usize,
        flags: []u8,
    ) void {
        for (self.decorations.items) |decoration| {
            const range = decoration.range;
            if (range.startLineNumber > model_line or range.endLineNumber < model_line) continue;

            var start_column = if (range.startLineNumber == model_line) range.startColumn else min_column;
            var end_column = if (range.endLineNumber == model_line) range.endColumn else max_column;
            start_column = @max(start_column, min_column);
            end_column = @min(end_column, max_column);
            if (start_column > max_column or end_column < min_column) continue;

            var start = visibleOffset(model_content, start_column, tab_size, start_visible_column);
            var end = visibleOffset(model_content, end_column, tab_size, start_visible_column);
            if (end <= start) {
                if (!range.isEmpty()) continue;
                end = start + 1;
            }
            start = @min(start, line_width);
            end = @min(end, line_width);

            const bit: u8 = switch (decoration.kind) {
                .find_match => CellFlag.find_match,
                .current_find_match => CellFlag.current_find_match,
                .find_scope => CellFlag.find_scope,
            };
            var cell = start;
            while (cell < end and cell < flags.len) : (cell += 1) {
                flags[cell] |= bit;
            }
        }
    }

    fn buildOverlays(
        self: *View,
        doc: *ui.Document,
        root: *ui.Node,
        cols: usize,
        text_height: usize,
    ) !void {
        for (self.overlays.items) |widget| {
            const width = @min(widget.width(widget.context, cols), cols);
            const height = @min(widget.height(widget.context), text_height);
            if (width == 0 or height == 0) continue;

            const top: usize = switch (widget.get_position(widget.context)) {
                .top_right_corner, .top_center => 0,
                .bottom_right_corner => text_height -| height,
            };
            const left: usize = switch (widget.get_position(widget.context)) {
                .top_right_corner, .bottom_right_corner => cols -| width,
                .top_center => (cols -| width) / 2,
            };

            const container = try doc.createElement(.div);
            container.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = @floatFromInt(left) },
                .top = .{ .cells = @floatFromInt(top) },
                .width = .{ .cells = @floatFromInt(width) },
                .height = .{ .cells = @floatFromInt(height) },
                .overflow = .hidden,
            });

            const content = try widget.build(widget.context, doc);
            _ = try container.appendChild(content);
            _ = try root.appendChild(container);

            // The widget subtree is connected now, so focus can be restored
            // after the document rebuild.
            if (widget.is_focused(widget.context)) {
                if (widget.focus_node(widget.context)) |node| {
                    _ = doc.focus(node);
                }
            }
        }
    }
};

fn appendStatus(view: *View, doc: *ui.Document, root: *ui.Node, rows: usize) !void {
    if (rows == 0) return;
    const editor = view.editor;
    const status_row: f64 = @floatFromInt(rows - 1);

    const bar = try doc.createElement(.div);
    bar.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = status_row },
        .width = .{ .percent = 100 },
        .height = .{ .cells = 1 },
        .overflow = .hidden,
        .reverse = true,
    });

    var status_buf: [1024]u8 = undefined;
    const position = editor.modelCursorPosition();
    const message = editor.message();
    const status = std.fmt.bufPrint(
        &status_buf,
        " {s}{s}  Ln {d}, Col {d}  {s}  Ctrl-Q quit{s}{s}",
        .{
            editor.path,
            if (editor.isDirty()) "*" else "",
            position.lineNumber,
            position.column,
            editor.languageId(),
            if (message.len > 0) "  " else "",
            message,
        },
    ) catch status_buf[0..0];

    const text = try doc.createText(status);
    _ = try bar.appendChild(text);
    _ = try root.appendChild(bar);
}

fn appendRuns(
    doc: *ui.Document,
    line: *ui.Node,
    rendered: line_renderer.RenderedLine,
    flags: []const u8,
) !void {
    var part_index: usize = 0;
    var byte_in_part: usize = 0;
    var cell: usize = 0;
    var absolute: usize = 0;

    var run_start: usize = 0;
    var run_style: ?ui.Style = null;

    while (part_index < rendered.parts.len) {
        const part = rendered.parts[part_index];
        if (byte_in_part >= part.text.len) {
            part_index += 1;
            byte_in_part = 0;
            continue;
        }

        const decoded = ui.dom.decodeAt(part.text, byte_in_part);
        if (decoded.len == 0) break;
        const width = measureCodepoint(decoded.cp);

        var style = tokenStyle(part);
        if (cell < flags.len) {
            const flag = flags[cell];
            if (flag & CellFlag.current_find_match != 0) {
                style.background = color(current_find_match_background);
                style.color = color(current_find_match_foreground);
            } else if (flag & CellFlag.find_match != 0) {
                style.background = color(find_match_background);
            } else if (flag & CellFlag.find_scope != 0) {
                style.background = color(find_scope_background);
            }
            if (flag & CellFlag.secondary_cursor != 0) {
                style.reverse = true;
                style.background = color(secondary_cursor_background);
            }
            if (flag & CellFlag.selected != 0) style.reverse = true;
        }

        if (run_style == null or !styleEql(run_style.?, style)) {
            if (run_style != null and absolute > run_start) {
                const node = try doc.createText(rendered.bytes[run_start..absolute]);
                node.setStyle(run_style.?);
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
        const node = try doc.createText(rendered.bytes[run_start..absolute]);
        node.setStyle(run_style.?);
        _ = try line.appendChild(node);
    }
}

fn markSelections(
    states: []const CursorState,
    view_line: usize,
    model_content: []const u8,
    tab_size: usize,
    start_visible_column: usize,
    line_width: usize,
    flags: []u8,
) void {
    for (states) |state| {
        const selection = state.viewState.selection;
        if (selection.isEmpty()) continue;
        if (view_line < selection.startLineNumber or view_line > selection.endLineNumber) continue;

        var start: usize = 0;
        if (view_line == selection.startLineNumber) {
            start = visibleOffset(model_content, selection.startColumn, tab_size, start_visible_column);
        }
        var end: usize = line_width;
        if (view_line == selection.endLineNumber) {
            end = visibleOffset(model_content, selection.endColumn, tab_size, start_visible_column);
        }
        start = @min(start, line_width);
        end = @min(end, line_width);
        var cell = start;
        while (cell < end and cell < flags.len) : (cell += 1) {
            flags[cell] |= CellFlag.selected;
        }
    }

    if (states.len > 1) {
        for (states[1..]) |state| {
            const position = state.viewState.position;
            if (position.lineNumber != view_line) continue;
            const cell = visibleOffset(model_content, position.column, tab_size, start_visible_column);
            if (cell < flags.len) flags[cell] |= CellFlag.secondary_cursor;
        }
    }
}

fn visibleOffset(
    model_content: []const u8,
    column: usize,
    tab_size: usize,
    start_visible_column: usize,
) usize {
    const visible = CursorColumns.visibleColumnFromColumn(model_content, column, tab_size);
    return visible -| start_visible_column;
}

fn tokenStyle(part: line_renderer.RenderedPart) ui.Style {
    var style = ui.Style{
        .bold = part.bold,
        .italic = part.italic,
        .underline = part.underline,
        .strikethrough = part.strikethrough,
    };
    if (theme.colorForToken(part.foreground)) |rgb| {
        style.color = color(rgb);
    }
    return style;
}

fn styleEql(a: ui.Style, b: ui.Style) bool {
    return std.meta.eql(a, b);
}

fn measureCodepoint(cp: u21) u2 {
    const next = CursorColumns.nextVisibleColumn(cp, 0, 1);
    return @intCast(@min(next, 2));
}

fn color(rgb: [3]u8) ui.Color {
    return .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
}

fn rowText(view: *View, allocator: std.mem.Allocator, row: usize) ![]u8 {
    return view.surface.grid().rowText(allocator, row);
}

test "View: text, gutter and status" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "a\nb", "test.txt", 80, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    const row0 = try rowText(view, allocator, 0);
    defer allocator.free(row0);
    try std.testing.expect(std.mem.indexOf(u8, row0, "1") != null);
    try std.testing.expect(std.mem.indexOf(u8, row0, "a") != null);

    const row1 = try rowText(view, allocator, 1);
    defer allocator.free(row1);
    try std.testing.expect(std.mem.indexOf(u8, row1, "2") != null);
    try std.testing.expect(std.mem.indexOf(u8, row1, "b") != null);

    const status = try rowText(view, allocator, 4);
    defer allocator.free(status);
    try std.testing.expect(std.mem.indexOf(u8, status, "Ctrl-Q") != null);

    const cursor = view.cursorCell().?;
    try std.testing.expectEqual(@as(usize, 0), cursor.row);
    try std.testing.expectEqual(editor.gutterWidth(), cursor.col);
}

test "View: CJK and tab runs keep the caret on the right cell" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "中\tq", "test.txt", 20, 3);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    const row = try rowText(view, allocator, 0);
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "中") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "q") != null);

    // The caret is at column 1, on the first cell after the gutter.
    const cursor = view.cursorCell().?;
    try std.testing.expectEqual(editor.gutterWidth(), cursor.col);
}

test "View: wrapped continuation gets a gutter arrow" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(
        allocator,
        io,
        "abcdefghij klmno",
        "test.txt",
        12,
        6,
    );
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    var found_arrow = false;
    var row: usize = 0;
    while (row < editor.textHeight()) : (row += 1) {
        const text = try rowText(view, allocator, row);
        defer allocator.free(text);
        if (std.mem.indexOf(u8, text, "↪") != null) {
            found_arrow = true;
            break;
        }
    }
    try std.testing.expect(found_arrow);
}

test "View: selection paints inverted cells" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "hello", "test.txt", 20, 3);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.moveRight(true);
    try editor.moveRight(true);

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    const grid = view.surface.grid();
    const gutter = editor.gutterWidth();
    try std.testing.expect(grid.attrs[grid.index(gutter, 0)] & ui.cell.Attr.inverse != 0);
    try std.testing.expectEqual(@as(u16, 0), grid.attrs[grid.index(gutter + 2, 0)] & ui.cell.Attr.inverse);
}

test "View: refresh keeps the frame diff and the cursor visible" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "a\nb", "test.txt", 20, 4);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var first: std.Io.Writer.Allocating = .init(allocator);
    defer first.deinit();
    try view.render(&first.writer);
    try std.testing.expect(first.written().len > 0);

    var unchanged: std.Io.Writer.Allocating = .init(allocator);
    defer unchanged.deinit();
    try view.refresh();
    try view.render(&unchanged.writer);
    try std.testing.expectEqual(@as(usize, 0), unchanged.written().len);

    try editor.moveDown(false);
    try view.refresh();
    var moved: std.Io.Writer.Allocating = .init(allocator);
    defer moved.deinit();
    try view.render(&moved.writer);
    try std.testing.expect(moved.written().len > 0);
    try std.testing.expectEqual(@as(usize, 1), view.cursorCell().?.row);
}

const TestOverlay = struct {
    focused: bool = false,
    node: ?*ui.Node = null,
    keys: usize = 0,

    fn overlay(self: *TestOverlay) editorBrowser.IOverlayWidget {
        return .{
            .context = self,
            .get_id = getId,
            .get_position = getPosition,
            .width = width,
            .height = height,
            .build = build,
            .focus_node = focusNode,
            .is_focused = isFocused,
        };
    }

    fn getId(context: *anyopaque) []const u8 {
        _ = context;
        return "test.overlay";
    }

    fn getPosition(context: *anyopaque) editorBrowser.OverlayWidgetPositionPreference {
        _ = context;
        return .top_right_corner;
    }

    fn width(context: *anyopaque, cols: usize) usize {
        _ = context;
        return @min(cols, 6);
    }

    fn height(context: *anyopaque) usize {
        _ = context;
        return 1;
    }

    fn build(context: *anyopaque, doc: *ui.Document) !*ui.Node {
        const self: *TestOverlay = @ptrCast(@alignCast(context));
        const node = try doc.createElement(.div);
        node.asElement().focusable = true;
        node.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = 0 },
            .top = .{ .cells = 0 },
            .width = .{ .percent = 100 },
            .height = .{ .cells = 1 },
            .reverse = true,
        });
        _ = try node.appendChild(try doc.createText("test"));
        try node.addEventListener(.{ .context = self, .key_down = onKey });
        self.node = node;
        return node;
    }

    fn focusNode(context: *anyopaque) ?*ui.Node {
        const self: *TestOverlay = @ptrCast(@alignCast(context));
        return self.node;
    }

    fn isFocused(context: *anyopaque) bool {
        const self: *TestOverlay = @ptrCast(@alignCast(context));
        return self.focused;
    }

    fn onKey(context: ?*anyopaque, event: *ui.KeyEvent) void {
        const self: *TestOverlay = @ptrCast(@alignCast(context orelse return));
        self.keys += 1;
        event.stopPropagation();
        event.preventDefault();
    }
};

test "View: overlay widget is placed top-right and takes focused keys" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "abc", "test.txt", 20, 4);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var overlay = TestOverlay{};
    try view.addOverlayWidget(overlay.overlay());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    const row = try rowText(view, allocator, 0);
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "test") != null);

    var event = ui.KeyEvent{ .key = .{ .char = 'x' } };
    try std.testing.expect(!view.dispatchKey(&event));

    overlay.focused = true;
    try view.refresh();
    try std.testing.expect(view.surface.document().activeElement() != null);
    try std.testing.expect(view.dispatchKey(&event));
    try std.testing.expectEqual(@as(usize, 1), overlay.keys);
}
