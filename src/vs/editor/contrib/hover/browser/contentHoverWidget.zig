// Port of `src/vs/editor/contrib/hover/browser/contentHoverWidget.ts`.
//
// Terminal adaptation: the hover is a rounded box anchored to the model
// position computed by `RenderedContentHover`. Upstream is a resizable content
// widget with a sash, rounded border and pixel layout; terminal cells have no
// resize handles, so the box auto-sizes to its contents and clamps to the text
// area. Scrolling is line-based (there is no horizontal scrolling because the
// terminal renderer wraps the contents).
//
// Browser-only pieces that are intentionally absent, documented in
// `README.md` and `docs/terminal-ui.md`:
//  * sash resizing and the `ResizableContentWidget` minimum/maximum geometry,
//  * the accessible-view hint and screen-reader announcements.
const std = @import("std");
const Allocator = std.mem.Allocator;

const ui = @import("ui");

const Position = @import("../../../common/core/position.zig").Position;
const editorBrowser = @import("../../../browser/editorBrowser.zig");
const RenderedContentHover = @import("./contentHoverRendered.zig").RenderedContentHover;

const hover_css = @import("hover_css.zig");
const base_hover = @import("../../../../base/browser/ui/hover/hoverWidget.zig");
pub const Theme = base_hover.Theme;

/// Upstream `ContentHoverWidget.ID`.
pub const widget_id = "editor.contrib.resizableContentHoverWidget";

const border_width: usize = 1;
const min_width_cells: usize = 20;
const min_height_cells: usize = 3;

/// The view/editor facts the widget needs. The controller also owns hiding, so
/// `hide`/`focus_editor` go back to the controller instead of the editor.
pub const ContentHoverWidgetHost = struct {
    context: *anyopaque,
    text_height: *const fn (context: *anyopaque) usize,
    visible_row_of: *const fn (context: *anyopaque, position: Position) ?usize,
    request_frame: *const fn (context: *anyopaque) void,
    hide: *const fn (context: *anyopaque) void,
    focus_editor: *const fn (context: *anyopaque) void,
    state_changed: ?*const fn (context: *anyopaque, visible: bool, focused: bool) void = null,
};

pub const ContentHoverWidget = struct {
    allocator: Allocator,
    host: ContentHoverWidgetHost,
    theme: Theme = .{},
    /// Owned by the widget; replaced on every `show`.
    rendered: ?*RenderedContentHover = null,
    scroll_top: usize = 0,
    focused: bool = false,
    root: ?*ui.Node = null,

    last_cols: usize = 0,
    widget_width: usize = 0,
    widget_height: usize = 0,
    content_width: usize = 0,
    content_rows: usize = 0,
    visible_rows: usize = 0,
    show_scrollbar: bool = false,
    preference: editorBrowser.ContentWidgetPositionPreference = .below,
    prefer_above: bool = true,
    /// Minimum content size requested by participants through the hover
    /// context (`setMinimumDimensions` upstream).
    minimum_width: usize = 1,
    minimum_height: usize = 1,

    pub fn init(allocator: Allocator, host: ContentHoverWidgetHost) !*ContentHoverWidget {
        const self = try allocator.create(ContentHoverWidget);
        self.* = .{
            .allocator = allocator,
            .host = host,
        };
        return self;
    }

    pub fn setTheme(self: *ContentHoverWidget, theme: Theme) void {
        self.theme = theme;
    }

    pub fn deinit(self: *ContentHoverWidget) void {
        self.clearRendered();
        self.allocator.destroy(self);
    }

    pub fn interface(self: *ContentHoverWidget) editorBrowser.IContentWidget {
        return .{
            .context = self,
            .get_id = getId,
            .get_position = getPosition,
            .width = width,
            .height = height,
            .build = build,
            .focus_node = focusNode,
            .is_focused = isFocusedCallback,
        };
    }

    pub fn show(self: *ContentHoverWidget, rendered: *RenderedContentHover) void {
        // Keep focus when a new result replaces the contents of a focused
        // hover; the view re-focuses the rebuilt box.
        const was_focused = self.focused;
        self.clearRendered();
        self.rendered = rendered;
        self.scroll_top = 0;
        self.focused = was_focused;
        self.minimum_width = 1;
        self.minimum_height = 1;
        self.publishState();
        self.host.request_frame(self.host.context);
    }

    pub fn setMinimumDimensions(self: *ContentHoverWidget, minimum_width: usize, minimum_height: usize) void {
        self.minimum_width = @max(self.minimum_width, minimum_width);
        self.minimum_height = @max(self.minimum_height, minimum_height);
        self.host.request_frame(self.host.context);
    }

    /// Focuses the box; the view re-focuses `focus_node` after each rebuild.
    pub fn focus(self: *ContentHoverWidget) void {
        self.focused = true;
        self.publishState();
        self.host.request_frame(self.host.context);
    }

    /// Takes ownership of the rendered hover. The controller calls this when
    /// the contents should go away.
    pub fn hide(self: *ContentHoverWidget) void {
        if (self.rendered == null) return;
        self.clearRendered();
        self.publishState();
        self.layout(self.last_cols);
        self.host.request_frame(self.host.context);
    }

    /// Hides through the controller so the current result and decoration are
    /// cleared too. Escape and clicks outside the box go through here.
    pub fn dismiss(self: *ContentHoverWidget) void {
        self.host.hide(self.host.context);
    }

    pub fn isVisible(self: *const ContentHoverWidget) bool {
        return self.rendered != null;
    }

    pub fn isFocused(self: *const ContentHoverWidget) bool {
        return self.focused;
    }

    pub fn isVisibleFromKeyboard(self: *const ContentHoverWidget) bool {
        const rendered = self.rendered orelse return false;
        return rendered.source == .keyboard;
    }

    pub fn position(self: *const ContentHoverWidget) ?Position {
        const rendered = self.rendered orelse return null;
        return rendered.show_at_position;
    }

    pub fn widgetContent(self: *const ContentHoverWidget) ?[]const u8 {
        const rendered = self.rendered orelse return null;
        return rendered.getWidgetContent();
    }

    pub fn focusedHoverPartIndex(self: *const ContentHoverWidget) isize {
        _ = self;
        // Hover parts are not individually focusable in the terminal port;
        // only the box itself takes focus.
        return -1;
    }

    pub fn scrollUp(self: *ContentHoverWidget) void {
        self.scrollBy(-1);
    }

    pub fn scrollDown(self: *ContentHoverWidget) void {
        self.scrollBy(1);
    }

    pub fn pageUp(self: *ContentHoverWidget) void {
        self.scrollBy(-@as(isize, @intCast(@max(self.visible_rows, 1))));
    }

    pub fn pageDown(self: *ContentHoverWidget) void {
        self.scrollBy(@as(isize, @intCast(@max(self.visible_rows, 1))));
    }

    pub fn goToTop(self: *ContentHoverWidget) void {
        if (self.scroll_top == 0) return;
        self.scroll_top = 0;
        self.host.request_frame(self.host.context);
    }

    pub fn goToBottom(self: *ContentHoverWidget) void {
        self.setScroll(self.maxScroll());
    }

    pub fn scrollLeft(self: *ContentHoverWidget) void {
        _ = self;
        // The terminal renderer wraps hover contents; there is no horizontal
        // scroll position to change.
    }

    pub fn scrollRight(self: *ContentHoverWidget) void {
        _ = self;
        // See `scrollLeft`.
    }

    fn publishState(self: *ContentHoverWidget) void {
        if (self.host.state_changed) |changed| changed(self.host.context, self.isVisible(), self.isFocused());
    }

    fn clearRendered(self: *ContentHoverWidget) void {
        if (self.rendered) |rendered| rendered.deinit();
        self.rendered = null;
        self.root = null;
        self.focused = false;
        self.scroll_top = 0;
    }

    fn maxScroll(self: *const ContentHoverWidget) usize {
        return self.content_rows -| self.visible_rows;
    }

    fn scrollBy(self: *ContentHoverWidget, delta: isize) void {
        if (self.maxScroll() == 0) return;
        const current: isize = @intCast(@min(self.scroll_top, self.maxScroll()));
        const next: isize = std.math.clamp(current + delta, 0, @as(isize, @intCast(self.maxScroll())));
        self.setScroll(@intCast(next));
    }

    fn setScroll(self: *ContentHoverWidget, value: usize) void {
        const clamped = @min(value, self.maxScroll());
        if (clamped == self.scroll_top) return;
        self.scroll_top = clamped;
        self.host.request_frame(self.host.context);
    }

    fn layout(self: *ContentHoverWidget, cols: usize) void {
        self.last_cols = cols;
        const rendered = self.rendered orelse {
            self.widget_width = 0;
            self.widget_height = 0;
            self.content_width = 0;
            self.content_rows = 0;
            self.visible_rows = 0;
            self.show_scrollbar = false;
            return;
        };

        const text_height = @max(self.host.text_height(self.host.context), 1);
        const max_width = @max(@max(cols * 66 / 100, min_width_cells), 1);
        const max_height = @min(@max(text_height / 4, 5), text_height);
        const natural = @max(
            rendered.measureWidth(@max(max_width - border_width * 2, 1)),
            self.minimum_width,
        ) + border_width * 2;
        self.widget_width = std.math.clamp(natural, @min(min_width_cells, cols), @min(max_width, cols));
        self.widget_width = @max(self.widget_width, border_width * 2 + 1);

        var content_width = self.widget_width - border_width * 2;
        var content_rows = @max(rendered.heightAt(content_width), self.minimum_height);
        const available_rows = max_height -| border_width * 2;
        if (content_rows > available_rows and content_width > 1) {
            // A scrollbar takes one content column, so measure again.
            content_width -= 1;
            content_rows = rendered.heightAt(content_width);
        }
        self.content_width = @max(content_width, 1);
        self.content_rows = content_rows;
        self.visible_rows = @max(@min(content_rows, available_rows), 1);
        self.show_scrollbar = content_rows > self.visible_rows;
        self.widget_height = self.visible_rows + border_width * 2;
        if (self.widget_height < min_height_cells) {
            self.widget_height = @min(min_height_cells, text_height);
            self.visible_rows = self.widget_height -| border_width * 2;
        }
        if (self.widget_height > text_height) {
            self.widget_height = text_height;
            self.visible_rows = self.widget_height -| border_width * 2;
        }
        if (self.visible_rows == 0) {
            self.widget_height = 0;
        }
        self.updatePreference(rendered.show_at_position, text_height);
        if (self.scroll_top > self.maxScroll()) self.scroll_top = self.maxScroll();
    }

    fn updatePreference(self: *ContentHoverWidget, anchor_position: Position, text_height: usize) void {
        const row = self.host.visible_row_of(self.host.context, anchor_position) orelse {
            self.preference = .below;
            return;
        };
        if (self.prefer_above and row >= self.widget_height) {
            self.preference = .above;
        } else if (row + self.widget_height <= text_height) {
            self.preference = .below;
        } else if (row >= self.widget_height) {
            self.preference = .above;
        } else {
            self.preference = .below;
        }
    }

    fn getId(context: *anyopaque) []const u8 {
        _ = context;
        return widget_id;
    }

    fn getPosition(context: *anyopaque) ?editorBrowser.IContentWidgetPosition {
        const self: *ContentHoverWidget = @ptrCast(@alignCast(context));
        const rendered = self.rendered orelse return null;
        return .{
            .position = rendered.show_at_position,
            .preference = self.preference,
        };
    }

    fn width(context: *anyopaque, cols: usize) usize {
        const self: *ContentHoverWidget = @ptrCast(@alignCast(context));
        self.layout(cols);
        return self.widget_width;
    }

    fn height(context: *anyopaque) usize {
        const self: *ContentHoverWidget = @ptrCast(@alignCast(context));
        self.layout(self.last_cols);
        return self.widget_height;
    }

    fn focusNode(context: *anyopaque) ?*ui.Node {
        const self: *ContentHoverWidget = @ptrCast(@alignCast(context));
        return self.root;
    }

    fn isFocusedCallback(context: *anyopaque) bool {
        const self: *ContentHoverWidget = @ptrCast(@alignCast(context));
        return self.focused;
    }

    fn build(context: *anyopaque, doc: *ui.Document) !*ui.Node {
        const self: *ContentHoverWidget = @ptrCast(@alignCast(context));
        const rendered = self.rendered orelse return error.NoRenderedHover;

        const widget = try base_hover.HoverWidget.build(doc, .{
            .root_width = self.widget_width -| border_width * 2,
            .root_height = self.widget_height -| border_width * 2,
            .border = border_width,
            .content_width = self.content_width,
            .content_rows = self.content_rows,
            .visible_rows = self.visible_rows,
            .scroll_top = self.scroll_top,
            .scrollbar = self.show_scrollbar,
        }, self.theme);
        const root = widget.containerDomNode;
        try root.addClass(hover_css.Class.monaco_hover);
        if (self.focused) try root.addClass(hover_css.Class.focused);
        root.asElement().focusable = true;
        try root.addEventListener(.{ .context = self, .key_down = onKey });
        try root.addEventListener(.{ .context = self, .wheel = onWheel });
        try root.addEventListener(.{ .context = self, .focus = onFocus, .blur = onBlur });
        self.root = root;
        _ = try rendered.build(doc, widget.contentsDomNode, self.content_width, 0);
        return root;
    }

    fn onWheel(context: ?*anyopaque, event: *ui.MouseEvent) void {
        const self: *ContentHoverWidget = @ptrCast(@alignCast(context orelse return));
        if (event.delta_y == 0) return;
        event.preventDefault();
        event.stopPropagation();
        self.scrollBy(@as(isize, @intCast(event.delta_y)));
    }

    fn onKey(context: ?*anyopaque, event: *ui.KeyEvent) void {
        const self: *ContentHoverWidget = @ptrCast(@alignCast(context orelse return));
        event.stopPropagation();
        switch (event.key) {
            .escape => {
                event.preventDefault();
                self.dismiss();
            },
            .up => {
                event.preventDefault();
                self.scrollBy(-1);
            },
            .down => {
                event.preventDefault();
                self.scrollBy(1);
            },
            .page_up => {
                event.preventDefault();
                self.pageUp();
            },
            .page_down => {
                event.preventDefault();
                self.pageDown();
            },
            .home => {
                event.preventDefault();
                self.goToTop();
            },
            .end => {
                event.preventDefault();
                self.goToBottom();
            },
            .tab, .backtab => {
                // There are no focusable hover actions in the terminal port;
                // Tab hands the keyboard back to the editor without closing
                // the hover, matching upstream's focus-out behavior.
                event.preventDefault();
                self.focused = false;
                self.publishState();
                self.host.focus_editor(self.host.context);
            },
            else => {},
        }
    }

    fn onFocus(context: ?*anyopaque, event: *ui.FocusEvent) void {
        _ = event;
        const self: *ContentHoverWidget = @ptrCast(@alignCast(context orelse return));
        self.focused = true;
        self.publishState();
        self.host.request_frame(self.host.context);
    }

    fn onBlur(context: ?*anyopaque, event: *ui.FocusEvent) void {
        _ = event;
        const self: *ContentHoverWidget = @ptrCast(@alignCast(context orelse return));
        self.focused = false;
        self.publishState();
        self.host.request_frame(self.host.context);
    }
};
