//! Markdown document preview pane for the terminal workbench.
//!
//! Async terminal adaptation: local image reads/decodes and remote http(s)
//! fetches run on the workbench `async_io` as per-preview jobs; the preview
//! only publishes loaded entries and keeps alt text until `pollImageJobs`
//! applies a result. Remote image requests use the ported `RequestService`
//! (30 s deadline, 32 MiB cap) and are only issued while the preview exists.
//!
//! The portable behavior is ported from
//! `vscode/extensions/markdown-language-features/preview/preview.ts`,
//! `preview-src/index.ts` and `preview-src/scroll-sync.ts`. The webview/DOM
//! layer is replaced by a `ui.Surface` painted only for the visible rows; the
//! renderer and scroll model live under
//! `src/vs/editor/common/markdown` and
//! `src/vs/workbench/contrib/markdown`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const ui = @import("ui");
const theme_colors_mod = @import("../vs/workbench/browser/themeColors.zig");
const Editor = @import("../vs/editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const Position = @import("../vs/editor/common/core/position.zig").Position;
const Range = @import("../vs/editor/common/core/range.zig").Range;
const time_compat = @import("../vs/base/common/timeCompat.zig");
const DeadlineTimer = @import("../vs/base/common/deadlineTimer.zig").DeadlineTimer;
const viewEvents = @import("../vs/editor/common/viewEvents.zig");
const ViewEventHandler = @import("../vs/editor/common/viewEventHandler.zig").ViewEventHandler;
const markdown = @import("../vs/editor/common/markdown/markdownTerminalRenderer.zig");
const preview_doc = @import("../vs/workbench/contrib/markdown/browser/markdownPreviewDocument.zig");
const scroll_sync = @import("../vs/workbench/contrib/markdown/browser/scrollSync.zig");
const topmost = @import("../vs/workbench/contrib/markdown/browser/topmostLineMonitor.zig");
const scrolling = @import("../vs/workbench/contrib/markdown/browser/scrolling.zig");
const preview_config = @import("../vs/workbench/contrib/markdown/browser/markdownPreviewConfig.zig");
const mediaImage = @import("../vs/workbench/contrib/mediaPreview/common/mediaImage.zig");
const TerminalImage = @import("./terminalImage.zig").TerminalImage;
const cellMetrics = @import("./cellMetrics.zig");
const RequestService = @import("../vs/platform/request/node/requestService.zig").RequestService;

/// Upper bound for image reads/fetches in flight per preview. Completed jobs
/// rebuild the document, which queues the next batch on the following tick.
const max_concurrent_image_jobs = 4;

const base_preview_background = ui.Color{ .r = 30, .g = 30, .b = 33 };
const base_preview_foreground = ui.Color{ .r = 204, .g = 204, .b = 204 };
const base_code_background = ui.Color{ .r = 30, .g = 30, .b = 30 };
const base_active_line_background = ui.Color{ .r = 70, .g = 76, .b = 84 };
const base_scrollbar_track = ui.Color{ .r = 30, .g = 32, .b = 40 };
const base_scrollbar_thumb = ui.Color{ .r = 105, .g = 108, .b = 122 };
const base_divider_color = ui.Color{ .r = 70, .g = 70, .b = 70 };

/// One image read/decode job started by `syncImagesAsync`. The result is
/// applied on the TUI thread in `pollImageJobs`.
const MarkdownImagePayload = struct {
    decoded: mediaImage.Decoded,
    size: usize,
    mtime: Io.Timestamp,
};

const MarkdownImageResult = union(enum) {
    image: MarkdownImagePayload,
    failed,
};

const MarkdownImageJob = struct {
    const Source = union(enum) {
        file: []u8,
        url: []u8,
    };

    preview: *MarkdownPreview,
    future: Io.Future(MarkdownImageResult),
    done: std.atomic.Value(bool) = .init(false),
    key: []u8,
    /// True once `publishImage` took ownership of `key` as the entry path.
    key_consumed: bool = false,
    source: Source,
    /// File reads are short and latency-sensitive; remote requests are not.
    local: bool,
    /// Remote requests are canceled by the poll loop after this timestamp.
    deadline_ms: ?i64 = null,

    fn deinit(self: *MarkdownImageJob, allocator: Allocator) void {
        if (!self.key_consumed) allocator.free(self.key);
        switch (self.source) {
            .file => |path| allocator.free(path),
            .url => |url| allocator.free(url),
        }
        allocator.destroy(self);
    }
};

fn runMarkdownImageJob(job: *MarkdownImageJob) MarkdownImageResult {
    defer job.done.store(true, .release);
    const async_io = job.preview.async_io orelse return .failed;
    return switch (job.source) {
        .file => |path| loadMarkdownLocalImage(job.preview.allocator, async_io, path),
        .url => |url| loadMarkdownRemoteImage(job.preview, url),
    };
}

fn loadMarkdownLocalImage(allocator: Allocator, io: Io, path: []const u8) MarkdownImageResult {
    const info = Io.Dir.cwd().statFile(io, path, .{}) catch return .failed;
    if (info.kind == .directory) return .failed;
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(mediaImage.max_file_bytes)) catch return .failed;
    defer allocator.free(bytes);
    if (bytes.len == 0) return .failed;
    const decoded = mediaImage.decode(allocator, bytes) catch return .failed;
    return .{ .image = .{ .decoded = decoded, .size = bytes.len, .mtime = info.mtime } };
}

fn loadMarkdownRemoteImage(preview: *MarkdownPreview, url: []const u8) MarkdownImageResult {
    const service = if (preview.request_service) |*value| value else return .failed;
    const options = @import("../vs/base/parts/request/common/request.zig").IRequestOptions{
        .url = url,
        .call_site = "markdownPreview.image",
        .timeout = 30_000,
    };
    var context = service.request(options) catch return .failed;
    defer context.deinit();
    if (context.body.bytes.len == 0 or context.body.bytes.len > mediaImage.max_file_bytes) return .failed;
    const decoded = mediaImage.decode(preview.allocator, context.body.bytes) catch return .failed;
    return .{ .image = .{ .decoded = decoded, .size = context.body.bytes.len, .mtime = Io.Timestamp.zero } };
}

pub const MarkdownPreview = struct {
    mermaid: @import("mermaidPreview.zig").Renderer,
    allocator: Allocator,
    editor: *Editor,
    runtime: ?*ui.image.Runtime = null,
    base_dir: []u8 = &.{},
    /// Io used for file/network image reads. Null keeps the synchronous local
    /// image path used by tests and by previews created before the workbench
    /// hands over its async Io.
    async_io: ?Io = null,
    request_service: ?RequestService = null,
    image_entries: std.StringHashMap(*ImageEntry),
    image_specs: std.array_list.Managed(preview_doc.ImageSpec),
    /// In-flight image loads keyed by resolved path or URL. Keys are owned by
    /// their job and removed before the job is freed.
    image_loading: std.StringHashMap(*MarkdownImageJob),
    image_jobs: std.array_list.Managed(*MarkdownImageJob),
    /// Negative cache so a failing image is not re-requested on every paint.
    image_failed: std.StringHashMap(void),
    surface: ?ui.Surface = null,
    content: ?markdown.Content = null,
    document: ?preview_doc.Document = null,
    width: usize = 0,
    height: usize = 0,
    content_width: usize = 1,
    scroll: usize = 0,
    visible: bool = false,
    dirty: bool = true,
    active_block: u32 = 0,
    last_version: u32 = 0,
    options: preview_config.MarkdownPreviewConfig = .{},

    first_update: bool = true,
    force_next_update: bool = false,
    is_scrolling: bool = false,
    scroll_disabled: bool = false,
    pending_reveal: bool = false,
    last_down_ms: ?i64 = null,
    last_down_row: usize = 0,

    monitor: topmost.TopmostLineMonitor = .{},
    refresh_timer: DeadlineTimer = .{},
    scrolling_timer: DeadlineTimer = .{},
    scroll_disabled_timer: DeadlineTimer = .{},
    reveal_timer: DeadlineTimer = .{},
    view_handler: ViewEventHandler = .{},
    last_error: ?anyerror = null,
    theme: ?*const theme_colors_mod.ThemeColors = null,
    image_background: u32 = 0,

    pub fn init(allocator: Allocator, editor: *Editor) !*MarkdownPreview {
        const self = try allocator.create(MarkdownPreview);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .editor = editor,
            .image_entries = std.StringHashMap(*ImageEntry).init(allocator),
            .image_specs = std.array_list.Managed(preview_doc.ImageSpec).init(allocator),
            .mermaid = .{ .allocator = allocator },
            .image_loading = std.StringHashMap(*MarkdownImageJob).init(allocator),
            .image_jobs = std.array_list.Managed(*MarkdownImageJob).init(allocator),
            .image_failed = std.StringHashMap(void).init(allocator),
        };
        errdefer {
            self.image_failed.deinit();
            self.image_jobs.deinit();
            self.image_loading.deinit();
            self.image_specs.deinit();
            self.image_entries.deinit();
        }
        self.base_dir = try documentBaseDir(allocator, editor.io, editor.path);
        errdefer allocator.free(self.base_dir);
        self.view_handler = ViewEventHandler.init(self, .{
            .onFlushed = onFlushed,
            .onScrollChanged = onScrollChanged,
            .onCursorStateChanged = onCursorStateChanged,
        });
        editor.addViewEventHandler(&self.view_handler);
        self.last_version = editor.model.getVersionId();
        return self;
    }

    /// Attaches the workbench's terminal image runtime. Called once when the
    /// tab is created; a preview created without it keeps alt-text rendering.
    pub fn setImageRuntime(self: *MarkdownPreview, runtime: ?*ui.image.Runtime) void {
        self.runtime = runtime;
        self.dirty = true;
    }

    /// Enables asynchronous local image reads and remote image requests.
    /// Called by the workbench when it creates the preview.
    pub fn setAsyncIo(self: *MarkdownPreview, io: Io) void {
        if (self.async_io != null) return;
        self.async_io = io;
        self.mermaid.io = io;
        self.request_service = RequestService.init(self.allocator, io);
    }

    pub fn setThemeColors(self: *MarkdownPreview, palette: ?*const theme_colors_mod.ThemeColors) void {
        self.theme = palette;
        self.dirty = true;
    }

    pub fn deinit(self: *MarkdownPreview) void {
        self.mermaid.deinit();
        self.cancelImageJobs();
        if (self.request_service) |*service| service.deinit();
        self.request_service = null;
        self.releaseAllImages();
        self.freeFailedImages();
        self.image_failed.deinit();
        self.image_jobs.deinit();
        self.image_loading.deinit();
        self.image_specs.deinit();
        self.image_entries.deinit();
        if (self.base_dir.len > 0) self.allocator.free(self.base_dir);
        self.editor.removeViewEventHandler(&self.view_handler);
        self.refresh_timer.cancel();
        self.scrolling_timer.cancel();
        self.scroll_disabled_timer.cancel();
        self.reveal_timer.cancel();
        if (self.document) |*document| document.deinit();
        if (self.content) |*content| content.deinit();
        if (self.surface) |*surface| surface.deinit();
        self.allocator.destroy(self);
    }

    /// Drops terminal image data/placements while keeping the decoded payload;
    /// the next build/paint re-uploads it. Used after a protocol or terminal
    /// resize cleared the screen.
    pub fn invalidateImages(self: *MarkdownPreview) void {
        var iterator = self.image_entries.iterator();
        while (iterator.next()) |entry| entry.value_ptr.*.terminal.invalidate();
        self.dirty = true;
    }

    pub fn setConfig(self: *MarkdownPreview, config: preview_config.MarkdownPreviewConfig) void {
        if (preview_config.MarkdownPreviewConfig.eql(self.options, config)) return;
        const breaks_changed = self.options.preview_breaks != config.preview_breaks;
        const selection_changed = self.options.mark_editor_selection != config.mark_editor_selection;
        self.options = config;
        if (breaks_changed) {
            self.forceRefresh() catch {};
        } else if (selection_changed) {
            self.updateActiveBlock();
            self.dirty = true;
        }
    }

    pub fn resize(self: *MarkdownPreview, width: usize, height: usize) !void {
        if (self.width == width and self.height == height) return;
        self.width = width;
        self.height = height;
        if (width == 0 or height == 0) {
            if (self.surface) |*surface| {
                surface.deinit();
                self.surface = null;
            }
            self.dirty = true;
            return;
        }
        self.content_width = @max(width -| 2, 1);
        self.invalidateImages();
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
        if (self.content) |*content| {
            const replacement = try self.buildDocument(content);
            if (self.document) |*document| document.deinit();
            self.document = replacement;
            self.clampScroll();
        }
        self.dirty = true;
    }

    pub fn open(self: *MarkdownPreview, start_line: ?f64) !void {
        self.visible = true;
        if (self.content == null or self.last_version != self.editor.model.getVersionId()) {
            try self.updatePreview(false);
        }
        self.first_update = false;
        if (start_line) |line| {
            self.scrollToSourceLine(line);
        }
        self.dirty = true;
    }

    pub fn close(self: *MarkdownPreview) void {
        self.visible = false;
        self.refresh_timer.cancel();
        self.cancelImageJobs();
    }

    pub fn refresh(self: *MarkdownPreview, force: bool) void {
        if (force) self.force_next_update = true;
        if (!self.visible) {
            self.dirty = true;
            return;
        }
        if (self.first_update or self.content == null) {
            self.updatePreview(force) catch |err| {
                self.last_error = err;
            };
            self.first_update = false;
            return;
        }
        if (!self.refresh_timer.isScheduled()) {
            self.refresh_timer.schedule(300, refreshDue, self);
        }
        self.first_update = false;
    }

    pub fn forceRefresh(self: *MarkdownPreview) !void {
        self.refresh_timer.cancel();
        self.force_next_update = false;
        try self.updatePreview(true);
    }

    pub fn scrollToSourceLine(self: *MarkdownPreview, line: f64) void {
        if (self.is_scrolling) return;
        const document = if (self.document) |*value| value else return;
        const target = scroll_sync.scrollToRevealSourceLine(document, line, @floatFromInt(self.scroll)) orelse return;
        self.setScroll(@intFromFloat(@floor(@max(target, 0))), .editor);
    }

    pub fn scrollToAnchor(self: *MarkdownPreview, fragment: []const u8) bool {
        const document = if (self.document) |*value| value else return false;
        const element = document.anchorElement(fragment) orelse return false;
        self.setScroll(@intFromFloat(@floor(@max(element.top, 0))), .preview);
        return true;
    }

    pub fn onTick(self: *MarkdownPreview, now_ms: i64) bool {
        var changed = false;
        if (self.mermaid.poll()) {
            self.updatePreview(false) catch |err| {
                self.last_error = err;
            };
            changed = true;
        }
        if (self.pollImageJobs()) changed = true;
        changed = self.refresh_timer.tick(now_ms) or changed;
        changed = self.scrolling_timer.tick(now_ms) or changed;
        changed = self.scroll_disabled_timer.tick(now_ms) or changed;
        changed = self.reveal_timer.tick(now_ms) or changed;
        if (self.monitor.poll(now_ms)) |line| {
            if (self.visible and !self.is_scrolling) {
                self.scrollToSourceLine(line);
                changed = true;
            }
        }
        return changed or (self.visible and self.surface != null and self.dirty);
    }

    pub fn nextTimeout(self: *const MarkdownPreview, now_ms: i64) ?u32 {
        var result: ?u32 = if (self.mermaid.job != null) 20 else null;
        const timers = [_]*const DeadlineTimer{
            &self.refresh_timer,
            &self.scrolling_timer,
            &self.scroll_disabled_timer,
            &self.reveal_timer,
        };
        for (timers) |timer| {
            if (timer.nextTimeoutMs(now_ms)) |timeout| {
                result = if (result) |current| @min(current, timeout) else timeout;
            }
        }
        if (self.monitor.nextTimeoutMs(now_ms)) |timeout| {
            result = if (result) |current| @min(current, timeout) else timeout;
        }
        return result;
    }

    pub fn paint(self: *MarkdownPreview, frame: *ui.Frame, x: usize, y: usize, w: usize, h: usize) !void {
        if (!self.visible or self.surface == null or w == 0 or h == 0) return;
        if (self.dirty) try self.buildNodes();
        const surface = &(self.surface orelse return);
        try surface.paintFrame();
        try self.paintImagePlaceholders(surface.presentedGrid(), w);
        try ui.CellGrid.blit(&frame.next, surface.grid(), x, y, w, h);
    }

    /// The pointer shape under a preview-relative cell. The content root is
    /// text; link spans and the scrollbar track override it.
    pub fn pointerAt(self: *MarkdownPreview, x: usize, y: usize) !?ui.Pointer {
        if (!self.visible) return null;
        if (self.dirty) try self.buildNodes();
        const surface = &(self.surface orelse return null);
        return surface.pointerAt(x, y);
    }

    pub fn handleMouse(self: *MarkdownPreview, event: *ui.MouseEvent, now_ms: i64) bool {
        if (!self.visible) return false;
        if (event.kind == .wheel) {
            self.scrollBy(event.delta_y, now_ms);
            return true;
        }
        if (event.kind != .down) return true;
        if (event.x >= self.width -| 1) {
            const max_scroll = self.maxScroll();
            const target = if (self.height == 0) 0 else (event.y * max_scroll) / self.height;
            self.setScroll(target, .preview);
            return true;
        }

        const row = self.scroll + event.y;
        const column = event.x -| 1;
        if (self.document) |*document| {
            if (document.linkAt(row, column)) |href| {
                if (href.len > 0 and href[0] == '#') {
                    _ = self.scrollToAnchor(href[1..]);
                    return true;
                }
            }
        }

        const double_click = if (self.last_down_ms) |last|
            now_ms - last <= 500 and self.last_down_row == row
        else
            false;
        if (double_click) {
            self.last_down_ms = null;
            if (self.options.double_click_to_switch_to_editor) self.revealLineInEditor(row);
            return true;
        }
        self.last_down_ms = now_ms;
        self.last_down_row = row;
        return true;
    }

    fn updatePreview(self: *MarkdownPreview, force: bool) !void {
        _ = force;
        if (self.content_width == 0) return;
        var value = try self.editor.model.getValue(.TextDefined, false);
        defer value.deinit();

        self.mermaid.reset(self.editor.model.getVersionId());
        var content = try markdown.parseDocument(self.allocator, value.items, .{
            .mermaid = .{ .context = &self.mermaid, .lookup = @import("mermaidPreview.zig").Renderer.lookup },
            .preview_breaks = self.options.preview_breaks,
        });
        errdefer content.deinit();

        var document = try self.buildDocument(&content);
        errdefer document.deinit();

        const previous_line = self.currentTopLine();
        if (self.document) |*old| old.deinit();
        if (self.content) |*old| old.deinit();
        self.content = content;
        self.document = document;
        self.last_version = self.editor.model.getVersionId();
        self.last_error = null;

        if (previous_line) |line| {
            if (self.document) |*doc| {
                if (scroll_sync.scrollToRevealSourceLine(doc, line, 0)) |target| {
                    self.scroll = @intFromFloat(@floor(@max(target, 0)));
                }
            }
        }
        self.clampScroll();
        self.updateActiveBlock();
        self.first_update = false;
        self.dirty = true;
    }

    fn currentTopLine(self: *const MarkdownPreview) ?f64 {
        const document = if (self.document) |*value| value else return null;
        return scroll_sync.getEditorLineNumberForPageOffset(document, @floatFromInt(self.scroll), @floatFromInt(self.scroll));
    }

    fn clampScroll(self: *MarkdownPreview) void {
        self.scroll = @min(self.scroll, self.maxScroll());
    }

    fn maxScroll(self: *const MarkdownPreview) usize {
        const document = self.document orelse return 0;
        return document.maxScroll(self.height, false);
    }

    fn setScroll(self: *MarkdownPreview, value: usize, source: ScrollSource) void {
        const clamped = @min(value, self.maxScroll());
        if (clamped == self.scroll) return;
        self.scroll = clamped;
        self.dirty = true;
        switch (source) {
            .editor => {
                self.scroll_disabled = true;
                self.scroll_disabled_timer.schedule(50, clearScrollDisabled, self);
            },
            .preview => {
                if (!self.scroll_disabled and self.options.scroll_editor_with_preview) {
                    if (!self.reveal_timer.isScheduled()) {
                        self.applyReveal(time_compat.milliTimestamp());
                        self.reveal_timer.schedule(50, flushReveal, self);
                    } else {
                        self.pending_reveal = true;
                    }
                }
            },
        }
    }

    fn scrollBy(self: *MarkdownPreview, delta: i32, now_ms: i64) void {
        _ = now_ms;
        if (delta == 0) return;
        const target: isize = @as(isize, @intCast(self.scroll)) + delta;
        self.setScroll(@intCast(@max(target, 0)), .preview);
    }

    fn applyReveal(self: *MarkdownPreview, now_ms: i64) void {
        _ = now_ms;
        const line = self.currentTopLine() orelse return;
        self.monitor.setPreviousLine(line);
        scrolling.scrollEditorToLine(line, self.editor);
        self.is_scrolling = true;
        self.scrolling_timer.schedule(200, clearScrolling, self);
    }

    fn revealLineInEditor(self: *MarkdownPreview, row: usize) void {
        const document = if (self.document) |*value| value else return;
        const line = scroll_sync.getEditorLineNumberForPageOffset(
            document,
            @floatFromInt(self.scroll + row),
            @floatFromInt(self.scroll),
        ) orelse return;
        if (std.math.isNan(line)) return;
        const line_count = self.editor.model.getLineCount();
        const model_line = @min(line_count, @max(1, @as(usize, @intFromFloat(@floor(line))) + 1));
        self.editor.setSelection(Range.init(model_line, 1, model_line, 1)) catch {};
    }

    fn updateActiveBlock(self: *MarkdownPreview) void {
        const document = if (self.document) |*value| value else {
            self.active_block = 0;
            return;
        };
        const position = self.editor.modelCursorPosition();
        const line = @as(f64, @floatFromInt(position.lineNumber -| 1));
        const found = scroll_sync.getElementsForSourceLine(document, line);
        self.active_block = if (found.previous) |element| element.block_id else 0;
    }

    const ImageEntry = struct {
        path: []u8,
        mtime: Io.Timestamp,
        size: usize,
        width: usize,
        height: usize,
        terminal: *TerminalImage,
        used: bool = false,
    };

    fn documentBaseDir(allocator: Allocator, io: Io, path: []const u8) ![]u8 {
        var cwd_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
        const cwd_length = Io.Dir.cwd().realPathFile(io, ".", &cwd_buffer) catch 0;
        const absolute = try std.fs.path.resolve(allocator, &.{ cwd_buffer[0..cwd_length], path });
        defer allocator.free(absolute);
        const directory = std.fs.path.dirname(absolute) orelse ".";
        return allocator.dupe(u8, directory);
    }

    fn percentDecode(allocator: Allocator, text: []const u8) ![]u8 {
        var out = try allocator.alloc(u8, text.len);
        errdefer allocator.free(out);
        var source: usize = 0;
        var target: usize = 0;
        while (source < text.len) {
            if (text[source] == '%' and source + 2 < text.len) {
                const high = std.fmt.charToDigit(text[source + 1], 16) catch {
                    out[target] = text[source];
                    source += 1;
                    target += 1;
                    continue;
                };
                const low = std.fmt.charToDigit(text[source + 2], 16) catch {
                    out[target] = text[source];
                    source += 1;
                    target += 1;
                    continue;
                };
                out[target] = (high << 4) | low;
                source += 3;
                target += 1;
                continue;
            }
            out[target] = text[source];
            source += 1;
            target += 1;
        }
        return allocator.realloc(out, target);
    }

    /// Resolves a Markdown image URL to a local file path. Remote and data URLs
    /// return null (the terminal preview does not fetch resources), and
    /// fragments/query strings are stripped.
    fn resolveImagePath(self: *const MarkdownPreview, allocator: Allocator, url: []const u8) !?[]u8 {
        const trimmed = std.mem.trim(u8, url, " \t\r\n");
        if (trimmed.len == 0) return null;
        var end = trimmed.len;
        if (std.mem.indexOfAny(u8, trimmed, "?#")) |index| end = index;
        var raw = trimmed[0..end];
        if (raw.len == 0) return null;
        if (std.mem.startsWith(u8, raw, "http://") or std.mem.startsWith(u8, raw, "https://") or
            std.mem.startsWith(u8, raw, "data:"))
        {
            return null;
        }
        if (std.mem.startsWith(u8, raw, "file://")) {
            raw = raw["file://".len..];
            if (std.mem.startsWith(u8, raw, "localhost/")) raw = raw["localhost".len..];
        }
        const decoded = try percentDecode(allocator, raw);
        defer allocator.free(decoded);
        if (decoded.len == 0) return null;
        if (std.fs.path.isAbsolute(decoded)) return try std.fs.path.resolve(allocator, &.{decoded});
        return try std.fs.path.resolve(allocator, &.{ self.base_dir, decoded });
    }

    fn cellSize(self: *const MarkdownPreview) preview_doc.CellSize {
        if (self.runtime) |runtime| {
            return .{ .width_px = runtime.cell_width_px, .height_px = runtime.cell_height_px };
        }
        return .{};
    }

    fn syncImages(self: *MarkdownPreview, content: *const markdown.Content) !void {
        if (self.async_io != null) return self.syncImagesAsync(content);
        self.image_specs.clearRetainingCapacity();
        var iterator = self.image_entries.iterator();
        while (iterator.next()) |entry| entry.value_ptr.*.used = false;

        const runtime = self.runtime orelse {
            self.releaseUnusedImages();
            return;
        };
        if (!runtime.enabled()) {
            self.releaseUnusedImages();
            return;
        }

        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();
        for (content.lines) |line| {
            for (line.spans) |span| {
                const image = span.image orelse continue;
                if (seen.contains(image.url)) continue;
                try seen.put(image.url, {});
                const path = (try self.resolveImagePath(self.allocator, image.url)) orelse continue;
                defer self.allocator.free(path);
                const entry = try self.getOrLoadImage(path) orelse continue;
                try self.image_specs.append(.{
                    .url = image.url,
                    .width = entry.width,
                    .height = entry.height,
                    .image_id = entry.terminal.id,
                });
            }
        }
        self.releaseUnusedImages();
    }

    fn syncImagesAsync(self: *MarkdownPreview, content: *const markdown.Content) !void {
        self.image_specs.clearRetainingCapacity();
        var iterator = self.image_entries.iterator();
        while (iterator.next()) |entry| entry.value_ptr.*.used = false;

        const runtime = self.runtime orelse {
            self.releaseUnusedImages();
            return;
        };
        if (!runtime.enabled()) {
            self.releaseUnusedImages();
            return;
        }

        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();
        for (content.lines) |line| {
            for (line.spans) |span| {
                const image = span.image orelse continue;
                if (seen.contains(image.url)) continue;
                try seen.put(image.url, {});

                const trimmed = std.mem.trim(u8, image.url, " \t\r\n");
                if (trimmed.len == 0) continue;
                if (std.mem.startsWith(u8, trimmed, "data:")) continue;
                const remote = std.mem.startsWith(u8, trimmed, "http://") or
                    std.mem.startsWith(u8, trimmed, "https://");
                if (remote) {
                    if (self.image_entries.get(trimmed)) |entry| {
                        entry.used = true;
                        try self.appendSpec(image.url, entry);
                        continue;
                    }
                    if (self.image_loading.contains(trimmed) or self.image_failed.contains(trimmed)) continue;
                    if (self.image_jobs.items.len >= max_concurrent_image_jobs) continue;
                    try self.queueImageLoad(trimmed, .{ .url = trimmed }, false);
                    continue;
                }

                const path = (try self.resolveImagePath(self.allocator, image.url)) orelse continue;
                defer self.allocator.free(path);
                if (self.image_entries.get(path)) |entry| {
                    entry.used = true;
                    try self.appendSpec(image.url, entry);
                    continue;
                }
                if (self.image_loading.contains(path) or self.image_failed.contains(path)) continue;
                if (self.image_jobs.items.len >= max_concurrent_image_jobs) continue;
                try self.queueImageLoad(path, .{ .file = path }, true);
            }
        }
        self.releaseUnusedImages();
    }

    fn appendSpec(self: *MarkdownPreview, url: []const u8, entry: *const ImageEntry) !void {
        try self.image_specs.append(.{
            .url = url,
            .width = entry.width,
            .height = entry.height,
            .image_id = entry.terminal.id,
        });
    }

    const ImageSource = union(enum) {
        file: []const u8,
        url: []const u8,
    };

    fn queueImageLoad(self: *MarkdownPreview, key: []const u8, source: ImageSource, local: bool) !void {
        const async_io = self.async_io orelse return;
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const source_copy: MarkdownImageJob.Source = switch (source) {
            .file => |path| .{ .file = try self.allocator.dupe(u8, path) },
            .url => |url| .{ .url = try self.allocator.dupe(u8, url) },
        };
        const job = try self.allocator.create(MarkdownImageJob);
        errdefer self.allocator.destroy(job);
        job.* = .{
            .preview = self,
            .future = undefined,
            .key = key_copy,
            .source = source_copy,
            .local = local,
            .deadline_ms = if (local) null else time_compat.milliTimestamp() + 30_000,
        };
        job.future = async_io.async(runMarkdownImageJob, .{job});
        self.image_jobs.append(job) catch |err| {
            _ = job.future.cancel(async_io);
            if (job.future.result == .image) {
                var decoded = job.future.result.image.decoded;
                decoded.deinit(self.allocator);
            }
            job.deinit(self.allocator);
            return err;
        };
        self.image_loading.put(job.key, job) catch |err| {
            _ = self.image_jobs.pop();
            _ = job.future.cancel(async_io);
            if (job.future.result == .image) {
                var decoded = job.future.result.image.decoded;
                decoded.deinit(self.allocator);
            }
            job.deinit(self.allocator);
            return err;
        };
    }

    /// Applies completed image jobs on the TUI thread. Returns true when at
    /// least one image entry or failure was published.
    fn pollImageJobs(self: *MarkdownPreview) bool {
        const async_io = self.async_io orelse return false;
        var applied = false;
        var index = self.image_jobs.items.len;
        while (index > 0) {
            index -= 1;
            const job = self.image_jobs.items[index];
            const expired = if (job.deadline_ms) |deadline| time_compat.milliTimestamp() >= deadline else false;
            if (!job.done.load(.acquire) and !expired) continue;
            const result = if (expired)
                job.future.cancel(async_io)
            else
                job.future.await(async_io);
            _ = self.image_jobs.orderedRemove(index);
            _ = self.image_loading.fetchRemove(job.key);
            switch (result) {
                .image => |payload| {
                    if (self.publishImage(job.key, payload)) |_| {
                        job.key_consumed = true;
                    } else {
                        self.markImageFailed(job.key);
                    }
                },
                .failed => self.markImageFailed(job.key),
            }
            job.deinit(self.allocator);
            applied = true;
        }
        if (applied) self.rebuildDocumentAfterImages();
        return applied;
    }

    fn rebuildDocumentAfterImages(self: *MarkdownPreview) void {
        const content = if (self.content) |*value| value else return;
        const replacement = self.buildDocument(content) catch |err| {
            self.last_error = err;
            return;
        };
        if (self.document) |*document| document.deinit();
        self.document = replacement;
        self.clampScroll();
        self.dirty = true;
    }

    fn publishImage(self: *MarkdownPreview, key: []u8, payload: MarkdownImagePayload) ?*ImageEntry {
        const runtime = self.runtime orelse {
            var decoded = payload.decoded;
            decoded.deinit(self.allocator);
            return null;
        };
        if (!runtime.enabled()) {
            var decoded = payload.decoded;
            decoded.deinit(self.allocator);
            return null;
        }
        const width = payload.decoded.width;
        const height = payload.decoded.height;
        const terminal = TerminalImage.init(self.allocator, runtime, payload.decoded) catch {
            var decoded = payload.decoded;
            decoded.deinit(self.allocator);
            return null;
        };
        const entry = self.allocator.create(ImageEntry) catch {
            terminal.deinit();
            return null;
        };
        entry.* = .{
            .path = key,
            .mtime = payload.mtime,
            .size = payload.size,
            .width = width,
            .height = height,
            .terminal = terminal,
            .used = true,
        };
        self.image_entries.put(key, entry) catch {
            terminal.deinit();
            self.allocator.destroy(entry);
            return null;
        };
        self.dirty = true;
        return entry;
    }

    fn markImageFailed(self: *MarkdownPreview, key: []const u8) void {
        if (self.image_failed.count() >= 64) return;
        const copy = self.allocator.dupe(u8, key) catch return;
        self.image_failed.put(copy, {}) catch {
            self.allocator.free(copy);
        };
    }

    fn freeFailedImages(self: *MarkdownPreview) void {
        var iterator = self.image_failed.keyIterator();
        while (iterator.next()) |key| self.allocator.free(key.*);
        self.image_failed.clearRetainingCapacity();
    }

    pub fn cancelImageJobs(self: *MarkdownPreview) void {
        const async_io = self.async_io orelse return;
        for (self.image_jobs.items) |job| {
            const result = job.future.cancel(async_io);
            if (result == .image) {
                var decoded = result.image.decoded;
                decoded.deinit(self.allocator);
            }
            job.deinit(self.allocator);
        }
        self.image_jobs.clearRetainingCapacity();
        self.image_loading.clearRetainingCapacity();
    }

    pub fn hasPendingLocalImages(self: *const MarkdownPreview) bool {
        for (self.image_jobs.items) |job| {
            if (job.local) return true;
        }
        return false;
    }

    fn getOrLoadImage(self: *MarkdownPreview, path: []const u8) !?*ImageEntry {
        const io = self.editor.io;
        const stat = Io.Dir.cwd().statFile(io, path, .{}) catch {
            self.removeImage(path);
            return null;
        };
        if (self.image_entries.get(path)) |entry| {
            if (entry.size == stat.size and std.meta.eql(entry.mtime, stat.mtime)) {
                entry.used = true;
                return entry;
            }
            self.removeImage(path);
        }

        const runtime = self.runtime orelse return null;
        if (!runtime.enabled()) return null;
        const bytes = Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(mediaImage.max_file_bytes)) catch return null;
        defer self.allocator.free(bytes);
        const decoded = mediaImage.decode(self.allocator, bytes) catch return null;
        const image_width = decoded.width;
        const image_height = decoded.height;
        const terminal = TerminalImage.init(self.allocator, runtime, decoded) catch |err| {
            var owned = decoded;
            owned.deinit(self.allocator);
            return err;
        };
        const key = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(key);
        const entry = try self.allocator.create(ImageEntry);
        errdefer self.allocator.destroy(entry);
        entry.* = .{
            .path = key,
            .mtime = stat.mtime,
            .size = stat.size,
            .width = image_width,
            .height = image_height,
            .terminal = terminal,
            .used = true,
        };
        try self.image_entries.put(key, entry);
        return entry;
    }

    fn removeImage(self: *MarkdownPreview, path: []const u8) void {
        if (self.image_entries.fetchRemove(path)) |kv| {
            kv.value.terminal.deinit();
            self.allocator.free(kv.value.path);
            self.allocator.destroy(kv.value);
        }
    }

    fn releaseUnusedImages(self: *MarkdownPreview) void {
        var unused = std.array_list.Managed(*ImageEntry).init(self.allocator);
        defer unused.deinit();
        var iterator = self.image_entries.iterator();
        while (iterator.next()) |entry| {
            if (!entry.value_ptr.*.used) unused.append(entry.value_ptr.*) catch continue;
        }
        for (unused.items) |entry| self.removeImage(entry.path);
    }

    fn releaseAllImages(self: *MarkdownPreview) void {
        var iterator = self.image_entries.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.*.terminal.deinit();
            self.allocator.free(entry.value_ptr.*.path);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.image_entries.clearRetainingCapacity();
    }

    fn buildDocument(self: *MarkdownPreview, content: *const markdown.Content) !preview_doc.Document {
        try self.syncImages(content);
        var document = try preview_doc.build(self.allocator, content, self.content_width, .{
            .images = self.image_specs.items,
            .cell = self.cellSize(),
        });
        errdefer document.deinit();
        try self.applyPlacements(&document);
        return document;
    }

    fn applyPlacements(self: *MarkdownPreview, document: *const preview_doc.Document) !void {
        const runtime = self.runtime orelse return;
        if (!runtime.enabled()) return;
        for (document.images) |placement| {
            var iterator = self.image_entries.iterator();
            while (iterator.next()) |entry| {
                const terminal = entry.value_ptr.*.terminal;
                if (terminal.id != placement.image_id) continue;
                try terminal.ensurePlacement(placement.cols, placement.rows);
                break;
            }
        }
    }

    pub fn usesImagePath(self: *const MarkdownPreview, path: []const u8) bool {
        var iterator = self.image_entries.iterator();
        while (iterator.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, path)) return true;
        }
        return false;
    }

    fn paintImagePlaceholders(self: *MarkdownPreview, grid: *ui.CellGrid, width: usize) !void {
        const runtime = self.runtime orelse return;
        if (!runtime.enabled()) return;
        const document = if (self.document) |*value| value else return;
        for (document.images) |placement| {
            if (placement.row + placement.rows <= self.scroll or placement.row >= self.scroll + self.height) continue;
            var image_row: usize = 0;
            while (image_row < placement.rows) : (image_row += 1) {
                const document_row = placement.row + image_row;
                if (document_row < self.scroll or document_row >= self.scroll + self.height) continue;
                const destination_row = document_row - self.scroll;
                var image_col: usize = 0;
                while (image_col < placement.cols) : (image_col += 1) {
                    const destination_col = 1 + placement.col + image_col;
                    if (destination_col >= width) continue;
                    try ui.image.putPlaceholderWithBackground(grid, destination_col, destination_row, placement.image_id, image_row, image_col, self.image_background);
                }
            }
        }
    }

    fn buildNodes(self: *MarkdownPreview) !void {
        var preview_background = base_preview_background;
        var preview_foreground = base_preview_foreground;
        var code_background = base_code_background;
        var active_line_background = base_active_line_background;
        var scrollbar_track = base_scrollbar_track;
        var scrollbar_thumb = base_scrollbar_thumb;
        var divider_color = base_divider_color;
        if (self.theme) |palette| {
            preview_background = palette.colorOr("editor.background", base_preview_background);
            preview_foreground = palette.colorOr("editor.foreground", base_preview_foreground);
            code_background = palette.colorOr("textCodeBlock.background", base_code_background);
            active_line_background = palette.colorOr("editor.lineHighlightBackground", base_active_line_background);
            scrollbar_track = palette.colorOr("editor.background", base_scrollbar_track);
            scrollbar_thumb = palette.colorOr("scrollbarSlider.background", base_scrollbar_thumb);
            divider_color = palette.colorOr("editorWidget.border", base_divider_color);
        }
        self.image_background = ui.cell.packColor(preview_background);
        const surface = &(self.surface orelse return);
        const document = &(self.document orelse {
            const doc = surface.document();
            doc.clear();
            const root = try doc.createElement(.div);
            root.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = 0 },
                .top = .{ .cells = 0 },
                .width = .{ .cells = @floatFromInt(self.width) },
                .height = .{ .cells = @floatFromInt(self.height) },
                .background = preview_background,
            });
            doc.setRoot(root);
            self.dirty = false;
            return;
        });

        const doc = surface.document();
        doc.clear();
        const root = try doc.createElement(.div);
        root.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = 0 },
            .top = .{ .cells = 0 },
            .width = .{ .cells = @floatFromInt(self.width) },
            .height = .{ .cells = @floatFromInt(self.height) },
            .background = preview_background,
            // Markdown body text uses the browser's I-beam; link spans and
            // the scrollbar override it.
            .pointer = .text,
        });
        doc.setRoot(root);

        const end = @min(document.rows.len, self.scroll + self.height);
        var row_index = self.scroll;
        while (row_index < end) : (row_index += 1) {
            const row = document.rows[row_index];
            const top = row_index - self.scroll;
            const is_code = row.block.kind == .code_block;
            const row_node = try doc.createElement(.div);
            row_node.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = 0 },
                .top = .{ .cells = @floatFromInt(top) },
                .width = .{ .cells = @floatFromInt(self.width) },
                .height = .{ .cells = 1 },
                .white_space = .pre,
                .overflow = .hidden,
                .background = if (is_code) code_background else null,
                .color = preview_foreground,
            });
            _ = try root.appendChild(row_node);

            if (self.options.mark_editor_selection and row.block.id != 0 and row.block.id == self.active_block) {
                const marker = try doc.createElement(.div);
                marker.setStyle(.{
                    .position = .absolute,
                    .left = .{ .cells = 0 },
                    .top = .{ .cells = 0 },
                    .width = .{ .cells = 1 },
                    .height = .{ .cells = 1 },
                    .background = active_line_background,
                });
                _ = try row_node.appendChild(marker);
            }

            const line_node = try doc.createElement(.div);
            line_node.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = 1 },
                .top = .{ .cells = 0 },
                .width = .{ .cells = @floatFromInt(self.content_width) },
                .height = .{ .cells = 1 },
                .white_space = .pre,
                .overflow = .hidden,
            });
            _ = try row_node.appendChild(line_node);

            if (row.rule) {
                try appendSpans(doc, line_node, row.spans);
                const width = self.content_width -| row.indent;
                if (width > 0) {
                    const dashes = try repeat(self.allocator, "─", width);
                    defer self.allocator.free(dashes);
                    const text = try doc.createText(dashes);
                    text.setStyle(.{ .color = divider_color });
                    _ = try line_node.appendChild(text);
                }
            } else {
                try appendSpans(doc, line_node, row.spans);
            }
        }

        if (document.rows.len > self.height) {
            const track = try doc.createElement(.div);
            track.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = @floatFromInt(self.width -| 1) },
                .top = .{ .cells = 0 },
                .width = .{ .cells = 1 },
                .height = .{ .cells = @floatFromInt(self.height) },
                .background = scrollbar_track,
                .pointer = .default,
            });
            _ = try root.appendChild(track);
            const thumb_height = @max(@as(usize, 1), (self.height * self.height) / document.rows.len);
            const travel = self.height -| thumb_height;
            const max_scroll = self.maxScroll();
            const thumb_top = if (max_scroll == 0) 0 else (self.scroll * travel) / max_scroll;
            const thumb = try doc.createElement(.div);
            thumb.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = 0 },
                .top = .{ .cells = @floatFromInt(thumb_top) },
                .width = .{ .cells = 1 },
                .height = .{ .cells = @floatFromInt(thumb_height) },
                .background = scrollbar_thumb,
            });
            _ = try track.appendChild(thumb);
        }

        self.dirty = false;
    }

    fn onFlushed(context: *anyopaque, _: *const viewEvents.ViewFlushedEvent) bool {
        const self: *MarkdownPreview = @ptrCast(@alignCast(context));
        if (self.editor.model.getVersionId() == self.last_version) return false;
        self.refresh(false);
        return false;
    }

    fn onScrollChanged(context: *anyopaque, event: *const viewEvents.ViewScrollChangedEvent) bool {
        const self: *MarkdownPreview = @ptrCast(@alignCast(context));
        if (!event.scrollTopChanged or !self.visible) return false;
        if (topmost.getVisibleLine(self.editor)) |line| {
            self.monitor.updateLine(line, time_compat.milliTimestamp());
        }
        return false;
    }

    fn onCursorStateChanged(context: *anyopaque, _: *const viewEvents.ViewCursorStateChangedEvent) bool {
        const self: *MarkdownPreview = @ptrCast(@alignCast(context));
        const old = self.active_block;
        self.updateActiveBlock();
        if (old != self.active_block) self.dirty = true;
        return false;
    }

    fn refreshDue(context: *anyopaque) void {
        const self: *MarkdownPreview = @ptrCast(@alignCast(context));
        const force = self.force_next_update;
        self.force_next_update = false;
        self.updatePreview(force) catch |err| {
            self.last_error = err;
        };
    }

    fn clearScrolling(context: *anyopaque) void {
        const self: *MarkdownPreview = @ptrCast(@alignCast(context));
        self.is_scrolling = false;
    }

    fn clearScrollDisabled(context: *anyopaque) void {
        const self: *MarkdownPreview = @ptrCast(@alignCast(context));
        self.scroll_disabled = false;
    }

    fn flushReveal(context: *anyopaque) void {
        const self: *MarkdownPreview = @ptrCast(@alignCast(context));
        if (self.pending_reveal) {
            self.pending_reveal = false;
            self.applyReveal(time_compat.milliTimestamp());
        }
    }
};

const ScrollSource = enum { editor, preview };

fn appendSpans(doc: *ui.Document, parent: *ui.Node, spans: []const markdown.Span) !void {
    for (spans) |span| {
        if (span.text.len == 0) continue;
        if (span.link != null) {
            // A link is an inline element with the pointer cursor; the text
            // run keeps its span paint style unchanged.
            const link = try doc.createElement(.span);
            link.setStyle(.{ .display = .inline_, .pointer = .pointer });
            const text = try doc.createText(span.text);
            text.setStyle(span.style);
            _ = try link.appendChild(text);
            _ = try parent.appendChild(link);
            continue;
        }
        const text = try doc.createText(span.text);
        text.setStyle(span.style);
        _ = try parent.appendChild(text);
    }
}

fn repeat(allocator: Allocator, text: []const u8, count: usize) ![]u8 {
    const result = try allocator.alloc(u8, text.len * count);
    var index: usize = 0;
    while (index < count) : (index += 1) {
        @memcpy(result[index * text.len ..][0..text.len], text);
    }
    return result;
}

test "markdownPreview: resolves local image URLs and skips remote ones" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "# title", "/tmp/docs/readme.md", 40, 10);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    const preview = try MarkdownPreview.init(allocator, editor);
    defer preview.deinit();

    {
        const path = (try preview.resolveImagePath(allocator, "images/a.png")).?;
        defer allocator.free(path);
        const expected = try std.fs.path.resolve(allocator, &.{ preview.base_dir, "images/a.png" });
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, path);
    }
    {
        const path = (try preview.resolveImagePath(allocator, "/tmp/abs.png#fragment")).?;
        defer allocator.free(path);
        const expected = try std.fs.path.resolve(allocator, &.{"/tmp/abs.png"});
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, path);
    }
    {
        const path = (try preview.resolveImagePath(allocator, "file:///tmp/a%20b.png")).?;
        defer allocator.free(path);
        const expected = try std.fs.path.resolve(allocator, &.{"/tmp/a b.png"});
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, path);
    }
    try std.testing.expect((try preview.resolveImagePath(allocator, "https://example.com/a.png")) == null);
    try std.testing.expect((try preview.resolveImagePath(allocator, "data:image/png;base64,AAAA")) == null);
}

test "markdownPreview: async local image load lands on the poll tick" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "image.png", .data = &async_png_1x1 });
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

    const editor = try Editor.createFromText(allocator, io, "# title", "/tmp/docs/readme.md", 40, 10);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    const preview = try MarkdownPreview.init(allocator, editor);
    defer preview.deinit();
    preview.setImageRuntime(&runtime);
    preview.setAsyncIo(async_io);

    try preview.queueImageLoad(path, .{ .file = path }, true);
    try std.testing.expect(preview.image_loading.contains(path));

    var waited: usize = 0;
    while (!preview.pollImageJobs() and waited < 2000) : (waited += 1) {
        async_io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(preview.usesImagePath(path));
    try std.testing.expect(!preview.image_loading.contains(path));
}

test "markdownPreview: links request the pointer shape" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(
        allocator,
        io,
        "See [link](https://example.com)\n\ntext\n\ntext\n\ntext\n\ntext",
        "/tmp/docs/readme.md",
        40,
        4,
    );
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    const preview = try MarkdownPreview.init(allocator, editor);
    defer preview.deinit();

    try preview.resize(40, 4);
    try preview.open(null);
    var frame = try ui.Frame.init(allocator, 40, 4);
    defer frame.deinit();
    frame.begin();
    try preview.paint(&frame, 0, 0, 40, 4);

    // The line node starts after the one-cell content margin: "See " is text,
    // "link" is an inline link element with the hand shape.
    try std.testing.expectEqual(ui.Pointer.text, (try preview.pointerAt(1, 0)).?);
    try std.testing.expectEqual(ui.Pointer.pointer, (try preview.pointerAt(5, 0)).?);

    // The overflowing document paints a scrollbar in the last column; it is
    // chrome, not text.
    try std.testing.expectEqual(ui.Pointer.default, (try preview.pointerAt(39, 0)).?);
}

test "markdownPreview: percent decoding keeps malformed escapes" {
    const allocator = std.testing.allocator;
    const decoded = try MarkdownPreview.percentDecode(allocator, "a%20b%zzc%");
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("a b%zzc%", decoded);
}

const async_png_1x1 = [_]u8{
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
