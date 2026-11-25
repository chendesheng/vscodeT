// Port of the portable state in
// `src/vs/workbench/contrib/mediaPreview/browser/imageViewer.ts`.
//
// The browser class also owns an `<img>`, scroll container, context menu,
// clipboard, pinch/zoom listeners and pixelation classes. The terminal port
// keeps the state and the geometry rules (fit, natural size, the predefined
// zoom levels, center-preserving zoom and scroll clamping) and leaves painting,
// input and status rendering to `src/vs/workbench/contrib/mediaPreview/browser/imagePreviewPane.zig`. Scroll offsets are
// terminal cells instead of CSS pixels; the scale itself still means "1 is the
// image's natural pixel size".
//
// Browser-only omissions, documented in README.md and docs/terminal-ui.md:
// `image-rendering: pixelated`, pinch gestures, clipboard copy, context menus,
// and DOM focus/modifier tracking.

const std = @import("std");

pub const MIN_SCALE: f64 = 0.1;
pub const MAX_SCALE: f64 = 20;

/// Upstream `ImageViewerScale`: a numeric zoom factor or fit-to-viewer.
pub const Scale = union(enum) {
    fit,
    number: f64,

    pub fn eql(a: Scale, b: Scale) bool {
        return switch (a) {
            .fit => b == .fit,
            .number => |value| switch (b) {
                .fit => false,
                .number => |other| value == other,
            },
        };
    }
};

pub const ViewState = struct {
    scale: Scale = .fit,
    /// Terminal cells scrolled from the image's top-left corner.
    scroll_left: usize = 0,
    scroll_top: usize = 0,
};

pub const PixelSize = struct {
    width: usize,
    height: usize,
};

pub const CellSize = struct {
    width_px: usize = 8,
    height_px: usize = 16,
};

pub const CellRect = struct {
    cols: usize,
    rows: usize,
};

/// The kitty row/column diacritic table has 297 entries, so a rendered image
/// grid cannot be addressed beyond this many cells on either axis.
pub const max_rendered_cells: usize = 297;

pub const zoom_levels = [_]f64{ 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1, 1.5, 2, 3, 5, 7, 10, 15, 20 };

/// Next predefined zoom level above `scale`, or `MAX_SCALE`.
pub fn getNextZoomLevel(scale: f64) f64 {
    for (zoom_levels) |level| {
        if (level > scale) return level;
    }
    return MAX_SCALE;
}

/// Previous predefined zoom level below `scale`, or `MIN_SCALE`.
pub fn getPreviousZoomLevel(scale: f64) f64 {
    var index = zoom_levels.len;
    while (index > 0) {
        index -= 1;
        if (zoom_levels[index] < scale) return zoom_levels[index];
    }
    return MIN_SCALE;
}

pub fn clampScale(scale: f64) f64 {
    return std.math.clamp(scale, MIN_SCALE, MAX_SCALE);
}

pub const ImageViewer = struct {
    scale: Scale = .fit,
    has_image: bool = false,
    natural: PixelSize = .{ .width = 0, .height = 0 },
    /// Scroll offset in cells for the current rendered size.
    scroll_left: usize = 0,
    scroll_top: usize = 0,

    pub fn setImage(self: *ImageViewer, natural: PixelSize) void {
        self.natural = natural;
        self.has_image = natural.width > 0 and natural.height > 0;
        self.scale = .fit;
        self.scroll_left = 0;
        self.scroll_top = 0;
    }

    pub fn clear(self: *ImageViewer) void {
        self.has_image = false;
        self.natural = .{ .width = 0, .height = 0 };
        self.scale = .fit;
        self.scroll_left = 0;
        self.scroll_top = 0;
    }

    pub fn naturalSize(self: *const ImageViewer) ?PixelSize {
        if (!self.has_image) return null;
        return self.natural;
    }

    /// The scale that fits the image in `viewport` without ever upscaling it.
    pub fn fitScale(self: *const ImageViewer, viewport: CellRect, cell: CellSize) f64 {
        if (!self.has_image) return 1;
        const viewport_width: f64 = @floatFromInt(viewport.cols *| cell.width_px);
        const viewport_height: f64 = @floatFromInt(viewport.rows *| cell.height_px);
        const image_width: f64 = @floatFromInt(self.natural.width);
        const image_height: f64 = @floatFromInt(self.natural.height);
        return @min(1, @min(viewport_width / image_width, viewport_height / image_height));
    }

    /// Cell grid used by the image's virtual placement.
    pub fn renderedCells(self: *const ImageViewer, viewport: CellRect, cell: CellSize) CellRect {
        if (!self.has_image) return .{ .cols = 0, .rows = 0 };
        const scale = switch (self.scale) {
            .fit => self.fitScale(viewport, cell),
            .number => |value| clampScale(value),
        };
        const width_px: f64 = @as(f64, @floatFromInt(self.natural.width)) * scale;
        const height_px: f64 = @as(f64, @floatFromInt(self.natural.height)) * scale;
        var cols: usize = @intFromFloat(@max(1, @ceil(width_px / @as(f64, @floatFromInt(cell.width_px)))));
        var rows: usize = @intFromFloat(@max(1, @ceil(height_px / @as(f64, @floatFromInt(cell.height_px)))));
        cols = @min(cols, max_rendered_cells);
        rows = @min(rows, max_rendered_cells);
        return .{ .cols = cols, .rows = rows };
    }

    /// Effective numeric scale of the current fit, mirroring upstream
    /// `_getNumericScale`.
    pub fn currentNumericScale(self: *const ImageViewer, viewport: CellRect, cell: CellSize) f64 {
        return switch (self.scale) {
            .number => |value| clampScale(value),
            .fit => blk: {
                if (!self.has_image) break :blk 1;
                const rendered = self.renderedCells(viewport, cell);
                const rendered_width: f64 = @floatFromInt(rendered.cols *| cell.width_px);
                const rendered_height: f64 = @floatFromInt(rendered.rows *| cell.height_px);
                const image_width: f64 = @floatFromInt(self.natural.width);
                const image_height: f64 = @floatFromInt(self.natural.height);
                break :blk if (rendered_width > 0) rendered_width / image_width else rendered_height / image_height;
            },
        };
    }

    pub fn zoomIn(self: *ImageViewer, viewport: CellRect, cell: CellSize) void {
        if (!self.has_image) return;
        const next = getNextZoomLevel(self.currentNumericScale(viewport, cell));
        self.zoomTo(.{ .number = next }, viewport, cell);
    }

    pub fn zoomOut(self: *ImageViewer, viewport: CellRect, cell: CellSize) void {
        if (!self.has_image) return;
        const previous = getPreviousZoomLevel(self.currentNumericScale(viewport, cell));
        self.zoomTo(.{ .number = previous }, viewport, cell);
    }

    /// Applies fit or a numeric zoom while preserving the visible center.
    pub fn zoomTo(self: *ImageViewer, new_scale: Scale, viewport: CellRect, cell: CellSize) void {
        if (!self.has_image) {
            self.scale = .fit;
            return;
        }
        const before = self.renderedCells(viewport, cell);
        const dx: f64 = if (before.cols > 0)
            (@as(f64, @floatFromInt(self.scroll_left)) + @as(f64, @floatFromInt(viewport.cols)) / 2) /
                @as(f64, @floatFromInt(before.cols))
        else
            0.5;
        const dy: f64 = if (before.rows > 0)
            (@as(f64, @floatFromInt(self.scroll_top)) + @as(f64, @floatFromInt(viewport.rows)) / 2) /
                @as(f64, @floatFromInt(before.rows))
        else
            0.5;

        self.scale = switch (new_scale) {
            .fit => .fit,
            .number => |value| .{ .number = clampScale(value) },
        };
        if (self.scale == .fit) {
            self.scroll_left = 0;
            self.scroll_top = 0;
            return;
        }

        const after = self.renderedCells(viewport, cell);
        const left = @as(f64, @floatFromInt(after.cols)) * dx - @as(f64, @floatFromInt(viewport.cols)) / 2;
        const top = @as(f64, @floatFromInt(after.rows)) * dy - @as(f64, @floatFromInt(viewport.rows)) / 2;
        self.scroll_left = if (left <= 0) 0 else @intFromFloat(@round(left));
        self.scroll_top = if (top <= 0) 0 else @intFromFloat(@round(top));
        self.clampScroll(viewport, cell);
    }

    pub fn setScale(self: *ImageViewer, scale: Scale, viewport: CellRect, cell: CellSize) void {
        self.zoomTo(scale, viewport, cell);
    }

    pub fn scrollBy(self: *ImageViewer, dx: i64, dy: i64, viewport: CellRect, cell: CellSize) void {
        if (!self.has_image or self.scale == .fit) return;
        self.scroll_left = addClamped(self.scroll_left, dx);
        self.scroll_top = addClamped(self.scroll_top, dy);
        self.clampScroll(viewport, cell);
    }

    pub fn clampScroll(self: *ImageViewer, viewport: CellRect, cell: CellSize) void {
        const rendered = self.renderedCells(viewport, cell);
        self.scroll_left = @min(self.scroll_left, rendered.cols -| viewport.cols);
        self.scroll_top = @min(self.scroll_top, rendered.rows -| viewport.rows);
    }

    pub fn getViewState(self: *const ImageViewer) ViewState {
        return .{ .scale = self.scale, .scroll_left = self.scroll_left, .scroll_top = self.scroll_top };
    }

    pub fn setViewState(self: *ImageViewer, state: ViewState, viewport: CellRect, cell: CellSize) void {
        self.zoomTo(state.scale, viewport, cell);
        if (state.scale != .fit) {
            self.scroll_left = state.scroll_left;
            self.scroll_top = state.scroll_top;
            self.clampScroll(viewport, cell);
        }
    }
};

fn addClamped(value: usize, delta: i64) usize {
    const base: i64 = @intCast(value);
    const result = base + delta;
    return if (result <= 0) 0 else @intCast(result);
}
