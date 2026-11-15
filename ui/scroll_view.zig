//! A manual scroll view: a clipped viewport, a translated content box and an
//! optional proportional scrollbar.
//!
//! The terminal layout has no CSS `overflow: scroll`/`auto`: `overflow` is
//! only visible/hidden/clip, so views that can overflow use this helper. The
//! caller appends content to `contentNode()` in whole cells, sets
//! `content_height`, and calls `init` again after a document rebuild.
//!
//! A `ScrollView` owns no heap memory. The wheel listener stores `self` as its
//! context, so the `ScrollView` storage must outlive the nodes it creates.
//!
//! ```zig
//! var view: ui.ScrollView = undefined;
//! try view.init(doc, panel, .{
//!     .width = 40,
//!     .height = 10,
//!     .content_height = 30,
//! });
//! const rows = view.contentNode();
//! ```

const std = @import("std");
const dom = @import("dom.zig");
const style = @import("style.zig");

const Color = style.Color;
const Document = dom.Document;
const Node = dom.Node;

pub const default_track_color = Color{ .r = 34, .g = 36, .b = 46 };
pub const default_thumb_color = Color{ .r = 96, .g = 102, .b = 128 };

pub const Options = struct {
    left: f64 = 0,
    top: f64 = 0,
    width: usize,
    height: usize,
    content_height: usize,
    initial_scroll: usize = 0,
    scrollbar: bool = true,
    scrollbar_width: usize = 1,
    background: ?Color = null,
    track_color: Color = default_track_color,
    thumb_color: Color = default_thumb_color,
};

pub const ScrollView = struct {
    doc: *Document,
    root: *Node,
    viewport: *Node,
    content: *Node,
    track: ?*Node = null,
    thumb: ?*Node = null,

    viewport_height: usize = 0,
    content_width: usize = 0,
    content_height: usize = 0,
    scroll_top: usize = 0,
    has_scrollbar: bool = false,
    thumb_height: usize = 1,

    /// Creates the viewport/content/scrollbar nodes under `parent`. The caller
    /// must keep `self` alive while the document exists.
    pub fn init(self: *ScrollView, doc: *Document, parent: *Node, options: Options) !void {
        const has_scrollbar = options.scrollbar and
            options.scrollbar_width > 0 and
            options.content_height > options.height;
        const scrollbar_cols: usize = if (has_scrollbar) options.scrollbar_width else 0;
        const content_width: usize = options.width -| scrollbar_cols;
        const max_scroll: usize = options.content_height -| options.height;
        const scroll_top: usize = @min(options.initial_scroll, max_scroll);
        const thumb_height: usize = if (has_scrollbar)
            @max(@as(usize, 1), @min(options.height, (options.height * options.height) / options.content_height))
        else
            1;

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
            .width = .{ .cells = @floatFromInt(content_width) },
            .height = .{ .cells = @floatFromInt(options.height) },
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
            .translate_y = -@as(f64, @floatFromInt(scroll_top)),
        });
        _ = try viewport.appendChild(content);

        var track: ?*Node = null;
        var thumb: ?*Node = null;
        if (has_scrollbar) {
            const track_node = try doc.createElement(.div);
            track_node.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = @floatFromInt(content_width) },
                .top = .{ .cells = 0 },
                .width = .{ .cells = @floatFromInt(options.scrollbar_width) },
                .height = .{ .cells = @floatFromInt(options.height) },
                .background = options.track_color,
            });
            _ = try root.appendChild(track_node);
            track = track_node;

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

        self.* = .{
            .doc = doc,
            .root = root,
            .viewport = viewport,
            .content = content,
            .track = track,
            .thumb = thumb,
            .viewport_height = options.height,
            .content_width = content_width,
            .content_height = options.content_height,
            .scroll_top = scroll_top,
            .has_scrollbar = has_scrollbar,
            .thumb_height = thumb_height,
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

    pub fn contentWidth(self: *const ScrollView) usize {
        return self.content_width;
    }

    pub fn maxScroll(self: *const ScrollView) usize {
        return self.content_height -| self.viewport_height;
    }

    /// Scrolls by `delta` whole cells (positive scrolls down). Returns whether
    /// the position changed.
    pub fn scrollBy(self: *ScrollView, delta: i32) bool {
        const max_scroll: isize = @intCast(self.maxScroll());
        const current: isize = @intCast(self.scroll_top);
        const wanted = @max(0, @min(max_scroll, current + @as(isize, delta)));
        return self.scrollTo(@intCast(wanted));
    }

    /// Scrolls to an absolute cell, clamped to the content. Returns whether the
    /// position changed.
    pub fn scrollTo(self: *ScrollView, cell: usize) bool {
        const wanted = @min(cell, self.maxScroll());
        if (wanted == self.scroll_top) return false;
        self.scroll_top = wanted;
        self.apply();
        return true;
    }

    fn apply(self: *ScrollView) void {
        var content_style = self.content.style().*;
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
            thumb.setStyle(thumb_style);
        }
    }

    fn onWheel(context: ?*anyopaque, event: *dom.MouseEvent) void {
        const self: *ScrollView = @ptrCast(@alignCast(context orelse return));
        if (event.delta_y == 0) return;
        event.preventDefault();
        event.stopPropagation();
        _ = self.scrollBy(event.delta_y);
    }
};

test "scroll view clamps, translates and tracks a thumb" {
    const testing = std.testing;
    var doc = try Document.init(testing.allocator, .{ .cols = 40, .rows = 12 });
    defer doc.deinit();
    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
    });
    doc.setRoot(root);

    var view: ScrollView = undefined;
    try view.init(&doc, root, .{
        .left = 1,
        .top = 1,
        .width = 20,
        .height = 8,
        .content_height = 30,
    });

    try testing.expect(view.has_scrollbar);
    try testing.expectEqual(@as(usize, 19), view.contentWidth());
    try testing.expectEqual(@as(usize, 22), view.maxScroll());
    try testing.expect(view.thumb != null);
    try testing.expectEqual(@as(f64, 0), view.content.style().translate_y);

    var wheel = dom.MouseEvent{ .kind = .wheel, .x = 2, .y = 2, .delta_y = 3 };
    doc.dispatchMouse(view.rootNode(), &wheel);
    try testing.expect(wheel.default_prevented);
    try testing.expectEqual(@as(usize, 3), view.scrollTop());
    try testing.expectEqual(@as(f64, -3), view.content.style().translate_y);

    _ = view.scrollBy(-100);
    try testing.expectEqual(@as(usize, 0), view.scrollTop());
    _ = view.scrollBy(1000);
    try testing.expectEqual(@as(usize, 22), view.scrollTop());
    try testing.expectEqual(@as(f64, -22), view.content.style().translate_y);

    const thumb_top = switch (view.thumb.?.style().top) {
        .cells => |value| value,
        else => -1,
    };
    try testing.expectEqual(@as(f64, 6), thumb_top);
}

test "scroll view without overflow has no scrollbar" {
    const testing = std.testing;
    var doc = try Document.init(testing.allocator, .{ .cols = 40, .rows = 12 });
    defer doc.deinit();
    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
    });
    doc.setRoot(root);

    var view: ScrollView = undefined;
    try view.init(&doc, root, .{
        .width = 20,
        .height = 10,
        .content_height = 4,
    });

    try testing.expect(!view.has_scrollbar);
    try testing.expectEqual(@as(usize, 20), view.contentWidth());
    try testing.expect(view.thumb == null);
    try testing.expect(!view.scrollBy(5));
    try testing.expectEqual(@as(usize, 0), view.scrollTop());
}

test "scroll view honours wide scrollbars and initial scroll" {
    const testing = std.testing;
    var doc = try Document.init(testing.allocator, .{ .cols = 40, .rows = 12 });
    defer doc.deinit();
    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
    });
    doc.setRoot(root);

    var view: ScrollView = undefined;
    try view.init(&doc, root, .{
        .width = 20,
        .height = 8,
        .content_height = 30,
        .initial_scroll = 100,
        .scrollbar_width = 2,
    });

    try testing.expectEqual(@as(usize, 18), view.contentWidth());
    try testing.expectEqual(@as(usize, 22), view.scrollTop());
    const thumb_width = switch (view.thumb.?.style().width) {
        .cells => |value| value,
        else => -1,
    };
    try testing.expectEqual(@as(f64, 2), thumb_width);
}
