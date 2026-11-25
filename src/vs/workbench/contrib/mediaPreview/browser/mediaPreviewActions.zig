// Port of the command metadata in
// `src/vs/workbench/contrib/mediaPreview/browser/mediaPreviewActions.ts`.
//
// Zoom actions resolve the active editor and quick input through Action2.
// Their previous terminal palette availability is retained until the upstream
// ActiveImagePreviewContext is ported completely. `imagePreview.openInTextEditor`
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

const std = @import("std");
const actions = @import("../../../../platform/actions/common/actions.zig");
const ServicesAccessor = @import("../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const editor_service = @import("../../../services/editor/common/editorService.zig");
const quick_input = @import("../../../../platform/quickinput/common/quickInput.zig");
const media = @import("../common/mediaPreview.zig");
const ImagePreviewPane = @import("imagePreviewPane.zig").ImagePreviewPane;

/// Upstream getImageViewer uses the focused viewer, then the active inner pane.
/// The terminal has no image diff or nested image control yet.
fn getImageViewer(editors: editor_service.IEditorService) ?*ImagePreviewPane {
    const pane = editors.activeEditorPane() orelse return null;
    if (!std.mem.eql(u8, pane.getId(), media.IMAGE_PREVIEW_EDITOR_ID)) return null;
    return @ptrCast(@alignCast(pane.getControl() orelse return null));
}

fn zoomIn(_: *anyopaque, accessor: ServicesAccessor) anyerror!void {
    if (getImageViewer((try accessor.get(editor_service.editor_service_id)).*)) |viewer| viewer.zoomIn();
}

fn zoomOut(_: *anyopaque, accessor: ServicesAccessor) anyerror!void {
    if (getImageViewer((try accessor.get(editor_service.editor_service_id)).*)) |viewer| viewer.zoomOut();
}

const zoom_items = [_]quick_input.QuickPickItem{
    .{ .item = .{ .id = "10", .label = "1000%" } },
    .{ .item = .{ .id = "5", .label = "500%" } },
    .{ .item = .{ .id = "2", .label = "200%" } },
    .{ .item = .{ .id = "1", .label = "100%" } },
    .{ .item = .{ .id = "0.5", .label = "50%" } },
    .{ .item = .{ .id = "0.2", .label = "20%" } },
    .{ .item = .{ .id = "fit", .label = "Whole Image" } },
};

fn selectZoomLevel(_: *anyopaque, accessor: ServicesAccessor) anyerror!void {
    const editors = try accessor.get(editor_service.editor_service_id);
    const viewer = getImageViewer(editors.*) orelse return;
    const active_id = switch (viewer.currentScale()) {
        .fit => "fit",
        .number => |value| blk: {
            for (zoom_items[0 .. zoom_items.len - 1]) |entry| {
                if (value == (std.fmt.parseFloat(f64, entry.item.id) catch continue)) break :blk entry.item.id;
            }
            break :blk "";
        },
    };
    const input = try accessor.get(quick_input.quick_input_service_id);
    try input.pick(&zoom_items, .{ .placeholder = "Select zoom level", .active_id = if (active_id.len > 0) active_id else null }, onZoomLevelAccepted, editors);
}

fn onZoomLevelAccepted(context: *anyopaque, result: ?*const quick_input.Item) anyerror!void {
    const item = result orelse return;
    const editors: *editor_service.IEditorService = @ptrCast(@alignCast(context));
    const viewer = getImageViewer(editors.*) orelse return;
    if (std.mem.eql(u8, item.id, "fit")) {
        viewer.setScale(.fit);
    } else {
        const value = std.fmt.parseFloat(f64, item.id) catch return;
        viewer.setScale(.{ .number = value });
    }
}

pub const zoom_actions = [_]actions.Action2{
    .{ .command = .{ .id = zoom_in_id, .title = zoom_in_title, .category = category }, .f1 = true, .context = @constCast(&{}), .run_fn = zoomIn },
    .{ .command = .{ .id = zoom_out_id, .title = zoom_out_title, .category = category }, .f1 = true, .context = @constCast(&{}), .run_fn = zoomOut },
    .{ .command = .{ .id = select_zoom_level_id, .title = select_zoom_level_title, .category = category }, .f1 = true, .context = @constCast(&{}), .run_fn = selectZoomLevel },
};
