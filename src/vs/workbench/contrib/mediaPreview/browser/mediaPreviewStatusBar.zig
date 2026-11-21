// Port of `src/vs/workbench/contrib/mediaPreview/browser/mediaPreviewStatusBar.ts`.
//
// Upstream contributes three right-aligned status entries (zoom, dimensions,
// file size) and updates them when the active media preview changes. The
// terminal controller keeps that shape and adds/disposes the same entries; the
// workbench calls `update` from `refreshStatus` instead of the browser's
// `onDidChangeActiveEditor` event.

const std = @import("std");
const Allocator = std.mem.Allocator;

const statusbar_part = @import("../../../browser/parts/statusbar/statusbarPart.zig");
const statusbar = @import("../../../services/statusbar/browser/statusbar.zig");
const viewer_mod = @import("imageViewer.zig");
const files = @import("../../../../platform/files/common/files.zig");

const StatusbarService = statusbar_part.StatusbarService;
const EntryAccessor = statusbar_part.EntryAccessor;
const StatusbarEntry = statusbar.StatusbarEntry;

pub const SELECT_IMAGE_ZOOM_LEVEL_COMMAND_ID = "imagePreview.selectZoomLevel";

pub const ZoomLabel = struct {
    buffer: [32]u8 = undefined,

    pub fn format(self: *ZoomLabel, scale: viewer_mod.Scale) []const u8 {
        return switch (scale) {
            .fit => "Whole Image",
            .number => |value| std.fmt.bufPrint(&self.buffer, "{d}%", .{@as(i64, @intFromFloat(@round(value * 100)))}) catch "100%",
        };
    }
};

pub const Info = struct {
    scale: ?viewer_mod.Scale = null,
    dimensions: ?viewer_mod.PixelSize = null,
    file_size: ?usize = null,
};

pub const MediaPreviewStatus = struct {
    allocator: Allocator,
    statusbar: *StatusbarService,
    zoom: ?EntryAccessor = null,
    dimensions: ?EntryAccessor = null,
    file_size: ?EntryAccessor = null,
    zoom_label: ZoomLabel = .{},
    dimensions_buffer: [32]u8 = undefined,
    size_buffer: [32]u8 = undefined,
    last: Info = .{},

    pub fn init(allocator: Allocator, service: *StatusbarService) !*MediaPreviewStatus {
        const self = try allocator.create(MediaPreviewStatus);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .statusbar = service };

        self.zoom = try service.addEntry(.{
            .name = "Image Zoom",
            .text = "",
            .tooltip = "Select Zoom Level",
            .command = .{ .id = SELECT_IMAGE_ZOOM_LEVEL_COMMAND_ID },
        }, "status.imagePreview.zoom", .right, .{ .number = 102 });
        errdefer if (self.zoom) |entry| entry.dispose();

        self.dimensions = try service.addEntry(.{
            .name = "Image Dimensions",
            .text = "",
        }, "status.imagePreview.dimensions", .right, .{ .number = 101 });
        errdefer if (self.dimensions) |entry| entry.dispose();

        self.file_size = try service.addEntry(.{
            .name = "Media File Size",
            .text = "",
        }, "status.mediaPreview.fileSize", .right, .{ .number = 100 });
        return self;
    }

    pub fn deinit(self: *MediaPreviewStatus) void {
        if (self.file_size) |entry| entry.dispose();
        if (self.dimensions) |entry| entry.dispose();
        if (self.zoom) |entry| entry.dispose();
        self.allocator.destroy(self);
    }

    pub fn update(self: *MediaPreviewStatus, info: ?Info) void {
        const value = info orelse Info{};
        const zoom_text = if (value.scale) |scale| self.zoom_label.format(scale) else "";
        const dimensions_text = if (value.dimensions) |size|
            std.fmt.bufPrint(&self.dimensions_buffer, "{d}x{d}", .{ size.width, size.height }) catch ""
        else
            "";
        const size_text = if (value.file_size) |size|
            files.ByteSize.formatSize(&self.size_buffer, size)
        else
            "";

        if (self.zoom) |entry| {
            if (zoom_text.len == 0) {
                entry.update(.{ .name = "", .text = "" });
            } else {
                entry.update(.{
                    .name = "Image Zoom",
                    .text = zoom_text,
                    .aria_label = zoom_text,
                    .tooltip = "Select Zoom Level",
                    .command = .{ .id = SELECT_IMAGE_ZOOM_LEVEL_COMMAND_ID },
                });
            }
        }
        if (self.dimensions) |entry| {
            entry.update(.{
                .name = if (dimensions_text.len > 0) "Image Dimensions" else "",
                .text = dimensions_text,
                .aria_label = dimensions_text,
            });
        }
        if (self.file_size) |entry| {
            entry.update(.{
                .name = if (size_text.len > 0) "Media File Size" else "",
                .text = size_text,
                .aria_label = size_text,
            });
        }
        self.last = value;
    }
};

test "mediaPreviewStatusBar: labels match VS Code" {
    var label = ZoomLabel{};
    try std.testing.expectEqualStrings("Whole Image", label.format(.fit));
    try std.testing.expectEqualStrings("100%", label.format(.{ .number = 1 }));
    try std.testing.expectEqualStrings("150%", label.format(.{ .number = 1.5 }));
    try std.testing.expectEqualStrings("10%", label.format(.{ .number = 0.1 }));
}
