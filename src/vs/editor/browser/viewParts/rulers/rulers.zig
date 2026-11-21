// Port of the portable column decisions of
// `src/vs/editor/browser/viewParts/rulers/rulers.ts`.
//
// Terminal adaptation: upstream appends absolutely-positioned vertical `<div>`
// rulers in the text area. The terminal paints a one-cell `│` at the same
// visible column through the view-line guide layer; the ruler is skipped where
// a text glyph occupies the cell, because a cell cannot show both. Per-ruler
// CSS color overrides are not parsed; the theme's `editorRuler.foreground` is
// used for every ruler.

const std = @import("std");
const editor_options = @import("../../../common/config/editorOptions.zig");
const IRulerOption = editor_options.IRulerOption;

/// 0-based terminal cell column for a configured ruler, or null when the
/// ruler is outside the text area. Upstream columns are 1-based.
pub fn columnFor(ruler: IRulerOption, text_width: usize) ?usize {
    if (!(ruler.column > 0)) return null;
    const rounded: usize = @intFromFloat(@round(ruler.column));
    if (rounded == 0) return null;
    const column = rounded - 1;
    if (column >= text_width) return null;
    return column;
}

/// Filters configured rulers to visible 0-based cell columns.
pub fn columns(allocator: std.mem.Allocator, rulers: []const IRulerOption, text_width: usize) ![]usize {
    var result = std.array_list.Managed(usize).init(allocator);
    errdefer result.deinit();
    for (rulers) |ruler| {
        const column = columnFor(ruler, text_width) orelse continue;
        try result.append(column);
    }
    return result.toOwnedSlice();
}

test "rulers: filters and converts visible columns" {
    const rulers = [_]IRulerOption{
        .{ .column = 10, .color = null },
        .{ .column = 0, .color = null },
        .{ .column = 80, .color = null },
        .{ .column = 20.4, .color = null },
    };
    const visible = try columns(std.testing.allocator, &rulers, 40);
    defer std.testing.allocator.free(visible);
    try std.testing.expectEqualSlices(usize, &.{ 9, 19 }, visible);
}
