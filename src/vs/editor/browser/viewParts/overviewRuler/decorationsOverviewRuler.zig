// Port of `src/vs/editor/browser/viewParts/overviewRuler/decorationsOverviewRuler.ts`.
//
// Terminal adaptation: the canvas is a terminal ruler of cell rows. The
// upstream `y1`/`y2` projection is kept, but each row is split into upper and
// lower half-cells and the pixel coordinates are scaled to those halves, so a
// marker edge can sit on either half of a row. The paint boundary chooses a
// half block or quadrant glyph from the winning marker's lane and `vertical`.
// There is no alpha, border or canvas background; colors are supplied by the
// TUI and already composited. `MIN_DECORATION_HEIGHT` is one cell (two halves)
// instead of six pixels, and cursor ticks are one half-cell tall.
//
// A row represents a range of document lines when the document is taller than
// the track; multiple markers landing on one row resolve by z-index, then
// color, matching upstream's group paint order. A row has one foreground
// color, so a marker that shares only one half of a row still wins the whole
// row. This quantization is inherent to terminal cells and is documented in
// `docs/terminal-ui.md`.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Horizontal half-cell lane inside the terminal ruler strip.
pub const Lane = enum { left, center, right, full };

/// Vertical extent of a marker inside its terminal row. A marker edge can sit
/// on the upper or lower half of a row because the projection uses half-cells.
pub const Vertical = enum { full, upper, lower };

/// One overview-ruler decoration, already converted to view lines and color.
pub const Decoration = struct {
    start_line_number: usize,
    end_line_number: usize,
    color: [3]u8,
    lane: Lane = .center,
    z_index: i32 = 0,
};

/// A cursor tick. Cursors are painted after all decorations, like upstream.
pub const Cursor = struct {
    line_number: usize,
    color: [3]u8,
    lane: Lane = .full,
};

/// The winning marker for one terminal row, including which half of the row it
/// occupies.
pub const Marker = struct {
    color: [3]u8,
    lane: Lane,
    vertical: Vertical = .full,
};

pub const Settings = struct {
    line_height: f64 = 1,
    /// Number of terminal rows available for the ruler.
    canvas_height: usize,
    /// Scrollable height in line-height units.
    outer_height: usize,
    overview_ruler_lanes: usize = 3,
    hide_cursor: bool = false,
    /// Minimum decoration height in terminal rows. The ruler projects into two
    /// half-cells per row, so this is doubled internally.
    min_decoration_height: usize = 1,
};

/// Renders the overview ruler into one optional marker per track row, with the
/// marker edge resolved to the upper or lower half of that row. The returned
/// slice is owned by the caller.
pub fn render(
    allocator: Allocator,
    decorations: []const Decoration,
    cursors: []const Cursor,
    settings: Settings,
) ![]?Marker {
    const rows = try allocator.alloc(?Marker, settings.canvas_height);
    errdefer allocator.free(rows);
    for (rows) |*row| row.* = null;

    if (settings.canvas_height == 0 or
        settings.overview_ruler_lanes == 0 or
        settings.outer_height == 0 or
        settings.line_height <= 0)
    {
        return rows;
    }

    // Two vertical subcells per terminal row: upper and lower half.
    const canvas_halves = settings.canvas_height * 2;
    const canvas_halves_f: f64 = @floatFromInt(canvas_halves);
    const outer_height: f64 = @floatFromInt(settings.outer_height);
    const height_ratio = canvas_halves_f / outer_height;
    const min_height: f64 = @floatFromInt(@max(settings.min_decoration_height, 1) * 2);
    const half_min_height = min_height / 2;

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
            // Same centering and canvas clamping as upstream, in half-cells.
            var center = @floor((y1 + y2) / 2);
            if (center < half_min_height) {
                center = half_min_height;
            } else if (center + half_min_height > canvas_halves_f) {
                center = canvas_halves_f - half_min_height;
            }
            y1 = center - half_min_height;
            y2 = center + half_min_height;
        }

        if (y1 < 0) {
            y2 -= y1;
            y1 = 0;
        }
        if (y2 > canvas_halves_f) {
            const shift = y2 - canvas_halves_f;
            y1 -= shift;
            y2 = canvas_halves_f;
            if (y1 < 0) y1 = 0;
        }

        var top = clampToUsize(@floor(y1), canvas_halves);
        var bottom = clampToUsize(@floor(y2), canvas_halves);
        if (top >= canvas_halves) top = canvas_halves - 1;
        if (bottom <= top) bottom = @min(top + 1, canvas_halves);

        var row = top / 2;
        const last_row = (bottom - 1) / 2;
        while (row <= last_row) : (row += 1) {
            const row_start = row * 2;
            const vertical: Vertical = if (top <= row_start and bottom >= row_start + 2)
                .full
            else if (top <= row_start)
                .upper
            else
                .lower;
            rows[row] = .{
                .color = decoration.color,
                .lane = decoration.lane,
                .vertical = vertical,
            };
        }
    }

    if (!settings.hide_cursor) {
        for (cursors) |cursor| {
            const line = @max(cursor.line_number, 1);
            const offset = @as(f64, @floatFromInt(line - 1)) * settings.line_height;
            var half = clampToUsize(@floor(offset * height_ratio), canvas_halves);
            if (half >= canvas_halves) half = canvas_halves - 1;
            rows[half / 2] = .{
                .color = cursor.color,
                .lane = cursor.lane,
                .vertical = if (half % 2 == 0) .upper else .lower,
            };
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

fn expectRows(rows: []const ?Marker, expected: []const ?Marker) !void {
    try testing.expectEqual(expected.len, rows.len);
    for (rows, expected) |actual, wanted| {
        if (wanted) |marker| {
            try testing.expectEqual(marker.color, actual.?.color);
            try testing.expectEqual(marker.lane, actual.?.lane);
            try testing.expectEqual(marker.vertical, actual.?.vertical);
        } else {
            try testing.expect(actual == null);
        }
    }
}

fn expectMarker(actual: ?Marker, color: [3]u8, lane: Lane, vertical: Vertical) !void {
    try testing.expectEqual(color, actual.?.color);
    try testing.expectEqual(lane, actual.?.lane);
    try testing.expectEqual(vertical, actual.?.vertical);
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

    var expected = [_]?Marker{ null, null, null, null, null, null, null, null, null, null };
    expected[0] = .{ .color = red, .lane = .center, .vertical = .full };
    expected[4] = .{ .color = red, .lane = .center, .vertical = .full };
    expected[9] = .{ .color = red, .lane = .center, .vertical = .full };
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

    var expected = [_]?Marker{ null, null, null, null, null, null, null, null, null, null };
    // The projected top edge lands on the lower half of row 0.
    expected[0] = .{ .color = blue, .lane = .center, .vertical = .lower };
    expected[1] = .{ .color = blue, .lane = .center, .vertical = .full };
    try expectRows(rows, &expected);
}

test "decorationsOverviewRuler: half-cell projection splits a marker across rows" {
    const allocator = testing.allocator;
    const blue = [3]u8{ 0, 0, 255 };
    const decorations = [_]Decoration{
        .{ .start_line_number = 2, .end_line_number = 3, .color = blue },
    };

    // Four rows over seven lines puts the start on half-cell 1 and the end on
    // half-cell 3: the lower half of row 0 and the upper half of row 1.
    const rows = try render(allocator, &decorations, &.{}, .{
        .canvas_height = 4,
        .outer_height = 7,
    });
    defer allocator.free(rows);

    var expected = [_]?Marker{ null, null, null, null };
    expected[0] = .{ .color = blue, .lane = .center, .vertical = .lower };
    expected[1] = .{ .color = blue, .lane = .center, .vertical = .upper };
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

    var expected = [_]?Marker{ null, null, null, null, null, null, null, null, null, null };
    expected[1] = .{ .color = green, .lane = .center, .vertical = .full };
    try expectRows(rows, &expected);
}

test "decorationsOverviewRuler: higher z-index wins a shared half-row" {
    const allocator = testing.allocator;
    const red = [3]u8{ 255, 0, 0 };
    const blue = [3]u8{ 0, 0, 255 };
    const decorations = [_]Decoration{
        .{ .start_line_number = 10, .end_line_number = 40, .color = red, .z_index = 0 },
        .{ .start_line_number = 12, .end_line_number = 14, .color = blue, .z_index = 10 },
    };

    const rows = try render(allocator, &decorations, &.{}, .{
        .canvas_height = 10,
        .outer_height = 100,
    });
    defer allocator.free(rows);

    // Red covers row 0's lower half through row 3; blue starts on the same
    // lower half and wins the halves it overlaps.
    try expectMarker(rows[0], blue, .center, .lower);
    try expectMarker(rows[1], blue, .center, .upper);
    // Red is still visible further down.
    try expectMarker(rows[2], red, .center, .full);
    try expectMarker(rows[3], red, .center, .full);
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

    // The cursor tick occupies the half-cell at the scaled line offset.
    try expectMarker(rows[4], white, .full, .lower);
}

test "decorationsOverviewRuler: cursor lands on the upper half at the top" {
    const allocator = testing.allocator;
    const white = [3]u8{ 255, 255, 255 };
    const cursors = [_]Cursor{
        .{ .line_number = 1, .color = white },
    };

    const rows = try render(allocator, &.{}, &cursors, .{
        .canvas_height = 10,
        .outer_height = 100,
    });
    defer allocator.free(rows);

    try expectMarker(rows[0], white, .full, .upper);
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

    var expected = [_]?Marker{ null, null, null, null, null, null, null, null, null, null };
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

    try expectMarker(rows[0], red, .center, .full);
    var count: usize = 0;
    for (rows) |row| {
        if (row != null) count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}
