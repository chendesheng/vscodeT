//! Terminal image preview pane.
//!
//! The browser view (`imageViewer.ts` + `imagePreviewEditor.ts` + their CSS) is
//! replaced by a `ui.Surface` for the message/background chrome and by kitty
//! Unicode placeholder cells for the image itself. The portable state and
//! load/reload controller live in
//! `src/vs/workbench/contrib/mediaPreview/browser/`; this file owns painting,
//! hit testing, scroll/zoom input and the terminal image handle.
//!
//! Async terminal adaptation: `initAsync` starts the read/decode on the
//! window worker pool. Completion applies the result and uploads the terminal
//! image on the TUI thread. The synchronous `init`/`reload` path remains for
//! startup and tests.
//!
//! A decoded image is placed as a `cols x rows` virtual grid. When it is larger
//! than the pane, only the visible sub-rect is written: the placeholder's
//! row/column indices address the full virtual grid, so clipping and scrolling
//! stay pixel-correct without re-uploading the image.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const ui = @import("ui");
const theme_colors_mod = @import("../vs/workbench/browser/themeColors.zig");
const media_preview = @import("../vs/workbench/contrib/mediaPreview/common/mediaPreview.zig");
const mediaImage = @import("../vs/workbench/contrib/mediaPreview/common/mediaImage.zig");
const image_preview_editor = @import("../vs/workbench/contrib/mediaPreview/browser/imagePreviewEditor.zig");
const viewer_mod = @import("../vs/workbench/contrib/mediaPreview/browser/imageViewer.zig");
const media_status = @import("../vs/workbench/contrib/mediaPreview/browser/mediaPreviewStatusBar.zig");
const TerminalImage = @import("./terminalImage.zig").TerminalImage;
const cellMetrics = @import("./cellMetrics.zig");

const ImagePreviewEditor = image_preview_editor.ImagePreviewEditor;
const ImageViewer = viewer_mod.ImageViewer;

pub const message_graphics_unsupported =
    "Image preview needs a terminal with kitty graphics support (kitty or Ghostty).";

const fallback_background = ui.Color{ .r = 30, .g = 30, .b = 33 };
const fallback_foreground = ui.Color{ .r = 204, .g = 204, .b = 204 };
const fallback_button_background = ui.Color{ .r = 0, .g = 122, .b = 204 };
const fallback_button_foreground = ui.Color{ .r = 255, .g = 255, .b = 255 };
const fallback_button_border = ui.Color{ .r = 70, .g = 70, .b = 70 };

/// What the pane wants the workbench to do after an input event.
pub const Action = enum { none, changed, open_text };

const dispatch = @import("../vs/base/common/windowDispatch.zig");
const ImageLoadJob = struct {
    pane: *ImagePreviewPane,
    future: Io.Future(image_preview_editor.LoadedImage),
    completion: dispatch.Task,
    load_id: u32,
    path: []u8,
};

fn runImageLoad(job: *ImageLoadJob) image_preview_editor.LoadedImage {
    defer job.completion.post();
    return ImagePreviewEditor.loadContent(job.pane.allocator, job.pane.window.?.io, job.path);
}

pub const ImagePreviewPane = struct {
    allocator: Allocator,
    io: Io,
    /// Io used for interactive/reload loads. Null keeps the synchronous
    /// host-read path used by startup and tests.
    window: ?*dispatch.Queue = null,
    load_job: ?*ImageLoadJob = null,
    runtime: *ui.image.Runtime,
    editor: *ImagePreviewEditor,
    terminal_image: ?*TerminalImage = null,
    surface: ?ui.Surface = null,
    width: usize = 0,
    height: usize = 0,
    dirty: bool = true,
    focused: bool = false,
    button_node: ?*ui.Node = null,
    theme: ?*const theme_colors_mod.ThemeColors = null,
    background: u32 = 0,

    pub fn init(
        allocator: Allocator,
        io: Io,
        runtime: *ui.image.Runtime,
        path: []const u8,
    ) !*ImagePreviewPane {
        const self = try allocator.create(ImagePreviewPane);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .io = io, .runtime = runtime, .editor = undefined };
        self.editor = try ImagePreviewEditor.init(allocator, .{
            .context = self,
            .read = hostRead,
            .show = hostShow,
            .clear = hostClear,
        }, path);
        return self;
    }

    /// Creates a pane whose image is read and decoded on `async_io` instead of
    /// on the TUI thread. The placeholder is rendered until the window applies the
    /// result.
    pub fn initAsync(
        allocator: Allocator,
        io: Io,
        window: *dispatch.Queue,
        runtime: *ui.image.Runtime,
        path: []const u8,
    ) !*ImagePreviewPane {
        const self = try allocator.create(ImagePreviewPane);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .io = io, .window = window, .runtime = runtime, .editor = undefined };
        self.editor = try ImagePreviewEditor.initDeferred(allocator, .{
            .context = self,
            .read = hostRead,
            .show = hostShow,
            .clear = hostClear,
        }, path);
        self.requestLoad(false);
        return self;
    }

    pub fn deinit(self: *ImagePreviewPane) void {
        self.cancelLoad();
        self.editor.deinit();
        if (self.surface) |*surface| surface.deinit();
        self.allocator.destroy(self);
    }

    pub fn hasPendingLoad(self: *const ImagePreviewPane) bool {
        return self.load_job != null;
    }

    /// Starts an async load (or falls back to the synchronous path when the
    /// pane has no async Io). Stale results are discarded by load id.
    pub fn requestLoad(self: *ImagePreviewPane, preserve_view_state: bool) void {
        const window = self.window orelse {
            if (preserve_view_state) self.editor.reload() else self.editor.load(false);
            self.dirty = true;
            return;
        };
        self.cancelLoad();
        const load_id = self.editor.beginLoad(preserve_view_state);
        const path = self.allocator.dupe(u8, self.editor.path) catch return;
        const job = self.allocator.create(ImageLoadJob) catch {
            self.allocator.free(path);
            return;
        };
        job.* = .{ .pane = self, .completion = .{ .queue = window, .context = self, .run = applyLoaded, .progress = true }, .future = undefined, .load_id = load_id, .path = path };
        job.future = window.io.async(runImageLoad, .{job});
        self.load_job = job;
        self.editor.message = image_preview_editor.message_loading;
        self.fileSizeChanged();
    }

    /// Drains a completed async load on the TUI thread. Returns true when the
    /// pane changed and needs a repaint.
    fn applyLoaded(context: *anyopaque, _: i64, _: bool) bool {
        const self: *ImagePreviewPane = @ptrCast(@alignCast(context));
        const job = self.load_job.?;
        const async_io = self.window.?.io;
        const loaded = job.future.await(async_io);
        self.load_job = null;
        const load_id = job.load_id;
        self.allocator.free(job.path);
        self.allocator.destroy(job);
        self.editor.applyLoaded(load_id, loaded);
        self.dirty = true;
        return true;
    }

    fn fileSizeChanged(self: *ImagePreviewPane) void {
        self.dirty = true;
    }

    pub fn cancelLoad(self: *ImagePreviewPane) void {
        const job = self.load_job orelse return;
        self.load_job = null;
        const async_io = self.window.?.io;
        const loaded = job.future.cancel(async_io);
        job.completion.schedule(null);
        if (loaded == .image) {
            var decoded = loaded.image.decoded;
            decoded.deinit(self.allocator);
        }
        self.allocator.free(job.path);
        self.allocator.destroy(job);
        self.dirty = true;
    }

    pub fn setThemeColors(self: *ImagePreviewPane, palette: ?*const theme_colors_mod.ThemeColors) void {
        self.theme = palette;
        self.dirty = true;
    }

    pub fn setFocused(self: *ImagePreviewPane, focused: bool) void {
        self.focused = focused;
    }

    pub fn layout(self: *ImagePreviewPane, width: usize, height: usize) !void {
        if (width == 0 or height == 0) {
            if (self.surface) |*surface| {
                surface.deinit();
                self.surface = null;
            }
            self.width = width;
            self.height = height;
            self.dirty = true;
            return;
        }
        if (self.width == width and self.height == height and self.surface != null) return;
        self.width = width;
        self.height = height;
        if (self.surface) |*surface| {
            try surface.resize(width, height);
        } else {
            self.surface = try ui.Surface.init(self.allocator, .{
                .cols = width,
                .rows = height,
                .tab_size = 4,
                .measure_width = cellMetrics.measureCodepoint,
            });
        }
        // A resize can clear the terminal, including image data and virtual
        // placements. Re-upload and re-place on the next paint.
        if (self.terminal_image) |image| image.invalidate();
        self.dirty = true;
    }

    pub fn reload(self: *ImagePreviewPane) void {
        if (self.window != null) {
            self.requestLoad(true);
            return;
        }
        self.editor.reload();
        self.dirty = true;
    }

    /// Drops the terminal-side image data and placement while keeping the
    /// decoded payload; the next paint re-uploads it. Used after a protocol or
    /// terminal-size change cleared the screen.
    pub fn invalidateImage(self: *ImagePreviewPane) void {
        if (self.terminal_image) |image| image.invalidate();
        self.dirty = true;
    }

    pub fn zoomIn(self: *ImagePreviewPane) void {
        const viewport = viewer_mod.CellRect{ .cols = self.width, .rows = self.height };
        self.editor.zoomIn(viewport, self.cellSize());
        self.dirty = true;
    }

    pub fn zoomOut(self: *ImagePreviewPane) void {
        const viewport = viewer_mod.CellRect{ .cols = self.width, .rows = self.height };
        self.editor.zoomOut(viewport, self.cellSize());
        self.dirty = true;
    }

    pub fn setScale(self: *ImagePreviewPane, scale: viewer_mod.Scale) void {
        const viewport = viewer_mod.CellRect{ .cols = self.width, .rows = self.height };
        self.editor.setScale(scale, viewport, self.cellSize());
        self.dirty = true;
    }

    pub fn currentScale(self: *const ImagePreviewPane) viewer_mod.Scale {
        return self.editor.viewer.scale;
    }

    pub fn statusInfo(self: *const ImagePreviewPane) media_status.Info {
        if (self.editor.hasImage()) {
            return .{
                .scale = self.editor.viewer.scale,
                .dimensions = self.editor.naturalSize(),
                .file_size = self.editor.file_size,
            };
        }
        return .{ .file_size = self.editor.file_size };
    }

    pub fn paint(self: *ImagePreviewPane, frame: *ui.Frame, x: usize, y: usize, w: usize, h: usize) !void {
        if (w == 0 or h == 0) return;
        if (self.width != w or self.height != h or self.surface == null) try self.layout(w, h);
        if (self.dirty) try self.buildNodes();
        const surface = &(self.surface orelse return);
        try surface.paintFrame();

        if (self.imageVisible()) {
            const viewport = viewer_mod.CellRect{ .cols = w, .rows = h };
            const cell = self.cellSize();
            self.editor.applyPendingViewState(viewport, cell);
            try self.paintPlaceholders(surface.presentedGrid(), w, h, viewport, cell);
        }

        try ui.CellGrid.blit(&frame.next, surface.grid(), x, y, w, h);
    }

    /// The pointer shape under a pane-relative cell. The message area keeps
    /// the terminal default; the "Open in Text Editor" button is clickable.
    pub fn pointerAt(self: *ImagePreviewPane, x: usize, y: usize) !?ui.Pointer {
        if (self.dirty) try self.buildNodes();
        const surface = &(self.surface orelse return null);
        return surface.pointerAt(x, y);
    }

    fn imageVisible(self: *const ImagePreviewPane) bool {
        return self.runtime.enabled() and self.editor.hasImage() and self.terminal_image != null;
    }

    fn cellSize(self: *const ImagePreviewPane) viewer_mod.CellSize {
        return .{
            .width_px = @max(self.runtime.cell_width_px, 1),
            .height_px = @max(self.runtime.cell_height_px, 1),
        };
    }

    fn paintPlaceholders(
        self: *ImagePreviewPane,
        grid: *ui.CellGrid,
        width: usize,
        height: usize,
        viewport: viewer_mod.CellRect,
        cell: viewer_mod.CellSize,
    ) !void {
        const image = self.terminal_image orelse return;
        const rendered = self.editor.viewer.renderedCells(viewport, cell);
        if (rendered.cols == 0 or rendered.rows == 0) return;
        try image.ensurePlacement(rendered.cols, rendered.rows);

        const centered_x = rendered.cols <= width;
        const centered_y = rendered.rows <= height;
        const origin_x = if (centered_x) (width - rendered.cols) / 2 else 0;
        const origin_y = if (centered_y) (height - rendered.rows) / 2 else 0;
        const scroll_left = if (centered_x) 0 else self.editor.viewer.scroll_left;
        const scroll_top = if (centered_y) 0 else self.editor.viewer.scroll_top;

        var row: usize = 0;
        while (row < height) : (row += 1) {
            if (centered_y and row < origin_y) continue;
            const image_row = if (centered_y) row - origin_y else scroll_top + row;
            if (image_row >= rendered.rows) continue;
            var col: usize = 0;
            while (col < width) : (col += 1) {
                if (centered_x and col < origin_x) continue;
                const image_col = if (centered_x) col - origin_x else scroll_left + col;
                if (image_col >= rendered.cols) continue;
                try ui.image.putPlaceholderWithBackground(grid, col, row, image.id, image_row, image_col, self.background);
            }
        }
    }

    fn buildNodes(self: *ImagePreviewPane) !void {
        const surface = &(self.surface orelse return);
        var background = fallback_background;
        var foreground = fallback_foreground;
        var button_background = fallback_button_background;
        var button_foreground = fallback_button_foreground;
        var button_border = fallback_button_border;
        if (self.theme) |palette| {
            background = palette.colorOr("editor.background", fallback_background);
            foreground = palette.colorOr("editor.foreground", fallback_foreground);
            button_background = palette.colorOr("button.background", fallback_button_background);
            button_foreground = palette.colorOr("button.foreground", fallback_button_foreground);
            button_border = palette.colorOr("button.border", fallback_button_border);
        }

        const doc = surface.document();
        doc.clear();
        const root = try doc.createElement(.div);
        root.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = 0 },
            .top = .{ .cells = 0 },
            .width = .{ .cells = @floatFromInt(self.width) },
            .height = .{ .cells = @floatFromInt(self.height) },
            .background = background,
        });
        doc.setRoot(root);
        self.button_node = null;

        self.background = ui.cell.packColor(background);
        const message = self.displayMessage() orelse {
            self.dirty = false;
            return;
        };

        const container = try doc.createElement(.div);
        container.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = 0 },
            .top = .{ .cells = 0 },
            .width = .{ .cells = @floatFromInt(self.width) },
            .height = .{ .cells = @floatFromInt(self.height) },
            .display = .flex,
            .flex_direction = .column,
            .justify_content = .center,
            .align_items = .center,
            .gap = .{ .row = 1 },
            .padding = .{ .top = 1, .right = 2, .bottom = 1, .left = 2 },
        });
        _ = try root.appendChild(container);

        const text = try doc.createText(message);
        text.setStyle(.{ .color = foreground, .text_align = .center });
        _ = try container.appendChild(text);

        const button = try doc.createElement(.div);
        button.setStyle(.{
            .padding = .{ .top = 0, .right = 1, .bottom = 0, .left = 1 },
            .background = button_background,
            .border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 },
            .border_color = button_border,
            .pointer = .pointer,
        });
        _ = try container.appendChild(button);
        const label = try doc.createText("Open in Text Editor");
        label.setStyle(.{ .color = button_foreground });
        _ = try button.appendChild(label);
        self.button_node = button;

        self.dirty = false;
    }

    fn displayMessage(self: *const ImagePreviewPane) ?[]const u8 {
        if (self.editor.message) |text| return text;
        if (self.editor.hasImage() and !self.runtime.enabled()) return message_graphics_unsupported;
        if (!self.editor.hasImage()) return image_preview_editor.message_corrupt;
        return null;
    }

    pub fn handleKey(self: *ImagePreviewPane, event: *const ui.KeyEvent) Action {
        const viewport = viewer_mod.CellRect{ .cols = self.width, .rows = self.height };
        const cell = self.cellSize();
        if (self.displayMessage() != null and event.key == .enter) return .open_text;
        if (event.mods.ctrl or event.mods.alt) return .none;
        switch (event.key) {
            .char => |ch| switch (ch) {
                '+', '=' => {
                    if (!self.editor.hasImage()) return .none;
                    self.editor.zoomIn(viewport, cell);
                    self.dirty = true;
                    return .changed;
                },
                '-' => {
                    if (!self.editor.hasImage()) return .none;
                    self.editor.zoomOut(viewport, cell);
                    self.dirty = true;
                    return .changed;
                },
                '0' => {
                    if (!self.editor.hasImage()) return .none;
                    self.editor.setScale(.fit, viewport, cell);
                    self.dirty = true;
                    return .changed;
                },
                else => return .none,
            },
            .up => return self.scrollKey(0, -1),
            .down => return self.scrollKey(0, 1),
            .left => return self.scrollKey(-1, 0),
            .right => return self.scrollKey(1, 0),
            .page_up => return self.scrollKey(0, -@as(i64, @intCast(@max(self.height, 1)))),
            .page_down => return self.scrollKey(0, @as(i64, @intCast(@max(self.height, 1)))),
            .home => {
                if (!self.editor.hasImage() or self.editor.viewer.scale == .fit) return .none;
                self.editor.viewer.scroll_top = 0;
                self.dirty = true;
                return .changed;
            },
            .end => {
                if (!self.editor.hasImage() or self.editor.viewer.scale == .fit) return .none;
                self.editor.viewer.scroll_top = std.math.maxInt(usize);
                self.editor.viewer.clampScroll(viewport, cell);
                self.dirty = true;
                return .changed;
            },
            .escape => return .none,
            else => return .none,
        }
    }

    fn scrollKey(self: *ImagePreviewPane, dx: i64, dy: i64) Action {
        if (!self.editor.hasImage() or self.editor.viewer.scale == .fit) return .none;
        const viewport = viewer_mod.CellRect{ .cols = self.width, .rows = self.height };
        const cell = self.cellSize();
        const before_left = self.editor.viewer.scroll_left;
        const before_top = self.editor.viewer.scroll_top;
        self.editor.viewer.scrollBy(dx, dy, viewport, cell);
        if (before_left == self.editor.viewer.scroll_left and before_top == self.editor.viewer.scroll_top) return .none;
        self.dirty = true;
        return .changed;
    }

    pub fn handleMouse(self: *ImagePreviewPane, event: *const ui.MouseEvent, focus_gained: bool) Action {
        if (event.kind == .wheel) {
            if (event.mods.ctrl or event.mods.alt) {
                if (!self.editor.hasImage() or event.delta_y == 0) return .none;
                const viewport = viewer_mod.CellRect{ .cols = self.width, .rows = self.height };
                const cell = self.cellSize();
                if (event.delta_y > 0) self.editor.zoomOut(viewport, cell) else self.editor.zoomIn(viewport, cell);
                self.dirty = true;
                return .changed;
            }
            var action: Action = .none;
            if (event.delta_y != 0) {
                action = self.scrollKey(0, event.delta_y);
            }
            if (event.delta_x != 0) {
                const horizontal = self.scrollKey(event.delta_x, 0);
                if (horizontal == .changed) action = .changed;
            }
            return action;
        }
        if (event.kind != .down or event.button != .left) return .none;

        if (self.button_node) |button| {
            if (self.hitNode(event.x, event.y)) |node| {
                if (node == button or node.parent == button) return .open_text;
            }
        }
        if (focus_gained) return .changed;
        if (!self.editor.hasImage() or !self.runtime.enabled()) return .none;

        const viewport = viewer_mod.CellRect{ .cols = self.width, .rows = self.height };
        const cell = self.cellSize();
        if (event.mods.ctrl or event.mods.alt) self.editor.zoomOut(viewport, cell) else self.editor.zoomIn(viewport, cell);
        self.dirty = true;
        return .changed;
    }

    fn hitNode(self: *ImagePreviewPane, x: usize, y: usize) ?*ui.Node {
        const surface = &(self.surface orelse return null);
        return surface.elementFromPoint(x, y) catch null;
    }

    fn hostRead(context: *anyopaque, allocator: Allocator, path: []const u8) anyerror!image_preview_editor.FileContent {
        const self: *ImagePreviewPane = @ptrCast(@alignCast(context));
        const bytes = try Io.Dir.cwd().readFileAlloc(self.io, path, allocator, .limited(mediaImage.max_file_bytes));
        return .{ .bytes = bytes, .size = bytes.len };
    }

    fn hostShow(context: *anyopaque, decoded: mediaImage.Decoded) anyerror!void {
        const self: *ImagePreviewPane = @ptrCast(@alignCast(context));
        if (self.terminal_image) |image| {
            image.deinit();
            self.terminal_image = null;
        }
        self.terminal_image = TerminalImage.init(self.allocator, self.runtime, decoded) catch |err| {
            var owned = decoded;
            owned.deinit(self.allocator);
            return err;
        };
        self.dirty = true;
    }

    fn hostClear(context: *anyopaque) void {
        const self: *ImagePreviewPane = @ptrCast(@alignCast(context));
        if (self.terminal_image) |image| {
            image.deinit();
            self.terminal_image = null;
        }
        self.dirty = true;
    }

    pub fn usesPath(self: *const ImagePreviewPane, path: []const u8) bool {
        return std.mem.eql(u8, self.editor.path, path);
    }

    pub fn imagePath(self: *const ImagePreviewPane) []const u8 {
        return self.editor.path;
    }
};

test "imagePreview: unsupported terminal shows the message and button" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "image.png", .data = &png_1x1 });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPathFile(io, "image.png", &path_buffer);
    const path = path_buffer[0..length];

    var runtime = ui.image.Runtime.init(allocator);
    defer runtime.deinit();
    const pane = try ImagePreviewPane.init(allocator, io, &runtime, path);
    defer pane.deinit();

    var frame = try ui.Frame.init(allocator, 40, 10);
    defer frame.deinit();
    try pane.paint(&frame, 0, 0, 40, 10);

    var found = false;
    var row: usize = 0;
    while (row < 10) : (row += 1) {
        const text = try frame.next.rowText(allocator, row);
        defer allocator.free(text);
        if (std.mem.indexOf(u8, text, "kitty graphics") != null) found = true;
    }
    try std.testing.expect(found);
    try std.testing.expect(pane.button_node != null);
    try std.testing.expectEqual(Action.open_text, pane.handleKey(&.{ .key = .enter }));
}

test "imagePreview: capable terminal paints placeholders and zooms" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "image.png", .data = &png_1x1 });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPathFile(io, "image.png", &path_buffer);
    const path = path_buffer[0..length];

    var runtime = ui.image.Runtime.init(allocator);
    defer runtime.deinit();
    runtime.setProtocol(.unicode_placeholders);
    runtime.setCellSize(8, 16);

    const pane = try ImagePreviewPane.init(allocator, io, &runtime, path);
    defer pane.deinit();

    var frame = try ui.Frame.init(allocator, 40, 10);
    defer frame.deinit();
    try pane.paint(&frame, 0, 0, 40, 10);

    const grid = &frame.next;
    var saw_placeholder = false;
    var row: usize = 0;
    while (row < 10) : (row += 1) {
        var col: usize = 0;
        while (col < 40) : (col += 1) {
            if (grid.cluster[grid.index(col, row)] == ui.image.placeholder_codepoint) saw_placeholder = true;
        }
    }
    try std.testing.expect(saw_placeholder);
    try std.testing.expect(pane.button_node == null);

    const viewport = viewer_mod.CellRect{ .cols = 40, .rows = 10 };
    const before = pane.editor.viewer.currentNumericScale(viewport, pane.cellSize());
    const action = pane.handleKey(&.{ .key = .{ .char = '+' } });
    try std.testing.expectEqual(Action.changed, action);
    try std.testing.expect(pane.editor.viewer.currentNumericScale(viewport, pane.cellSize()) >= before);
}

test "imagePreview: async load reads and decodes off the caller thread" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "image.png", .data = &png_1x1 });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPathFile(io, "image.png", &path_buffer);
    const path = path_buffer[0..length];

    var io_state = Io.Threaded.init(allocator, .{});
    defer io_state.deinit();
    const async_io = io_state.io();

    var runtime = ui.image.Runtime.init(allocator);
    defer runtime.deinit();
    runtime.setProtocol(.unicode_placeholders);
    runtime.setCellSize(8, 16);

    var window = dispatch.Queue{ .io = async_io };
    const pane = try ImagePreviewPane.initAsync(allocator, io, &window, &runtime, path);
    defer pane.deinit();
    try std.testing.expect(pane.hasPendingLoad());

    var waited: usize = 0;
    while (!window.dispatch(@import("../vs/base/common/timeCompat.zig").milliTimestamp()) and waited < 2000) : (waited += 1) {
        async_io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(pane.editor.hasImage());
    try std.testing.expect(!pane.hasPendingLoad());

    var frame = try ui.Frame.init(allocator, 40, 10);
    defer frame.deinit();
    try pane.paint(&frame, 0, 0, 40, 10);
    const grid = &frame.next;
    var saw_placeholder = false;
    var row: usize = 0;
    while (row < 10) : (row += 1) {
        var col: usize = 0;
        while (col < 40) : (col += 1) {
            if (grid.cluster[grid.index(col, row)] == ui.image.placeholder_codepoint) saw_placeholder = true;
        }
    }
    try std.testing.expect(saw_placeholder);
}

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
