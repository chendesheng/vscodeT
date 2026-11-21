// Port of the image cases in
// `src/vs/workbench/contrib/mediaPreview/test/browser/mediaPreviewEditorInputs.test.ts`.
//
// The upstream suite also covers the audio/video `MediaPlayerEditorInput`,
// webview rendering and file-dialog "Save As"; those subsystems are not ported
// (the terminal has no media playback or file dialog).

const std = @import("std");
const media_preview = @import("../../common/mediaPreview.zig");
const input_mod = @import("../../browser/imagePreviewEditorInput.zig");
const ImagePreviewEditorInput = input_mod.ImagePreviewEditorInput;
const ImagePreviewEditorInputSerializer = input_mod.ImagePreviewEditorInputSerializer;

test "imagePreviewEditorInput: read-only path identity and serialization" {
    const allocator = std.testing.allocator;
    const input = try ImagePreviewEditorInput.init(allocator, "/images/logo.png");
    defer input.deinit();
    const same = try ImagePreviewEditorInput.init(allocator, "/images/logo.png");
    defer same.deinit();
    const other = try ImagePreviewEditorInput.init(allocator, "/images/other.png");
    defer other.deinit();

    try std.testing.expectEqualStrings("workbench.input.imagePreview", input.base.type_id);
    try std.testing.expectEqualStrings(media_preview.IMAGE_PREVIEW_EDITOR_ID, input.base.editor_id.?);
    try std.testing.expectEqualStrings("logo.png", input.base.getName());
    try std.testing.expect(input.base.isReadonly());
    try std.testing.expect(input.base.matches(.{ .input = &same.base }));
    try std.testing.expect(!input.base.matches(.{ .input = &other.base }));
    try std.testing.expect(input.base.matches(.{ .untyped = .{
        .resource = "/images/logo.png",
        .editor_id = media_preview.IMAGE_PREVIEW_EDITOR_ID,
    } }));
    try std.testing.expect(!input.base.matches(.{ .untyped = .{
        .resource = "/images/logo.png",
        .editor_id = "default",
    } }));

    var serializer = ImagePreviewEditorInputSerializer.init(allocator);
    const interface = serializer.interface();
    const serialized = (try interface.serialize(interface.context, &input.base, allocator)).?;
    defer allocator.free(@constCast(serialized));
    try std.testing.expectEqualStrings("/images/logo.png", serialized);
    const restored = (try interface.deserialize(interface.context, serialized)).?;
    const restored_input: *ImagePreviewEditorInput = @ptrCast(@alignCast(restored.impl.?));
    defer restored_input.deinit();
    try std.testing.expectEqualStrings("/images/logo.png", restored_input.base.resource.?);
}
