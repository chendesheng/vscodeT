// Port of `src/vs/editor/browser/viewParts/editorScrollbar/editorScrollbar.ts`.
//
// Terminal adaptation: the browser scrollbar is a `SmoothScrollableElement`
// with DOM range/slider parts and bitmap/theme shadows. The terminal paints
// the same scroll state into the reserved right-hand cells: overview-ruler
// markers first, then the half-cell-precision thumb glyph. Ruler markers
// project to half-cells too, so a marker edge can sit on the upper or lower
// half of a row and is drawn with a quadrant or half-block glyph. The thumb
// uses the exact (fractional) slider position and size from `ScrollbarState`,
// and both edges are quantized to half cells. The thumb's mouse hit box covers
// every row the painted thumb touches, so its painted edges remain draggable.
// A terminal row shares one foreground color, so the thumb still owns every
// cell it touches. The wheel path ports `ScrollableElement._onMouseWheel`: scale by
// `mouseWheelScrollSensitivity`, apply `fastScrollSensitivity` for Alt,
// accumulate sub-line remainders and move whole view lines through the
// editor's `ViewLayout`. The scroll-state contract comes from the ported
// `scrollbarState` and `decorationsOverviewRuler`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");

const editorBrowser = @import("../../editorBrowser.zig");
const RetainedViewPartHost = editorBrowser.RetainedViewPartHost;
const Editor = @import("../../widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const decorationsOverviewRuler = @import("../overviewRuler/decorationsOverviewRuler.zig");
const scrollbar_state = @import("../../../../base/browser/ui/scrollbar/scrollbarState.zig");

const scrollbar_thumb_color = [3]u8{ 108, 108, 108 };
pub const TerminalScrollbar = struct {
    allocator: Allocator,
    width: usize,
    drag: ?DragState = null,
    /// Sub-line remainder of the wheel deltas. The terminal scrolls whole view
    /// lines, so a fractional `mouseWheelScrollSensitivity` accumulates here
    /// instead of being dropped, like upstream's smooth-scroll accumulator.
    wheel_remainder_lines: f64 = 0,
    /// Terminal retention: the ruler column and one cell per screen row are
    /// kept across frames; a repaint only rewrites the cells whose thumb or
    /// marker paint changed.
    overview: decorationsOverviewRuler.DecorationsOverviewRuler = .{},
    column: ?*ui.Node = null,
    cells: std.array_list.Managed(Cell),
    column_left: usize = 0,
    column_width: usize = 0,
    column_height: usize = 0,

    const DragState = struct {
        start_row: usize,
        initial_state: scrollbar_state.ScrollbarState,
    };

    const Cell = struct {
        node: *ui.Node,
        color: ui.Color = .{ .r = 0, .g = 0, .b = 0 },
    };

    pub fn init(allocator: Allocator) TerminalScrollbar {
        return .{
            .allocator = allocator,
            .width = 0,
            .cells = std.array_list.Managed(Cell).init(allocator),
        };
    }

    pub fn deinit(self: *TerminalScrollbar) void {
        self.drag = null;
        self.overview.deinit(self.allocator);
        self.cells.deinit();
    }

    /// Drops the retained node pointers when the document that owns them is
    /// being cleared or replaced. The nodes are not touched.
    pub fn resetNodes(self: *TerminalScrollbar) void {
        self.cells.clearRetainingCapacity();
        self.column = null;
        self.column_left = 0;
        self.column_width = 0;
        self.column_height = 0;
    }

    pub fn isDragging(self: *const TerminalScrollbar) bool {
        return self.drag != null;
    }

    pub fn endDrag(self: *TerminalScrollbar) void {
        self.drag = null;
    }

    /// Port of the scrollbar slider's pointer-down behavior. Starts a drag,
    /// jumping to the clicked track position when the press is not on the
    /// thumb.
    pub fn beginDrag(
        self: *TerminalScrollbar,
        editor: *Editor,
        x: usize,
        y: usize,
        cols: usize,
        scrollbar_width: usize,
        height: usize,
    ) void {
        if (height == 0) return;
        var scroll_state = self.state(editor);
        if (!scroll_state.isNeeded()) return;

        const geometry = thumbGeometry(scroll_state, height);
        const row = @min(y, height - 1);
        const in_thumb = cols -| scrollbar_width <= x and
            row >= geometry.top and
            row < geometry.top + geometry.size;
        if (!in_thumb) {
            const desired = scroll_state.getDesiredScrollPositionFromOffset(@floatFromInt(row));
            const applied = applyScrollPosition(editor, desired);
            _ = scroll_state.setScrollPosition(@floatFromInt(applied));
        }
        self.drag = .{ .start_row = row, .initial_state = scroll_state };
    }

    /// Port of the wheel delta pipeline in
    /// `src/vs/base/browser/ui/scrollbar/scrollableElement.ts`: scale by
    /// `mouseWheelScrollSensitivity`, apply `fastScrollSensitivity` when Alt is
    /// held, accumulate the fractional line remainder and move whole view
    /// lines. The terminal input decoder already reports deltas in lines (±3
    /// per notch), so no pixel-to-line conversion is needed.
    pub fn delegateScrollFromMouseWheelEvent(
        self: *TerminalScrollbar,
        editor: *Editor,
        delta_lines: i32,
        mods: ui.Modifiers,
        mouse_wheel_scroll_sensitivity: f64,
        fast_scroll_sensitivity: f64,
    ) bool {
        if (delta_lines == 0) return false;
        var delta = @as(f64, @floatFromInt(delta_lines)) * mouse_wheel_scroll_sensitivity;
        if (mods.alt) delta *= fast_scroll_sensitivity;
        self.wheel_remainder_lines += delta;
        const whole = if (self.wheel_remainder_lines < 0)
            @ceil(self.wheel_remainder_lines)
        else
            @floor(self.wheel_remainder_lines);
        if (whole == 0) return false;
        self.wheel_remainder_lines -= whole;
        const limit: f64 = 1_000_000;
        const clamped = @max(@min(whole, limit), -limit);
        return editor.scrollViewLines(@intFromFloat(clamped));
    }

    pub fn dragTo(self: *TerminalScrollbar, editor: *Editor, y: usize, height: usize) bool {
        const drag = self.drag orelse return false;
        if (height == 0) return false;
        const row = @min(y, height - 1);
        const delta = @as(f64, @floatFromInt(row)) - @as(f64, @floatFromInt(drag.start_row));
        const desired = drag.initial_state.getDesiredScrollPositionFromDelta(delta);
        _ = applyScrollPosition(editor, desired);
        return true;
    }

    /// Port of `EditorScrollbar`'s scroll-state ownership for the terminal.
    pub fn state(self: *const TerminalScrollbar, editor: *Editor) scrollbar_state.ScrollbarState {
        _ = self;
        return scrollbar_state.ScrollbarState.initWithMinimumSliderSize(
            0,
            1,
            0,
            @floatFromInt(editor.textHeight()),
            @floatFromInt(editor.scrollHeight()),
            @floatFromInt(editor.topViewLine() - 1),
            1,
        );
    }

    /// Paints the overview ruler and thumb into the reserved column.
    pub fn render(
        self: *TerminalScrollbar,
        doc: *ui.Document,
        root: *ui.Node,
        editor: *Editor,
        text_height: usize,
        cols: usize,
        column_width: usize,
        host: ?*RetainedViewPartHost,
    ) !void {
        if (column_width < 1) {
            if (self.column != null) self.destroyColumn(doc, host);
            return;
        }
        const left = cols -| column_width;
        if (left >= cols) return;

        const row_markers = self.overview.rows;
        const scroll_state = self.state(editor);
        const halves = if (scroll_state.isNeeded())
            thumbHalfGeometry(scroll_state, text_height)
        else
            ThumbHalves{ .top = 0, .end = 0 };

        const previous_cells = self.cells.items.len;
        var new_column = false;
        if (self.column == null) {
            const column = try doc.createElement(.div);
            column.setStyle(columnStyle(left, column_width, text_height));
            _ = try root.appendChild(column);
            self.column = column;
            self.column_left = left;
            self.column_width = column_width;
            self.column_height = text_height;
            new_column = true;
        }
        const column = self.column.?;
        var geometry_changed = false;
        if (!new_column) {
            if (self.column_left != left or self.column_width != column_width) {
                column.setStyle(columnStyle(left, column_width, text_height));
                self.column_left = left;
                self.column_width = column_width;
                self.column_height = text_height;
                geometry_changed = true;
            } else if (self.column_height != text_height) {
                column.asElement().style.height = .{ .cells = @floatFromInt(text_height) };
                self.column_height = text_height;
                geometry_changed = true;
            }
        }

        while (self.cells.items.len < text_height) {
            const cell_row = self.cells.items.len;
            const cell = try doc.createElement(.div);
            cell.setStyle(cellStyle(cell_row, column_width));
            const glyph = try doc.createTextBorrowed("");
            _ = try cell.appendChild(glyph);
            _ = try column.appendChild(cell);
            try self.cells.append(.{ .node = cell });
        }
        while (self.cells.items.len > text_height) {
            const dropped = self.cells.pop().?;
            if (host) |retained| retained.removeSubtree(dropped.node);
            doc.destroy(dropped.node);
        }
        if (geometry_changed) {
            for (self.cells.items) |cell| {
                cell.node.asElement().style.width = .{ .cells = @floatFromInt(column_width) };
            }
        }

        if (new_column) {
            var row: usize = 0;
            while (row < text_height) : (row += 1) {
                const paint = desiredCell(row_markers, halves, row);
                _ = paintCell(&self.cells.items[row], paint.glyph, paint.color);
            }
            if (host) |retained| try retained.addSubtree(column);
            return;
        }

        if (geometry_changed) {
            var row: usize = 0;
            while (row < text_height) : (row += 1) {
                const paint = desiredCell(row_markers, halves, row);
                _ = paintCell(&self.cells.items[row], paint.glyph, paint.color);
            }
            if (host) |retained| try retained.rebuildSubtree(column);
            return;
        }

        var row: usize = 0;
        while (row < text_height) : (row += 1) {
            const paint = desiredCell(row_markers, halves, row);
            const changed = paintCell(&self.cells.items[row], paint.glyph, paint.color);
            if (row >= previous_cells) {
                if (host) |retained| try retained.addSubtree(self.cells.items[row].node);
            } else if (changed) {
                if (host) |retained| try retained.rebuildSubtree(self.cells.items[row].node);
            }
        }
    }

    fn destroyColumn(self: *TerminalScrollbar, doc: *ui.Document, host: ?*RetainedViewPartHost) void {
        if (self.column) |column| {
            if (host) |retained| retained.removeSubtree(column);
            doc.destroy(column);
        } else {
            for (self.cells.items) |cell| {
                if (host) |retained| retained.removeSubtree(cell.node);
                doc.destroy(cell.node);
            }
        }
        self.resetNodes();
    }
};

const CellPaint = struct {
    glyph: []const u8,
    color: ui.Color,
};

fn columnStyle(left: usize, width: usize, height: usize) ui.Style {
    return .{
        .position = .absolute,
        .left = .{ .cells = @floatFromInt(left) },
        .top = .{ .cells = 0 },
        .width = .{ .cells = @floatFromInt(width) },
        .height = .{ .cells = @floatFromInt(height) },
        .overflow = .hidden,
    };
}

fn cellStyle(row: usize, width: usize) ui.Style {
    return .{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = @floatFromInt(row) },
        .width = .{ .cells = @floatFromInt(width) },
        .height = .{ .cells = 1 },
        .white_space = .pre,
    };
}

fn desiredCell(
    row_markers: []const ?decorationsOverviewRuler.Marker,
    halves: ThumbHalves,
    row: usize,
) CellPaint {
    const thumb_part = thumbPartAt(halves, row);
    if (thumb_part != .none) {
        const vertical: decorationsOverviewRuler.Vertical = switch (thumb_part) {
            .none => unreachable,
            .full => .full,
            .upper => .upper,
            .lower => .lower,
        };
        return .{ .glyph = markerGlyph(.full, vertical), .color = color(scrollbar_thumb_color) };
    }
    const marker = if (row < row_markers.len) row_markers[row] else null;
    if (marker) |paint| {
        return .{ .glyph = markerGlyph(paint.lane, paint.vertical), .color = color(paint.color) };
    }
    return .{ .glyph = "", .color = .{ .r = 0, .g = 0, .b = 0 } };
}

/// Rewrites one retained scrollbar cell. Returns whether its painted glyph or
/// colour changed.
fn paintCell(cell: *TerminalScrollbar.Cell, glyph: []const u8, cell_color: ui.Color) bool {
    const text = cell.node.first_child orelse return false;
    if (cell.color.eql(cell_color) and std.mem.eql(u8, text.asText().data, glyph)) return false;
    cell.color = cell_color;
    // desiredCell selects string literals, so the text survives cell-list growth.
    text.setTextBorrowed(glyph);
    text.setStyle(.{ .color = cell_color });
    cell.node.asElement().style.color = cell_color;
    return true;
}

fn markerGlyph(lane: decorationsOverviewRuler.Lane, vertical: decorationsOverviewRuler.Vertical) []const u8 {
    return switch (vertical) {
        .full => switch (lane) {
            .left => "▐ ",
            .center => " ▌",
            .right => " ▐",
            .full => "▐█",
        },
        .upper => switch (lane) {
            .left => "▝ ",
            .center => " ▘",
            .right => " ▝",
            .full => "▝▀",
        },
        .lower => switch (lane) {
            .left => "▗ ",
            .center => " ▖",
            .right => " ▗",
            .full => "▗▄",
        },
    };
}

const ThumbHalves = struct {
    top: usize,
    end: usize,
};

const ThumbPart = enum { none, upper, lower, full };

fn thumbHalfGeometry(state: scrollbar_state.ScrollbarState, track_height: usize) ThumbHalves {
    const total_halves = track_height * 2;
    if (track_height == 0 or total_halves == 0) return .{ .top = 0, .end = 0 };

    // Round each edge independently from the exact geometry, so the thumb size
    // keeps its fractional half-cell instead of being forced to whole cells.
    const exact_top = state.getSliderPositionExact();
    const raw_top = @round(exact_top * 2);
    const raw_end = @round((exact_top + state.getSliderSizeExact()) * 2);

    const top: usize = if (raw_top <= 0)
        0
    else if (raw_top >= @as(f64, @floatFromInt(total_halves - 1)))
        total_halves - 1
    else
        @intFromFloat(raw_top);
    var end: usize = if (raw_end <= 0)
        0
    else if (raw_end >= @as(f64, @floatFromInt(total_halves)))
        total_halves
    else
        @intFromFloat(raw_end);
    if (end <= top) end = @min(top + 1, total_halves);
    return .{ .top = top, .end = end };
}

fn thumbPartAt(halves: ThumbHalves, row: usize) ThumbPart {
    const row_start = row * 2;
    const row_end = row_start + 2;
    if (halves.end <= row_start or halves.top >= row_end) return .none;
    if (halves.top <= row_start and halves.end >= row_end) return .full;
    if (halves.top <= row_start) return .upper;
    return .lower;
}

const ThumbGeometry = struct {
    top: usize,
    size: usize,
};

fn thumbGeometry(state: scrollbar_state.ScrollbarState, track_height: usize) ThumbGeometry {
    if (track_height == 0) return .{ .top = 0, .size = 0 };

    // Pointer events address whole rows, so the hit box covers every row the
    // half-cell thumb touches. This keeps the painted edges draggable even
    // though the paint is more precise than the upstream rounded slider.
    const halves = thumbHalfGeometry(state, track_height);
    if (halves.end <= halves.top) return .{ .top = 0, .size = 0 };
    const top = halves.top / 2;
    const last = (halves.end - 1) / 2;
    return .{ .top = top, .size = last - top + 1 };
}

fn applyScrollPosition(editor: *Editor, desired: f64) usize {
    const max_scroll = editor.scrollHeight() -| editor.textHeight();
    const clamped: usize = if (!(desired > 0))
        0
    else if (desired >= @as(f64, @floatFromInt(max_scroll)))
        max_scroll
    else
        @min(@as(usize, @intFromFloat(@round(desired))), max_scroll);
    _ = editor.setTopViewLine(clamped + 1);
    return clamped;
}

fn color(rgb: [3]u8) ui.Color {
    return .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
}

test "editorScrollbar: half-cell marker glyphs cover every lane" {
    const testing = std.testing;

    try testing.expectEqualStrings("▐ ", markerGlyph(.left, .full));
    try testing.expectEqualStrings("▝ ", markerGlyph(.left, .upper));
    try testing.expectEqualStrings("▗ ", markerGlyph(.left, .lower));
    try testing.expectEqualStrings(" ▌", markerGlyph(.center, .full));
    try testing.expectEqualStrings(" ▘", markerGlyph(.center, .upper));
    try testing.expectEqualStrings(" ▖", markerGlyph(.center, .lower));
    try testing.expectEqualStrings(" ▐", markerGlyph(.right, .full));
    try testing.expectEqualStrings(" ▝", markerGlyph(.right, .upper));
    try testing.expectEqualStrings(" ▗", markerGlyph(.right, .lower));
    try testing.expectEqualStrings("▐█", markerGlyph(.full, .full));
    try testing.expectEqualStrings("▝▀", markerGlyph(.full, .upper));
    try testing.expectEqualStrings("▗▄", markerGlyph(.full, .lower));
}

test "editorScrollbar: thumb edges use the exact fractional size" {
    const testing = std.testing;
    // Five visible lines over 13 give a 25/13-cell slider; both edges land on
    // half cells instead of rounding the size down to one whole cell.
    const state = scrollbar_state.ScrollbarState.initWithMinimumSliderSize(0, 1, 0, 5, 13, 1, 1);
    const halves = thumbHalfGeometry(state, 5);

    try testing.expectEqual(@as(usize, 1), halves.top);
    try testing.expectEqual(@as(usize, 5), halves.end);
}

test "editorScrollbar: wheel sensitivity, fast scroll and remainder" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var text: std.Io.Writer.Allocating = .init(allocator);
    defer text.deinit();
    for (0..50) |i| try text.writer.print("line {d}\n", .{i});

    const editor = try Editor.createFromText(allocator, io, text.written(), "test.txt", 40, 12);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    var scrollbar = TerminalScrollbar.init(allocator);
    defer scrollbar.deinit();

    // A quarter sensitivity leaves a sub-line remainder.
    try testing.expect(!scrollbar.delegateScrollFromMouseWheelEvent(editor, 3, .{}, 0.25, 1.0));
    try testing.expectEqual(@as(usize, 1), editor.topViewLine());
    try testing.expect(scrollbar.delegateScrollFromMouseWheelEvent(editor, 3, .{}, 0.25, 1.0));
    try testing.expectEqual(@as(usize, 2), editor.topViewLine());

    // Default sensitivity moves one input line per reported line.
    try testing.expect(scrollbar.delegateScrollFromMouseWheelEvent(editor, 3, .{}, 1.0, 1.0));
    try testing.expectEqual(@as(usize, 5), editor.topViewLine());

    // Alt applies fastScrollSensitivity.
    try testing.expect(scrollbar.delegateScrollFromMouseWheelEvent(
        editor,
        2,
        .{ .alt = true },
        1.0,
        5.0,
    ));
    try testing.expectEqual(@as(usize, 15), editor.topViewLine());

    // Clamps at the end of the document.
    _ = scrollbar.delegateScrollFromMouseWheelEvent(editor, 1000, .{}, 1.0, 1.0);
    try testing.expectEqual(editor.viewLineCount() -| editor.textHeight() + 1, editor.topViewLine());
}

test "editorScrollbar: unchanged thumb rows keep their glyphs when the viewport grows" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const lines: [40]u8 = @splat('\n');
    const editor = try Editor.createFromText(allocator, io, &lines, "test.txt", 40, 12);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    var doc = try ui.Document.init(allocator, .{ .cols = 40, .rows = 32 });
    defer doc.deinit();
    const root = try doc.createElement(.div);
    doc.setRoot(root);
    var scrollbar = TerminalScrollbar.init(allocator);
    defer scrollbar.deinit();

    for ([_]usize{ 12, 32 }) |height| {
        editor.setViewport(40, height);
        try scrollbar.render(&doc, root, editor, editor.textHeight(), 40, 2, null);
        for (scrollbar.cells.items[0..2]) |cell| {
            try std.testing.expectEqualStrings("▐█", cell.node.first_child.?.asText().data);
        }
    }
}
