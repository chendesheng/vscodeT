// Port of `src/vs/editor/browser/viewParts/editorScrollbar/editorScrollbar.ts`.
//
// Terminal adaptation: the browser scrollbar is a `SmoothScrollableElement`
// with DOM range/slider parts and bitmap/theme shadows. The terminal paints
// the same scroll state into the reserved right-hand cells: overview-ruler
// markers first, then the half-cell-precision thumb glyph, with scrolling
// input handled by the host. The scroll-state contract comes from the ported
// `scrollbarState` and `decorationsOverviewRuler`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");

const Editor = @import("../../widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const CursorState = @import("../../../common/cursorCommon.zig").CursorState;
const Position = @import("../../../common/core/position.zig").Position;
const decorationsOverviewRuler = @import("../overviewRuler/decorationsOverviewRuler.zig");
const scrollbar_state = @import("../../../../base/browser/ui/scrollbar/scrollbarState.zig");

const scrollbar_thumb_color = [3]u8{ 108, 108, 108 };
const overview_cursor_color = [3]u8{ 200, 200, 200 };
const overview_secondary_cursor_color = [3]u8{ 86, 70, 26 };

pub const TerminalScrollbar = struct {
    allocator: Allocator,
    width: usize,
    drag: ?DragState = null,

    const DragState = struct {
        start_row: usize,
        initial_state: scrollbar_state.ScrollbarState,
    };

    pub fn init(allocator: Allocator) TerminalScrollbar {
        return .{ .allocator = allocator, .width = 0 };
    }

    pub fn deinit(self: *TerminalScrollbar) void {
        self.drag = null;
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
        states: []const CursorState,
        text_height: usize,
        cols: usize,
        column_width: usize,
    ) !void {
        if (column_width < 1) return;
        const left = cols -| column_width;
        if (left >= cols) return;

        var markers = std.array_list.Managed(decorationsOverviewRuler.Decoration).init(self.allocator);
        defer markers.deinit();
        try appendOverviewMarkers(&markers, editor, self.allocator);

        var cursors = std.array_list.Managed(decorationsOverviewRuler.Cursor).init(self.allocator);
        defer cursors.deinit();
        const multiple_cursors = states.len > 1;
        for (states, 0..) |cursor_state, index| {
            const cursor_color = if (multiple_cursors and index > 0)
                overview_secondary_cursor_color
            else
                overview_cursor_color;
            try cursors.append(.{
                .line_number = cursor_state.viewState.position.lineNumber,
                .color = cursor_color,
                .lane = .full,
            });
        }
        std.mem.sort(decorationsOverviewRuler.Cursor, cursors.items, {}, cursorLessThan);

        const row_markers = try decorationsOverviewRuler.render(
            self.allocator,
            markers.items,
            cursors.items,
            .{
                .line_height = 1,
                .canvas_height = text_height,
                .outer_height = editor.scrollHeight(),
                .overview_ruler_lanes = 3,
                .hide_cursor = false,
                .min_decoration_height = 1,
            },
        );
        defer self.allocator.free(row_markers);

        const scroll_state = self.state(editor);
        const halves = if (scroll_state.isNeeded())
            thumbHalfGeometry(scroll_state, text_height)
        else
            ThumbHalves{ .top = 0, .end = 0 };

        const column = try doc.createElement(.div);
        column.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = @floatFromInt(left) },
            .top = .{ .cells = 0 },
            .width = .{ .cells = @floatFromInt(column_width) },
            .height = .{ .cells = @floatFromInt(text_height) },
            .overflow = .hidden,
        });
        _ = try root.appendChild(column);

        var row: usize = 0;
        while (row < text_height) : (row += 1) {
            const thumb_part = thumbPartAt(halves, row);
            const marker = if (row < row_markers.len) row_markers[row] else null;
            if (thumb_part == .none and marker == null) continue;

            const marker_color = if (thumb_part != .none) scrollbar_thumb_color else marker.?.color;
            const glyph_text: []const u8 = if (thumb_part != .none)
                switch (thumb_part) {
                    .none => unreachable,
                    .full => "▐█",
                    .upper => "▝▀",
                    .lower => "▗▄",
                }
            else
                markerGlyph(marker.?.lane, marker.?.vertical);

            const cell = try doc.createElement(.div);
            cell.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = 0 },
                .top = .{ .cells = @floatFromInt(row) },
                .width = .{ .cells = @floatFromInt(column_width) },
                .height = .{ .cells = 1 },
                .white_space = .pre,
                .color = color(marker_color),
            });
            const glyph = try doc.createText(glyph_text);
            glyph.setStyle(.{ .color = color(marker_color) });
            _ = try cell.appendChild(glyph);
            _ = try column.appendChild(cell);
        }
    }
};

pub fn appendOverviewMarkers(
    markers: *std.array_list.Managed(decorationsOverviewRuler.Decoration),
    editor: *Editor,
    allocator: Allocator,
) !void {
    const model_decorations = try editor.model.getOverviewRulerDecorations(0, false);
    defer allocator.free(model_decorations);

    for (model_decorations) |decoration| {
        const ruler = decoration.options.overviewRuler orelse continue;
        const marker_color = ruler.color orelse continue;
        const start = editor.viewPositionOfModelPosition(Position.init(
            decoration.range.startLineNumber,
            decoration.range.startColumn,
        ));
        const end = editor.viewPositionOfModelPosition(Position.init(
            decoration.range.endLineNumber,
            decoration.range.endColumn,
        ));
        try markers.append(.{
            .start_line_number = start.lineNumber,
            .end_line_number = @max(start.lineNumber, end.lineNumber),
            .color = marker_color,
            .lane = overviewRulerLaneFromModel(ruler.position),
            .z_index = @intCast(decoration.options.zIndex orelse 0),
        });
    }
}

fn overviewRulerLaneFromModel(lane: @import("../../../common/model.zig").OverviewRulerLane) decorationsOverviewRuler.Lane {
    return switch (lane) {
        .Left => .left,
        .Center => .center,
        .Right => .right,
        .Full => .full,
    };
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

fn cursorLessThan(_: void, a: decorationsOverviewRuler.Cursor, b: decorationsOverviewRuler.Cursor) bool {
    return a.line_number < b.line_number;
}

const ThumbHalves = struct {
    top: usize,
    end: usize,
};

const ThumbPart = enum { none, upper, lower, full };

fn thumbHalfGeometry(state: scrollbar_state.ScrollbarState, track_height: usize) ThumbHalves {
    const total_halves = track_height * 2;
    if (track_height == 0 or total_halves == 0) return .{ .top = 0, .end = 0 };

    const raw_top = @round(state.getSliderPositionExact() * 2);
    const raw_size = @round(state.getSliderSize() * 2);
    const size: usize = if (raw_size <= 0)
        1
    else
        @intFromFloat(raw_size);
    const top: usize = if (raw_top <= 0)
        0
    else if (raw_top >= @as(f64, @floatFromInt(total_halves - 1)))
        total_halves - 1
    else
        @intFromFloat(raw_top);
    return .{
        .top = top,
        .end = @min(top + size, total_halves),
    };
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

    const raw_size = @round(state.getSliderSize());
    var size: usize = if (raw_size >= @as(f64, @floatFromInt(track_height)))
        track_height
    else if (raw_size <= 0)
        1
    else
        @intFromFloat(raw_size);
    if (size == 0) size = 1;
    if (size > track_height) size = track_height;

    const max_top = track_height - size;
    const raw_top = @round(state.getSliderPosition());
    const top: usize = if (raw_top <= 0)
        0
    else if (raw_top >= @as(f64, @floatFromInt(max_top)))
        max_top
    else
        @intFromFloat(raw_top);

    return .{ .top = top, .size = size };
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
