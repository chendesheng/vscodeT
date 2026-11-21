//! One decoded image owned by a terminal view.
//!
//! A `TerminalImage` allocates a kitty image id, transmits the encoded payload
//! lazily, and keeps the virtual placement in sync with the cell rectangle the
//! view can show. The payload is retained so a resize (which clears the screen)
//! can re-upload it without touching the file again.
//!
//! Each view owns its own `TerminalImage`s. That keeps image ids and virtual
//! placements unambiguous when the same file is shown at different sizes in the
//! Markdown preview and the image preview pane.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ui = @import("ui");
const mediaImage = @import("../vs/workbench/contrib/mediaPreview/common/mediaImage.zig");

pub const TerminalImage = struct {
    allocator: Allocator,
    runtime: *ui.image.Runtime,
    id: u32,
    placement_id: u32,
    width_px: usize,
    height_px: usize,
    payload: mediaImage.Payload,
    uploaded: bool = false,
    placed_cols: usize = 0,
    placed_rows: usize = 0,
    has_placement: bool = false,

    pub fn init(
        allocator: Allocator,
        runtime: *ui.image.Runtime,
        decoded: mediaImage.Decoded,
    ) !*TerminalImage {
        const self = try allocator.create(TerminalImage);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .runtime = runtime,
            .id = runtime.allocId(),
            .placement_id = runtime.allocId(),
            .width_px = decoded.width,
            .height_px = decoded.height,
            .payload = decoded.payload,
        };
        return self;
    }

    pub fn deinit(self: *TerminalImage) void {
        if (self.has_placement) {
            self.runtime.removePlacement(self.id, self.placement_id) catch {};
        }
        self.runtime.deleteImage(self.id) catch {};
        switch (self.payload) {
            .png => |value| self.allocator.free(value),
            .rgba => |value| self.allocator.free(value),
        }
        self.allocator.destroy(self);
    }

    /// Uploads the pixels once. A protocol change after creation uploads them on
    /// the first placement attempt.
    pub fn upload(self: *TerminalImage) !void {
        if (self.uploaded or !self.runtime.enabled()) return;
        switch (self.payload) {
            .png => |value| try self.runtime.transmitPng(self.id, value),
            .rgba => |value| try self.runtime.transmitRgba(self.id, self.width_px, self.height_px, value),
        }
        self.uploaded = true;
    }

    /// Ensures the virtual placement matches the requested cell grid.
    pub fn ensurePlacement(self: *TerminalImage, cols: usize, rows: usize) !void {
        if (!self.runtime.enabled()) return;
        const wanted_cols = std.math.clamp(cols, 1, ui.image.max_grid_index + 1);
        const wanted_rows = std.math.clamp(rows, 1, ui.image.max_grid_index + 1);
        if (self.has_placement and self.placed_cols == wanted_cols and self.placed_rows == wanted_rows) return;

        try self.upload();
        if (self.has_placement) try self.runtime.removePlacement(self.id, self.placement_id);
        try self.runtime.placeVirtual(self.id, self.placement_id, wanted_cols, wanted_rows);
        self.has_placement = true;
        self.placed_cols = wanted_cols;
        self.placed_rows = wanted_rows;
    }

    /// Drops the terminal-side placement and image data while keeping the
    /// decoded payload, so a later `ensurePlacement` re-uploads it (used after
    /// the terminal was cleared or resized).
    pub fn invalidate(self: *TerminalImage) void {
        if (self.has_placement) {
            self.runtime.removePlacement(self.id, self.placement_id) catch {};
        }
        self.runtime.deleteImage(self.id) catch {};
        self.has_placement = false;
        self.uploaded = false;
        self.placed_cols = 0;
        self.placed_rows = 0;
    }
};

test "terminalImage: uploads once and re-places on size changes" {
    const allocator = std.testing.allocator;
    var runtime = ui.image.Runtime.init(allocator);
    defer runtime.deinit();
    runtime.setProtocol(.unicode_placeholders);

    const png = try allocator.dupe(u8, "png-bytes");
    var decoded = mediaImage.Decoded{
        .width = 20,
        .height = 10,
        .payload = .{ .png = png },
    };
    // Ownership moves into the terminal image.
    const image = try TerminalImage.init(allocator, &runtime, decoded);
    decoded = undefined;
    defer image.deinit();

    try image.ensurePlacement(4, 2);
    try image.ensurePlacement(4, 2);
    try image.ensurePlacement(8, 4);

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try runtime.flush(&output.writer);
    const text = output.written();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "a=t,f=100"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "a=p,U=1,i="));
    try std.testing.expect(std.mem.indexOf(u8, text, "c=4,r=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "c=8,r=4") != null);

    image.invalidate();
    try image.ensurePlacement(8, 4);
    output.clearRetainingCapacity();
    try runtime.flush(&output.writer);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output.written(), "a=t,f=100"));
}

test "terminalImage: sizes are capped at the diacritic table" {
    const allocator = std.testing.allocator;
    var runtime = ui.image.Runtime.init(allocator);
    defer runtime.deinit();
    runtime.setProtocol(.unicode_placeholders);

    var decoded = mediaImage.Decoded{
        .width = 1,
        .height = 1,
        .payload = .{ .png = try allocator.dupe(u8, "x") },
    };
    const image = try TerminalImage.init(allocator, &runtime, decoded);
    decoded = undefined;
    defer image.deinit();
    try image.ensurePlacement(1000, 1000);
    try std.testing.expectEqual(ui.image.max_grid_index + 1, image.placed_cols);
    try std.testing.expectEqual(ui.image.max_grid_index + 1, image.placed_rows);
}
