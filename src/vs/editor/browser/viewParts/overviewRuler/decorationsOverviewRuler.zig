// Port of `src/vs/editor/browser/viewParts/overviewRuler/decorationsOverviewRuler.ts`.
//
// Terminal adaptation: the canvas is a single column of terminal cells. The
// upstream `y1`/`y2` projection is kept, but a row is written instead of a
// canvas `fillRect`, and every overview-ruler lane collapses onto that column.
// There is no alpha, border or canvas background; colors are supplied by the
// TUI and already composited. `MIN_DECORATION_HEIGHT` is one cell instead of
// six pixels, and cursor ticks are one cell tall.
//
// A row represents a range of document lines when the document is taller than
// the track; multiple markers landing on one row resolve by z-index, then
// color, matching upstream's group paint order. This quantization is inherent
// to terminal rows and is documented in `docs/terminal-ui.md`.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// One overview-ruler decoration, already converted to view lines and color.
pub const Decoration = struct {
    start_line_number: usize,
    end_line_number: usize,
    color: [3]u8,
    z_index: i32 = 0,
};

/// A cursor tick. Cursors are painted after all decorations, like upstream.
pub const Cursor = struct {
    line_number: usize,
    color: [3]u8,
};

pub const Settings = struct {
    line_height: f64 = 1,
    /// Number of terminal rows available for the ruler.
    canvas_height: usize,
    /// Scrollable height in line-height units.
    outer_height: usize,
    overview_ruler_lanes: usize = 3,
    hide_cursor: bool = false,
    min_decoration_height: usize = 1,
};

/// Renders the overview ruler into one optional color per track row. The
/// returned slice is owned by the caller.
pub fn render(
    allocator: Allocator,
    decorations: []const Decoration,
    cursors: []const Cursor,
    settings: Settings,
) ![]?[3]u8 {
    const rows = try allocator.alloc(?[3]u8, settings.canvas_height);
    errdefer allocator.free(rows);
    for (rows) |*row| row.* = null;

    if (settings.canvas_height == 0 or
        settings.overview_ruler_lanes == 0 or
        settings.outer_height == 0 or
        settings.line_height <= 0)
    {
        return rows;
    }

    const canvas_height: f64 = @floatFromInt(settings.canvas_height);
    const outer_height: f64 = @floatFromInt(settings.outer_height);
    const height_ratio = canvas_height / outer_height;
    const min_height: f64 = @floatFromInt(@max(settings.min_decoration_height, 1));

    const sorted = try allocator.dupe(Decoration, decorations);
    defer allocator.free(sorted);
    std.mem.sort(Decoration, sorted, {}, lessThan);

    for (sorted) |decoration| {
        const start = @max(decoration.start_line_number, 1);
        const end = @max(decoration.end_line_number, start);
        const offset1 = @as(f64, @floatFromInt(start - 1)) * settings.line_height;
        const offset2 = @as(f64, @floatFromInt(end - 1)) * settings.line_height + settings.line_height;

        var y1 = @floor(offset1 * height_ratio);
        var y2 = @floor(offset2 * height_ratio);

        if (y2 - y1 < min_height) {
            if (min_height <= 1) {
                // A terminal marker is one row: keep it on the row containing
                // the scaled line offset instead of centering it one row up.
                y2 = y1 + 1;
            } else {
                const center = (y1 + y2) / 2;
                y1 = @floor(center - min_height / 2);
                y2 = y1 + min_height;
            }
        }

        if (y1 < 0) {
            y2 -= y1;
            y1 = 0;
        }
        if (y2 > canvas_height) {
            const shift = y2 - canvas_height;
            y1 -= shift;
            y2 = canvas_height;
            if (y1 < 0) y1 = 0;
        }

        var top = clampToUsize(@floor(y1), settings.canvas_height);
        var bottom = clampToUsize(@floor(y2), settings.canvas_height);
        if (top >= settings.canvas_height) top = settings.canvas_height - 1;
        if (bottom <= top) bottom = @min(top + 1, settings.canvas_height);

        var row = top;
        while (row < bottom) : (row += 1) {
            rows[row] = decoration.color;
        }
    }

    if (!settings.hide_cursor) {
        for (cursors) |cursor| {
            const line = @max(cursor.line_number, 1);
            const offset = @as(f64, @floatFromInt(line - 1)) * settings.line_height;
            var row = clampToUsize(@floor(offset * height_ratio), settings.canvas_height);
            if (row >= settings.canvas_height) row = settings.canvas_height - 1;
            rows[row] = cursor.color;
        }
    }

    return rows;
}

fn clampToUsize(value: f64, max: usize) usize {
    if (value <= 0) return 0;
    const limit: f64 = @floatFromInt(max);
    if (value >= limit) return max;
    return @intFromFloat(value);
}

fn lessThan(_: void, a: Decoration, b: Decoration) bool {
    if (a.z_index != b.z_index) return a.z_index < b.z_index;
    const color_order = std.mem.order(u8, &a.color, &b.color);
    if (color_order != .eq) return color_order == .lt;
    if (a.start_line_number != b.start_line_number) {
        return a.start_line_number < b.start_line_number;
    }
    return a.end_line_number < b.end_line_number;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectRows(rows: []const ?[3]u8, expected: []const ?[3]u8) !void {
    try testing.expectEqual(expected.len, rows.len);
    for (rows, expected) |actual, wanted| {
        if (wanted) |color| {
            try testing.expectEqual(color, actual.?);
        } else {
            try testing.expect(actual == null);
        }
    }
}

fn expectColor(actual: ?[3]u8, expected: [3]u8) !void {
    try testing.expectEqual(expected, actual.?);
}

test "decorationsOverviewRuler: maps lines to rows" {
    const allocator = testing.allocator;
    const red = [3]u8{ 255, 0, 0 };
    const decorations = [_]Decoration{
        .{ .start_line_number = 1, .end_line_number = 1, .color = red },
        .{ .start_line_number = 50, .end_line_number = 50, .color = red },
        .{ .start_line_number = 100, .end_line_number = 100, .color = red },
    };

    const rows = try render(allocator, &decorations, &.{}, .{
        .canvas_height = 10,
        .outer_height = 100,
    });
    defer allocator.free(rows);

    var expected = [_]?[3]u8{ null, null, null, null, null, null, null, null, null, null };
    expected[0] = red;
    expected[4] = red;
    expected[9] = red;
    try expectRows(rows, &expected);
}

test "decorationsOverviewRuler: multi-line range spans rows" {
    const allocator = testing.allocator;
    const blue = [3]u8{ 0, 0, 255 };
    const decorations = [_]Decoration{
        .{ .start_line_number = 10, .end_line_number = 20, .color = blue },
    };

    const rows = try render(allocator, &decorations, &.{}, .{
        .canvas_height = 10,
        .outer_height = 100,
    });
    defer allocator.free(rows);

    var expected = [_]?[3]u8{ null, null, null, null, null, null, null, null, null, null };
    expected[0] = blue;
    expected[1] = blue;
    try expectRows(rows, &expected);
}

test "decorationsOverviewRuler: short document stays at the top" {
    const allocator = testing.allocator;
    const green = [3]u8{ 0, 255, 0 };
    const decorations = [_]Decoration{
        .{ .start_line_number = 2, .end_line_number = 2, .color = green },
    };

    const rows = try render(allocator, &decorations, &.{}, .{
        .canvas_height = 10,
        .outer_height = 10,
    });
    defer allocator.free(rows);

    var expected = [_]?[3]u8{ null, null, null, null, null, null, null, null, null, null };
    expected[1] = green;
    try expectRows(rows, &expected);
}

test "decorationsOverviewRuler: higher z-index wins a shared row" {
    const allocator = testing.allocator;
    const red = [3]u8{ 255, 0, 0 };
    const blue = [3]u8{ 0, 0, 255 };
    const decorations = [_]Decoration{
        .{ .start_line_number = 10, .end_line_number = 20, .color = red, .z_index = 0 },
        .{ .start_line_number = 12, .end_line_number = 14, .color = blue, .z_index = 10 },
    };

    const rows = try render(allocator, &decorations, &.{}, .{
        .canvas_height = 10,
        .outer_height = 100,
    });
    defer allocator.free(rows);

    // Red covers rows 0-1; blue lands on row 1 and wins there by z-index.
    try expectColor(rows[0], red);
    try expectColor(rows[1], blue);
}

test "decorationsOverviewRuler: cursors paint after decorations" {
    const allocator = testing.allocator;
    const red = [3]u8{ 255, 0, 0 };
    const white = [3]u8{ 255, 255, 255 };
    const decorations = [_]Decoration{
        .{ .start_line_number = 50, .end_line_number = 50, .color = red },
    };
    const cursors = [_]Cursor{
        .{ .line_number = 50, .color = white },
    };

    const rows = try render(allocator, &decorations, &cursors, .{
        .canvas_height = 10,
        .outer_height = 100,
    });
    defer allocator.free(rows);

    try expectColor(rows[4], white);
}

test "decorationsOverviewRuler: lanes off renders no markers or cursors" {
    const allocator = testing.allocator;
    const red = [3]u8{ 255, 0, 0 };
    const decorations = [_]Decoration{
        .{ .start_line_number = 1, .end_line_number = 1, .color = red },
    };
    const cursors = [_]Cursor{
        .{ .line_number = 1, .color = red },
    };

    const rows = try render(allocator, &decorations, &cursors, .{
        .canvas_height = 10,
        .outer_height = 100,
        .overview_ruler_lanes = 0,
    });
    defer allocator.free(rows);

    var expected = [_]?[3]u8{ null, null, null, null, null, null, null, null, null, null };
    try expectRows(rows, &expected);
}

test "decorationsOverviewRuler: many decorations in one row collapse" {
    const allocator = testing.allocator;
    const red = [3]u8{ 255, 0, 0 };
    const decorations = [_]Decoration{
        .{ .start_line_number = 1, .end_line_number = 1, .color = red },
        .{ .start_line_number = 2, .end_line_number = 2, .color = red },
        .{ .start_line_number = 3, .end_line_number = 3, .color = red },
        .{ .start_line_number = 4, .end_line_number = 4, .color = red },
    };

    const rows = try render(allocator, &decorations, &.{}, .{
        .canvas_height = 10,
        .outer_height = 1000,
    });
    defer allocator.free(rows);

    try expectColor(rows[0], red);
    var count: usize = 0;
    for (rows) |row| {
        if (row != null) count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}
