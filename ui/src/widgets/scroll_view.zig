//! A manual two-axis scroll view: a clipped viewport, a translated content
//! box and optional proportional scrollbars.
//!
//! The terminal layout has no CSS `overflow: scroll`/`auto`: `overflow` is
//! only visible/hidden/clip, so views that can overflow use this helper. The
//! caller appends content to `contentNode()` in whole cells, sets the content
//! extents, and calls `init` again after a document rebuild.
//!
//! A `ScrollView` owns no heap memory. The wheel listener stores `self` as its
//! context, so the `ScrollView` storage must outlive the nodes it creates.
//!
//! ```zig
//! var view: ui.ScrollView = undefined;
//! try view.init(doc, panel, .{
//!     .width = 40,
//!     .height = 10,
//!     .content_width = 80,
//!     .content_height = 30,
//! });
//! const rows = view.contentNode();
//! ```
//!
//! Vertical-only callers keep the original behavior: when `content_width` is
//! omitted (zero), it defaults to the viewport width and the horizontal axis
//! never overflows.

const std = @import("std");
const dom = @import("../dom/dom.zig");
const scroll = @import("scroll.zig");
const style = @import("../style/style.zig");

const Color = style.Color;
const Document = dom.Document;
const Node = dom.Node;
const ScrollWindow = scroll.ScrollWindow;

pub const default_track_color = Color{ .r = 34, .g = 36, .b = 46 };
pub const default_thumb_color = Color{ .r = 96, .g = 102, .b = 128 };

pub const ScrollCallback = struct {
    context: ?*anyopaque = null,
    callback: *const fn (context: ?*anyopaque, left: usize, top: usize) void,
};

pub const Options = struct {
    left: f64 = 0,
    top: f64 = 0,
    width: usize,
    height: usize,
    /// Full horizontal content extent. Zero means "same as the viewport".
    content_width: usize = 0,
    content_height: usize,
    initial_scroll_left: usize = 0,
    initial_scroll: usize = 0,
    scrollbar: bool = true,
    scrollbar_width: usize = 1,
    horizontal_scrollbar: bool = false,
    horizontal_scrollbar_height: usize = 1,
    background: ?Color = null,
    track_color: Color = default_track_color,
    thumb_color: Color = default_thumb_color,
    /// Called after user-driven wheel scrolling; programmatic `scrollTo*`
    /// calls do not fire it, so a host can mirror the position without a loop.
    on_scroll: ?ScrollCallback = null,
};

pub const ScrollView = struct {
    doc: *Document,
    root: *Node,
    viewport: *Node,
    content: *Node,
    track: ?*Node = null,
    thumb: ?*Node = null,
    horizontal_track: ?*Node = null,
    horizontal_thumb: ?*Node = null,

    /// Height of the vertical viewport (excludes a horizontal scrollbar).
    viewport_height: usize = 0,
    /// Width of the horizontal viewport (excludes a vertical scrollbar).
    content_width: usize = 0,
    viewport_width: usize = 0,
    content_height: usize = 0,
    scroll_top: usize = 0,
    scroll_left: usize = 0,
    has_scrollbar: bool = false,
    has_horizontal_scrollbar: bool = false,
    thumb_height: usize = 1,
    thumb_width: usize = 1,
    scroll_y: ScrollWindow = .{},
    scroll_x: ScrollWindow = .{},
    on_scroll: ?ScrollCallback = null,

    /// Creates the viewport/content/scrollbar nodes under `parent`. The caller
    /// must keep `self` alive while the document exists.
    pub fn init(self: *ScrollView, doc: *Document, parent: *Node, options: Options) !void {
        const requested_width = if (options.content_width == 0)
            options.width
        else
            options.content_width;

        // Two passes let a horizontal scrollbar create enough vertical overflow
        // to need the vertical scrollbar, and vice versa.
        var has_vertical = options.scrollbar and options.content_height > options.height;
        var has_horizontal = options.horizontal_scrollbar and requested_width > options.width;
        var viewport_width: usize = 0;
        var viewport_height: usize = 0;
        for (0..2) |_| {
            viewport_width = options.width -|
                (if (has_vertical) options.scrollbar_width else 0);
            viewport_height = options.height -|
                (if (has_horizontal) options.horizontal_scrollbar_height else 0);
            has_vertical = options.scrollbar and options.content_height > viewport_height;
            has_horizontal = options.horizontal_scrollbar and requested_width > viewport_width;
        }
        viewport_width = @max(1, options.width -|
            (if (has_vertical) options.scrollbar_width else 0));
        viewport_height = @max(1, options.height -|
            (if (has_horizontal) options.horizontal_scrollbar_height else 0));

        const content_width = @max(requested_width, viewport_width);
        var scroll_x = ScrollWindow.init(viewport_width, content_width, options.initial_scroll_left);
        var scroll_y = ScrollWindow.init(viewport_height, options.content_height, options.initial_scroll);
        scroll_x.offset = @min(scroll_x.offset, scroll_x.maxOffset());
        scroll_y.offset = @min(scroll_y.offset, scroll_y.maxOffset());

        const root = try doc.createElement(.div);
        root.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = options.left },
            .top = .{ .cells = options.top },
            .width = .{ .cells = @floatFromInt(options.width) },
            .height = .{ .cells = @floatFromInt(options.height) },
            .background = options.background,
        });
        _ = try parent.appendChild(root);

        const viewport = try doc.createElement(.div);
        viewport.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = 0 },
            .top = .{ .cells = 0 },
            .width = .{ .cells = @floatFromInt(viewport_width) },
            .height = .{ .cells = @floatFromInt(viewport_height) },
            .overflow = .clip,
        });
        _ = try root.appendChild(viewport);

        const content = try doc.createElement(.div);
        content.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = 0 },
            .top = .{ .cells = 0 },
            .width = .{ .cells = @floatFromInt(content_width) },
            .height = .{ .cells = @floatFromInt(options.content_height) },
            .translate_y = -@as(f64, @floatFromInt(scroll_y.offset)),
            .translate_x = -@as(f64, @floatFromInt(scroll_x.offset)),
        });
        _ = try viewport.appendChild(content);

        var track: ?*Node = null;
        var thumb: ?*Node = null;
        if (has_vertical) {
            const track_node = try doc.createElement(.div);
            track_node.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = @floatFromInt(viewport_width) },
                .top = .{ .cells = 0 },
                .width = .{ .cells = @floatFromInt(options.scrollbar_width) },
                .height = .{ .cells = @floatFromInt(viewport_height) },
                .background = options.track_color,
            });
            _ = try root.appendChild(track_node);
            track = track_node;

            const thumb_height = verticalThumbHeight(viewport_height, options.content_height);
            const thumb_node = try doc.createElement(.div);
            thumb_node.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = 0 },
                .top = .{ .cells = 0 },
                .width = .{ .cells = @floatFromInt(options.scrollbar_width) },
                .height = .{ .cells = @floatFromInt(thumb_height) },
                .background = options.thumb_color,
            });
            _ = try track_node.appendChild(thumb_node);
            thumb = thumb_node;
        }

        var horizontal_track: ?*Node = null;
        var horizontal_thumb: ?*Node = null;
        if (has_horizontal) {
            const track_node = try doc.createElement(.div);
            track_node.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = 0 },
                .top = .{ .cells = @floatFromInt(viewport_height) },
                .width = .{ .cells = @floatFromInt(viewport_width) },
                .height = .{ .cells = @floatFromInt(options.horizontal_scrollbar_height) },
                .background = options.track_color,
            });
            _ = try root.appendChild(track_node);
            horizontal_track = track_node;

            const thumb_width = horizontalThumbWidth(viewport_width, content_width);
            const thumb_node = try doc.createElement(.div);
            thumb_node.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = 0 },
                .top = .{ .cells = 0 },
                .width = .{ .cells = @floatFromInt(thumb_width) },
                .height = .{ .cells = @floatFromInt(options.horizontal_scrollbar_height) },
                .background = options.thumb_color,
            });
            _ = try track_node.appendChild(thumb_node);
            horizontal_thumb = thumb_node;
        }

        self.* = .{
            .doc = doc,
            .root = root,
            .viewport = viewport,
            .content = content,
            .track = track,
            .thumb = thumb,
            .horizontal_track = horizontal_track,
            .horizontal_thumb = horizontal_thumb,
            .viewport_height = viewport_height,
            .viewport_width = viewport_width,
            .content_width = viewport_width,
            .content_height = options.content_height,
            .scroll_top = scroll_y.offset,
            .scroll_left = scroll_x.offset,
            .has_scrollbar = has_vertical,
            .has_horizontal_scrollbar = has_horizontal,
            .thumb_height = verticalThumbHeight(viewport_height, options.content_height),
            .thumb_width = horizontalThumbWidth(viewport_width, content_width),
            .scroll_y = scroll_y,
            .scroll_x = scroll_x,
            .on_scroll = options.on_scroll,
        };
        try root.addEventListener(.{ .context = self, .wheel = onWheel });
        self.apply();
    }

    pub fn contentNode(self: *ScrollView) *Node {
        return self.content;
    }

    pub fn rootNode(self: *ScrollView) *Node {
        return self.root;
    }

    pub fn scrollTop(self: *const ScrollView) usize {
        return self.scroll_top;
    }

    pub fn scrollLeft(self: *const ScrollView) usize {
        return self.scroll_left;
    }

    /// Width of the horizontal viewport (excludes the vertical scrollbar).
    pub fn contentWidth(self: *const ScrollView) usize {
        return self.content_width;
    }

    /// Full horizontal content extent.
    pub fn contentExtentWidth(self: *const ScrollView) usize {
        return self.scroll_x.content;
    }

    pub fn maxScroll(self: *const ScrollView) usize {
        return self.scroll_y.maxOffset();
    }

    pub fn maxScrollX(self: *const ScrollView) usize {
        return self.scroll_x.maxOffset();
    }

    /// Scrolls by `delta` whole cells (positive scrolls down). Programmatic:
    /// does not fire `on_scroll`.
    pub fn scrollBy(self: *ScrollView, delta: i32) bool {
        if (!self.scroll_y.scrollBy(delta)) return false;
        self.scroll_top = self.scroll_y.offset;
        self.apply();
        return true;
    }

    /// Scrolls by `delta` whole cells (positive scrolls right). Programmatic:
    /// does not fire `on_scroll`.
    pub fn scrollByX(self: *ScrollView, delta: i32) bool {
        if (!self.scroll_x.scrollBy(delta)) return false;
        self.scroll_left = self.scroll_x.offset;
        self.apply();
        return true;
    }

    /// Scrolls to an absolute cell, clamped to the content. Programmatic: does
    /// not fire `on_scroll`.
    pub fn scrollTo(self: *ScrollView, cell: usize) bool {
        if (!self.scroll_y.scrollTo(cell)) return false;
        self.scroll_top = self.scroll_y.offset;
        self.apply();
        return true;
    }

    pub fn scrollToX(self: *ScrollView, cell: usize) bool {
        if (!self.scroll_x.scrollTo(cell)) return false;
        self.scroll_left = self.scroll_x.offset;
        self.apply();
        return true;
    }

    /// Moves/resizes the viewport. Scrollbars are created at `init`; callers
    /// that toggle overflow after construction re-create the view.
    pub fn setViewportRect(self: *ScrollView, left: f64, top: f64, width: usize, height: usize) void {
        const bar_width: usize = if (self.has_scrollbar) 1 else 0;
        const bar_height: usize = if (self.has_horizontal_scrollbar) 1 else 0;
        const viewport_width = @max(1, width -| bar_width);
        const viewport_height = @max(1, height -| bar_height);

        var root_style = self.root.style().*;
        root_style.left = .{ .cells = left };
        root_style.top = .{ .cells = top };
        root_style.width = .{ .cells = @floatFromInt(width) };
        root_style.height = .{ .cells = @floatFromInt(height) };
        self.root.setStyle(root_style);

        var viewport_style = self.viewport.style().*;
        viewport_style.width = .{ .cells = @floatFromInt(viewport_width) };
        viewport_style.height = .{ .cells = @floatFromInt(viewport_height) };
        self.viewport.setStyle(viewport_style);

        if (self.track) |track| {
            var track_style = track.style().*;
            track_style.left = .{ .cells = @floatFromInt(viewport_width) };
            track_style.height = .{ .cells = @floatFromInt(viewport_height) };
            track.setStyle(track_style);
        }
        if (self.horizontal_track) |track| {
            var track_style = track.style().*;
            track_style.top = .{ .cells = @floatFromInt(viewport_height) };
            track_style.width = .{ .cells = @floatFromInt(viewport_width) };
            track.setStyle(track_style);
        }

        self.viewport_width = viewport_width;
        self.viewport_height = viewport_height;
        self.content_width = viewport_width;
        self.scroll_x.setExtents(viewport_width, self.scroll_x.content);
        self.scroll_y.setExtents(viewport_height, self.scroll_y.content);
        self.scroll_left = self.scroll_x.offset;
        self.scroll_top = self.scroll_y.offset;
        self.thumb_height = verticalThumbHeight(viewport_height, self.scroll_y.content);
        self.thumb_width = horizontalThumbWidth(viewport_width, self.scroll_x.content);
        self.apply();
    }

    /// Updates both content extents. Scrollbars are created at `init`; a view
    /// that starts without overflow keeps its current node structure.
    pub fn setContentSize(self: *ScrollView, width: usize, height: usize) void {
        const content_width = @max(width, self.viewport_width);
        self.scroll_x.setExtents(self.viewport_width, content_width);
        self.scroll_y.setExtents(self.viewport_height, height);
        self.content_height = height;
        var content_style = self.content.style().*;
        content_style.width = .{ .cells = @floatFromInt(content_width) };
        content_style.height = .{ .cells = @floatFromInt(height) };
        self.content.setStyle(content_style);
        self.scroll_left = self.scroll_x.offset;
        self.scroll_top = self.scroll_y.offset;
        self.thumb_height = verticalThumbHeight(self.viewport_height, height);
        self.thumb_width = horizontalThumbWidth(self.viewport_width, content_width);
        self.apply();
    }

    fn apply(self: *ScrollView) void {
        var content_style = self.content.style().*;
        content_style.translate_x = -@as(f64, @floatFromInt(self.scroll_left));
        content_style.translate_y = -@as(f64, @floatFromInt(self.scroll_top));
        self.content.setStyle(content_style);

        if (self.thumb) |thumb| {
            const travel = self.viewport_height -| self.thumb_height;
            const max_scroll = self.maxScroll();
            const thumb_top = if (max_scroll == 0)
                0
            else
                self.scroll_top * travel / max_scroll;
            var thumb_style = thumb.style().*;
            thumb_style.top = .{ .cells = @floatFromInt(thumb_top) };
            thumb_style.height = .{ .cells = @floatFromInt(self.thumb_height) };
            thumb.setStyle(thumb_style);
        }

        if (self.horizontal_thumb) |thumb| {
            const travel = self.viewport_width -| self.thumb_width;
            const max_scroll = self.maxScrollX();
            const thumb_left = if (max_scroll == 0)
                0
            else
                self.scroll_left * travel / max_scroll;
            var thumb_style = thumb.style().*;
            thumb_style.left = .{ .cells = @floatFromInt(thumb_left) };
            thumb_style.width = .{ .cells = @floatFromInt(self.thumb_width) };
            thumb.setStyle(thumb_style);
        }
    }

    fn notify(self: *ScrollView) void {
        const callback = self.on_scroll orelse return;
        callback.callback(callback.context, self.scroll_left, self.scroll_top);
    }

    fn onWheel(context: ?*anyopaque, event: *dom.MouseEvent) void {
        const self: *ScrollView = @ptrCast(@alignCast(context orelse return));
        var changed = false;
        if (event.delta_x != 0 and self.scroll_x.scrollBy(event.delta_x)) {
            self.scroll_left = self.scroll_x.offset;
            changed = true;
        }
        if (event.delta_y != 0 and self.scroll_y.scrollBy(event.delta_y)) {
            self.scroll_top = self.scroll_y.offset;
            changed = true;
        }
        if (!changed) return;
        event.preventDefault();
        event.stopPropagation();
        self.apply();
        self.notify();
    }
};

fn verticalThumbHeight(viewport_height: usize, content_height: usize) usize {
    if (content_height <= viewport_height or viewport_height == 0) return 1;
    return @max(@as(usize, 1), (viewport_height * viewport_height) / content_height);
}

fn horizontalThumbWidth(viewport_width: usize, content_width: usize) usize {
    if (content_width <= viewport_width or viewport_width == 0) return 1;
    return @max(@as(usize, 1), (viewport_width * viewport_width) / content_width);
}
