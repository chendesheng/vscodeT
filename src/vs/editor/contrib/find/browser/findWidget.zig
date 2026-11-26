// Port of `src/vs/editor/contrib/find/browser/findWidget.ts`.
//
// Terminal adaptation. The browser widget is an overlay with two input boxes,
// a replace toggle, match count, previous/next/close buttons, find options and
// replace buttons. Here it is a one- or two-row bar in the top-right corner
// with block-caret input boxes, visible clickable controls (the terminal has
// no focusable buttons) and a `Theme` bundle resolved by the host from the
// `editorWidget.*`/`input.*`/`inputOption.*` ids.
//
// Kept from upstream: open/close and replace-row state, incremental search
// while typing, Enter/Shift-Enter next/previous, Escape close, Alt-C/W/R
// option toggles, replace/replace-all, the match counter, and the visible
// replace toggle/previous/next/close/preserve-case/replace/replace-all
// controls.
// TUI-specific: the key map (documented in the README), the cell layout, and
// the absence of the browser accessibility tree. The browser sash becomes a
// draggable terminal sash. Find and replace
// input histories are kept host-side and navigated with Up/Down.
// `findOnType`, `closeOnResult`, `loop`, `seedSearchStringFromSelection` and
// history enablement are host-resolved options. The browser
// `FindWidgetViewZone` uses the shared model-anchored ViewZones part, with
// terminal cell heights rather than browser pixels. Its spacer scrolls with
// the content while the overlay remains fixed at the top-right corner.
// Ctrl-H cannot be used for replace because terminals report it as
// Backspace; the replace row is on Ctrl-R instead.

const std = @import("std");
const ui = @import("ui");
const sash_css = @import("../../../../base/browser/ui/sash/sash_css.zig");

const editorBrowser = @import("../../../browser/editorBrowser.zig");
const find_state = @import("./findState.zig");
const FindReplaceState = find_state.FindReplaceState;
const FindModel = @import("./findModel.zig").FindModel;
const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const ViewZones = @import("../../../browser/viewParts/viewZones/viewZones.zig").ViewZones;
const ViewHost = @import("../../../browser/widget/codeEditor/terminalViewHost.zig").TerminalViewHost;
const ViewEventHandler = @import("../../../common/viewEventHandler.zig").ViewEventHandler;
const view_events = @import("../../../common/viewEvents.zig");
const dispatch = @import("../../../../base/common/windowDispatch.zig");
const CursorColumns = @import("../../../common/core/cursorColumns.zig").CursorColumns;
pub const FindWidgetViewState = struct { widgetViewZoneVisible: bool, scrollTop: usize };

const Allocator = std.mem.Allocator;
const RangeType = @import("../../../common/core/range.zig").Range;

const background = ui.Color{ .r = 45, .g = 45, .b = 55 };
const foreground = ui.Color{ .r = 230, .g = 230, .b = 230 };
const dim_foreground = ui.Color{ .r = 140, .g = 140, .b = 150 };
const hover_background = ui.Color{ .r = 72, .g = 72, .b = 92 };

/// Terminal colors for the find bar. The editor layer does not import the
/// workbench theme bridge; the host resolves the upstream color ids and passes
/// this bundle, keeping the widget testable in isolation.
pub const Theme = struct {
    background: ui.Color = background,
    foreground: ui.Color = foreground,
    dim_foreground: ui.Color = dim_foreground,
    hover_background: ui.Color = hover_background,
    sash_hover_border: ?ui.Color = null,
    input_background: ui.Color = .{ .r = 30, .g = 30, .b = 35 },
    input_foreground: ui.Color = foreground,
    placeholder: ui.Color = dim_foreground,
    active_background: ui.Color = foreground,
    active_foreground: ui.Color = background,
    selection_background: ?ui.Color = null,
    selection_foreground: ?ui.Color = null,

    pub fn dark() Theme {
        return .{};
    }
};

const count_width: usize = 10;
const toggles_width: usize = 12;

const FocusField = enum { find, replace };

/// The mouse-operable controls in the bar. The terminal adaptation has no
/// focusable buttons, but they are still clickable and show a hover state.
const Control = enum {
    toggle_replace,
    match_case,
    whole_word,
    regex,
    scope,
    prev,
    next,
    close,
    preserve_case,
    replace_one,
    replace_all,
};

const control_count = 11;

pub const FindWidget = struct {
    allocator: Allocator,
    state: *FindReplaceState,
    model: ?*FindModel,

    find_input: ui.InputBox,
    replace_input: ui.InputBox,
    /// `IHistory<string>` for the find input, most-recent last.
    history: std.array_list.Managed([]u8),
    history_index: ?usize = null,
    replace_history: std.array_list.Managed([]u8),
    replace_history_index: ?usize = null,
    find_on_type: bool = true,
    close_on_result: bool = false,
    history_enabled: bool = true,
    replace_history_enabled: bool = true,
    theme: Theme = Theme.dark(),

    focused: bool = false,
    focus_field: FocusField = .find,
    widget_width: usize = 0,
    preferred_width: usize = 76,
    last_cols: usize = 0,
    resizing: bool = false,
    resize_start_x: usize = 0,
    resize_start_width: usize = 0,
    add_extra_space_on_top: bool = true,
    focus_node_value: ?*ui.Node = null,
    /// The control under the pointer last frame, for the hover style.
    hover_control: ?Control = null,
    /// This frame's bar and control nodes, used to resolve pointer targets. They
    /// are rebuilt every frame and never retained across `build`.
    bar_root: ?*ui.Node = null,
    document_root: ?*ui.Node = null,
    control_nodes: [control_count]?*ui.Node = @splat(null),

    close_context: ?*anyopaque = null,
    on_close: ?*const fn (context: ?*anyopaque) void = null,
    layout_context: ?*anyopaque = null,
    on_layout: ?*const fn (context: ?*anyopaque) void = null,
    state_listener: ?usize = null,
    zone_host: ?struct { editor: *Editor, view: *ViewHost, zones: *ViewZones } = null,
    view_zone_id: ?[]const u8 = null,
    view_zone_height: usize = 0,
    zone_transition: bool = false,
    scroll_handler: ViewEventHandler = .{},
    zone_layout_task: dispatch.Task = .{},
    pending_view_state: ?FindWidgetViewState = null,

    pub fn init(allocator: Allocator, state: *FindReplaceState, model: *FindModel) !*FindWidget {
        const self = try allocator.create(FindWidget);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .state = state,
            .model = model,
            .find_input = ui.InputBox.init(allocator),
            .replace_input = ui.InputBox.init(allocator),
            .history = std.array_list.Managed([]u8).init(allocator),
            .replace_history = std.array_list.Managed([]u8).init(allocator),
        };
        errdefer {
            self.find_input.deinit();
            self.replace_input.deinit();
            self.history.deinit();
            self.replace_history.deinit();
        }
        self.find_input.placeholder = "Find";
        self.find_input.color = foreground;
        self.find_input.placeholder_color = dim_foreground;
        self.find_input.callback_context = self;
        self.find_input.on_change = onFindChanged;

        self.replace_input.placeholder = "Replace";
        self.replace_input.color = foreground;
        self.replace_input.placeholder_color = dim_foreground;
        self.replace_input.callback_context = self;
        self.replace_input.on_change = onReplaceChanged;
        self.applyTheme();
        self.state_listener = try state.on_find_replace_state_change.listen(self, onStateChanged);

        return self;
    }

    /// Applies the host-resolved theme ids to the bar and its input boxes.
    pub fn setTheme(self: *FindWidget, theme: Theme) void {
        self.theme = theme;
        self.applyTheme();
    }

    fn applyTheme(self: *FindWidget) void {
        self.find_input.color = self.theme.input_foreground;
        self.find_input.placeholder_color = self.theme.placeholder;
        self.find_input.selection_background = self.theme.selection_background;
        self.find_input.selection_foreground = self.theme.selection_foreground;
        self.replace_input.color = self.theme.input_foreground;
        self.replace_input.placeholder_color = self.theme.placeholder;
        self.replace_input.selection_background = self.theme.selection_background;
        self.replace_input.selection_foreground = self.theme.selection_foreground;
    }

    pub fn deinit(self: *FindWidget) void {
        self.detachViewZones();
        if (self.state_listener) |listener| self.state.on_find_replace_state_change.unlisten(listener);
        for (self.history.items) |entry| self.allocator.free(entry);
        self.history.deinit();
        for (self.replace_history.items) |entry| self.allocator.free(entry);
        self.replace_history.deinit();
        self.find_input.deinit();
        self.replace_input.deinit();
        self.allocator.destroy(self);
    }

    fn recordHistory(self: *FindWidget) void {
        if (!self.history_enabled) return;
        const value = self.find_input.getValue();
        if (value.len == 0) return;
        if (self.history.items.len > 0 and
            std.mem.eql(u8, self.history.items[self.history.items.len - 1], value))
        {
            return;
        }
        const copy = self.allocator.dupe(u8, value) catch return;
        self.history.append(copy) catch {
            self.allocator.free(copy);
            return;
        };
        if (self.history.items.len > 20) {
            const oldest = self.history.orderedRemove(0);
            self.allocator.free(oldest);
        }
        self.history_index = null;
    }

    fn navigateHistory(self: *FindWidget, backwards: bool) bool {
        if (!self.history_enabled) return false;
        if (self.history.items.len == 0) return false;
        var index = self.history_index orelse self.history.items.len;
        if (backwards) {
            if (index == 0) return true;
            index -= 1;
        } else {
            if (index + 1 >= self.history.items.len) {
                self.history_index = null;
                self.find_input.clear() catch {};
                return true;
            }
            index += 1;
        }
        self.history_index = index;
        self.find_input.setValue(self.history.items[index]) catch {};
        return true;
    }

    pub fn interface(self: *FindWidget) editorBrowser.IOverlayWidget {
        return .{
            .context = self,
            .get_id = getId,
            .get_position = getPosition,
            .width = width,
            .height = height,
            .build = build,
            .focus_node = focusNode,
            .is_focused = isFocused,
            .on_before_node_removed = prepareNodeReset,
        };
    }

    pub fn open(self: *FindWidget) void {
        self.focused = true;
        self.focus_field = .find;
        self.state.change(.{ .is_revealed = true }, false, true);
    }

    pub fn openReplace(self: *FindWidget) void {
        const model = self.model orelse return;
        if (model.editor.isReadOnly()) return self.open();
        self.focused = true;
        self.focus_field = .replace;
        self.state.change(.{ .is_revealed = true, .is_replace_revealed = true }, false, true);
    }

    pub fn toggleReplace(self: *FindWidget) void {
        const model = self.model orelse return;
        if (model.editor.isReadOnly()) return;
        self.focused = true;
        self.state.change(.{
            .is_revealed = true,
            .is_replace_revealed = !self.state.is_replace_revealed,
        }, false, true);
        self.focus_field = if (self.state.is_replace_revealed) .replace else .find;
    }

    fn recordReplaceHistory(self: *FindWidget) void {
        if (!self.replace_history_enabled) return;
        const value = self.replace_input.getValue();
        if (value.len == 0) return;
        if (self.replace_history.items.len > 0 and
            std.mem.eql(u8, self.replace_history.items[self.replace_history.items.len - 1], value))
        {
            return;
        }
        const copy = self.allocator.dupe(u8, value) catch return;
        self.replace_history.append(copy) catch {
            self.allocator.free(copy);
            return;
        };
        if (self.replace_history.items.len > 20) {
            const oldest = self.replace_history.orderedRemove(0);
            self.allocator.free(oldest);
        }
        self.replace_history_index = null;
    }

    fn navigateReplaceHistory(self: *FindWidget, backwards: bool) bool {
        if (!self.replace_history_enabled) return false;
        if (self.replace_history.items.len == 0) return false;
        var index = self.replace_history_index orelse self.replace_history.items.len;
        if (backwards) {
            if (index == 0) return true;
            index -= 1;
        } else {
            if (index + 1 >= self.replace_history.items.len) {
                self.replace_history_index = null;
                self.replace_input.clear() catch {};
                return true;
            }
            index += 1;
        }
        self.replace_history_index = index;
        self.replace_input.setValue(self.replace_history.items[index]) catch {};
        return true;
    }

    pub fn close(self: *FindWidget) void {
        self.recordHistory();
        self.recordReplaceHistory();
        self.focused = false;
        self.hover_control = null;
        self.bar_root = null;
        self.state.change(.{ .is_revealed = false }, false, true);
        if (self.on_close) |callback| callback(self.close_context);
    }

    pub fn setAddExtraSpaceOnTop(self: *FindWidget, enabled: bool) void {
        if (self.add_extra_space_on_top == enabled) return;
        self.add_extra_space_on_top = enabled;
        if (enabled) self.showViewZone(true) catch {} else self.removeViewZone(true) catch {};
        self.notifyLayout();
    }

    pub fn setFindOnType(self: *FindWidget, enabled: bool) void {
        self.find_on_type = enabled;
    }

    pub fn setCloseOnResult(self: *FindWidget, enabled: bool) void {
        self.close_on_result = enabled;
    }

    pub fn setHistorySettings(self: *FindWidget, find_enabled: bool, replace_enabled: bool) void {
        self.history_enabled = find_enabled;
        self.replace_history_enabled = replace_enabled;
    }

    fn updateResize(self: *FindWidget, event: *const ui.MouseEvent) void {
        if (!self.resizing) return;
        const delta = if (event.x >= self.resize_start_x)
            self.resize_start_width -| (event.x - self.resize_start_x)
        else
            self.resize_start_width + (self.resize_start_x - event.x);
        const new_width = @max(@min(delta, self.last_cols), 20);
        if (new_width != self.preferred_width) {
            self.preferred_width = new_width;
            if (self.on_layout) |callback| callback(self.layout_context orelse return);
        }
    }

    fn finishNavigation(self: *FindWidget) void {
        if (self.close_on_result and self.state.current_match != null) self.close();
    }

    fn navigateNext(self: *FindWidget) void {
        const model = self.model orelse return;
        model.moveToNextMatch() catch |err| {
            self.report(err);
            return;
        };
        self.finishNavigation();
    }

    fn navigatePrevious(self: *FindWidget) void {
        const model = self.model orelse return;
        model.moveToPrevMatch() catch |err| {
            self.report(err);
            return;
        };
        self.finishNavigation();
    }

    /// Upstream `editor.find.addExtraSpaceOnTop` + `_getHeight()`: the find
    /// view zone occupies the widget's own rows at the top of the editor.
    pub fn viewZoneRows(self: *const FindWidget) usize {
        if (!self.state.is_revealed or !self.add_extra_space_on_top) return 0;
        return if (self.state.is_replace_revealed) 2 else 1;
    }

    pub fn attachViewZones(self: *FindWidget, editor: *Editor, view: *ViewHost, zones: *ViewZones) void {
        self.detachViewZones();
        self.zone_host = .{ .editor = editor, .view = view, .zones = zones };
        self.scroll_handler = ViewEventHandler.init(self, .{ .onScrollChanged = onScrollChanged });
        editor.addViewEventHandler(&self.scroll_handler);
        const state = self.pending_view_state;
        self.pending_view_state = null;
        if (state) |saved| {
            self.setViewState(saved);
        } else self.layoutViewZone(null) catch {};
    }

    pub fn detachViewZones(self: *FindWidget) void {
        self.zone_layout_task.schedule(null);
        const host = self.zone_host orelse return;
        host.editor.removeViewEventHandler(&self.scroll_handler);
        self.removeViewZone(false) catch {};
        self.zone_host = null;
        self.view_zone_id = null;
        self.view_zone_height = 0;
    }

    pub fn onModelDetached(self: *FindWidget) void {
        self.zone_layout_task.schedule(null);
        self.removeViewZone(false) catch {};
        self.view_zone_id = null;
        self.view_zone_height = 0;
    }

    pub fn onModelAttached(self: *FindWidget) void {
        self.layoutViewZone(null) catch {};
    }

    pub fn attachWindow(self: *FindWidget, window: *dispatch.Queue) void {
        if (self.zone_layout_task.queue == window) return;
        self.zone_layout_task.schedule(null);
        self.zone_layout_task = .{ .queue = window, .context = self, .run = onLayoutDeadline };
    }

    pub fn getViewState(self: *const FindWidget) FindWidgetViewState {
        const scroll_top = if (self.zone_host) |host| host.editor.scrollTop() else if (self.model) |model| model.editor.scrollTop() else 0;
        return .{ .widgetViewZoneVisible = self.view_zone_id != null and self.view_zone_height > scroll_top, .scrollTop = scroll_top };
    }

    pub fn setViewState(self: *FindWidget, state: ?FindWidgetViewState) void {
        const saved = state orelse return;
        if (self.zone_host == null) {
            self.pending_view_state = saved;
            return;
        }
        if (saved.widgetViewZoneVisible) self.layoutViewZone(saved.scrollTop) catch {};
    }

    fn notifyLayout(self: *FindWidget) void {
        if (self.on_layout) |callback| callback(self.layout_context);
    }

    fn onStateChanged(event: find_state.FindReplaceStateChangedEvent, self: *FindWidget) !void {
        if (event.is_revealed) {
            if (self.state.is_revealed) try self.showViewZone(self.adjustScrollOnReveal()) else try self.removeViewZone(true);
            self.notifyLayout();
        }
        if (event.is_replace_revealed) {
            try self.showViewZone(true);
            self.notifyLayout();
        }
        if (event.search_string or event.current_match) try self.layoutViewZone(null);
    }

    fn onScrollChanged(context: *anyopaque, event: *const view_events.ViewScrollChangedEvent) bool {
        const self: *FindWidget = @ptrCast(@alignCast(context));
        if (self.zone_transition or self.view_zone_id != null or self.viewZoneRows() == 0) return false;
        if (event.scrollTopChanged or self.zone_layout_task.queue == null) {
            self.layoutViewZone(null) catch {};
        } else self.zone_layout_task.post();
        return false;
    }

    fn onLayoutDeadline(context: *anyopaque, _: i64, _: bool) bool {
        const self: *FindWidget = @ptrCast(@alignCast(context));
        self.layoutViewZone(null) catch {};
        return self.view_zone_id != null;
    }

    fn positionCell(editor: *Editor, position: @import("../../../common/core/position.zig").Position) usize {
        const data = editor.viewLineData(position.lineNumber) catch return editor.gutterWidth();
        const column = @min(@max(position.column, data.minColumn), data.maxColumn);
        const visible = CursorColumns.visibleColumnFromColumn(data.content, column, editor.tabSize());
        return editor.gutterWidth() + (visible -| editor.scrollLeft());
    }

    /// Avoid covering a selected range that would intersect the fixed bar.
    /// This is the terminal-cell projection of FindWidget._reveal's
    /// scrolled-position/DOM-overlap check.
    fn adjustScrollOnReveal(self: *FindWidget) bool {
        const host = self.zone_host orelse return true;
        const editor = host.editor;
        const selection = editor.modelSelection();
        const start = editor.viewPositionOfModelPosition(selection.getStartPosition());
        const row = editor.visibleRowOfViewLine(start.lineNumber) orelse return true;
        if (row >= self.viewZoneRows()) return true;
        if (selection.startLineNumber != selection.endLineNumber) return false;
        const end = editor.viewPositionOfModelPosition(selection.getEndPosition());
        const widget_left = editor.screen_width -| @min(editor.screen_width, @max(self.preferred_width, 20));
        return positionCell(editor, start) <= widget_left and positionCell(editor, end) <= widget_left;
    }

    fn zone(self: *FindWidget, rows: usize) editorBrowser.IViewZone {
        _ = self;
        return .{ .after_line_number = 0, .height_in_lines = rows };
    }

    const ZoneUpdate = struct { widget: *FindWidget, height: usize };

    fn updateZone(update: ZoneUpdate, accessor: editorBrowser.IViewZoneChangeAccessor) !void {
        const self = update.widget;
        if (self.view_zone_id) |id| {
            try accessor.layoutZone(id, self.zone(update.height));
        } else self.view_zone_id = try accessor.addZone(self.zone(update.height));
        self.view_zone_height = update.height;
    }

    fn eraseZone(self: *FindWidget, accessor: editorBrowser.IViewZoneChangeAccessor) !void {
        if (self.view_zone_id) |id| try accessor.removeZone(id);
        self.view_zone_id = null;
        self.view_zone_height = 0;
    }

    fn layoutViewZone(self: *FindWidget, target_scroll_top: ?usize) !void {
        if (self.zone_transition or self.view_zone_id != null) return;
        const host = self.zone_host orelse return;
        const rows = self.viewZoneRows();
        if (rows == 0) return;
        self.zone_transition = true;
        defer self.zone_transition = false;
        const previous = host.editor.scrollTop();
        try host.zones.changeViewZones(ZoneUpdate{ .widget = self, .height = rows }, updateZone);
        const target = target_scroll_top orelse 0;
        _ = host.editor.setScrollTop(if (target != 0) target else previous +| rows);
    }

    fn showViewZone(self: *FindWidget, adjust_scroll: bool) !void {
        if (self.zone_transition) return;
        const host = self.zone_host orelse return;
        var rows = self.viewZoneRows();
        if (rows == 0) return;
        const old_height = self.view_zone_height;
        if (self.view_zone_id == null) {
            const padding: usize = @intFromFloat(@ceil(@max(0, host.view.options.get(.padding).top)));
            rows -|= padding;
            if (rows == 0) return;
        } else if (rows == old_height) return;
        self.zone_transition = true;
        defer self.zone_transition = false;
        const previous = host.editor.scrollTop();
        try host.zones.changeViewZones(ZoneUpdate{ .widget = self, .height = rows }, updateZone);
        if (adjust_scroll) _ = host.editor.setScrollTop(if (rows >= old_height) previous +| (rows - old_height) else previous -| (old_height - rows));
    }

    fn removeViewZone(self: *FindWidget, adjust_scroll: bool) !void {
        if (self.zone_transition or self.view_zone_id == null) return;
        const host = self.zone_host orelse return;
        self.zone_transition = true;
        defer self.zone_transition = false;
        const previous = host.editor.scrollTop();
        const old_height = self.view_zone_height;
        try host.zones.changeViewZones(self, eraseZone);
        if (adjust_scroll) _ = host.editor.setScrollTop(previous -| old_height);
    }

    fn getId(context: *anyopaque) []const u8 {
        _ = context;
        return "editor.widget.findWidget";
    }

    fn getPosition(context: *anyopaque) editorBrowser.OverlayWidgetPositionPreference {
        _ = context;
        return .top_right_corner;
    }

    fn width(context: *anyopaque, cols: usize) usize {
        const self: *FindWidget = @ptrCast(@alignCast(context));
        if (!self.state.is_revealed) return 0;
        self.last_cols = cols;
        self.widget_width = @min(cols, @max(self.preferred_width, 20));
        return self.widget_width;
    }

    fn height(context: *anyopaque) usize {
        const self: *FindWidget = @ptrCast(@alignCast(context));
        if (!self.state.is_revealed) return 0;
        return if (self.state.is_replace_revealed) 2 else 1;
    }

    fn isFocused(context: *anyopaque) bool {
        const self: *FindWidget = @ptrCast(@alignCast(context));
        return self.focused;
    }

    fn focusNode(context: *anyopaque) ?*ui.Node {
        const self: *FindWidget = @ptrCast(@alignCast(context));
        return self.focus_node_value;
    }

    fn documentListener(self: *FindWidget) ui.Listener {
        return .{ .context = self, .capture = true, .mouse_move = onDocumentMove, .mouse_up = onDocumentUp };
    }

    fn prepareNodeReset(context: *anyopaque, leaving_document: bool) void {
        const self: *FindWidget = @ptrCast(@alignCast(context));
        self.bar_root = null;
        self.focus_node_value = null;
        self.control_nodes = @splat(null);
        self.find_input.node = null;
        self.find_input.node_document = null;
        self.replace_input.node = null;
        self.replace_input.node_document = null;
        if (leaving_document) {
            if (self.document_root) |root| _ = root.removeEventListener(self.documentListener());
            self.document_root = null;
            self.resizing = false;
            self.hover_control = null;
        }
    }

    fn build(context: *anyopaque, doc: *ui.Document) !*ui.Node {
        const self: *FindWidget = @ptrCast(@alignCast(context));
        return self.buildBar(doc);
    }

    fn buildBar(self: *FindWidget, doc: *ui.Document) !*ui.Node {
        const width_cells = self.widget_width;
        self.bar_root = null;
        self.control_nodes = @splat(null);
        const root = try doc.createElement(.div);
        root.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = 0 },
            .top = .{ .cells = 0 },
            .width = .{ .percent = 100 },
            .height = .{ .percent = 100 },
            .display = .flex,
            .flex_direction = .column,
            .overflow = .hidden,
            .background = self.theme.background,
            .color = self.theme.foreground,
        });
        try root.addEventListener(.{
            .context = self,
            .capture = true,
            .key_down = onKeyCapture,
        });
        try root.addEventListener(.{ .context = self, .mouse_move = onBarMove });
        self.bar_root = root;
        // Motion outside the bar never reaches a bar listener; the document
        // root clears the stale hover so a control does not stay highlighted.
        if (doc.root) |doc_root| {
            if (self.document_root == null) {
                try doc_root.addEventListener(self.documentListener());
                self.document_root = doc_root;
            }
        }

        // The find row mirrors upstream's `.find-part`: replace toggle, find
        // input, match count, previous/next, the Aa/ab/.*/Sel toggles and the
        // close button. Narrow terminals drop the trailing action group.
        const wide = width_cells >= 44;
        const medium = width_cells >= 32;
        var fixed = @as(usize, 10); // toggle + label + close + gaps + padding
        if (medium) fixed += 16; // count + prev + next + their gaps
        if (wide) fixed += 13; // toggles + gap
        const find_row = try appendRow(doc, root, false);
        self.appendControl(
            doc,
            find_row,
            if (self.state.is_replace_revealed) "\u{25BE}" else "\u{25B8}",
            1,
            .toggle_replace,
            self.state.is_replace_revealed,
        );
        _ = try appendLabel(doc, find_row, "Find", 4, self.theme.dim_foreground);
        const find_width = @max(width_cells -| fixed, 1);
        const find_node = try self.buildInput(
            doc,
            find_row,
            &self.find_input,
            find_width,
            self.focused and self.focus_field == .find,
        );
        try find_node.addEventListener(.{
            .context = self,
            .focus = onFindFocus,
            .blur = onBlur,
        });

        var replace_node: ?*ui.Node = null;
        if (medium) {
            var count_buffer: [16]u8 = undefined;
            const count = formatCount(&count_buffer, self.state);
            _ = try appendRightAligned(doc, find_row, count, count_width, .{
                .color = self.theme.dim_foreground,
            });
            self.appendControl(doc, find_row, "\u{2191}", 1, .prev, false);
            self.appendControl(doc, find_row, "\u{2193}", 1, .next, false);
        }
        if (wide) {
            const toggles = try appendToggleGroup(doc, find_row);
            self.appendToggle(doc, toggles, "Aa", self.state.matchCase(), .match_case);
            self.appendToggle(doc, toggles, "ab", self.state.wholeWord(), .whole_word);
            self.appendToggle(doc, toggles, ".*", self.state.isRegex(), .regex);
            self.appendToggle(doc, toggles, "Sel", self.state.search_scope != null, .scope);
        }
        self.appendControl(doc, find_row, "\u{00D7}", 1, .close, false);

        if (self.state.is_replace_revealed) {
            // `.replace-part` is the second flex row.
            const replace_row = try appendRow(doc, root, true);
            _ = try appendLabel(doc, replace_row, "Repl", 4, self.theme.dim_foreground);
            const replace_width = @max(@as(usize, 1), width_cells -| 16);
            replace_node = try self.buildInput(
                doc,
                replace_row,
                &self.replace_input,
                replace_width,
                self.focused and self.focus_field == .replace,
            );
            try replace_node.?.addEventListener(.{
                .context = self,
                .focus = onReplaceFocus,
                .blur = onBlur,
            });
            self.appendControl(doc, replace_row, "AB", 2, .preserve_case, self.state.preserveCase());
            self.appendControl(doc, replace_row, "\u{21C4}", 1, .replace_one, false);
            self.appendControl(doc, replace_row, "All", 3, .replace_all, false);
        }

        const sash = try doc.createElement(.div);
        try sash.setClasses(&.{ sash_css.Class.sash, sash_css.Class.vertical });
        const sash_highlight = sash_css.hoverStyle(self.theme.sash_hover_border);
        sash.setStyle(.{
            .left = .{ .cells = 0 },
            .background = if (self.resizing) sash_highlight.background else null,
        });
        sash.setHoverStyle(sash_highlight);
        try sash.addEventListener(.{ .context = self, .mouse_down = onSashDown });
        _ = try root.appendChild(sash);

        self.focus_node_value = if (self.focus_field == .replace)
            (replace_node orelse find_node)
        else
            find_node;

        return root;
    }

    fn buildInput(
        self: *FindWidget,
        doc: *ui.Document,
        parent: *ui.Node,
        input: *ui.InputBox,
        width_cells: usize,
        focused: bool,
    ) !*ui.Node {
        // The input box itself remains a zero-origin, 100%-wide absolute child;
        // the relative flex holder owns the cell width flex computes for it.
        const holder = try doc.createElement(.div);
        holder.setStyle(.{
            .position = .relative,
            .height = .{ .cells = 1 },
            .white_space = .pre,
            .flex_grow = 1,
            .flex_basis = .{ .cells = 0 },
            .overflow = .hidden,
            .background = self.theme.input_background,
        });

        input.focused = focused;
        const node = try input.build(doc, width_cells);
        _ = try holder.appendChild(node);
        _ = try parent.appendChild(holder);
        return node;
    }

    fn appendToggle(
        self: *FindWidget,
        doc: *ui.Document,
        parent: *ui.Node,
        text: []const u8,
        active: bool,
        control: Control,
    ) void {
        self.appendControl(doc, parent, text, text.len, control, active);
    }

    /// One clickable control. The terminal bar has no focusable buttons; the
    /// same actions are reachable from the keyboard and every control shows a
    /// hover/active state.
    fn appendControl(
        self: *FindWidget,
        doc: *ui.Document,
        parent: *ui.Node,
        text: []const u8,
        width_cells: usize,
        control: Control,
        active: bool,
    ) void {
        const hovered = self.hover_control != null and self.hover_control.? == control;
        const node = doc.createText(text) catch return;
        node.setStyle(.{
            .color = if (active)
                self.theme.active_foreground
            else if (hovered)
                self.theme.foreground
            else
                self.theme.dim_foreground,
            .background = if (active)
                self.theme.active_background
            else if (hovered)
                self.theme.hover_background
            else
                null,
            .bold = active,
        });
        const holder = doc.createElement(.div) catch return;
        holder.setStyle(.{
            .width = .{ .cells = @floatFromInt(width_cells) },
            .height = .{ .cells = 1 },
            .white_space = .pre,
            .flex_shrink = 0,
            .pointer = .pointer,
            .display = .flex,
            .justify_content = .center,
        });
        _ = holder.appendChild(node) catch return;
        _ = parent.appendChild(holder) catch {};
        self.control_nodes[@backingInt(control)] = holder;
        holder.addEventListener(.{
            .context = self,
            .mouse_down = onControlDown,
            .click = onControlClick,
        }) catch {};
    }

    fn controlFor(self: *const FindWidget, target: ?*ui.Node) ?Control {
        var current = target;
        while (current) |node| : (current = node.parent) {
            for (self.control_nodes, 0..) |maybe_control, index| {
                const control_node = maybe_control orelse continue;
                if (control_node == node) return @fromBackingInt(@intCast(index));
            }
        }
        return null;
    }

    fn activateControl(self: *FindWidget, control: Control) void {
        const model = self.model orelse return;
        switch (control) {
            .toggle_replace => self.toggleReplace(),
            .match_case => self.state.change(.{ .match_case = !self.state.matchCase() }, true, true),
            .whole_word => self.state.change(.{ .whole_word = !self.state.wholeWord() }, true, true),
            .regex => self.state.change(.{ .is_regex = !self.state.isRegex() }, true, true),
            .scope => self.toggleSearchScope(),
            .prev => self.navigatePrevious(),
            .next => self.navigateNext(),
            .close => self.close(),
            .preserve_case => self.state.change(.{ .preserve_case = !self.state.preserveCase() }, true, true),
            .replace_one => model.replace() catch |err| self.report(err),
            .replace_all => model.replaceAll() catch |err| self.report(err),
        }
    }

    fn handleKey(self: *FindWidget, event: *ui.KeyEvent) bool {
        const model = self.model orelse return false;
        switch (event.key) {
            .escape => {
                self.close();
                return true;
            },
            .tab, .backtab => {
                if (model.editor.isReadOnly()) return false;
                self.focus_field = if (self.focus_field == .find) .replace else .find;
                if (self.focus_field == .replace and !self.state.is_replace_revealed) {
                    self.state.change(.{ .is_replace_revealed = true }, false, true);
                }
                return true;
            },
            .enter => {
                self.recordHistory();
                self.recordReplaceHistory();
                if (!self.find_on_type) {
                    self.state.change(.{ .search_string = self.find_input.getValue() }, true, true);
                }
                if (event.mods.ctrl and event.mods.alt) {
                    model.replaceAll() catch |err| self.report(err);
                } else if (event.mods.alt) {
                    model.selectAllMatches() catch |err| self.report(err);
                } else if (event.mods.ctrl) {
                    model.replace() catch |err| self.report(err);
                } else if (event.mods.shift) {
                    self.navigatePrevious();
                } else if (self.focus_field == .replace) {
                    model.replace() catch |err| self.report(err);
                } else {
                    self.navigateNext();
                }
                return true;
            },
            .up => {
                if (self.focus_field == .find and self.navigateHistory(true)) return true;
                if (self.focus_field == .replace and self.navigateReplaceHistory(true)) return true;
                self.navigatePrevious();
                return true;
            },
            .down => {
                if (self.focus_field == .find and self.navigateHistory(false)) return true;
                if (self.focus_field == .replace and self.navigateReplaceHistory(false)) return true;
                self.navigateNext();
                return true;
            },
            .char => |ch| {
                if (event.mods.ctrl and !event.mods.alt and (ch == 'r' or ch == 'R')) {
                    self.toggleReplace();
                    return true;
                }
                if (event.mods.alt and !event.mods.ctrl) {
                    switch (ch) {
                        'c', 'C' => {
                            self.state.change(.{ .match_case = !self.state.matchCase() }, true, true);
                            return true;
                        },
                        'w', 'W' => {
                            self.state.change(.{ .whole_word = !self.state.wholeWord() }, true, true);
                            return true;
                        },
                        'r', 'R' => {
                            self.state.change(.{ .is_regex = !self.state.isRegex() }, true, true);
                            return true;
                        },
                        'p', 'P' => {
                            self.state.change(.{ .preserve_case = !self.state.preserveCase() }, true, true);
                            return true;
                        },
                        'l', 'L' => {
                            self.toggleSearchScope();
                            return true;
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
        return false;
    }

    fn toggleSearchScope(self: *FindWidget) void {
        if (self.state.search_scope != null) {
            self.state.change(.{ .search_scope = .none }, true, true);
            return;
        }

        const model = self.model orelse return;
        const selections = model.editor.getSelections() catch return;
        defer self.allocator.free(selections);
        if (selections.len == 0) return;

        const ranges = self.allocator.alloc(RangeType, selections.len) catch return;
        defer self.allocator.free(ranges);
        var count: usize = 0;
        for (selections) |selection| {
            if (selection.isEmpty()) continue;
            ranges[count] = RangeType.init(
                selection.startLineNumber,
                selection.startColumn,
                selection.endLineNumber,
                selection.endColumn,
            );
            count += 1;
        }
        if (count == 0) return;

        self.state.change(.{ .search_scope = .{ .ranges = ranges[0..count] } }, true, true);
    }

    fn report(self: *FindWidget, err: anyerror) void {
        const model = self.model orelse return;
        model.editor.setMessage("find failed: {s}", .{@errorName(err)});
    }
};

fn formatCount(buffer: *[16]u8, state: *FindReplaceState) []const u8 {
    if (state.search_string.len == 0) return "0/0";
    if (state.matches_count == 0) return "No results";
    return std.fmt.bufPrint(buffer, "{d}/{d}", .{
        state.matches_position,
        state.matches_count,
    }) catch "0/0";
}

fn appendRow(doc: *ui.Document, parent: *ui.Node, right_padding: bool) !*ui.Node {
    const row = try doc.createElement(.div);
    row.setStyle(.{
        .height = .{ .cells = 1 },
        .white_space = .pre,
        .display = .flex,
        .align_items = .center,
        .gap = .{ .column = 1 },
        .padding = if (right_padding)
            ui.EdgeDecl{ .left = 1, .right = 1 }
        else
            ui.EdgeDecl{ .left = 1 },
        .overflow = .hidden,
    });
    _ = try parent.appendChild(row);
    return row;
}

fn appendLabel(doc: *ui.Document, parent: *ui.Node, text: []const u8, width_cells: usize, color_value: ui.Color) !*ui.Node {
    const holder = try doc.createElement(.div);
    holder.setStyle(.{
        .width = .{ .cells = @floatFromInt(width_cells) },
        .height = .{ .cells = 1 },
        .white_space = .pre,
        .flex_shrink = 0,
        .overflow = .hidden,
    });
    const node = try doc.createText(text);
    node.setStyle(.{ .color = color_value });
    _ = try holder.appendChild(node);
    _ = try parent.appendChild(holder);
    return holder;
}

fn appendRightAligned(
    doc: *ui.Document,
    parent: *ui.Node,
    text: []const u8,
    width_cells: usize,
    style: ui.Style,
) !void {
    const holder = try doc.createElement(.div);
    holder.setStyle(.{
        .width = .{ .cells = @floatFromInt(width_cells) },
        .height = .{ .cells = 1 },
        .white_space = .pre,
        .flex_shrink = 0,
        .text_align = .right,
        .overflow = .hidden,
    });
    const node = try doc.createText(text);
    node.setStyle(style);
    _ = try holder.appendChild(node);
    _ = try parent.appendChild(holder);
}

fn appendToggleGroup(doc: *ui.Document, parent: *ui.Node) !*ui.Node {
    const group = try doc.createElement(.div);
    group.setStyle(.{
        .width = .{ .cells = toggles_width },
        .height = .{ .cells = 1 },
        .white_space = .pre,
        .display = .flex,
        .flex_shrink = 0,
    });
    _ = try parent.appendChild(group);
    return group;
}

fn isWithin(target: ?*ui.Node, ancestor: ?*ui.Node) bool {
    const root = ancestor orelse return false;
    var current = target;
    while (current) |node| : (current = node.parent) {
        if (node == root) return true;
    }
    return false;
}

fn onBarMove(context: ?*anyopaque, event: *ui.MouseEvent) void {
    const self: *FindWidget = @ptrCast(@alignCast(context orelse return));
    if (self.resizing) {
        self.updateResize(event);
        return;
    }
    self.hover_control = self.controlFor(event.target);
}

fn onDocumentMove(context: ?*anyopaque, event: *ui.MouseEvent) void {
    const self: *FindWidget = @ptrCast(@alignCast(context orelse return));
    if (self.resizing) {
        self.updateResize(event);
        return;
    }
    if (!isWithin(event.target, self.bar_root)) self.hover_control = null;
}

fn onDocumentUp(context: ?*anyopaque, _: *ui.MouseEvent) void {
    const self: *FindWidget = @ptrCast(@alignCast(context orelse return));
    self.resizing = false;
}

fn onSashDown(context: ?*anyopaque, event: *ui.MouseEvent) void {
    const self: *FindWidget = @ptrCast(@alignCast(context orelse return));
    if (event.button != .left) return;
    self.resizing = true;
    self.resize_start_x = event.x;
    self.resize_start_width = self.widget_width;
    event.preventDefault();
}

fn onControlDown(context: ?*anyopaque, event: *ui.MouseEvent) void {
    _ = context;
    if (event.button == .left) {
        // Keep the input's keyboard focus; the click toggles the option.
        event.preventDefault();
    }
}

fn onControlClick(context: ?*anyopaque, event: *ui.MouseEvent) void {
    const self: *FindWidget = @ptrCast(@alignCast(context orelse return));
    if (event.button != .left) return;
    const control = self.controlFor(event.target) orelse return;
    self.activateControl(control);
    self.hover_control = control;
}

fn onKeyCapture(context: ?*anyopaque, event: *ui.KeyEvent) void {
    const self: *FindWidget = @ptrCast(@alignCast(context orelse return));
    if (self.handleKey(event)) {
        event.stopPropagation();
        event.preventDefault();
    }
}

fn onFindFocus(context: ?*anyopaque, _: *ui.FocusEvent) void {
    const self: *FindWidget = @ptrCast(@alignCast(context orelse return));
    self.focused = true;
    self.focus_field = .find;
}

fn onReplaceFocus(context: ?*anyopaque, _: *ui.FocusEvent) void {
    const self: *FindWidget = @ptrCast(@alignCast(context orelse return));
    self.focused = true;
    self.focus_field = .replace;
}

fn onBlur(context: ?*anyopaque, _: *ui.FocusEvent) void {
    const self: *FindWidget = @ptrCast(@alignCast(context orelse return));
    self.focused = false;
}

fn onFindChanged(context: ?*anyopaque, value: []const u8) void {
    const self: *FindWidget = @ptrCast(@alignCast(context orelse return));
    if (!self.find_on_type) return;
    self.state.change(.{ .search_string = value }, true, true);
}

fn onReplaceChanged(context: ?*anyopaque, value: []const u8) void {
    const self: *FindWidget = @ptrCast(@alignCast(context orelse return));
    self.state.change(.{ .replace_string = value }, false, true);
}
