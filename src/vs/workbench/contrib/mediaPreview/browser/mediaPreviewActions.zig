// Port of the command metadata in
// `src/vs/workbench/contrib/mediaPreview/browser/mediaPreviewActions.ts`.
//
// The TUI registers these through the workbench command palette instead of
// upstream's `Action2`/context-key registry. `imagePreview.openInTextEditor`
// is the terminal counterpart of the upstream failed-load message button and
// `reopenInTextEditor`; `reopenAsPreview` is not needed because SVG opens in
// the text editor and raster images open in the preview.

pub const category = "Image Preview";

pub const zoom_in_id = "imagePreview.zoomIn";
pub const zoom_in_title = "Zoom In";

pub const zoom_out_id = "imagePreview.zoomOut";
pub const zoom_out_title = "Zoom Out";

pub const select_zoom_level_id = "imagePreview.selectZoomLevel";
pub const select_zoom_level_title = "Select Zoom Level";

pub const open_in_text_id = "imagePreview.openInTextEditor";
pub const open_in_text_title = "Open in Text Editor";

test "mediaPreviewActions: command ids match upstream" {
    try @import("std").testing.expectEqualStrings("imagePreview.zoomIn", zoom_in_id);
    try @import("std").testing.expectEqualStrings("imagePreview.zoomOut", zoom_out_id);
    try @import("std").testing.expectEqualStrings("imagePreview.selectZoomLevel", select_zoom_level_id);
}
