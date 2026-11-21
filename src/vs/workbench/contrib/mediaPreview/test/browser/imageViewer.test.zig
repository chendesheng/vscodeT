// Port of the portable cases in
// `src/vs/workbench/contrib/mediaPreview/test/browser/imageViewer.test.ts`.
//
// The upstream suite also covers DOM image decoding, context menus, clipboard
// writes, pinch/wheel modifiers, focus tracking and pixelation classes. Those
// need a browser and are documented as ported omissions in README.md; the
// geometry, zoom-level, view-state and failed-load cases are below.

const std = @import("std");
const viewer = @import("../../browser/imageViewer.zig");
const ImageViewer = viewer.ImageViewer;
const CellRect = viewer.CellRect;
const CellSize = viewer.CellSize;
const getNextZoomLevel = viewer.getNextZoomLevel;
const getPreviousZoomLevel = viewer.getPreviousZoomLevel;

test "imageViewer: predefined zoom levels match VS Code" {
    const probes = [_]f64{ 0.05, 0.1, 0.95, 1, 2.5, 20, 25 };
    const expected_next = [_]f64{ 0.1, 0.2, 1, 1.5, 3, 20, 20 };
    const expected_previous = [_]f64{ 0.1, 0.1, 0.9, 0.9, 2, 15, 20 };
    for (probes, 0..) |probe, index| {
        try std.testing.expectEqual(expected_next[index], getNextZoomLevel(probe));
        try std.testing.expectEqual(expected_previous[index], getPreviousZoomLevel(probe));
    }
}

test "imageViewer: fit does not upscale and zooming steps from the fitted scale" {
    var model = ImageViewer{};
    model.setImage(.{ .width = 40, .height = 20 });
    const viewport = CellRect{ .cols = 40, .rows = 20 };
    const cell = CellSize{ .width_px = 10, .height_px = 20 };

    try std.testing.expectEqual(@as(f64, 1), model.fitScale(viewport, cell));
    model.zoomIn(viewport, cell);
    try std.testing.expect(model.scale.eql(.{ .number = 1.5 }));

    model.setScale(.{ .number = 5 }, viewport, cell);
    try std.testing.expect(model.scale.eql(.{ .number = 5 }));

    model.setScale(.fit, viewport, cell);
    try std.testing.expect(model.scale.eql(.fit));

    model.zoomOut(viewport, cell);
    try std.testing.expect(model.scale.eql(.{ .number = 0.9 }));
}

test "imageViewer: large images fit down and scroll is clamped" {
    var model = ImageViewer{};
    model.setImage(.{ .width = 1000, .height = 500 });
    const viewport = CellRect{ .cols = 50, .rows = 20 };
    const cell = CellSize{ .width_px = 10, .height_px = 20 };
    const rendered = model.renderedCells(viewport, cell);
    try std.testing.expect(rendered.cols <= viewport.cols);
    try std.testing.expect(rendered.rows <= viewport.rows);
    try std.testing.expect(model.fitScale(viewport, cell) < 1);

    model.setScale(.{ .number = 2 }, viewport, cell);
    model.scrollBy(100000, 100000, viewport, cell);
    const zoomed = model.renderedCells(viewport, cell);
    try std.testing.expectEqual(zoomed.cols -| viewport.cols, model.scroll_left);
    try std.testing.expectEqual(zoomed.rows -| viewport.rows, model.scroll_top);
}

test "imageViewer: view state restores the zoom and scroll" {
    var model = ImageViewer{};
    model.setImage(.{ .width = 40, .height = 20 });
    const viewport = CellRect{ .cols = 20, .rows = 10 };
    const cell = CellSize{ .width_px = 8, .height_px = 16 };
    model.setScale(.{ .number = 3 }, viewport, cell);
    const state = model.getViewState();

    model.setImage(.{ .width = 40, .height = 20 });
    try std.testing.expect(model.scale.eql(.fit));
    model.setViewState(state, viewport, cell);
    try std.testing.expect(model.scale.eql(.{ .number = 3 }));
}

test "imageViewer: an image that failed to load does not zoom" {
    var model = ImageViewer{};
    const viewport = CellRect{ .cols = 20, .rows = 10 };
    const cell = CellSize{ .width_px = 8, .height_px = 16 };
    model.zoomIn(viewport, cell);
    model.setScale(.{ .number = 5 }, viewport, cell);
    try std.testing.expect(model.scale.eql(.fit));
    try std.testing.expect(!model.has_image);
}

test "imageViewer: rendered grids stay within the placeholder table" {
    var model = ImageViewer{};
    model.setImage(.{ .width = 20000, .height = 10000 });
    const viewport = CellRect{ .cols = 80, .rows = 24 };
    const cell = CellSize{ .width_px = 8, .height_px = 16 };
    model.setScale(.{ .number = 20 }, viewport, cell);
    const rendered = model.renderedCells(viewport, cell);
    try std.testing.expect(rendered.cols <= viewer.max_rendered_cells);
    try std.testing.expect(rendered.rows <= viewer.max_rendered_cells);
}
