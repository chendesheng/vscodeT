// Port of `src/vs/editor/browser/viewParts/overviewRuler/decorationsOverviewRuler.ts`.
//
// Terminal adaptation: the canvas is a terminal ruler of cell rows. The
// upstream `y1`/`y2` projection is kept, but each row is split into upper and
// lower half-cells and the pixel coordinates are scaled to those halves, so a
// marker edge can sit on either half of a row. The paint boundary chooses a
// half block or quadrant glyph from the winning marker's lane and `vertical`.
// There is no alpha, border or canvas background; colors are supplied by the
// TUI and already composited. `MIN_DECORATION_HEIGHT` is one half-cell
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

const events = @import("../../../common/viewEvents.zig");
const ViewContext = @import("../../../common/viewModel/viewContext.zig").ViewContext;
const view_model = @import("../../../common/viewModel.zig");
const ViewPart = @import("../../view/viewPart.zig").ViewPart;
const rendering = @import("../../view/renderingContext.zig");
const overview_cursor_color = [3]u8{ 200, 200, 200 };
const overview_secondary_cursor_color = [3]u8{ 86, 70, 26 };

/// Upstream overview-ruler view part. The terminal scrollbar composites these
/// retained rows with its thumb during the document-part render pass.
pub const DecorationsOverviewRuler = struct {
    base: ViewPart = undefined,
    attached: bool = false,
    allocator: Allocator = undefined,
    height: usize = 0,
    render_error: ?anyerror = null,
    rows: []?Marker = &.{},
    decorations: []Decoration = &.{},
    cursors: []Cursor = &.{},
    needed: bool = true,

    pub fn attach(self: *DecorationsOverviewRuler, allocator: Allocator, context: *ViewContext) void {
        self.allocator = allocator;
        self.attached = true;
        self.base.initWithHandlerContext(context, self, .{
            .onCursorStateChanged = onCursor,
            .onDecorationsChanged = onDecorations,
            .onScrollChanged = onScroll,
            .onConfigurationChanged = onConfiguration,
            .onThemeChanged = onTheme,
            .onFlushed = onFlush,
            .onLineMappingChanged = onMapping,
            .onZonesChanged = onZones,
        }, prepareRender, renderPart);
    }

    pub fn deinit(self: *DecorationsOverviewRuler, allocator: Allocator) void {
        if (self.attached) self.base.deinit();
        allocator.free(self.rows);
        allocator.free(self.decorations);
        allocator.free(self.cursors);
    }

    fn require(ctx: *anyopaque) bool {
        const self: *DecorationsOverviewRuler = @ptrCast(@alignCast(ctx));
        self.needed = true;
        return true;
    }
    fn onCursor(_: *anyopaque, _: *const events.ViewCursorStateChangedEvent) bool {
        return true;
    }
    fn onDecorations(_: *anyopaque, event: *const events.ViewDecorationsChangedEvent) bool {
        return event.affectsOverviewRuler;
    }
    fn onScroll(ctx: *anyopaque, event: *const events.ViewScrollChangedEvent) bool {
        return event.scrollHeightChanged and require(ctx);
    }
    fn onConfiguration(ctx: *anyopaque, event: *const events.ViewConfigurationChangedEvent) bool {
        return (event.hasChanged(.layoutInfo) or event.hasChanged(.overviewRulerLanes)) and require(ctx);
    }
    fn onTheme(ctx: *anyopaque, _: *const events.ViewThemeChangedEvent) bool {
        return require(ctx);
    }
    fn onFlush(ctx: *anyopaque, _: *const events.ViewFlushedEvent) bool {
        return require(ctx);
    }
    fn onMapping(ctx: *anyopaque, _: *const events.ViewLineMappingChangedEvent) bool {
        return require(ctx);
    }
    fn onZones(ctx: *anyopaque, _: *const events.ViewZonesChangedEvent) bool {
        return require(ctx);
    }

    pub fn setHeight(self: *DecorationsOverviewRuler, height: usize) void {
        if (self.height == height) return;
        self.height = height;
        self.needed = true;
        self.base.handler.forceShouldRender();
    }

    fn prepareRender(_: *ViewPart, _: *rendering.RenderingContext) void {}

    fn renderPart(part: *ViewPart, ctx: *rendering.RestrictedRenderingContext) void {
        const self: *DecorationsOverviewRuler = @fieldParentPtr("base", part);
        self.renderOverview(ctx) catch |err| {
            self.render_error = err;
        };
    }

    fn renderOverview(self: *DecorationsOverviewRuler, ctx: *rendering.RestrictedRenderingContext) !void {
        if (self.height == 0) return;
        const model = self.base.context.view_model;
        const get = model.get_all_overview_ruler_decorations orelse return;
        const markers = try get(model.context, self.allocator);
        defer self.allocator.free(markers);
        const selections = ctx.viewportData.selections;
        const cursors = try self.allocator.alloc(Cursor, selections.len);
        defer self.allocator.free(cursors);
        for (selections, cursors, 0..) |selection, *cursor, index| {
            cursor.* = .{
                .line_number = selection.getPosition().lineNumber,
                .color = if (index == 0) overview_cursor_color else overview_secondary_cursor_color,
            };
        }
        std.mem.sort(Cursor, cursors, {}, cursorLessThan);
        try self.renderMarkers(self.allocator, markers, cursors, .{
            .canvas_height = self.height,
            .outer_height = @intFromFloat(ctx.scrollHeight),
        });
    }

    pub fn renderMarkers(self: *DecorationsOverviewRuler, allocator: Allocator, markers: []const Decoration, cursors: []const Cursor, settings: Settings) !void {
        if (self.needed or self.rows.len != settings.canvas_height or
            !sameItems(Decoration, self.decorations, markers) or !sameItems(Cursor, self.cursors, cursors))
        {
            const next_markers = try allocator.dupe(Decoration, markers);
            errdefer allocator.free(next_markers);
            const next_cursors = try allocator.dupe(Cursor, cursors);
            errdefer allocator.free(next_cursors);
            const rows = try renderSorted(allocator, markers, cursors, settings);
            allocator.free(self.rows);
            allocator.free(self.decorations);
            allocator.free(self.cursors);
            self.rows = rows;
            self.decorations = next_markers;
            self.cursors = next_cursors;
        }
        self.needed = false;
    }

    fn sameItems(comptime T: type, a: []const T, b: []const T) bool {
        if (a.len != b.len) return false;
        for (a, b) |left, right| if (!std.meta.eql(left, right)) return false;
        return true;
    }
};

pub const Lane = view_model.OverviewLane;

/// Vertical extent of a marker inside its terminal row. A marker edge can sit
/// on the upper or lower half of a row because the projection uses half-cells.
pub const Vertical = enum { full, upper, lower };

pub const Decoration = view_model.OverviewDecoration;

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
    /// Minimum decoration height in terminal half-cells. A single-line marker
    /// in a long document is one half-cell tall; upstream uses six device
    /// pixels, which is roughly half a cell too.
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
    const sorted = try allocator.dupe(Decoration, decorations);
    defer allocator.free(sorted);
    std.mem.sort(Decoration, sorted, {}, lessThan);

    return renderSorted(allocator, sorted, cursors, settings);
}

fn renderSorted(allocator: Allocator, sorted: []const Decoration, cursors: []const Cursor, settings: Settings) ![]?Marker {
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
    const min_height: f64 = @floatFromInt(@max(settings.min_decoration_height, 1));
    const leading_halves = @floor(min_height / 2);

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
            const trailing_halves = min_height - leading_halves;
            if (center < leading_halves) {
                center = leading_halves;
            } else if (center + trailing_halves > canvas_halves_f) {
                center = canvas_halves_f - trailing_halves;
            }
            y1 = center - leading_halves;
            y2 = y1 + min_height;
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
    // A one-line marker is one half-cell tall: the upper half when it projects
    // to an even half index and the lower half when it projects to an odd one.
    expected[0] = .{ .color = red, .lane = .center, .vertical = .upper };
    expected[4] = .{ .color = red, .lane = .center, .vertical = .lower };
    expected[9] = .{ .color = red, .lane = .center, .vertical = .lower };
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

    // Red covers row 0's lower half through row 3; blue lands on row 1's upper
    // half and wins the halves it overlaps.
    try expectMarker(rows[0], red, .center, .lower);
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

    try expectMarker(rows[0], red, .center, .upper);
    var count: usize = 0;
    for (rows) |row| {
        if (row != null) count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}
fn cursorLessThan(_: void, a: Cursor, b: Cursor) bool {
    return a.line_number < b.line_number;
}
