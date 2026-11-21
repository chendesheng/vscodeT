// Port of the portable cases in
// `src/vs/workbench/contrib/mediaPreview/test/browser/imagePreviewEditor.test.ts`.
//
// Upstream drives real `<img>`/canvas decoding and deferred file reads. The
// terminal controller is synchronous and takes a host boundary; these tests
// cover the same load/reload/LFS/failure outcomes with a fake host. The
// browser image watcher tests are represented by the workbench integration
// test in `src/vs/workbench/browser/workbench.zig`.

const std = @import("std");
const image_preview_editor = @import("../../browser/imagePreviewEditor.zig");
const mediaImage = @import("../../common/mediaImage.zig");
const viewer_mod = @import("../../browser/imageViewer.zig");
const Allocator = std.mem.Allocator;
const ImagePreviewEditor = image_preview_editor.ImagePreviewEditor;
const Host = image_preview_editor.Host;
const FileContent = image_preview_editor.FileContent;
const message_read_error = image_preview_editor.message_read_error;
const message_unsupported = image_preview_editor.message_unsupported;
const message_git_lfs = image_preview_editor.message_git_lfs;
const message_empty = image_preview_editor.message_empty;

const png_1x1 = [_]u8{
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
    0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
    0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
    0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xDD, 0x8D,
    0xB0, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
    0x44, 0xAE, 0x42, 0x60, 0x82,
};

const FakeHost = struct {
    contents: []const u8 = &png_1x1,
    read_error: bool = false,
    show_error: bool = false,
    reads: usize = 0,
    clears: usize = 0,
    shown_width: usize = 0,
    shown_height: usize = 0,

    fn read(context: *anyopaque, allocator: Allocator, _: []const u8) anyerror!FileContent {
        const self: *FakeHost = @ptrCast(@alignCast(context));
        self.reads += 1;
        if (self.read_error) return error.FileNotFound;
        const bytes = try allocator.dupe(u8, self.contents);
        return .{ .bytes = bytes, .size = bytes.len };
    }

    fn show(context: *anyopaque, decoded: mediaImage.Decoded) anyerror!void {
        const self: *FakeHost = @ptrCast(@alignCast(context));
        var owned = decoded;
        defer owned.deinit(std.testing.allocator);
        if (self.show_error) return error.WriteFailed;
        self.shown_width = owned.width;
        self.shown_height = owned.height;
    }

    fn clear(context: *anyopaque) void {
        const self: *FakeHost = @ptrCast(@alignCast(context));
        self.clears += 1;
    }

    fn host(self: *FakeHost) Host {
        return .{ .context = self, .read = read, .show = show, .clear = clear };
    }
};

fn createEditor(fake: *FakeHost) !*ImagePreviewEditor {
    return ImagePreviewEditor.init(std.testing.allocator, fake.host(), "image.png");
}

test "imagePreviewEditor: loads dimensions and file size" {
    var fake = FakeHost{};
    const editor = try createEditor(&fake);
    defer editor.deinit();
    try std.testing.expect(editor.hasImage());
    try std.testing.expectEqual(@as(usize, 1), editor.naturalSize().?.width);
    try std.testing.expectEqual(png_1x1.len, editor.file_size.?);
    try std.testing.expect(editor.message == null);
    try std.testing.expectEqual(@as(usize, 1), fake.shown_width);
}

test "imagePreviewEditor: reports read, format, LFS and empty failures" {
    var read_error = FakeHost{ .read_error = true };
    const unreadable = try createEditor(&read_error);
    defer unreadable.deinit();
    try std.testing.expectEqualStrings(message_read_error, unreadable.message.?);
    try std.testing.expect(!unreadable.hasImage());

    var svg = FakeHost{ .contents = "<svg></svg>" };
    const unsupported = try createEditor(&svg);
    defer unsupported.deinit();
    try std.testing.expectEqualStrings(message_unsupported, unsupported.message.?);

    var lfs = FakeHost{ .contents = "version https://git-lfs.github.com/spec/v1\noid sha256:00\nsize 1\n" };
    const pointer = try createEditor(&lfs);
    defer pointer.deinit();
    try std.testing.expectEqualStrings(message_git_lfs, pointer.message.?);

    var empty = FakeHost{ .contents = "" };
    const empty_editor = try createEditor(&empty);
    defer empty_editor.deinit();
    try std.testing.expectEqualStrings(message_empty, empty_editor.message.?);
}

test "imagePreviewEditor: reload preserves the view state for the view to apply" {
    var fake = FakeHost{};
    const editor = try createEditor(&fake);
    defer editor.deinit();
    const viewport = viewer_mod.CellRect{ .cols = 20, .rows = 10 };
    const cell = viewer_mod.CellSize{ .width_px = 8, .height_px = 16 };
    editor.setScale(.{ .number = 3 }, viewport, cell);

    editor.reload();
    try std.testing.expect(editor.pending_view_state != null);
    editor.applyPendingViewState(viewport, cell);
    try std.testing.expect(editor.viewer.scale.eql(.{ .number = 3 }));
    try std.testing.expectEqual(@as(usize, 2), fake.reads);
    try std.testing.expectEqual(@as(usize, 2), fake.clears);
}

test "imagePreviewEditor: a failed show leaves no image and reports a read error" {
    var fake = FakeHost{ .show_error = true };
    const editor = try createEditor(&fake);
    defer editor.deinit();
    try std.testing.expect(!editor.hasImage());
    try std.testing.expectEqualStrings(message_read_error, editor.message.?);
}
