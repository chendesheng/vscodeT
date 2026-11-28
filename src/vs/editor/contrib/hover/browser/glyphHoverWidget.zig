// Port of `src/vs/editor/contrib/hover/browser/glyphHoverWidget.ts`.
// The widget owns the delayed HoverOperation, Markdown rendering and overlay
// lifecycle. Browser pixel placement is rounded to editor-relative cells;
// the shared overlay part performs the final clipping and hit testing.
const std = @import("std");
const ui = @import("ui");
const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const View = @import("../../../browser/widget/codeEditor/terminalEditorView.zig").IEditorView;
const Position = @import("../../../common/core/position.zig").Position;
const editorBrowser = @import("../../../browser/editorBrowser.zig");
const markdown = @import("../../../common/markdown/markdownTerminalRenderer.zig");
const markdown_rows = @import("markdownHoverParticipant.zig");
const hover = @import("hoverOperation.zig");
const computer = @import("glyphHoverComputer.zig");
const Options = computer.GlyphHoverComputerOptions;
const Message = computer.IHoverMessage;
const MouseEvent = @import("hoverTypes.zig").EditorMouseEvent;
const DeadlineTimer = @import("contentHoverController.zig").DeadlineTimer;
const hover_css = @import("hover_css.zig");
const base_hover = @import("../../../../base/browser/ui/hover/hoverWidget.zig");
const Theme = base_hover.Theme;
const WindowQueue = @import("../../../../base/common/windowDispatch.zig").Queue;

pub const GlyphHoverWidget = struct {
    pub const ID = "editor.contrib.modesGlyphHoverWidget";
    allocator: std.mem.Allocator,
    editor: *Editor,
    view: ?*View = null,
    operation: hover.HoverOperation(Options, Message),
    timer: DeadlineTimer = .{},
    computer_arena: std.heap.ArenaAllocator,
    render_arena: std.heap.ArenaAllocator,
    contents: []const markdown.Content = &.{},
    options: ?Options = null,
    theme: Theme = .{},
    code_background: ?ui.Color = null,
    visible: bool = false,
    left: usize = 0,
    top: usize = 0,
    width_cells: usize = 0,
    height_cells: usize = 0,
    border: usize = 0,
    content_width: usize = 0,
    content_rows: usize = 0,
    visible_rows: usize = 0,
    scroll_top: usize = 0,
    scrollbar: bool = false,

    pub fn init(allocator: std.mem.Allocator, editor: *Editor) !*GlyphHoverWidget {
        const self = try allocator.create(GlyphHoverWidget);
        self.* = .{ .allocator = allocator, .editor = editor, .timer = .{ .io = editor.clockIo() }, .operation = undefined, .computer_arena = .init(allocator), .render_arena = .init(allocator) };
        self.operation = .init(allocator, .{ .context = self, .compute_sync = computeSync }, self.timer.interface(), withResult, self);
        return self;
    }

    pub fn deinit(self: *GlyphHoverWidget) void {
        self.unbindHost();
        self.operation.deinit();
        self.render_arena.deinit();
        self.computer_arena.deinit();
        self.allocator.destroy(self);
    }

    pub fn bindHost(self: *GlyphHoverWidget, view: *View) !void {
        if (self.view == view) return;
        self.unbindHost();
        try view.addOverlayWidget(self.interface());
        self.view = view;
    }

    pub fn unbindHost(self: *GlyphHoverWidget) void {
        self.hide();
        if (self.view) |view| view.removeOverlayWidget(ID) catch {};
        self.view = null;
    }

    pub fn attachWindow(self: *GlyphHoverWidget, window: *WindowQueue) void {
        self.timer.attachWindow(window);
    }

    pub fn setDelay(self: *GlyphHoverWidget, delay: u64) void {
        self.operation.hover_time_ms = delay;
    }

    pub fn setTheme(self: *GlyphHoverWidget, theme: Theme, code_background: ?ui.Color) void {
        self.theme = theme;
        self.code_background = code_background;
        self.invalidate();
    }

    pub fn showsOrWillShow(self: *GlyphHoverWidget, event: MouseEvent) bool {
        const position = event.target.position orelse return false;
        const lane: computer.LaneOrLineNumber = switch (event.target.type) {
            .gutter_line_numbers => .line_no,
            .gutter_glyph_margin => blk: {
                const detail = event.target.detail orelse return false;
                if (detail != .glyph_margin) return false;
                break :blk .{ .lane = detail.glyph_margin.glyphMarginLane orelse return false };
            },
            else => return false,
        };
        const options: Options = .{ .lineNumber = position.lineNumber, .laneOrLine = lane };
        if (self.options) |current| if (std.meta.eql(current, options)) return true;
        self.hide();
        self.options = options;
        self.operation.start(.delayed, options);
        return true;
    }

    pub fn onModelDecorationsChanged(self: *GlyphHoverWidget) void {
        if (!self.visible) return;
        const options = self.options orelse return;
        self.operation.cancel();
        self.operation.start(.delayed, options);
    }

    pub fn hide(self: *GlyphHoverWidget) void {
        self.options = null;
        self.operation.cancel();
        if (!self.visible) return;
        self.visible = false;
        self.width_cells = 0;
        self.height_cells = 0;
        self.contents = &.{};
        _ = self.render_arena.reset(.retain_capacity);
        self.invalidate();
    }

    pub fn contains(self: *const GlyphHoverWidget, x: usize, y: usize) bool {
        return self.visible and x >= self.left and x < self.left + self.width_cells and y >= self.top and y < self.top + self.height_cells;
    }

    fn computeSync(context: *anyopaque, options: *const Options) ![]const Message {
        const self: *GlyphHoverWidget = @ptrCast(@alignCast(context));
        const model = self.editor.getModel() orelse return &.{};
        _ = self.computer_arena.reset(.retain_capacity);
        const a = self.computer_arena.allocator();
        const messages = try computer.GlyphHoverComputer.computeSync(a, model, options.*);
        if (messages.len != 0 or options.laneOrLine != .lane) return messages;
        // Upstream glyph widgets with their own managed hover (e.g. diff
        // revert buttons) have a separate tooltip, not a model decoration.
        // The terminal's glyph cell exposes that same presentation title.
        const view = self.view orelse return messages;
        if (view.terminal_view_host.glyphWidgetTooltipAt(options.lineNumber, options.laneOrLine.lane)) |title| {
            const results = try a.alloc(Message, 1);
            results[0] = .{ .value = try a.dupe(u8, title) };
            return results;
        }
        return messages;
    }

    fn withResult(context: *anyopaque, result: hover.HoverResult(Options, Message)) void {
        const self: *GlyphHoverWidget = @ptrCast(@alignCast(context));
        if (result.value.len == 0) {
            self.hide();
            return;
        }
        _ = self.render_arena.reset(.retain_capacity);
        const a = self.render_arena.allocator();
        var parsed: std.ArrayList(markdown.Content) = .empty;
        for (result.value) |message| {
            const content = markdown.parseWithOptions(a, self.editor.clockIo(), message.value, .{
                .code_fence_fallback_language = if (self.editor.getModel()) |model| model.getLanguageId() else "plaintext",
                .code_background = self.code_background,
            }) catch continue;
            parsed.append(a, content) catch {};
        }
        if (parsed.items.len == 0) {
            self.hide();
            return;
        }
        self.contents = parsed.items;
        self.options = result.options;
        self.visible = true;
        self.scroll_top = 0;
        self.invalidate();
    }

    fn invalidate(self: *GlyphHoverWidget) void {
        if (self.view) |view| view.invalidate();
    }

    fn id(_: *anyopaque) []const u8 {
        return ID;
    }

    fn preference(_: *anyopaque) editorBrowser.OverlayWidgetPositionPreference {
        return .top_left_corner; // explicit coordinates below, like upstream's null preference
    }

    fn width(context: *anyopaque, cols: usize) usize {
        const self: *GlyphHoverWidget = @ptrCast(@alignCast(context));
        const options = self.options orelse return 0;
        if (!self.visible or cols == 0) return 0;
        const left = self.editor.gutterGlyphWidth() + if (options.laneOrLine == .line_no) self.editor.gutterNumberWidth() else 0;
        const max_width = cols -| left;
        const editor_height = self.editor.textHeight();
        if (max_width == 0 or editor_height == 0) return 0;
        self.border = if (max_width > 2 and editor_height > 2) 1 else 0;
        const border_cells = self.border * 2;
        const max_content_width = max_width -| border_cells;
        self.content_width = @min(max_content_width, markdown_rows.measureMarkdownContents(self.contents, max_content_width));
        self.content_rows = markdown_rows.heightMarkdownContents(self.allocator, self.contents, self.content_width);
        const max_rows = editor_height -| border_cells;
        self.visible_rows = @min(self.content_rows, max_rows);
        self.scrollbar = self.content_rows > max_rows and max_content_width > 1;
        if (self.scrollbar) {
            self.content_width = @min(self.content_width, max_content_width - 1);
            self.content_rows = markdown_rows.heightMarkdownContents(self.allocator, self.contents, self.content_width);
            self.visible_rows = @min(self.content_rows, max_rows);
        }
        self.scroll_top = @min(self.scroll_top, self.content_rows -| self.visible_rows);
        self.width_cells = self.content_width + border_cells + @intFromBool(self.scrollbar);
        self.height_cells = self.visible_rows + border_cells;
        return self.width_cells;
    }

    fn height(context: *anyopaque) usize {
        const self: *GlyphHoverWidget = @ptrCast(@alignCast(context));
        return if (self.visible) self.height_cells else 0;
    }

    fn coordinates(context: *anyopaque, cols: usize, editor_height: usize, widget_width: usize, widget_height: usize) ?editorBrowser.OverlayWidgetCoordinates {
        const self: *GlyphHoverWidget = @ptrCast(@alignCast(context));
        const options = self.options orelse return null;
        const view_line = self.editor.viewPositionOfModelPosition(Position.init(options.lineNumber, 1)).lineNumber;
        const row = self.editor.visibleRowOfViewLine(view_line) orelse return null;
        self.left = @min(self.editor.gutterGlyphWidth() + if (options.laneOrLine == .line_no) self.editor.gutterNumberWidth() else 0, cols -| widget_width);
        self.top = @min(row -| ((widget_height -| 1) / 2), editor_height -| widget_height);
        return .{ .left = self.left, .top = self.top };
    }

    fn build(context: *anyopaque, doc: *ui.Document) !*ui.Node {
        const self: *GlyphHoverWidget = @ptrCast(@alignCast(context));
        const widget = try base_hover.HoverWidget.build(doc, .{
            .root_width = self.width_cells,
            .root_height = self.height_cells,
            .border = self.border,
            .content_width = self.content_width,
            .content_rows = self.content_rows,
            .visible_rows = self.visible_rows,
            .scroll_top = self.scroll_top,
            .scrollbar = self.scrollbar,
        }, self.theme);
        try widget.containerDomNode.addClass(hover_css.Class.monaco_hover);
        try widget.containerDomNode.addEventListener(.{ .context = self, .wheel = onWheel });
        _ = try markdown_rows.buildMarkdownContents(self.contents, doc, widget.contentsDomNode, self.content_width, 0);
        return widget.containerDomNode;
    }

    fn onWheel(context: ?*anyopaque, event: *ui.MouseEvent) void {
        const self: *GlyphHoverWidget = @ptrCast(@alignCast(context orelse return));
        if (!self.scrollbar or event.delta_y == 0) return;
        const next = @max(0, @as(isize, @intCast(self.scroll_top)) + @as(isize, @intCast(event.delta_y)));
        self.scroll_top = @min(@as(usize, @intCast(next)), self.content_rows -| self.visible_rows);
        event.preventDefault();
        event.stopPropagation();
        self.invalidate();
    }

    fn focusNode(_: *anyopaque) ?*ui.Node {
        return null;
    }
    fn focused(_: *anyopaque) bool {
        return false;
    }

    pub fn interface(self: *GlyphHoverWidget) editorBrowser.IOverlayWidget {
        return .{ .context = self, .get_id = id, .get_position = preference, .get_position_coordinates = coordinates, .width = width, .height = height, .build = build, .focus_node = focusNode, .is_focused = focused };
    }
};
