// Port of the portable controller in
// `src/vs/workbench/contrib/mediaPreview/browser/imagePreviewEditor.ts`.
//
// Upstream the pane creates an `ImageViewer`, reads the resource through the
// file service, watches it for changes, decodes it through a blob URL and
// writes a placeholder message on failure. The terminal port keeps the load
// result state (file size, dimensions, message, has-image, reload) and the
// `ImageViewer` model, while file reading, decoding and terminal painting are
// supplied through a `Host`. The synchronous `load` remains for tests and
// host-driven callers; `beginLoad`/`applyLoaded` split the portable load state
// so the terminal pane can read and decode on the async Io and apply the
// result on the TUI thread. `loadId` still guards against stale results.
//
// Browser-only omissions: object URLs, `<img>` decoding, the message
// button's DOM subtree, view-state mementos and the media-player inputs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const mediaImage = @import("../common/mediaImage.zig");
const media_preview = @import("../common/mediaPreview.zig");
const viewer_mod = @import("imageViewer.zig");

const ImageViewer = viewer_mod.ImageViewer;
const ViewState = viewer_mod.ViewState;

pub const message_git_lfs = "The image is stored with Git LFS and is not available for preview.";
pub const message_unsupported = "This image format is not supported in the terminal preview.";
pub const message_too_large = "The image is too large to preview.";
pub const message_corrupt = "An error occurred while loading the image.";
pub const message_read_error = "The image could not be read.";
pub const message_empty = "The image file is empty.";
pub const message_loading = "Loading image...";

pub const FileContent = struct {
    /// Owned by the caller.
    bytes: []u8,
    size: usize,
};

/// Host boundary. `read` returns owned bytes; `show` takes ownership of the
/// decoded payload (including on failure) and uploads it to the terminal;
/// `clear` discards the currently displayed image (for example before a reload).
/// Result of reading and decoding an image on a worker thread. The terminal
/// pane keeps the portable message/state decisions in `applyLoaded`.
pub const LoadedImage = union(enum) {
    image: struct { decoded: mediaImage.Decoded, size: usize },
    empty,
    git_lfs: usize,
    unsupported: usize,
    too_large: usize,
    corrupt: usize,
    read_error,
};

pub const Host = struct {
    context: *anyopaque,
    read: *const fn (context: *anyopaque, allocator: Allocator, path: []const u8) anyerror!FileContent,
    show: *const fn (context: *anyopaque, decoded: mediaImage.Decoded) anyerror!void,
    clear: *const fn (context: *anyopaque) void,
};

pub const ImagePreviewEditor = struct {
    allocator: Allocator,
    host: Host,
    path: []u8,
    viewer: ImageViewer = .{},
    file_size: ?usize = null,
    message: ?[]const u8 = null,
    /// View state captured by `reload` and applied by the view once it knows
    /// the pane's cell geometry.
    pending_view_state: ?ViewState = null,
    /// View state captured by `beginLoad` until `applyLoaded` runs.
    load_previous_view_state: ?ViewState = null,
    load_id: u32 = 0,

    pub fn init(allocator: Allocator, host: Host, path: []const u8) !*ImagePreviewEditor {
        const self = try initDeferred(allocator, host, path);
        self.load(false);
        return self;
    }

    /// Creates the controller without reading anything. The caller starts an
    /// async load and later calls `beginLoad`/`applyLoaded`.
    pub fn initDeferred(allocator: Allocator, host: Host, path: []const u8) !*ImagePreviewEditor {
        const self = try allocator.create(ImagePreviewEditor);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .host = host,
            .path = try allocator.dupe(u8, path),
        };
        return self;
    }

    /// Resets the load state and returns the load id the result must match.
    pub fn beginLoad(self: *ImagePreviewEditor, preserve_view_state: bool) u32 {
        self.load_id += 1;
        self.load_previous_view_state = if (preserve_view_state) self.viewer.getViewState() else null;
        self.host.clear(self.host.context);
        self.viewer.clear();
        self.message = null;
        self.file_size = null;
        return self.load_id;
    }

    /// Reads, checks and decodes an image. Pure worker-thread work: it does not
    /// touch the viewer or terminal, only the supplied allocator/io.
    pub fn loadContent(allocator: Allocator, io: Io, path: []const u8) LoadedImage {
        const bytes = Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(mediaImage.max_file_bytes)) catch |err| {
            return if (err == error.FileTooBig or err == error.StreamTooLong) .{ .too_large = 0 } else .read_error;
        };
        defer allocator.free(bytes);
        const size = bytes.len;
        if (size == 0) return .empty;
        if (media_preview.isGitLfsPointer(bytes)) return .{ .git_lfs = size };
        const decoded = mediaImage.decode(allocator, bytes) catch |err| return switch (err) {
            error.UnsupportedFormat => .{ .unsupported = size },
            error.ImageTooLarge => .{ .too_large = size },
            error.CorruptImage => .{ .corrupt = size },
            else => .read_error,
        };
        return .{ .image = .{ .decoded = decoded, .size = size } };
    }

    /// Applies a `loadContent` result on the TUI thread. Stale results (a newer
    /// reload started meanwhile) take ownership of their payload and drop it.
    pub fn applyLoaded(self: *ImagePreviewEditor, load_id: u32, loaded: LoadedImage) void {
        if (load_id != self.load_id) {
            if (loaded == .image) {
                var decoded = loaded.image.decoded;
                decoded.deinit(self.allocator);
            }
            return;
        }
        self.message = null;
        self.file_size = null;
        switch (loaded) {
            .image => |value| {
                self.file_size = value.size;
                self.viewer.setImage(.{ .width = value.decoded.width, .height = value.decoded.height });
                // `show` takes ownership of the decoded payload even on error.
                self.host.show(self.host.context, value.decoded) catch {
                    self.viewer.clear();
                    self.message = message_read_error;
                };
            },
            .empty => self.message = message_empty,
            .git_lfs => |size| {
                self.file_size = size;
                self.message = message_git_lfs;
            },
            .unsupported => |size| {
                self.file_size = size;
                self.message = message_unsupported;
            },
            .too_large => |size| {
                self.file_size = if (size == 0) null else size;
                self.message = message_too_large;
            },
            .corrupt => |size| {
                self.file_size = size;
                self.message = message_corrupt;
            },
            .read_error => self.message = message_read_error,
        }
        self.pending_view_state = self.load_previous_view_state;
        self.load_previous_view_state = null;
    }

    pub fn deinit(self: *ImagePreviewEditor) void {
        self.host.clear(self.host.context);
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    pub fn hasImage(self: *const ImagePreviewEditor) bool {
        return self.viewer.has_image;
    }

    pub fn naturalSize(self: *const ImagePreviewEditor) ?viewer_mod.PixelSize {
        return self.viewer.naturalSize();
    }

    /// Reads and decodes the image. A missing/corrupt/unsupported file becomes
    /// a message instead of an error so the tab can render a placeholder.
    pub fn load(self: *ImagePreviewEditor, preserve_view_state: bool) void {
        const load_id = self.load_id + 1;
        self.load_id = load_id;
        const previous = if (preserve_view_state) self.viewer.getViewState() else null;

        self.host.clear(self.host.context);
        self.viewer.clear();
        self.message = null;

        const content = self.host.read(self.host.context, self.allocator, self.path) catch |err| {
            self.file_size = null;
            self.message = if (err == error.FileTooBig or err == error.StreamTooLong) message_too_large else message_read_error;
            self.pending_view_state = previous;
            return;
        };
        defer self.allocator.free(content.bytes);
        self.file_size = content.size;

        if (content.bytes.len == 0) {
            self.message = message_empty;
            self.pending_view_state = previous;
            return;
        }
        if (media_preview.isGitLfsPointer(content.bytes)) {
            self.message = message_git_lfs;
            self.pending_view_state = previous;
            return;
        }

        const decoded = mediaImage.decode(self.allocator, content.bytes) catch |err| {
            self.message = switch (err) {
                error.UnsupportedFormat => message_unsupported,
                error.ImageTooLarge => message_too_large,
                error.CorruptImage => message_corrupt,
                else => message_read_error,
            };
            self.pending_view_state = previous;
            return;
        };
        self.viewer.setImage(.{ .width = decoded.width, .height = decoded.height });
        // `show` takes ownership of the decoded payload even when it fails.
        self.host.show(self.host.context, decoded) catch {
            self.viewer.clear();
            self.message = message_read_error;
            self.pending_view_state = previous;
            return;
        };
        self.pending_view_state = previous;
    }

    pub fn reload(self: *ImagePreviewEditor) void {
        self.load(true);
    }

    /// Applies a view state captured across a reload. Must be called once the
    /// view knows its viewport and cell size.
    pub fn applyPendingViewState(
        self: *ImagePreviewEditor,
        viewport: viewer_mod.CellRect,
        cell: viewer_mod.CellSize,
    ) void {
        const state = self.pending_view_state orelse return;
        self.pending_view_state = null;
        if (!self.viewer.has_image) return;
        self.viewer.setViewState(state, viewport, cell);
    }

    pub fn zoomIn(self: *ImagePreviewEditor, viewport: viewer_mod.CellRect, cell: viewer_mod.CellSize) void {
        self.viewer.zoomIn(viewport, cell);
    }

    pub fn zoomOut(self: *ImagePreviewEditor, viewport: viewer_mod.CellRect, cell: viewer_mod.CellSize) void {
        self.viewer.zoomOut(viewport, cell);
    }

    pub fn setScale(
        self: *ImagePreviewEditor,
        scale: viewer_mod.Scale,
        viewport: viewer_mod.CellRect,
        cell: viewer_mod.CellSize,
    ) void {
        self.viewer.setScale(scale, viewport, cell);
    }
};
