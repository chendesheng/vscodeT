// Port of `src/vs/editor/contrib/zoneWidget/browser/zoneWidget.ts`.
// A retained ViewZone contains the frame/child view directly, instead of a
// browser placeholder plus an independently positioned DOM overlay. Its tracked
// model anchor, show/update/hide and resize contracts remain the same.
const std = @import("std");
const ui = @import("ui");
const browser = @import("../../../browser/editorBrowser.zig");
const view_mod = @import("../../../browser/widget/codeEditor/terminalEditorView.zig");
const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const Position = @import("../../../common/core/position.zig").Position;
const Range = @import("../../../common/core/range.zig").Range;
const model_mod = @import("../../../common/model.zig");
const css = @import("zoneWidget_css.zig");

pub const ZoneWidget = struct {
    allocator: std.mem.Allocator,
    editor: *Editor,
    view: *view_mod.IEditorView,
    delegate: Delegate,
    options: Options,
    zone_id: ?[]const u8 = null,
    anchor: Position = Position.init(1, 1),
    height: usize = 0,
    top: f64 = -1000000,
    left: usize = 0,
    width: usize = 0,
    marker: []u64 = &.{},
    marker_options: model_mod.ModelDecorationOptions = model_mod.ModelDecorationOptions.init("zone-widget-position", .NeverGrowsWhenTypingAtEdges),
    content_listener: ?usize = null,
    resize: ?struct { start_y: usize, height: usize } = null,
    frame_color: ui.Color = .{ .r = 0, .g = 122, .b = 204 },

    pub const Options = struct { show_arrow: bool = true, show_frame: bool = true, is_accessible: bool = false, is_resizeable: bool = false, keep_editor_selection: bool = false, ordinal: ?i32 = null, show_in_hidden_areas: bool = false };
    pub const Delegate = struct {
        context: *anyopaque,
        build: *const fn (*anyopaque, *ui.Node, browser.IViewZone.RenderInfo) anyerror!void,
        update: *const fn (*anyopaque, *ui.Node, browser.IViewZone.RenderInfo) anyerror!void,
        before_remove: ?*const fn (*anyopaque) void = null,
        on_top: ?*const fn (*anyopaque, f64) void = null,
    };

    pub fn init(self: *ZoneWidget, allocator: std.mem.Allocator, editor: *Editor, view: *view_mod.IEditorView, options: Options, delegate: Delegate) !void {
        self.* = .{ .allocator = allocator, .editor = editor, .view = view, .delegate = delegate, .options = options };
        self.content_listener = try editor.model.onDidChangeContentWithContextId(self, onContent);
    }

    pub fn deinit(self: *ZoneWidget) void {
        if (self.content_listener) |id| self.editor.model.removeDidChangeContentListener(id);
        self.hide();
    }

    fn setMarker(self: *ZoneWidget, anchor: Position) !void {
        const next = try self.editor.model.deltaDecorations(self.marker, &.{.{ .range = Range.init(anchor.lineNumber, anchor.column, anchor.lineNumber, anchor.column), .options = &self.marker_options }}, 0);
        self.allocator.free(self.marker);
        self.marker = next;
    }

    pub fn position(self: *ZoneWidget) ?Position {
        if (self.marker.len == 0) return null;
        const range = self.editor.model.getDecorationRange(self.marker[0]) orelse return null;
        return range.getStartPosition();
    }

    pub fn show(self: *ZoneWidget, anchor: Position, height: usize) !void {
        const validated = self.editor.model.validatePosition(anchor);
        self.anchor = validated;
        self.height = @max(1, @min(height, @max(12, self.editor.textHeight() * 4 / 5)));
        try self.setMarker(validated);
        try self.refresh();
        if (!self.options.keep_editor_selection) try self.editor.setCursorPosition(validated);
        _ = self.editor.revealLine(validated.lineNumber, .CenterIfOutsideViewport);
        const view_position = self.editor.viewPositionOfModelPosition(validated);
        const top: usize = @intFromFloat(self.editor.viewLayout().getVerticalOffsetAfterLineNumber(view_position.lineNumber, false));
        const end = top + self.height;
        if (end > self.editor.scrollTop() + self.editor.textHeight()) _ = self.editor.setScrollTop(@min(top, end -| self.editor.textHeight()));
    }

    pub fn updatePositionAndHeight(self: *ZoneWidget, anchor: Position, height: ?usize) !void {
        if (self.zone_id == null) return;
        self.anchor = self.editor.model.validatePosition(anchor);
        if (height) |rows| self.height = @max(1, rows);
        try self.setMarker(self.anchor);
        try self.refresh();
    }

    pub fn refresh(self: *ZoneWidget) !void {
        try self.view.viewZones().changeViewZones(self, apply);
        self.view.invalidate();
    }

    fn apply(self: *ZoneWidget, accessor: browser.IViewZoneChangeAccessor) !void {
        const zone: browser.IViewZone = .{ .after_line_number = self.anchor.lineNumber, .after_column = self.anchor.column, .height_in_lines = self.height, .ordinal = self.options.ordinal, .show_in_hidden_areas = self.options.show_in_hidden_areas, .suppress_mouse_down = true, .full_editor_width = true, .context = self, .build = build, .update = update, .on_before_node_removed = beforeRemove, .on_dom_node_top = onTop };
        if (self.zone_id) |id| try accessor.layoutZone(id, zone) else self.zone_id = try accessor.addZone(zone);
    }

    pub fn hide(self: *ZoneWidget) void {
        if (self.zone_id != null) self.view.viewZones().changeViewZones(self, remove) catch {};
        const ids = self.editor.model.deltaDecorations(self.marker, &.{}, 0) catch &.{};
        self.allocator.free(ids);
        self.allocator.free(self.marker);
        self.marker = &.{};
        self.resize = null;
        self.top = -1000000;
        self.view.invalidate();
    }
    fn remove(self: *ZoneWidget, accessor: browser.IViewZoneChangeAccessor) !void {
        if (self.zone_id) |id| try accessor.removeZone(id);
        self.zone_id = null;
    }

    fn onContent(_: @import("../../../common/textModelEvents.zig").InternalModelContentChangeEvent, self: *ZoneWidget) !void {
        const anchor = self.position() orelse return;
        if (self.anchor.equals(anchor)) return;
        self.anchor = anchor;
        try self.refresh();
    }

    fn build(context: ?*anyopaque, doc: *ui.Document, info: browser.IViewZone.RenderInfo) !*ui.Node {
        const self: *ZoneWidget = @ptrCast(@alignCast(context.?));
        const root = try doc.createElement(.div);
        errdefer doc.destroy(root);
        try root.addClass(css.Class.zone_widget);
        root.setStyle(.{ .width = .{ .percent = 100 }, .height = .{ .percent = 100 } });
        try root.setAttribute("role", "presentation");
        if (!self.options.is_accessible) try root.setAttribute("aria-hidden", "true");
        const container = try doc.createElement(.div);
        try container.addClass(css.Class.zone_widget_container);
        container.setStyle(.{ .width = .{ .percent = 100 }, .height = .{ .percent = 100 } });
        _ = try root.appendChild(container);
        self.left = info.left;
        self.width = info.width;
        errdefer if (self.delegate.before_remove) |notify| notify(self.delegate.context);
        try self.delegate.build(self.delegate.context, container, info);
        return root;
    }
    fn update(context: ?*anyopaque, root: *ui.Node, info: browser.IViewZone.RenderInfo) !void {
        const self: *ZoneWidget = @ptrCast(@alignCast(context.?));
        self.left = info.left;
        self.width = info.width;
        try self.delegate.update(self.delegate.context, root.first_child.?, info);
    }
    fn beforeRemove(context: ?*anyopaque) void {
        const self: *ZoneWidget = @ptrCast(@alignCast(context.?));
        if (self.delegate.before_remove) |notify| notify(self.delegate.context);
    }
    fn onTop(context: ?*anyopaque, top: f64) void {
        const self: *ZoneWidget = @ptrCast(@alignCast(context.?));
        self.top = top;
        if (self.delegate.on_top) |notify| notify(self.delegate.context, top);
    }

    pub fn relativeRow(self: *const ZoneWidget, x: usize, y: usize) ?usize {
        if (self.zone_id == null or x < self.left or x >= self.left + self.width) return null;
        const raw = @as(f64, @floatFromInt(y)) - self.top;
        if (raw < 0 or raw >= @as(f64, @floatFromInt(self.height))) return null;
        return @intFromFloat(raw);
    }

    pub fn handleResize(self: *ZoneWidget, event: *ui.MouseEvent) !bool {
        if (!self.options.is_resizeable) return false;
        switch (event.kind) {
            .down => {
                if (event.button != .left or self.relativeRow(event.x, event.y) != self.height -| 1) return false;
                self.resize = .{ .start_y = event.y, .height = self.height };
                return true;
            },
            .move => {
                const drag = self.resize orelse return false;
                const desired = @as(isize, @intCast(drag.height)) + @as(isize, @intCast(event.y)) - @as(isize, @intCast(drag.start_y));
                if (desired > 5 and desired < 35 and self.height != @as(usize, @intCast(desired))) {
                    self.height = @intCast(desired);
                    try self.refresh();
                }
                return true;
            },
            .up, .click => if (self.resize != null) {
                self.resize = null;
                return true;
            },
            else => {},
        }
        return false;
    }
};
