// Port of the portable target-classification subset of
// `src/vs/editor/browser/controller/mouseTarget.ts`.
//
// Upstream resolves the DOM element under the pointer and walks its
// fingerprints to distinguish text, empty line space, gutter, widgets,
// scrollbar and status. The terminal host exposes the already-composed
// document and its placed rectangles through `TerminalMouseHost`, so the
// classification order and returned `MouseTarget` data stay upstream-shaped.

const std = @import("std");
const ui = @import("ui");

const editorBrowser = @import("../editorBrowser.zig");
const MouseTarget = editorBrowser.MouseTarget;
const MouseTargetType = editorBrowser.MouseTargetType;
const Position = @import("../../common/core/position.zig").Position;
const Range = @import("../../common/core/range.zig").Range;

/// Cell geometry of the terminal editor area.
pub const Geometry = struct {
    cols: usize,
    text_height: usize,
    gutter_width: usize,
    top_view_line: usize,
    view_line_count: usize,
    scrollbar_width: usize,
};

/// The terminal host surface the factory needs. All coordinates are cells.
pub const TerminalMouseHost = struct {
    context: *anyopaque,
    /// Returns the composed element under the pointer, if any.
    element_at: *const fn (context: *anyopaque, x: usize, y: usize) ?*ui.Node,
    content_widget_contains: *const fn (context: *anyopaque, x: usize, y: usize) bool,
    overlay_widget_contains: *const fn (context: *anyopaque, x: usize, y: usize) bool,
    geometry: *const fn (context: *anyopaque) Geometry,
    /// Rendered text width in cells, or null when the view line is not laid
    /// out in the current frame.
    line_text_width: *const fn (context: *anyopaque, view_line: usize) ?usize,
    position_at_view_point: *const fn (context: *anyopaque, view_line: usize, column: usize) anyerror!Position,
};

/// Port of `MouseTargetFactory.createMouseTarget` for the terminal document.
pub fn createMouseTarget(host: TerminalMouseHost, x: usize, y: usize) !MouseTarget {
    const geometry = host.geometry(host.context);
    const element = host.element_at(host.context, x, y);
    const mouse_column = x + 1;

    if (host.content_widget_contains(host.context, x, y)) {
        return .{ .element = element, .type = .content_widget, .mouse_column = mouse_column };
    }
    if (host.overlay_widget_contains(host.context, x, y)) {
        return .{ .element = element, .type = .overlay_widget, .mouse_column = mouse_column };
    }

    if (y >= geometry.text_height) {
        return .{ .element = element, .type = .status, .mouse_column = mouse_column };
    }

    if (geometry.scrollbar_width > 0 and x >= geometry.cols -| geometry.scrollbar_width) {
        const view_line = @min(geometry.top_view_line + y, geometry.view_line_count);
        return .{
            .element = element,
            .type = .scrollbar,
            .position = try host.position_at_view_point(host.context, view_line, 0),
            .mouse_column = mouse_column,
        };
    }

    const view_line = geometry.top_view_line + y;
    if (x < geometry.gutter_width) {
        return .{
            .element = element,
            .type = if (x + 1 == geometry.gutter_width and geometry.gutter_width >= 2)
                .gutter_line_decorations
            else
                .gutter_line_numbers,
            .position = try host.position_at_view_point(
                host.context,
                @min(view_line, geometry.view_line_count),
                0,
            ),
            .mouse_column = mouse_column,
        };
    }

    if (view_line > geometry.view_line_count) {
        return .{
            .element = element,
            .type = .content_empty,
            .mouse_column = mouse_column,
            .detail = .{ .content_empty = .{ .is_after_lines = true } },
        };
    }

    const position = try host.position_at_view_point(host.context, view_line, x - geometry.gutter_width);
    const range = Range.init(position.lineNumber, position.column, position.lineNumber, position.column);
    const text_width = host.line_text_width(host.context, view_line) orelse {
        return .{
            .element = element,
            .type = .content_empty,
            .mouse_column = mouse_column,
            .detail = .{ .content_empty = .{ .is_after_lines = false } },
        };
    };

    const offset = x - geometry.gutter_width;
    if (offset < text_width) {
        return .{
            .element = element,
            .type = .content_text,
            .position = position,
            .range = range,
            .mouse_column = mouse_column,
        };
    }
    return .{
        .element = element,
        .type = .content_empty,
        .position = position,
        .range = range,
        .mouse_column = mouse_column,
        .detail = .{ .content_empty = .{
            .is_after_lines = false,
            .horizontal_distance_to_text = offset - text_width,
        } },
    };
}
