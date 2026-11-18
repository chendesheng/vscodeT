//! The editor view, rendered through the standalone `ui` library.
//!
//! This replaces the hand-written `Screen`/`render.zig` path with a
//! `ui.Document`: one absolutely positioned element per view line, a gutter
//! element, inline token runs painted by `viewLineRenderer`, a status bar and a
//! hardware cursor cell. It is a deliberate terminal adaptation of
//! `src/vs/editor/browser/view/`, not a literal port: the browser view parts
//! (viewLayer, viewLines, selections, cursors) are collapsed into this file
//! until the view model is ported.
//!
//! The document is rebuilt from the editor when `refresh` is called (after a
//! key, an edit or a resize). `Document.clear` keeps the arena and the
//! `Surface` frame so the renderer still emits only the changed cells. The view
//! also owns the terminal mouse adaptation: click/drag caret placement, drag
//! selection, click synthesis and wheel scrolling of the editor viewport.
//!
//! Find, bracket, word and hover ranges are materialized as `TextModel`
//! decorations by `ModelDecorationSink` or by the view's bracket pass. Inline
//! decorations are resolved with the ported
//! `LineDecoration.filter`/`extractWrapped` path, mirroring upstream's
//! ViewLine; the resulting classes map to terminal cell flags.
//!
//! Indentation guides are painted as dim `│` cells over the leading
//! whitespace, using the ported `GuidesTextModelPart` count. Vertical
//! bracket-pair guides and the active indentation/bracket scope are painted
//! with brighter colors. Guides never overwrite text cells; horizontal guide
//! segments are not terminal cells, so they are not painted.
//!
//! The right edge of the text area reserves two cells that double as the
//! overview ruler and the scrollbar. Marker ranges project onto text rows
//! instead of canvas pixels, so several document lines can share a row. The
//! scrollbar thumb is painted after the markers in the same cells, so it covers
//! them on the rows it occupies, matching the terminal rendering of the
//! browser's overlapping overview-ruler and slider layers.

const std = @import("std");
const ui = @import("ui");

const Editor = @import("./editor.zig").Editor;
const theme = @import("./theme.zig");
const CursorColumns = @import("../vs/editor/common/core/cursorColumns.zig").CursorColumns;
const CursorState = @import("../vs/editor/common/cursorCommon.zig").CursorState;
const Position = @import("../vs/editor/common/core/position.zig").Position;
const Range = @import("../vs/editor/common/core/range.zig").Range;
const Selection = @import("../vs/editor/common/core/selection.zig").Selection;
const lineDecorations = @import("../vs/editor/common/viewLayout/lineDecorations.zig");
const inlineDecorations = @import("../vs/editor/common/viewModel/inlineDecorations.zig");
const InlineDecoration = inlineDecorations.InlineDecoration;
const line_renderer = @import("../vs/editor/common/viewLayout/viewLineRenderer.zig");
const editorBrowser = @import("../vs/editor/browser/editorBrowser.zig");
const decorationsOverviewRuler = @import("../vs/editor/browser/viewParts/overviewRuler/decorationsOverviewRuler.zig");
const model_module = @import("../vs/editor/common/model.zig");
const TextModel = @import("../vs/editor/common/model/textModel.zig").TextModel;
const ModelDeltaDecoration = model_module.ModelDeltaDecoration;
const ModelDecorationOptions = model_module.ModelDecorationOptions;
const OverviewRulerLane = model_module.OverviewRulerLane;
const scrollbar_state = @import("../vs/base/browser/ui/scrollbar/scrollbarState.zig");
const GuidesTextModelPart = @import("../vs/editor/common/model/guidesTextModelPart.zig").GuidesTextModelPart;
const computeIndentLevel = @import("../vs/editor/common/model/utils.zig").computeIndentLevel;
const indent_guides = @import("../vs/editor/browser/viewParts/indentGuides/indentGuides.zig");

const gutter_color = [3]u8{ 110, 110, 110 };
const continuation_color = [3]u8{ 90, 90, 90 };
const tilde_color = [3]u8{ 70, 70, 70 };
const indent_guide_color = [3]u8{ 60, 62, 64 };
const indent_guide_active_color = [3]u8{ 96, 100, 104 };
const bracket_guide_colors = [_][3]u8{
    .{ 70, 76, 84 },
    .{ 82, 74, 80 },
    .{ 72, 84, 78 },
    .{ 86, 80, 70 },
    .{ 78, 74, 88 },
    .{ 70, 84, 86 },
};
const bracket_guide_active_color = [3]u8{ 132, 138, 144 };

const find_options = makeDecorationOptions("findMatch", .Left, overview_find_color, 10);
const current_find_options = makeDecorationOptions("currentFindMatch", .Full, overview_current_find_color, 13);
const find_scope_options = makeDecorationOptions("findScope", null, null, 0);
const bracket_options = makeDecorationOptions("bracket-match", .Right, overview_bracket_color, 0);
const bracket_inline_options = makeDecorationOptions("bracket-match", null, null, 0);
const word_text_options = makeDecorationOptions("wordHighlightText", .Center, overview_word_color, 0);
const word_options = makeDecorationOptions("wordHighlight", .Center, overview_word_color, 0);
const word_strong_options = makeDecorationOptions("wordHighlightStrong", .Center, overview_word_strong_color, 0);
const hover_options = makeDecorationOptions("hoverHighlight", null, null, 0);
const search_range_options = makeDecorationOptions("rangeHighlight", null, null, 1);

fn makeDecorationOptions(
    comptime class_name: []const u8,
    lane: ?OverviewRulerLane,
    marker_color: ?[3]u8,
    z_index: usize,
) ModelDecorationOptions {
    var options = ModelDecorationOptions.init(class_name, .NeverGrowsWhenTypingAtEdges);
    options.className = class_name;
    options.inlineClassName = class_name;
    options.overviewRuler = if (lane != null and marker_color != null)
        .{ .position = lane.?, .color = marker_color.? }
    else
        null;
    options.zIndex = z_index;
    return options;
}

fn decorationOptions(kind: editorBrowser.DecorationKind, show_in_overview: bool) *const ModelDecorationOptions {
    return switch (kind) {
        .find_match => &find_options,
        .current_find_match => &current_find_options,
        .find_scope => &find_scope_options,
        .bracket_match => if (show_in_overview) &bracket_options else &bracket_inline_options,
        .hover_highlight => &hover_options,
        .word_highlight_text => &word_text_options,
        .word_highlight => &word_options,
        .word_highlight_strong => &word_strong_options,
        .search_range_highlight => &search_range_options,
    };
}

fn overviewRulerLaneFromModel(lane: OverviewRulerLane) decorationsOverviewRuler.Lane {
    return switch (lane) {
        .Left => .left,
        .Center => .center,
        .Right => .right,
        .Full => .full,
    };
}
const current_line_background = [3]u8{ 32, 32, 36 };
const secondary_cursor_background = [3]u8{ 110, 90, 30 };

/// A cell position, 0-based, ready for `tui.moveCursor` after adding one.
pub const Cell = struct {
    row: usize,
    col: usize,
};

const GuideSpec = struct {
    row: usize,
    col: usize,
    color: [3]u8,
};

const DecorationOwner = struct {
    const find: usize = 1;
    const bracket: usize = 2;
    const word: usize = 3;
    const hover: usize = 4;
    const search: usize = 5;
};

const CellFlag = struct {
    const normal: u16 = 0;
    const selected: u16 = 1 << 0;
    const secondary_cursor: u16 = 1 << 1;
    const find_match: u16 = 1 << 2;
    const current_find_match: u16 = 1 << 3;
    const find_scope: u16 = 1 << 4;
    const bracket_match: u16 = 1 << 5;
    const hover_highlight: u16 = 1 << 6;
    const word_highlight_text: u16 = 1 << 7;
    const word_highlight: u16 = 1 << 8;
    const word_highlight_strong: u16 = 1 << 9;
    const snippet_placeholder: u16 = 1 << 10;
    const finish_snippet_placeholder: u16 = 1 << 11;
    const value_set_replacement: u16 = 1 << 12;
    const search_range_highlight: u16 = 1 << 13;
};

const find_match_background = [3]u8{ 80, 70, 20 };
const current_find_match_background = [3]u8{ 200, 120, 0 };
const current_find_match_foreground = [3]u8{ 0, 0, 0 };
const find_scope_background = [3]u8{ 40, 50, 70 };
const bracket_match_background = [3]u8{ 45, 80, 55 };
const bracket_match_foreground = [3]u8{ 235, 255, 235 };
/// Upstream's `editor.hoverHighlightBackground` (#264f7840) is translucent.
/// Cells have no alpha, so this is the dark-theme color composited over the
/// editor background, keeping the text readable.
const hover_highlight_background = [3]u8{ 32, 42, 52 };
/// `editor.wordHighlightBackground` / `wordHighlightTextBackground`
/// (#575757B8) and `wordHighlightStrongBackground` (#004972B8), composited
/// over the dark editor background because cells have no alpha.
const word_highlight_background = [3]u8{ 71, 71, 71 };
const word_highlight_strong_background = [3]u8{ 8, 61, 91 };
/// Snippet placeholder decorations are CSS backgrounds upstream. Cells have
/// no alpha, so these are composited over the dark editor background.
const snippet_placeholder_background = [3]u8{ 52, 58, 68 };
const finish_snippet_placeholder_background = [3]u8{ 66, 56, 42 };
const search_range_highlight_background = [3]u8{ 48, 54, 66 };

/// Overview-ruler marker colors. Cells have no alpha, so the translucent
/// upstream theme colors are composited over the dark editor background.
/// Find/current-find follow `editorOverviewRuler.findMatchForeground`; the
/// current match keeps the stronger inline find color so it stands out.
const overview_find_color = [3]u8{ 96, 66, 22 };
const overview_current_find_color = [3]u8{ 150, 90, 0 };
const overview_bracket_color = [3]u8{ 92, 92, 92 };
const overview_word_color = [3]u8{ 78, 78, 78 };
const overview_word_strong_color = [3]u8{ 96, 80, 96 };
const overview_cursor_color = [3]u8{ 92, 93, 91 };
const overview_secondary_cursor_color = [3]u8{ 86, 70, 26 };
/// The thumb is intentionally a little brighter than the markers so it remains
/// distinguishable while the marker cells stay subdued.
const scrollbar_thumb_color = [3]u8{ 108, 108, 108 };

pub const View = struct {
    allocator: std.mem.Allocator,
    editor: *Editor,
    guides: GuidesTextModelPart,
    surface: ui.Surface,
    /// Overlay widgets anchored to an editor corner, painted above the lines
    /// and the status row.
    overlays: std.array_list.Managed(editorBrowser.IOverlayWidget),
    /// Content widgets anchored to model positions, painted above the lines
    /// and below the overlays (the hover widget is one).
    content_widgets: std.array_list.Managed(editorBrowser.IContentWidget),
    /// Content widget containers for the current frame, used to hit-test and
    /// to keep pointer events out of the text.
    content_entries: std.array_list.Managed(ContentEntry),
    /// Overlay widget rectangles for the current frame; pointer events on an
    /// overlay must not reach the editor's hover logic.
    overlay_entries: std.array_list.Managed(WidgetRect),
    /// The line element under the primary cursor, filled in while building.
    cursor_line: ?*ui.Node = null,
    /// Cells between the start of that line's content and the caret.
    cursor_offset: usize = 0,
    /// Text-row elements in view order, rebuilt with the document. A hit on
    /// one of these maps to its view line; hits on the gutter, the status row
    /// or overlays do not.
    line_entries: std.array_list.Managed(LineEntry),
    /// Width of the rightmost cells reserved for the combined overview ruler
    /// and scrollbar. The editor wraps around the same width.
    scrollbar_width: usize = 0,
    /// The active thumb/track drag. The state is cloned at press time so the
    /// pointer delta maps against the geometry that was under the pointer.
    scrollbar_drag: ?ScrollbarDrag = null,
    /// The last left-button press, in cells, kept across document rebuilds so
    /// a release can synthesize a click without retaining node pointers.
    mouse_press: ?MousePress = null,
    /// Where a left-button drag started, in model coordinates.
    drag_anchor: ?Position = null,
    /// A drag moved the selection, so the release is not a click.
    drag_moved: bool = false,
    /// Workbench status-bar text supplied through the ported
    /// `StatusbarModel`. Empty slices fall back to the editor's own status
    /// string so standalone editor view tests keep their old contract.
    status_left: [512]u8 = undefined,
    status_left_len: usize = 0,
    status_right: [256]u8 = undefined,
    status_right_len: usize = 0,
    /// Whether this view paints the editor's fallback status row. The
    /// multi-group workbench disables it in favour of its status-bar part.
    status_bar_visible: bool = true,

    const LineEntry = struct {
        node: *ui.Node,
        view_line: usize,
        /// Cells of rendered text on this view line, used by hit testing to
        /// separate CONTENT_TEXT from CONTENT_EMPTY.
        text_width: usize = 0,
    };

    const ContentEntry = struct {
        widget: editorBrowser.IContentWidget,
        node: *ui.Node,
        left: usize,
        top: usize,
        width: usize,
        height: usize,

        fn contains(self: ContentEntry, x: usize, y: usize) bool {
            return x >= self.left and x < self.left + self.width and
                y >= self.top and y < self.top + self.height;
        }
    };

    const WidgetRect = struct {
        node: *ui.Node,
        left: usize,
        top: usize,
        width: usize,
        height: usize,

        fn contains(self: WidgetRect, x: usize, y: usize) bool {
            return x >= self.left and x < self.left + self.width and
                y >= self.top and y < self.top + self.height;
        }
    };

    const MousePress = struct {
        x: usize,
        y: usize,
    };

    const ScrollbarDrag = struct {
        start_row: usize,
        initial_state: scrollbar_state.ScrollbarState,
    };

    pub fn init(allocator: std.mem.Allocator, editor: *Editor) !*View {
        const self = try allocator.create(View);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .editor = editor,
            .guides = GuidesTextModelPart.init(editor.model),
            .surface = undefined,
            .overlays = std.array_list.Managed(editorBrowser.IOverlayWidget).init(allocator),
            .content_widgets = std.array_list.Managed(editorBrowser.IContentWidget).init(allocator),
            .content_entries = std.array_list.Managed(ContentEntry).init(allocator),
            .overlay_entries = std.array_list.Managed(WidgetRect).init(allocator),
            .line_entries = std.array_list.Managed(LineEntry).init(allocator),
        };
        errdefer self.overlays.deinit();
        errdefer self.content_widgets.deinit();
        errdefer self.content_entries.deinit();
        errdefer self.overlay_entries.deinit();
        errdefer self.line_entries.deinit();
        editor.setScrollbarWidth(overviewRulerWidth(editor));
        self.scrollbar_width = editor.scrollbar_width;
        self.surface = try ui.Surface.init(allocator, .{
            .cols = editor.screen_width,
            .rows = editor.screen_height,
            .tab_size = editor.tabSize(),
            .measure_width = measureCodepoint,
        });
        errdefer self.surface.deinit();
        try self.rebuild();
        return self;
    }

    pub fn deinit(self: *View) void {
        self.line_entries.deinit();
        self.overlay_entries.deinit();
        self.content_entries.deinit();
        self.content_widgets.deinit();
        self.overlays.deinit();
        self.surface.deinit();
        self.allocator.destroy(self);
    }

    /// Registers an overlay widget. The caller owns the widget struct and must
    /// keep its context alive until it is removed or the view is destroyed.
    pub fn addOverlayWidget(self: *View, widget: editorBrowser.IOverlayWidget) !void {
        try self.overlays.append(widget);
        try self.refresh();
    }

    /// Registers a content widget anchored to a model position.
    pub fn addContentWidget(self: *View, widget: editorBrowser.IContentWidget) !void {
        try self.content_widgets.append(widget);
        try self.refresh();
    }

    /// Enables or disables the view's own status row. Disabling it gives the
    /// surface's last row back to editor text.
    pub fn setStatusBarVisible(self: *View, visible: bool) !void {
        if (self.status_bar_visible == visible) return;
        self.status_bar_visible = visible;
        self.editor.setStatusRow(visible);
        try self.refresh();
    }

    /// Supplies the standalone editor view's fallback status text. Workbench
    /// tabs disable this row and use the workbench status bar instead.
    pub fn setStatusText(self: *View, left: []const u8, right: []const u8) void {
        const left_len = @min(left.len, self.status_left.len);
        @memcpy(self.status_left[0..left_len], left[0..left_len]);
        self.status_left_len = left_len;
        const right_len = @min(right.len, self.status_right.len);
        @memcpy(self.status_right[0..right_len], right[0..right_len]);
        self.status_right_len = right_len;
    }

    /// Replaces the find contribution's model decorations.
    pub fn setDecorations(self: *View, decorations: []const editorBrowser.Decoration) !void {
        try self.replaceModelDecorations(DecorationOwner.find, decorations);
    }

    /// Sets (or clears, with an empty slice) the hover highlight range.
    pub fn setHoverDecorations(self: *View, decorations: []const editorBrowser.Decoration) !void {
        try self.replaceModelDecorations(DecorationOwner.hover, decorations);
    }

    /// Sets (or clears, with an empty slice) the word-occurrence highlights.
    pub fn setWordHighlights(self: *View, decorations: []const editorBrowser.Decoration) !void {
        try self.replaceModelDecorations(DecorationOwner.word, decorations);
    }

    /// Sets the range highlighted by the Search view.
    pub fn setSearchHighlights(self: *View, decorations: []const editorBrowser.Decoration) !void {
        try self.replaceModelDecorations(DecorationOwner.search, decorations);
    }

    pub fn clearDecorations(self: *View) !void {
        try self.setDecorations(&.{});
    }

    fn replaceModelDecorations(
        self: *View,
        owner: usize,
        decorations: []const editorBrowser.Decoration,
    ) !void {
        try replaceModelDecorationsFor(self.editor.model, owner, decorations);
    }

    /// A contribution-facing sink that writes model decorations directly,
    /// without going through the view. The view reads the same model
    /// decorations back for painting and the overview ruler.
    pub const ModelDecorationSink = struct {
        model: *TextModel,
        owner: usize,

        pub fn context(self: *ModelDecorationSink) *anyopaque {
            return self;
        }

        pub fn set(sink_context: ?*anyopaque, decorations: []const editorBrowser.Decoration) void {
            const self: *ModelDecorationSink = @ptrCast(@alignCast(sink_context orelse return));
            replaceModelDecorationsFor(self.model, self.owner, decorations) catch {};
        }
    };

    pub fn replaceModelDecorationsFor(
        model: *TextModel,
        owner: usize,
        decorations: []const editorBrowser.Decoration,
    ) !void {
        const allocator = model.getAllocator();
        try model.removeAllDecorationsWithOwnerId(owner);
        if (decorations.len == 0) return;

        const deltas = try allocator.alloc(ModelDeltaDecoration, decorations.len);
        defer allocator.free(deltas);
        for (decorations, 0..) |decoration, index| {
            deltas[index] = .{
                .range = decoration.range,
                .options = @constCast(decorationOptions(decoration.kind, decoration.show_in_overview_ruler)),
            };
        }

        const ids = try model.deltaDecorations(&.{}, deltas, owner);
        defer allocator.free(ids);
    }

    pub fn removeOverlayWidget(self: *View, id: []const u8) !void {
        var index: usize = 0;
        while (index < self.overlays.items.len) : (index += 1) {
            const widget = self.overlays.items[index];
            if (std.mem.eql(u8, widget.get_id(widget.context), id)) {
                _ = self.overlays.orderedRemove(index);
                try self.refresh();
                return;
            }
        }
    }

    pub fn removeContentWidget(self: *View, id: []const u8) !void {
        var index: usize = 0;
        while (index < self.content_widgets.items.len) : (index += 1) {
            const widget = self.content_widgets.items[index];
            if (std.mem.eql(u8, widget.get_id(widget.context), id)) {
                _ = self.content_widgets.orderedRemove(index);
                try self.refresh();
                return;
            }
        }
    }

    /// Sends the event through the widget document when a widget owns focus.
    /// Returns true when a listener consumed it, so the editor must not also
    /// handle the key.
    pub fn dispatchKey(self: *View, event: *ui.KeyEvent) bool {
        const doc = self.surface.document();
        if (doc.active_element == null) return false;
        doc.dispatchEvent(event);
        return event.default_prevented or event.propagation_stopped;
    }

    /// Hit-tests and dispatches a mouse event, then applies the editor's own
    /// default actions: a press places the caret, a drag selects, and the wheel
    /// scrolls the viewport. Returns true when the caret or selection changed.
    pub fn dispatchMouse(self: *View, event: *ui.MouseEvent) !bool {
        const doc = self.surface.document();
        const target = (try self.surface.elementFromPoint(event.x, event.y)) orelse
            (doc.root orelse return false);
        ui.event.dispatchMouse(doc, target, event);

        const scrollbar_hit = self.isScrollbarCell(event.x) and
            event.y < self.editor.textHeight() and
            !self.pointInWidget(event.x, event.y);

        var caret_changed = false;
        switch (event.kind) {
            .down => {
                if (event.button == .left and scrollbar_hit) {
                    self.mouse_press = null;
                    self.drag_anchor = null;
                    self.drag_moved = false;
                    if (!event.default_prevented) {
                        self.beginScrollbarDrag(event.x, event.y);
                    }
                    return false;
                }
                self.scrollbar_drag = null;
                if (event.button == .left and
                    !event.default_prevented and
                    try self.toggleFoldControl(event.x, event.y))
                {
                    self.mouse_press = null;
                    self.drag_anchor = null;
                    self.drag_moved = false;
                    return true;
                }
                if (event.button == .left) {
                    self.mouse_press = .{ .x = event.x, .y = event.y };
                    self.drag_anchor = null;
                    self.drag_moved = false;
                    if (!event.default_prevented) {
                        if (self.lineEntryAt(target)) |entry| {
                            const position = try self.positionAtCell(entry.view_line, event.x);
                            if (event.mods.shift) {
                                const previous = self.editor.modelSelection();
                                const anchor = previous.getSelectionStart();
                                self.drag_anchor = anchor;
                                try self.selectFrom(anchor, position);
                            } else {
                                try self.editor.setCursorPosition(position);
                                self.drag_anchor = position;
                            }
                            caret_changed = true;
                        }
                    }
                }
            },
            .move => {
                if (self.scrollbar_drag != null) {
                    self.updateScrollbarDrag(event.y);
                    return false;
                }
                if (event.button == .left) {
                    if (self.drag_anchor) |anchor| {
                        if (self.lineEntryAt(target)) |entry| {
                            const position = try self.positionAtCell(entry.view_line, event.x);
                            if (position.lineNumber != anchor.lineNumber or
                                position.column != anchor.column)
                            {
                                try self.editor.updateDragSelection(anchor, position);
                                self.drag_moved = true;
                                caret_changed = true;
                            }
                        }
                    }
                }
            },
            .up => {
                if (self.scrollbar_drag != null) {
                    self.scrollbar_drag = null;
                    return false;
                }
                if (event.button == .left) {
                    if (self.mouse_press) |press| {
                        self.mouse_press = null;
                        const drag_moved = self.drag_moved;
                        self.drag_anchor = null;
                        self.drag_moved = false;
                        // A selecting drag is not a click; otherwise a press
                        // and a release on different elements click their
                        // common ancestor.
                        if (!drag_moved) {
                            const press_target = (try self.surface.elementFromPoint(press.x, press.y)) orelse
                                (doc.root orelse target);
                            const click_target = ui.event.commonInclusiveAncestor(press_target, target) orelse
                                press_target;
                            var click = ui.MouseEvent{
                                .kind = .click,
                                .x = event.x,
                                .y = event.y,
                                .button = .left,
                                .mods = event.mods,
                            };
                            ui.event.dispatchMouse(doc, click_target, &click);
                        }
                    }
                }
            },
            .wheel => {
                if (!event.default_prevented and
                    event.y < self.editor.textHeight() and
                    event.delta_y != 0)
                {
                    _ = self.editor.scrollViewLines(event.delta_y);
                }
            },
            .click => {},
        }
        return caret_changed;
    }

    fn isScrollbarCell(self: *View, x: usize) bool {
        if (self.scrollbar_width == 0) return false;
        const cols = self.surface.document().cols;
        return x >= cols -| self.scrollbar_width;
    }

    fn pointInWidget(self: *const View, x: usize, y: usize) bool {
        for (self.content_entries.items) |entry| {
            if (entry.contains(x, y)) return true;
        }
        for (self.overlay_entries.items) |entry| {
            if (entry.contains(x, y)) return true;
        }
        return false;
    }

    fn beginScrollbarDrag(self: *View, x: usize, y: usize) void {
        const editor = self.editor;
        const height = editor.textHeight();
        if (height == 0) return;
        const row = @min(y, height - 1);

        var state = self.scrollbarState();
        if (!state.isNeeded()) return;

        const geometry = thumbGeometry(state, height);
        const cols = self.surface.document().cols;
        const in_thumb = x >= cols -| self.scrollbar_width and
            row >= geometry.top and
            row < geometry.top + geometry.size;

        if (!in_thumb) {
            const desired = state.getDesiredScrollPositionFromOffset(@floatFromInt(row));
            const applied = applyScrollPosition(editor, desired);
            _ = state.setScrollPosition(@floatFromInt(applied));
        }

        self.scrollbar_drag = .{
            .start_row = row,
            .initial_state = state,
        };
    }

    fn updateScrollbarDrag(self: *View, y: usize) void {
        const drag = self.scrollbar_drag orelse return;
        const height = self.editor.textHeight();
        if (height == 0) return;
        const row = @min(y, height - 1);
        const delta = @as(f64, @floatFromInt(row)) - @as(f64, @floatFromInt(drag.start_row));
        const desired = drag.initial_state.getDesiredScrollPositionFromDelta(delta);
        _ = applyScrollPosition(self.editor, desired);
    }

    fn lineEntryAt(self: *const View, target: *ui.Node) ?LineEntry {
        var node: ?*ui.Node = target;
        while (node) |current| : (node = current.parent) {
            for (self.line_entries.items) |entry| {
                if (entry.node == current) return entry;
            }
        }
        return null;
    }

    fn lineEntryForViewLine(self: *const View, view_line: usize) ?LineEntry {
        const top = self.editor.topViewLine();
        if (view_line < top) return null;
        const index = view_line - top;
        if (index >= self.line_entries.items.len) return null;
        const entry = self.line_entries.items[index];
        return if (entry.view_line == view_line) entry else null;
    }

    /// The mouse target for a cell, mirroring upstream's `onMouseMove` target
    /// types. Hover needs to know whether the pointer is on text, past the end
    /// of a line, on the gutter or on a widget.
    pub fn mouseTargetAt(self: *View, x: usize, y: usize) !editorBrowser.MouseTarget {
        const doc = self.surface.document();
        const target = (try self.surface.elementFromPoint(x, y)) orelse doc.root orelse
            return .{ .mouse_column = x + 1 };

        for (self.content_entries.items) |entry| {
            if (entry.contains(x, y)) {
                return .{ .element = target, .type = .content_widget, .mouse_column = x + 1 };
            }
        }
        for (self.overlay_entries.items) |entry| {
            if (entry.contains(x, y)) {
                return .{ .element = target, .type = .overlay_widget, .mouse_column = x + 1 };
            }
        }

        const text_height = self.editor.textHeight();
        if (y >= text_height) {
            return .{ .element = target, .type = .status, .mouse_column = x + 1 };
        }

        const gutter = self.editor.gutterWidth();
        const top = self.editor.topViewLine();
        const cols = doc.cols;
        if (self.scrollbar_width > 0 and x >= cols -| self.scrollbar_width) {
            const view_line = @min(top + y, self.editor.viewLineCount());
            return .{
                .element = target,
                .type = .scrollbar,
                .position = try self.editor.positionAtViewPoint(view_line, 0),
                .mouse_column = x + 1,
            };
        }

        const view_line = top + y;
        if (x < gutter) {
            return .{
                .element = target,
                .type = if (x + 1 == gutter and gutter >= 2)
                    .gutter_line_decorations
                else
                    .gutter_line_numbers,
                .position = try self.editor.positionAtViewPoint(@min(view_line, self.editor.viewLineCount()), 0),
                .mouse_column = x + 1,
            };
        }

        if (view_line > self.editor.viewLineCount()) {
            return .{
                .element = target,
                .type = .content_empty,
                .mouse_column = x + 1,
                .detail = .{ .content_empty = .{ .is_after_lines = true } },
            };
        }

        const position = try self.editor.positionAtViewPoint(view_line, x - gutter);
        const range = Range.init(position.lineNumber, position.column, position.lineNumber, position.column);
        const entry = self.lineEntryForViewLine(view_line) orelse {
            return .{ .element = target, .type = .content_empty, .mouse_column = x + 1, .detail = .{ .content_empty = .{ .is_after_lines = false } } };
        };
        const offset = x - gutter;
        if (offset < entry.text_width) {
            return .{
                .element = target,
                .type = .content_text,
                .position = position,
                .range = range,
                .mouse_column = x + 1,
            };
        }
        return .{
            .element = target,
            .type = .content_empty,
            .position = position,
            .range = range,
            .mouse_column = x + 1,
            .detail = .{ .content_empty = .{
                .is_after_lines = false,
                .horizontal_distance_to_text = offset - entry.text_width,
            } },
        };
    }

    /// The last gutter cell is the fold-control column. It only toggles when
    /// the view line is the first output line of a model line with a region.
    fn foldControlAt(self: *const View, x: usize, y: usize) ?usize {
        const gutter = self.editor.gutterWidth();
        if (gutter < 2 or x + 1 != gutter) return null;
        if (y >= self.editor.textHeight()) return null;
        const view_line = self.editor.topViewLine() + y;
        if (view_line > self.editor.viewLineCount()) return null;
        if (self.editor.outputLineIndex(view_line) != 0) return null;
        return view_line;
    }

    fn toggleFoldControl(self: *View, x: usize, y: usize) !bool {
        const view_line = self.foldControlAt(x, y) orelse return false;
        const changed = try self.editor.toggleFoldAtViewLine(view_line);
        if (changed) try self.rebuild();
        return changed;
    }

    fn positionAtCell(self: *const View, view_line: usize, x: usize) !Position {
        const gutter = self.editor.gutterWidth();
        return self.editor.positionAtViewPoint(view_line, x -| gutter);
    }

    fn selectFrom(self: *View, anchor: Position, position: Position) !void {
        try self.editor.setSelections(&[_]Selection{
            Selection.init(anchor.lineNumber, anchor.column, position.lineNumber, position.column),
        });
    }

    /// Recreates the surface at the editor's current viewport size. The caller
    /// clears the screen because the new surface starts a fresh frame.
    pub fn resize(self: *View) !void {
        self.scrollbar_drag = null;
        const width = self.editor.screen_width;
        const height = self.editor.screen_height;
        if (self.surface.document().cols == width and self.surface.document().rows == height) {
            return self.refresh();
        }

        const replacement = try ui.Surface.init(self.allocator, .{
            .cols = width,
            .rows = height,
            .tab_size = self.editor.tabSize(),
            .measure_width = measureCodepoint,
        });

        var previous = self.surface;
        self.surface = replacement;
        previous.deinit();
        try self.rebuild();
    }

    /// Rebuilds the whole document from the editor state.
    pub fn refresh(self: *View) !void {
        try self.rebuild();
    }

    /// The text row of a model position, or null when it is outside the
    /// viewport. Content widgets use this to decide above/below placement.
    pub fn visibleRowOf(self: *View, position: Position) ?usize {
        const view_position = self.editor.viewPositionOfModelPosition(position);
        const top = self.editor.topViewLine();
        if (view_position.lineNumber < top) return null;
        const row = view_position.lineNumber - top;
        if (row >= self.editor.textHeight()) return null;
        return row;
    }

    /// Gives the keyboard back to the editor after a content widget closes.
    pub fn focusEditor(self: *View) void {
        self.surface.document().blur();
    }

    /// Paints into the view's own frame without writing ANSI. The multi-file
    /// workbench composites this grid below the tab strip.
    pub fn paint(self: *View) !void {
        try self.surface.paintFrame();
    }

    pub fn grid(self: *View) *const ui.CellGrid {
        return self.surface.grid();
    }

    pub fn render(self: *View, writer: *std.Io.Writer) !void {
        try self.surface.render(writer, .{ .synchronized = true });
    }

    /// The hardware cursor cell, valid after `render` has laid the tree out.
    /// Returns null when the caret is outside the text area.
    pub fn cursorCell(self: *View) ?Cell {
        // A focused widget paints its own block caret; the hardware cursor
        // belongs to the editor.
        if (self.surface.document().active_element != null) return null;
        const line = self.cursor_line orelse return null;
        const rows = self.surface.document().rows;
        const cols = self.surface.document().cols;
        const rect = line.asElement().rect;
        const row = ui.cell.snap(rect.y);
        if (row >= rows) return null;
        const right = @min(cols, self.editor.textAreaRight());
        const col = @min(ui.cell.snap(rect.x) + self.cursor_offset, right -| 1);
        return .{ .row = row, .col = col };
    }

    /// Whether no overlay or content widget owns the keyboard. Word
    /// occurrence highlighting follows the editor's text focus.
    pub fn hasEditorFocus(self: *const View) bool {
        for (self.overlays.items) |overlay| {
            if (overlay.is_focused(overlay.context)) return false;
        }
        for (self.content_widgets.items) |widget| {
            if (widget.is_focused(widget.context)) return false;
        }
        return true;
    }

    fn rebuild(self: *View) !void {
        const editor = self.editor;
        editor.setScrollbarWidth(overviewRulerWidth(editor));
        self.scrollbar_width = editor.scrollbar_width;
        editor.ensureTokensVisible();
        editor.refreshFoldingIfDirty();
        // The cursor is revealed by cursor moves and edits, not on every
        // rebuild: a wheel scroll is allowed to leave it off-screen.
        _ = editor.scrollViewLines(0);

        var bracket_decorations = std.array_list.Managed(editorBrowser.Decoration).init(self.allocator);
        defer bracket_decorations.deinit();
        const bracket_data = try editor.updateBracketMatches(self.hasEditorFocus());
        for (bracket_data) |entry| {
            const brackets = entry.brackets orelse continue;
            const overview = entry.options == .with_overview_ruler;
            try bracket_decorations.append(.{
                .range = brackets[0],
                .kind = .bracket_match,
                .show_in_overview_ruler = overview,
            });
            try bracket_decorations.append(.{
                .range = brackets[1],
                .kind = .bracket_match,
                .show_in_overview_ruler = overview,
            });
        }
        try self.replaceModelDecorations(DecorationOwner.bracket, bracket_decorations.items);

        const doc = self.surface.document();
        doc.clear();
        self.cursor_line = null;
        self.cursor_offset = 0;
        self.line_entries.clearRetainingCapacity();
        self.content_entries.clearRetainingCapacity();
        self.overlay_entries.clearRetainingCapacity();

        const cols = doc.cols;
        const rows = doc.rows;
        const scrollbar_width = if (self.scrollbar_width > 0 and
            cols > editor.gutterWidth() + self.scrollbar_width)
            self.scrollbar_width
        else
            0;
        self.scrollbar_width = scrollbar_width;
        const gutter = @min(editor.gutterWidth(), cols -| scrollbar_width);
        const text_width = @max(@as(usize, 1), cols -| gutter -| scrollbar_width);
        const text_right = @min(cols, gutter + text_width);
        const text_height = editor.textHeight();
        const total = editor.viewLineCount();
        const top = editor.topViewLine();
        const tab_size = editor.tabSize();
        const indent_size = @max(editor.indentSize(), 1);

        var guide_counts: []usize = &.{};
        var guide_start_model_line: usize = 0;
        var guide_end_model_line: usize = 0;
        if (top <= total) {
            const end_view_line = @min(total, top + text_height -| 1);
            guide_start_model_line = editor.modelLineNumber(top);
            guide_end_model_line = editor.modelLineNumber(end_view_line);
            guide_counts = try self.guides.getLinesIndentGuides(
                self.allocator,
                guide_start_model_line,
                guide_end_model_line,
            );
        }
        defer if (guide_counts.len > 0) self.allocator.free(guide_counts);

        var guide_specs = std.array_list.Managed(GuideSpec).init(self.allocator);
        defer guide_specs.deinit();

        if (guide_counts.len > 0) {
            // Passive indentation guides first; bracket pairs and the active
            // scope paint over them when they share a cell.
            for (guide_counts, 0..) |guide_count, index| {
                const model_line = guide_start_model_line + index;
                const row = viewRowForModelLine(editor, top, model_line) orelse continue;
                var content = try editor.model.getLineContent(model_line);
                defer content.deinit();
                const indent_width = computeIndentLevel(content.items, tab_size);
                var level: usize = 0;
                while (level < guide_count) : (level += 1) {
                    const guide_col = level * indent_size;
                    if (guide_col >= text_width) break;
                    if (indent_width >= 0 and guide_col >= @as(usize, @intCast(indent_width))) break;
                    try guide_specs.append(.{ .row = row, .col = guide_col, .color = indent_guide_color });
                }
            }

            // Active indentation scope: the contiguous block around the caret
            // with at least the caret line's guide level.
            const cursor_model_line = editor.modelCursorPosition().lineNumber;
            if (cursor_model_line >= guide_start_model_line and
                cursor_model_line - guide_start_model_line < guide_counts.len)
            {
                const cursor_index = cursor_model_line - guide_start_model_line;
                var cursor_content = try editor.model.getLineContent(cursor_model_line);
                defer cursor_content.deinit();
                const cursor_indent = computeIndentLevel(cursor_content.items, tab_size);
                const active_level = if (cursor_indent >= 0)
                    ceilDiv(@as(usize, @intCast(cursor_indent)), indent_size)
                else
                    guide_counts[cursor_index];
                if (active_level > 0) {
                    var first = cursor_index;
                    while (first > 0 and guide_counts[first - 1] >= active_level) first -= 1;
                    var last = cursor_index;
                    while (last + 1 < guide_counts.len and guide_counts[last + 1] >= active_level) last += 1;
                    var index = first;
                    while (index <= last) : (index += 1) {
                        const model_line = guide_start_model_line + index;
                        const row = viewRowForModelLine(editor, top, model_line) orelse continue;
                        try guide_specs.append(.{
                            .row = row,
                            .col = (active_level - 1) * indent_size,
                            .color = indent_guide_active_color,
                        });
                    }
                }
            }

            // Vertical bracket-pair guides. They are only painted where the
            // underlying cell is leading whitespace; a terminal cell cannot
            // show both the guide and a text glyph.
            if (guide_end_model_line >= guide_start_model_line) {
                const bracket_guides = try indent_guides.getBracketGuides(
                    self.allocator,
                    editor.model,
                    guide_start_model_line,
                    guide_end_model_line,
                    editor.modelCursorPosition(),
                );
                defer {
                    for (bracket_guides) |*line_guides| line_guides.deinit();
                    self.allocator.free(bracket_guides);
                }

                for (bracket_guides, 0..) |line_guides, index| {
                    const model_line = guide_start_model_line + index;
                    const row = viewRowForModelLine(editor, top, model_line) orelse continue;
                    var content = try editor.model.getLineContent(model_line);
                    defer content.deinit();
                    const indent_width = computeIndentLevel(content.items, tab_size);
                    for (line_guides.items) |guide| {
                        if (guide.column >= text_width) continue;
                        if (indent_width >= 0 and guide.column >= @as(usize, @intCast(indent_width))) continue;
                        try guide_specs.append(.{
                            .row = row,
                            .col = guide.column,
                            .color = if (guide.active)
                                bracket_guide_active_color
                            else
                                bracket_guide_colors[guide.level % bracket_guide_colors.len],
                        });
                    }
                }
            }
        }

        const root = try doc.createElement(.div);
        root.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = 0 },
            .top = .{ .cells = 0 },
            .width = .{ .percent = 100 },
            .height = .{ .percent = 100 },
            .overflow = .hidden,
        });
        doc.setRoot(root);

        const states = try editor.viewCursorStates();
        defer editor.allocator.free(states);
        const cursor = states[0].viewState.position;

        var row: usize = 0;
        while (row < text_height) : (row += 1) {
            const view_line = top + row;
            const row_cells: f64 = @floatFromInt(row);

            if (view_line > total) {
                if (gutter >= 2) {
                    const filler = try doc.createElement(.div);
                    filler.setStyle(.{
                        .position = .absolute,
                        .left = .{ .cells = 0 },
                        .top = .{ .cells = row_cells },
                        .width = .{ .cells = @floatFromInt(gutter - 1) },
                        .height = .{ .cells = 1 },
                        .white_space = .pre,
                        .text_align = .right,
                    });
                    const tilde = try doc.createText("~");
                    tilde.setStyle(.{ .color = color(tilde_color) });
                    _ = try filler.appendChild(tilde);
                    _ = try root.appendChild(filler);
                }
                continue;
            }

            const model_line = editor.modelLineNumber(view_line);
            const output_index = editor.outputLineIndex(view_line);

            // Gutter: the model line number on the first view line, a
            // continuation arrow on the rest. Upstream splits this into
            // `lineNumbersWidth` and `lineDecorationsWidth` and starts the text
            // at `contentLeft`; the terminal uses one decorations cell, so the
            // number column is `gutter - 1` and the last gutter cell is blank.
            const gutter_line = try doc.createElement(.div);
            gutter_line.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = 0 },
                .top = .{ .cells = row_cells },
                .width = .{ .cells = @floatFromInt(gutter - 1) },
                .height = .{ .cells = 1 },
                .white_space = .pre,
                .text_align = .right,
            });

            if (output_index == 0) {
                var number_buf: [32]u8 = undefined;
                const number = std.fmt.bufPrint(&number_buf, "{d}", .{model_line}) catch "";
                const node = try doc.createText(number);
                node.setStyle(.{ .color = color(gutter_color) });
                _ = try gutter_line.appendChild(node);
            } else if (gutter >= 2) {
                const node = try doc.createText("↪");
                node.setStyle(.{ .color = color(continuation_color) });
                _ = try gutter_line.appendChild(node);
            }
            _ = try root.appendChild(gutter_line);

            if (output_index == 0 and gutter >= 2) {
                const state = editor.foldStateAtModelLine(model_line);
                if (state != .none) {
                    const fold_cell = try doc.createElement(.div);
                    fold_cell.setStyle(.{
                        .position = .absolute,
                        .left = .{ .cells = @floatFromInt(gutter - 1) },
                        .top = .{ .cells = row_cells },
                        .width = .{ .cells = 1 },
                        .height = .{ .cells = 1 },
                        .white_space = .pre,
                    });
                    const glyph = try doc.createText(if (state == .collapsed) "▸" else "▾");
                    glyph.setStyle(.{ .color = color(gutter_color) });
                    _ = try fold_cell.appendChild(glyph);
                    _ = try root.appendChild(fold_cell);
                }
            }

            const is_cursor_line = view_line == cursor.lineNumber;
            const line = try doc.createElement(.div);
            line.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = @floatFromInt(gutter) },
                .top = .{ .cells = row_cells },
                .width = .{ .cells = @floatFromInt(text_width) },
                .height = .{ .cells = 1 },
                .white_space = .pre,
                .overflow = .hidden,
                .background = if (is_cursor_line) color(current_line_background) else null,
            });

            const data = try editor.viewLineData(view_line);
            const rendered = try line_renderer.renderLine(self.allocator, .{
                .content = data.content,
                .tokens = data.tokens,
                .tab_size = tab_size,
                .start_visible_column = data.startVisibleColumn,
            });
            defer rendered.deinit(self.allocator);

            const model_content = try editor.model.getLineContent(model_line);
            defer model_content.deinit();

            // Bracket and find ranges are model columns; clip them to this
            // wrapped segment's model span before mapping to cells. Without
            // this, a range on another segment maps to cell zero of every
            // continuation line.
            const segment_start_column = editor.modelColumnOfViewPosition(view_line, data.minColumn);
            const segment_end_column = editor.modelColumnOfViewPosition(view_line, data.maxColumn);
            const line_start_offset = editor.model.getOffsetAt(Position.init(model_line, 1));
            const segment_start_offset = editor.model.getOffsetAt(Position.init(model_line, segment_start_column)) - line_start_offset;
            const segment_end_offset = editor.model.getOffsetAt(Position.init(model_line, segment_end_column)) - line_start_offset;

            const indent_cells = data.minColumn - 1;
            const line_width = doc.measureText(rendered.bytes);
            const flags = try self.allocator.alloc(u16, @max(line_width, 1));
            defer self.allocator.free(flags);
            @memset(flags, CellFlag.normal);

            markSelections(
                states,
                view_line,
                model_content.items,
                tab_size,
                data.startVisibleColumn,
                indent_cells,
                line_width,
                flags,
            );
            try self.markDecorations(
                model_line,
                segment_start_column,
                segment_start_offset,
                segment_end_offset,
                model_content.items,
                tab_size,
                data.startVisibleColumn,
                indent_cells,
                line_width,
                flags,
            );

            try appendRuns(doc, line, rendered, flags);

            // A collapsed region ends its first line with the upstream
            // `inline-folded` ellipsis. It is painted after the text and is not
            // part of the selectable line width.
            if (output_index == 0 and line_width < text_width and
                editor.foldStateAtModelLine(model_line) == .collapsed)
            {
                const ellipsis = try doc.createElement(.div);
                ellipsis.setStyle(.{
                    .position = .absolute,
                    .left = .{ .cells = @floatFromInt(line_width) },
                    .top = .{ .cells = 0 },
                    .width = .{ .cells = 1 },
                    .height = .{ .cells = 1 },
                    .white_space = .pre,
                });
                const glyph = try doc.createText("…");
                glyph.setStyle(.{ .color = color(continuation_color) });
                _ = try ellipsis.appendChild(glyph);
                _ = try line.appendChild(ellipsis);
            }

            // Guides paint after the text runs, but only in cells that are
            // leading whitespace or on blank lines, so a text glyph is never
            // replaced by a guide line.
            if (output_index == 0) {
                for (guide_specs.items) |spec| {
                    if (spec.row != row) continue;
                    const guide = try doc.createElement(.div);
                    guide.setStyle(.{
                        .position = .absolute,
                        .left = .{ .cells = @floatFromInt(spec.col) },
                        .top = .{ .cells = 0 },
                        .width = .{ .cells = 1 },
                        .height = .{ .cells = 1 },
                        .white_space = .pre,
                    });
                    const glyph = try doc.createText("│");
                    glyph.setStyle(.{ .color = color(spec.color) });
                    _ = try guide.appendChild(glyph);
                    _ = try line.appendChild(guide);
                }
            }

            if (is_cursor_line) {
                self.cursor_line = line;
                self.cursor_offset = visibleOffset(
                    model_content.items,
                    cursor.column,
                    tab_size,
                    data.startVisibleColumn,
                    indent_cells,
                );
            }

            _ = try root.appendChild(line);
            try self.line_entries.append(.{ .node = line, .view_line = view_line, .text_width = line_width });
        }

        try appendStatus(self, doc, root, rows);
        try self.buildScrollbar(doc, root, states, text_height, cols);
        try self.buildOverlays(doc, root, cols, text_height);
        try self.buildContentWidgets(doc, root, cols, text_right, text_height, gutter, tab_size);
    }

    fn markDecorations(
        self: *View,
        model_line: usize,
        segment_start_column: usize,
        segment_start_offset: usize,
        segment_end_offset: usize,
        model_content: []const u8,
        tab_size: usize,
        start_visible_column: usize,
        indent_cells: usize,
        line_width: usize,
        flags: []u16,
    ) !void {
        var inline_list = std.array_list.Managed(InlineDecoration).init(self.allocator);
        defer inline_list.deinit();
        try appendModelInlineDecorations(&inline_list, self.editor.model, model_line, self.allocator);
        if (inline_list.items.len == 0) return;

        const filtered = try lineDecorations.LineDecoration.filter(
            self.allocator,
            inline_list.items,
            model_line,
            1,
            self.editor.model.getLineMaxColumn(model_line),
        );
        defer self.allocator.free(filtered);

        // Upstream's ViewLine does the same: filter the model decorations for
        // this line, then extract the slice for each wrapped output line.
        const wrapped = try lineDecorations.LineDecoration.extractWrapped(
            self.allocator,
            filtered,
            segment_start_offset,
            segment_end_offset,
        );
        defer self.allocator.free(wrapped);

        for (wrapped) |decoration| {
            const bit = decorationBit(decoration.className) orelse continue;
            const start_model_column = segment_start_column + decoration.startColumn - 1;
            const end_model_column = segment_start_column + decoration.endColumn - 1;
            var start = visibleOffset(model_content, start_model_column, tab_size, start_visible_column, indent_cells);
            var end = visibleOffset(model_content, end_model_column, tab_size, start_visible_column, indent_cells);
            if (start >= end) continue;
            start = @min(start, line_width);
            end = @min(end, line_width);

            var cell = start;
            while (cell < end and cell < flags.len) : (cell += 1) {
                flags[cell] |= bit;
            }
        }
    }

    fn buildScrollbar(
        self: *View,
        doc: *ui.Document,
        root: *ui.Node,
        states: []const CursorState,
        text_height: usize,
        cols: usize,
    ) !void {
        const column_width = self.scrollbar_width;
        if (column_width < 1) return;
        const left = cols -| column_width;
        if (left >= cols) return;

        var markers = std.array_list.Managed(decorationsOverviewRuler.Decoration).init(self.allocator);
        defer markers.deinit();
        try self.appendOverviewMarkers(&markers);

        var cursors = std.array_list.Managed(decorationsOverviewRuler.Cursor).init(self.allocator);
        defer cursors.deinit();
        const multiple_cursors = states.len > 1;
        for (states, 0..) |state, index| {
            const cursor_color = if (multiple_cursors and index > 0)
                overview_secondary_cursor_color
            else
                overview_cursor_color;
            try cursors.append(.{
                .line_number = state.viewState.position.lineNumber,
                .color = cursor_color,
                .lane = .full,
            });
        }
        std.mem.sort(decorationsOverviewRuler.Cursor, cursors.items, {}, cursorLessThan);

        const row_markers = try decorationsOverviewRuler.render(
            self.allocator,
            markers.items,
            cursors.items,
            .{
                .line_height = 1,
                .canvas_height = text_height,
                .outer_height = self.editor.scrollHeight(),
                .overview_ruler_lanes = 3,
                .hide_cursor = false,
                .min_decoration_height = 1,
            },
        );
        defer self.allocator.free(row_markers);

        // A single strip root owns both layers. Marker cells are appended
        // first; thumb rows are overwritten by the thumb glyph in the same
        // cells, so the thumb covers the marker without a second column.
        const state = self.scrollbarState();
        const thumb_needed = state.isNeeded();
        const halves = if (thumb_needed)
            thumbHalfGeometry(state, text_height)
        else
            ThumbHalves{ .top = 0, .end = 0 };

        const column = try doc.createElement(.div);
        column.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = @floatFromInt(left) },
            .top = .{ .cells = 0 },
            .width = .{ .cells = @floatFromInt(column_width) },
            .height = .{ .cells = @floatFromInt(text_height) },
            .overflow = .hidden,
        });
        _ = try root.appendChild(column);

        var row: usize = 0;
        while (row < text_height) : (row += 1) {
            const thumb_part = thumbPartAt(halves, row);
            const marker = if (row < row_markers.len) row_markers[row] else null;
            if (thumb_part == .none and marker == null) continue;

            // Flow (github.com/neurocyte/flow) renders its vertical
            // scrollbar as a foreground glyph over the editor background.
            // The scrollbar is right-aligned and 1.5 cells wide: the right
            // half of the first cell plus the full second cell. Quadrant
            // blocks give the thumb half-cell vertical precision at its top
            // and bottom edges.
            const marker_color = if (thumb_part != .none) scrollbar_thumb_color else marker.?.color;
            const glyph_text: []const u8 = if (thumb_part != .none)
                switch (thumb_part) {
                    .none => unreachable,
                    .full => "▐█", // right half first cell + full second cell
                    .upper => "▝▀", // upper right quadrant + upper half block
                    .lower => "▗▄", // lower right quadrant + lower half block
                }
            else
                markerGlyph(marker.?.lane, marker.?.vertical);

            const cell = try doc.createElement(.div);
            cell.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = 0 },
                .top = .{ .cells = @floatFromInt(row) },
                .width = .{ .cells = @floatFromInt(column_width) },
                .height = .{ .cells = 1 },
                .white_space = .pre,
                .color = color(marker_color),
            });
            const glyph = try doc.createText(glyph_text);
            glyph.setStyle(.{ .color = color(marker_color) });
            _ = try cell.appendChild(glyph);
            _ = try column.appendChild(cell);
        }
    }

    fn appendOverviewMarkers(
        self: *View,
        markers: *std.array_list.Managed(decorationsOverviewRuler.Decoration),
    ) !void {
        const editor = self.editor;
        const model_decorations = try editor.model.getOverviewRulerDecorations(0, false);
        defer self.allocator.free(model_decorations);

        for (model_decorations) |decoration| {
            const ruler = decoration.options.overviewRuler orelse continue;
            const marker_color = ruler.color orelse continue;
            const start = editor.viewPositionOfModelPosition(Position.init(
                decoration.range.startLineNumber,
                decoration.range.startColumn,
            ));
            const end = editor.viewPositionOfModelPosition(Position.init(
                decoration.range.endLineNumber,
                decoration.range.endColumn,
            ));
            try markers.append(.{
                .start_line_number = start.lineNumber,
                .end_line_number = @max(start.lineNumber, end.lineNumber),
                .color = marker_color,
                .lane = overviewRulerLaneFromModel(ruler.position),
                .z_index = @intCast(decoration.options.zIndex orelse 0),
            });
        }
    }

    fn scrollbarState(self: *const View) scrollbar_state.ScrollbarState {
        const editor = self.editor;
        return scrollbar_state.ScrollbarState.initWithMinimumSliderSize(
            0,
            1,
            0,
            @floatFromInt(editor.textHeight()),
            @floatFromInt(editor.scrollHeight()),
            @floatFromInt(editor.topViewLine() - 1),
            1,
        );
    }

    fn buildOverlays(
        self: *View,
        doc: *ui.Document,
        root: *ui.Node,
        cols: usize,
        text_height: usize,
    ) !void {
        for (self.overlays.items) |widget| {
            const width = @min(widget.width(widget.context, cols), cols);
            const height = @min(widget.height(widget.context), text_height);
            if (width == 0 or height == 0) continue;

            const top: usize = switch (widget.get_position(widget.context)) {
                .top_right_corner, .top_center => 0,
                .bottom_right_corner => text_height -| height,
            };
            const left: usize = switch (widget.get_position(widget.context)) {
                .top_right_corner, .bottom_right_corner => cols -| width,
                .top_center => (cols -| width) / 2,
            };

            const container = try doc.createElement(.div);
            container.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = @floatFromInt(left) },
                .top = .{ .cells = @floatFromInt(top) },
                .width = .{ .cells = @floatFromInt(width) },
                .height = .{ .cells = @floatFromInt(height) },
                .overflow = .hidden,
            });

            const content = try widget.build(widget.context, doc);
            _ = try container.appendChild(content);
            _ = try root.appendChild(container);
            try self.overlay_entries.append(.{
                .node = container,
                .left = left,
                .top = top,
                .width = width,
                .height = height,
            });

            // The widget subtree is connected now, so focus can be restored
            // after the document rebuild.
            if (widget.is_focused(widget.context)) {
                if (widget.focus_node(widget.context)) |node| {
                    _ = doc.focus(node);
                }
            }
        }
    }

    /// Places content widgets at their model anchor. Upstream positions them
    /// in pixels next to the view position and lets the content widget layer
    /// clamp them to the editor; the terminal maps the anchor to a cell and
    /// keeps the box inside the text area.
    fn buildContentWidgets(
        self: *View,
        doc: *ui.Document,
        root: *ui.Node,
        cols: usize,
        text_right: usize,
        text_height: usize,
        gutter: usize,
        tab_size: usize,
    ) !void {
        const editor = self.editor;
        const top = editor.topViewLine();
        if (text_right == 0) return;
        for (self.content_widgets.items) |widget| {
            const widget_position = widget.get_position(widget.context) orelse continue;
            const view_position = editor.viewPositionOfModelPosition(widget_position.position);
            if (view_position.lineNumber < top or view_position.lineNumber >= top + text_height) {
                continue;
            }
            const row = view_position.lineNumber - top;

            const width = @min(widget.width(widget.context, cols), text_right);
            const height = @min(widget.height(widget.context), text_height);
            if (width == 0 or height == 0) continue;

            const data = try editor.viewLineData(view_position.lineNumber);
            const model_line = editor.modelLineNumber(view_position.lineNumber);
            const model_column = editor.modelColumnOfViewPosition(view_position.lineNumber, view_position.column);
            const model_content = try editor.model.getLineContent(model_line);
            defer model_content.deinit();
            const anchor_cell = visibleOffset(
                model_content.items,
                model_column,
                tab_size,
                data.startVisibleColumn,
                data.minColumn - 1,
            );

            const left = @min(gutter + anchor_cell, text_right -| width);
            var widget_top: usize = switch (widget_position.preference) {
                .below => row + 1,
                .above => row -| height,
            };
            if (widget_top + height > text_height) {
                widget_top = text_height -| height;
            }

            const container = try doc.createElement(.div);
            container.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = @floatFromInt(left) },
                .top = .{ .cells = @floatFromInt(widget_top) },
                .width = .{ .cells = @floatFromInt(width) },
                .height = .{ .cells = @floatFromInt(height) },
                .overflow = .hidden,
            });

            const content = try widget.build(widget.context, doc);
            _ = try container.appendChild(content);
            _ = try root.appendChild(container);
            try self.content_entries.append(.{
                .widget = widget,
                .node = container,
                .left = left,
                .top = widget_top,
                .width = width,
                .height = height,
            });

            if (widget.is_focused(widget.context)) {
                if (widget.focus_node(widget.context)) |node| {
                    _ = doc.focus(node);
                }
            }
        }
    }
};

/// Two cells when there is room for them plus at least one text column. The
/// marker and thumb layers share these cells. Very narrow terminals keep their
/// text instead.
fn overviewRulerWidth(editor: *const Editor) usize {
    const available = editor.screen_width -| editor.gutterWidth();
    return if (available >= 3) 2 else 0;
}

fn markerGlyph(lane: decorationsOverviewRuler.Lane, vertical: decorationsOverviewRuler.Vertical) []const u8 {
    return switch (vertical) {
        .full => switch (lane) {
            .left => "▐ ", // right half of the first cell
            .center => " ▌", // left half of the second cell
            .right => " ▐", // right half of the second cell
            .full => "▐█", // all 1.5 cells
        },
        .upper => switch (lane) {
            .left => "▝ ", // upper right quadrant of the first cell
            .center => " ▘", // upper left quadrant of the second cell
            .right => " ▝", // upper right quadrant of the second cell
            .full => "▝▀", // upper 1.5 cells
        },
        .lower => switch (lane) {
            .left => "▗ ", // lower right quadrant of the first cell
            .center => " ▖", // lower left quadrant of the second cell
            .right => " ▗", // lower right quadrant of the second cell
            .full => "▗▄", // lower 1.5 cells
        },
    };
}

fn cursorLessThan(_: void, a: decorationsOverviewRuler.Cursor, b: decorationsOverviewRuler.Cursor) bool {
    return a.line_number < b.line_number;
}

const ThumbGeometry = struct {
    top: usize,
    size: usize,
};

const ThumbHalves = struct {
    top: usize,
    end: usize,
};

const ThumbPart = enum { none, upper, lower, full };

fn thumbHalfGeometry(state: scrollbar_state.ScrollbarState, track_height: usize) ThumbHalves {
    const total_halves = track_height * 2;
    if (track_height == 0 or total_halves == 0) return .{ .top = 0, .end = 0 };

    const raw_top = @round(state.getSliderPositionExact() * 2);
    const raw_size = @round(state.getSliderSize() * 2);
    const size: usize = if (raw_size <= 0)
        1
    else
        @intFromFloat(raw_size);
    const top: usize = if (raw_top <= 0)
        0
    else if (raw_top >= @as(f64, @floatFromInt(total_halves - 1)))
        total_halves - 1
    else
        @intFromFloat(raw_top);
    return .{
        .top = top,
        .end = @min(top + size, total_halves),
    };
}

fn thumbPartAt(halves: ThumbHalves, row: usize) ThumbPart {
    const row_start = row * 2;
    const row_end = row_start + 2;
    if (halves.end <= row_start or halves.top >= row_end) return .none;
    if (halves.top <= row_start and halves.end >= row_end) return .full;
    if (halves.top <= row_start) return .upper;
    return .lower;
}

fn thumbGeometry(state: scrollbar_state.ScrollbarState, track_height: usize) ThumbGeometry {
    if (track_height == 0) return .{ .top = 0, .size = 0 };

    const raw_size = @round(state.getSliderSize());
    var size: usize = if (raw_size >= @as(f64, @floatFromInt(track_height)))
        track_height
    else if (raw_size <= 0)
        1
    else
        @intFromFloat(raw_size);
    if (size == 0) size = 1;
    if (size > track_height) size = track_height;

    const max_top = track_height - size;
    const raw_top = @round(state.getSliderPosition());
    const top: usize = if (raw_top <= 0)
        0
    else if (raw_top >= @as(f64, @floatFromInt(max_top)))
        max_top
    else
        @intFromFloat(raw_top);

    return .{ .top = top, .size = size };
}

/// Applies a scrollbar's zero-based scroll position to the editor and returns
/// the clamped position.
fn applyScrollPosition(editor: *Editor, desired: f64) usize {
    const max_scroll = editor.scrollHeight() -| editor.textHeight();
    const clamped: usize = if (!(desired > 0))
        0
    else if (desired >= @as(f64, @floatFromInt(max_scroll)))
        max_scroll
    else
        @min(@as(usize, @intFromFloat(@round(desired))), max_scroll);
    _ = editor.setTopViewLine(clamped + 1);
    return clamped;
}

fn appendStatus(view: *View, doc: *ui.Document, root: *ui.Node, rows: usize) !void {
    if (rows == 0 or !view.status_bar_visible) return;
    const editor = view.editor;
    const status_row: f64 = @floatFromInt(rows - 1);

    const bar = try doc.createElement(.div);
    bar.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = status_row },
        .width = .{ .percent = 100 },
        .height = .{ .cells = 1 },
        .white_space = .pre,
        .overflow = .hidden,
        .reverse = true,
    });

    if (view.status_left_len > 0 or view.status_right_len > 0) {
        if (view.status_left_len > 0) {
            const left = try doc.createText(view.status_left[0..view.status_left_len]);
            _ = try bar.appendChild(left);
        }
        if (view.status_right_len > 0) {
            const right = try doc.createElement(.div);
            right.setStyle(.{
                .position = .absolute,
                .right = .{ .cells = 0 },
                .top = .{ .cells = 0 },
                .white_space = .pre,
            });
            const text = try doc.createText(view.status_right[0..view.status_right_len]);
            _ = try right.appendChild(text);
            _ = try bar.appendChild(right);
        }
        _ = try root.appendChild(bar);
        return;
    }

    var status_buf: [1024]u8 = undefined;
    const position = editor.modelCursorPosition();
    const message = editor.message();
    const status = std.fmt.bufPrint(
        &status_buf,
        " {s}{s}  Ln {d}, Col {d}  {s}  Ctrl-Q quit{s}{s}",
        .{
            editor.path,
            if (editor.isDirty()) "*" else "",
            position.lineNumber,
            position.column,
            editor.languageId(),
            if (message.len > 0) "  " else "",
            message,
        },
    ) catch status_buf[0..0];

    const text = try doc.createText(status);
    _ = try bar.appendChild(text);
    _ = try root.appendChild(bar);
}

fn appendRuns(
    doc: *ui.Document,
    line: *ui.Node,
    rendered: line_renderer.RenderedLine,
    flags: []const u16,
) !void {
    var part_index: usize = 0;
    var byte_in_part: usize = 0;
    var cell: usize = 0;
    var absolute: usize = 0;

    var run_start: usize = 0;
    var run_style: ?ui.Style = null;

    while (part_index < rendered.parts.len) {
        const part = rendered.parts[part_index];
        if (byte_in_part >= part.text.len) {
            part_index += 1;
            byte_in_part = 0;
            continue;
        }

        const decoded = ui.dom.decodeAt(part.text, byte_in_part);
        if (decoded.len == 0) break;
        const width = measureCodepoint(decoded.cp);

        var style = tokenStyle(part);
        if (cell < flags.len) {
            const flag = flags[cell];
            if (flag & CellFlag.search_range_highlight != 0) {
                style.background = color(search_range_highlight_background);
            }
            if (flag & CellFlag.word_highlight_text != 0) {
                style.background = color(word_highlight_background);
            } else if (flag & CellFlag.word_highlight != 0) {
                style.background = color(word_highlight_background);
            } else if (flag & CellFlag.word_highlight_strong != 0) {
                style.background = color(word_highlight_strong_background);
            }
            if (flag & CellFlag.hover_highlight != 0) {
                style.background = color(hover_highlight_background);
            }
            if (flag & CellFlag.bracket_match != 0) {
                style.background = color(bracket_match_background);
                style.color = color(bracket_match_foreground);
                style.underline = true;
            }
            if (flag & CellFlag.current_find_match != 0) {
                style.background = color(current_find_match_background);
                style.color = color(current_find_match_foreground);
            } else if (flag & CellFlag.find_match != 0) {
                style.background = color(find_match_background);
            } else if (flag & CellFlag.find_scope != 0) {
                style.background = color(find_scope_background);
            }
            if (flag & CellFlag.snippet_placeholder != 0) {
                style.background = color(snippet_placeholder_background);
            } else if (flag & CellFlag.finish_snippet_placeholder != 0) {
                style.background = color(finish_snippet_placeholder_background);
            }
            if (flag & CellFlag.value_set_replacement != 0) {
                // The browser draws a 2 px bracket-match outline; a cell has no
                // outline, so use the same foreground color as an underline.
                style.color = color(bracket_match_foreground);
                style.underline = true;
            }
            if (flag & CellFlag.secondary_cursor != 0) {
                style.reverse = true;
                style.background = color(secondary_cursor_background);
            }
            if (flag & CellFlag.selected != 0) style.reverse = true;
        }

        if (run_style == null or !styleEql(run_style.?, style)) {
            if (run_style != null and absolute > run_start) {
                const node = try doc.createText(rendered.bytes[run_start..absolute]);
                node.setStyle(run_style.?);
                _ = try line.appendChild(node);
            }
            run_start = absolute;
            run_style = style;
        }

        absolute += decoded.len;
        byte_in_part += decoded.len;
        cell += width;
    }

    if (run_style != null and absolute > run_start) {
        const node = try doc.createText(rendered.bytes[run_start..absolute]);
        node.setStyle(run_style.?);
        _ = try line.appendChild(node);
    }
}

fn markSelections(
    states: []const CursorState,
    view_line: usize,
    model_content: []const u8,
    tab_size: usize,
    start_visible_column: usize,
    indent_cells: usize,
    line_width: usize,
    flags: []u16,
) void {
    for (states) |state| {
        const selection = state.viewState.selection;
        if (selection.isEmpty()) continue;
        if (view_line < selection.startLineNumber or view_line > selection.endLineNumber) continue;

        var start: usize = 0;
        if (view_line == selection.startLineNumber) {
            start = visibleOffset(model_content, selection.startColumn, tab_size, start_visible_column, indent_cells);
        }
        var end: usize = line_width;
        if (view_line == selection.endLineNumber) {
            end = visibleOffset(model_content, selection.endColumn, tab_size, start_visible_column, indent_cells);
        }
        start = @min(start, line_width);
        end = @min(end, line_width);
        var cell = start;
        while (cell < end and cell < flags.len) : (cell += 1) {
            flags[cell] |= CellFlag.selected;
        }
    }

    if (states.len > 1) {
        for (states[1..]) |state| {
            const position = state.viewState.position;
            if (position.lineNumber != view_line) continue;
            const cell = visibleOffset(model_content, position.column, tab_size, start_visible_column, indent_cells);
            if (cell < flags.len) flags[cell] |= CellFlag.secondary_cursor;
        }
    }
}

fn visibleOffset(
    model_content: []const u8,
    column: usize,
    tab_size: usize,
    start_visible_column: usize,
    indent_cells: usize,
) usize {
    const visible = CursorColumns.visibleColumnFromColumn(model_content, column, tab_size);
    return (visible -| start_visible_column) + indent_cells;
}

fn tokenStyle(part: line_renderer.RenderedPart) ui.Style {
    var style = ui.Style{
        .bold = part.bold,
        .italic = part.italic,
        .underline = part.underline,
        .strikethrough = part.strikethrough,
    };
    if (theme.colorForToken(part.foreground)) |rgb| {
        style.color = color(rgb);
    }
    return style;
}

fn styleEql(a: ui.Style, b: ui.Style) bool {
    return std.meta.eql(a, b);
}

fn appendModelInlineDecorations(
    out: *std.array_list.Managed(InlineDecoration),
    model: *TextModel,
    model_line: usize,
    allocator: std.mem.Allocator,
) !void {
    const decorations = try model.getLineDecorations(model_line, 0, false);
    defer allocator.free(decorations);
    for (decorations) |decoration| {
        const class_name = decoration.options.inlineClassName orelse
            decoration.options.className orelse continue;
        if (decorationBit(class_name) == null) continue;
        try out.append(.{
            .range = decoration.range,
            .inlineClassName = class_name,
            .type = .Regular,
        });
    }
}

fn decorationBit(class_name: []const u8) ?u16 {
    if (std.mem.eql(u8, class_name, "findMatch") or std.mem.eql(u8, class_name, "findMatchInline")) return CellFlag.find_match;
    if (std.mem.eql(u8, class_name, "currentFindMatch") or std.mem.eql(u8, class_name, "currentFindMatchInline")) return CellFlag.current_find_match;
    if (std.mem.eql(u8, class_name, "findScope")) return CellFlag.find_scope;
    if (std.mem.eql(u8, class_name, "bracket-match") or std.mem.eql(u8, class_name, "bracket-match-inline")) return CellFlag.bracket_match;
    if (std.mem.eql(u8, class_name, "hoverHighlight")) return CellFlag.hover_highlight;
    if (std.mem.eql(u8, class_name, "wordHighlightText")) return CellFlag.word_highlight_text;
    if (std.mem.eql(u8, class_name, "wordHighlight")) return CellFlag.word_highlight;
    if (std.mem.eql(u8, class_name, "wordHighlightStrong")) return CellFlag.word_highlight_strong;
    if (std.mem.eql(u8, class_name, "snippet-placeholder")) return CellFlag.snippet_placeholder;
    if (std.mem.eql(u8, class_name, "finish-snippet-placeholder")) return CellFlag.finish_snippet_placeholder;
    if (std.mem.eql(u8, class_name, "valueSetReplacement")) return CellFlag.value_set_replacement;
    if (std.mem.eql(u8, class_name, "rangeHighlight")) return CellFlag.search_range_highlight;
    return null;
}

fn ceilDiv(value: usize, divisor: usize) usize {
    return value / divisor + @intFromBool(value % divisor != 0);
}

fn viewRowForModelLine(editor: *Editor, top: usize, model_line: usize) ?usize {
    const view_position = editor.viewPositionOfModelPosition(Position.init(model_line, 1));
    if (view_position.lineNumber < top) return null;
    const row = view_position.lineNumber - top;
    if (row >= editor.textHeight()) return null;
    return row;
}

fn measureCodepoint(cp: u21) u2 {
    const next = CursorColumns.nextVisibleColumn(cp, 0, 1);
    return @intCast(@min(next, 2));
}

fn color(rgb: [3]u8) ui.Color {
    return .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
}

fn rowText(view: *View, allocator: std.mem.Allocator, row: usize) ![]u8 {
    return view.surface.grid().rowText(allocator, row);
}

fn numberedLines(allocator: std.mem.Allocator, count: usize) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    var buffer: [32]u8 = undefined;
    for (0..count) |index| {
        if (index != 0) try out.append('\n');
        const text = try std.fmt.bufPrint(&buffer, "line{d}", .{index});
        try out.appendSlice(text);
    }
    return out.toOwnedSlice();
}

test "View: text, gutter and status" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "a\nb", "test.txt", 80, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    const row0 = try rowText(view, allocator, 0);
    defer allocator.free(row0);
    try std.testing.expect(std.mem.indexOf(u8, row0, "1") != null);
    try std.testing.expect(std.mem.indexOf(u8, row0, "a") != null);

    const row1 = try rowText(view, allocator, 1);
    defer allocator.free(row1);
    try std.testing.expect(std.mem.indexOf(u8, row1, "2") != null);
    try std.testing.expect(std.mem.indexOf(u8, row1, "b") != null);

    const status = try rowText(view, allocator, 4);
    defer allocator.free(status);
    try std.testing.expect(std.mem.indexOf(u8, status, "Ctrl-Q") != null);

    const cursor = view.cursorCell().?;
    try std.testing.expectEqual(@as(usize, 0), cursor.row);
    try std.testing.expectEqual(editor.gutterWidth(), cursor.col);
}

test "View: CJK and tab runs keep the caret on the right cell" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "中\tq", "test.txt", 20, 3);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    const row = try rowText(view, allocator, 0);
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "中") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "q") != null);

    // The caret is at column 1, on the first cell after the gutter.
    const cursor = view.cursorCell().?;
    try std.testing.expectEqual(editor.gutterWidth(), cursor.col);
}

test "View: wrapped continuation gets a gutter arrow" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(
        allocator,
        io,
        "abcdefghij klmno",
        "test.txt",
        12,
        6,
    );
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    var found_arrow = false;
    var row: usize = 0;
    while (row < editor.textHeight()) : (row += 1) {
        const text = try rowText(view, allocator, row);
        defer allocator.free(text);
        if (std.mem.indexOf(u8, text, "↪") != null) {
            found_arrow = true;
            break;
        }
    }
    try std.testing.expect(found_arrow);
}

test "View: selection paints inverted cells" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "hello", "test.txt", 20, 3);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    try editor.moveRight(true);
    try editor.moveRight(true);

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    const grid = view.surface.grid();
    const gutter = editor.gutterWidth();
    try std.testing.expect(grid.attrs[grid.index(gutter, 0)] & ui.cell.Attr.inverse != 0);
    try std.testing.expectEqual(@as(u16, 0), grid.attrs[grid.index(gutter + 2, 0)] & ui.cell.Attr.inverse);
}

test "View: refresh keeps the frame diff and the cursor visible" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "a\nb", "test.txt", 20, 4);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var first: std.Io.Writer.Allocating = .init(allocator);
    defer first.deinit();
    try view.render(&first.writer);
    try std.testing.expect(first.written().len > 0);

    var unchanged: std.Io.Writer.Allocating = .init(allocator);
    defer unchanged.deinit();
    try view.refresh();
    try view.render(&unchanged.writer);
    try std.testing.expectEqual(@as(usize, 0), unchanged.written().len);

    try editor.moveDown(false);
    try view.refresh();
    var moved: std.Io.Writer.Allocating = .init(allocator);
    defer moved.deinit();
    try view.render(&moved.writer);
    try std.testing.expect(moved.written().len > 0);
    try std.testing.expectEqual(@as(usize, 1), view.cursorCell().?.row);
}

const TestOverlay = struct {
    focused: bool = false,
    node: ?*ui.Node = null,
    keys: usize = 0,

    fn overlay(self: *TestOverlay) editorBrowser.IOverlayWidget {
        return .{
            .context = self,
            .get_id = getId,
            .get_position = getPosition,
            .width = width,
            .height = height,
            .build = build,
            .focus_node = focusNode,
            .is_focused = isFocused,
        };
    }

    fn getId(context: *anyopaque) []const u8 {
        _ = context;
        return "test.overlay";
    }

    fn getPosition(context: *anyopaque) editorBrowser.OverlayWidgetPositionPreference {
        _ = context;
        return .top_right_corner;
    }

    fn width(context: *anyopaque, cols: usize) usize {
        _ = context;
        return @min(cols, 6);
    }

    fn height(context: *anyopaque) usize {
        _ = context;
        return 1;
    }

    fn build(context: *anyopaque, doc: *ui.Document) !*ui.Node {
        const self: *TestOverlay = @ptrCast(@alignCast(context));
        const node = try doc.createElement(.div);
        node.asElement().focusable = true;
        node.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = 0 },
            .top = .{ .cells = 0 },
            .width = .{ .percent = 100 },
            .height = .{ .cells = 1 },
            .white_space = .pre,
            .reverse = true,
        });
        _ = try node.appendChild(try doc.createText("test"));
        try node.addEventListener(.{ .context = self, .key_down = onKey });
        self.node = node;
        return node;
    }

    fn focusNode(context: *anyopaque) ?*ui.Node {
        const self: *TestOverlay = @ptrCast(@alignCast(context));
        return self.node;
    }

    fn isFocused(context: *anyopaque) bool {
        const self: *TestOverlay = @ptrCast(@alignCast(context));
        return self.focused;
    }

    fn onKey(context: ?*anyopaque, event: *ui.KeyEvent) void {
        const self: *TestOverlay = @ptrCast(@alignCast(context orelse return));
        self.keys += 1;
        event.stopPropagation();
        event.preventDefault();
    }
};

test "View: overlay widget is placed top-right and takes focused keys" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "abc", "test.txt", 20, 4);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var overlay = TestOverlay{};
    try view.addOverlayWidget(overlay.overlay());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    const row = try rowText(view, allocator, 0);
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "test") != null);

    var event = ui.KeyEvent{ .key = .{ .char = 'x' } };
    try std.testing.expect(!view.dispatchKey(&event));

    overlay.focused = true;
    try view.refresh();
    try std.testing.expect(view.surface.document().activeElement() != null);
    try std.testing.expect(view.dispatchKey(&event));
    try std.testing.expectEqual(@as(usize, 1), overlay.keys);
}

const TestContentWidget = struct {
    position: Position,
    preference: editorBrowser.ContentWidgetPositionPreference = .below,
    width_cells: usize = 5,
    height_cells: usize = 1,
    node: ?*ui.Node = null,

    fn widget(self: *TestContentWidget) editorBrowser.IContentWidget {
        return .{
            .context = self,
            .get_id = getId,
            .get_position = getPosition,
            .width = width,
            .height = height,
            .build = build,
            .focus_node = focusNode,
            .is_focused = isFocused,
        };
    }

    fn getId(_: *anyopaque) []const u8 {
        return "test.content";
    }

    fn getPosition(context: *anyopaque) ?editorBrowser.IContentWidgetPosition {
        const self: *TestContentWidget = @ptrCast(@alignCast(context));
        return .{ .position = self.position, .preference = self.preference };
    }

    fn width(context: *anyopaque, cols: usize) usize {
        const self: *TestContentWidget = @ptrCast(@alignCast(context));
        return @min(self.width_cells, cols);
    }

    fn height(context: *anyopaque) usize {
        const self: *TestContentWidget = @ptrCast(@alignCast(context));
        return self.height_cells;
    }

    fn build(context: *anyopaque, doc: *ui.Document) !*ui.Node {
        const self: *TestContentWidget = @ptrCast(@alignCast(context));
        const node = try doc.createElement(.div);
        node.asElement().focusable = true;
        node.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = 0 },
            .top = .{ .cells = 0 },
            .width = .{ .percent = 100 },
            .height = .{ .cells = 1 },
            .white_space = .pre,
            .reverse = true,
        });
        _ = try node.appendChild(try doc.createText("HOVER"));
        self.node = node;
        return node;
    }

    fn focusNode(context: *anyopaque) ?*ui.Node {
        const self: *TestContentWidget = @ptrCast(@alignCast(context));
        return self.node;
    }

    fn isFocused(_: *anyopaque) bool {
        return false;
    }
};

test "View: content widget anchors to a model position" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "abcdef", "test.txt", 20, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var widget = TestContentWidget{
        .position = Position.init(1, 3),
        .width_cells = 7,
        .height_cells = 1,
    };
    try view.addContentWidget(widget.widget());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    try std.testing.expectEqual(@as(usize, 1), view.content_entries.items.len);
    const entry = view.content_entries.items[0];
    // Gutter is 3 cells wide, and column 3 starts at cell 2 of the text.
    try std.testing.expectEqual(@as(usize, 5), entry.left);
    try std.testing.expectEqual(@as(usize, 1), entry.top);

    const row = try rowText(view, allocator, 1);
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "HOVER") != null);

    const target = try view.mouseTargetAt(entry.left + 1, entry.top);
    try std.testing.expectEqual(editorBrowser.MouseTargetType.content_widget, target.type);
}

test "View: content widget anchors on a wrapped line" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "aaaa bbbb cccc dddd", "test.txt", 20, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    // Text width is 17; the word wrap puts `dddd` on the second view line.
    try std.testing.expectEqual(@as(usize, 1), view.visibleRowOf(Position.init(1, 18)).?);
    try std.testing.expectEqual(@as(usize, 0), view.visibleRowOf(Position.init(1, 1)).?);

    var widget = TestContentWidget{
        .position = Position.init(1, 18),
        .width_cells = 5,
        .height_cells = 1,
    };
    try view.addContentWidget(widget.widget());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    try std.testing.expectEqual(@as(usize, 2), view.content_entries.items[0].top);
    // Column 18 is the third cell of the wrapped segment, which starts at the
    // left edge of the text area.
    try std.testing.expectEqual(@as(usize, 5), view.content_entries.items[0].left);
}

test "View: content widget flips above and clamps to the text area" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "a\nb\nc", "test.txt", 12, 4);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var below = TestContentWidget{
        .position = Position.init(2, 1),
        .preference = .below,
        .width_cells = 5,
        .height_cells = 2,
    };
    try view.addContentWidget(below.widget());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    // Row 1 is the anchor; two rows below do not fit the three-row text area,
    // so the widget is clamped to its last two rows.
    try std.testing.expectEqual(@as(usize, 1), view.content_entries.items[0].top);

    below.preference = .above;
    try view.refresh();
    try view.render(&out.writer);
    try std.testing.expectEqual(@as(usize, 0), view.content_entries.items[0].top);
}

test "View: word highlight decorations paint text and strong colors" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "word word", "test.txt", 20, 4);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();
    try view.setWordHighlights(&[_]editorBrowser.Decoration{
        .{ .range = Range.init(1, 1, 1, 5), .kind = .word_highlight_text },
        .{ .range = Range.init(1, 6, 1, 10), .kind = .word_highlight_strong },
    });
    try view.refresh();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    const grid = view.surface.grid();
    const gutter = editor.gutterWidth();
    const text = ui.cell.unpackColor(grid.bg[grid.index(gutter, 0)]);
    try std.testing.expectEqual(@as(u8, 71), text.r);
    try std.testing.expectEqual(@as(u8, 71), text.g);
    const strong = ui.cell.unpackColor(grid.bg[grid.index(gutter + 5, 0)]);
    try std.testing.expectEqual(@as(u8, 8), strong.r);
    try std.testing.expectEqual(@as(u8, 61), strong.g);
    try std.testing.expectEqual(@as(u8, 91), strong.b);
}

test "View: hover highlight paints the anchor range" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "abcdef", "test.txt", 20, 4);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();
    try view.setHoverDecorations(&[_]editorBrowser.Decoration{
        .{ .range = Range.init(1, 2, 1, 5), .kind = .hover_highlight },
    });
    try view.refresh();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    const grid = view.surface.grid();
    // Gutter is 2; columns 2..4 of the text are highlighted.
    const background = grid.bg[grid.index(3, 0)];
    try std.testing.expect(background != 0);
}

test "View: gutter fold control collapses and expands a region" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(
        allocator,
        io,
        "class A {\n  void f() {\n    x();\n  }\n}",
        "test.zig",
        40,
        8,
    );
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    const view = try View.init(allocator, editor);
    defer view.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    const gutter = editor.gutterWidth();
    const grid = view.surface.grid();
    try std.testing.expectEqual(@as(u32, '▾'), grid.cluster[grid.index(gutter - 1, 0)]);
    const target = try view.mouseTargetAt(gutter - 1, 0);
    try std.testing.expectEqual(editorBrowser.MouseTargetType.gutter_line_decorations, target.type);

    var down = testMouse(.down, gutter - 1, 0);
    try std.testing.expect(try view.dispatchMouse(&down));
    try std.testing.expectEqual(@as(usize, 2), editor.viewLineCount());
    try std.testing.expectEqual(@as(usize, 5), editor.modelLineNumber(2));

    try view.render(&out.writer);
    try std.testing.expectEqual(@as(u32, '▸'), grid.cluster[grid.index(gutter - 1, 0)]);
    const row1 = try rowText(view, allocator, 1);
    defer allocator.free(row1);
    try std.testing.expect(std.mem.indexOf(u8, row1, "5") != null);

    var up = testMouse(.up, gutter - 1, 0);
    _ = try view.dispatchMouse(&up);
    var down_again = testMouse(.down, gutter - 1, 0);
    try std.testing.expect(try view.dispatchMouse(&down_again));
    try std.testing.expectEqual(@as(usize, 5), editor.viewLineCount());
}

test "View: mouse target distinguishes text, empty area, gutter and status" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "abc", "test.txt", 20, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    const on_text = try view.mouseTargetAt(4, 0);
    try std.testing.expectEqual(editorBrowser.MouseTargetType.content_text, on_text.type);
    try std.testing.expectEqual(@as(usize, 2), on_text.position.?.column);

    const empty = try view.mouseTargetAt(15, 0);
    try std.testing.expectEqual(editorBrowser.MouseTargetType.content_empty, empty.type);
    const empty_detail = empty.detail.?.content_empty;
    try std.testing.expect(!empty_detail.is_after_lines);

    const after_lines = try view.mouseTargetAt(3, 3);
    try std.testing.expectEqual(editorBrowser.MouseTargetType.content_empty, after_lines.type);
    try std.testing.expect(after_lines.detail.?.content_empty.is_after_lines);

    const gutter = try view.mouseTargetAt(0, 0);
    try std.testing.expectEqual(editorBrowser.MouseTargetType.gutter_line_numbers, gutter.type);

    const status = try view.mouseTargetAt(3, 4);
    try std.testing.expectEqual(editorBrowser.MouseTargetType.status, status.type);
}

test "View: the gutter keeps a blank cell before the text" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "a\nb", "test.txt", 20, 4);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    const gutter = editor.gutterWidth();
    const grid = view.surface.grid();
    // Number column: right-aligned in `gutter - 1`; the last gutter cell is the
    // decorations/gap column; text starts at `gutter`.
    try std.testing.expectEqual(@as(u32, '1'), grid.cluster[grid.index(gutter - 2, 0)]);
    try std.testing.expectEqual(@as(u32, 0), grid.cluster[grid.index(gutter - 1, 0)]);
    try std.testing.expectEqual(@as(u32, 'a'), grid.cluster[grid.index(gutter, 0)]);
}

fn testMouse(kind: ui.MouseKind, x: usize, y: usize) ui.MouseEvent {
    return .{ .kind = kind, .x = x, .y = y, .button = .left };
}

test "View: a left click places the caret and ignores gutter and status" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "abc\ndef", "test.txt", 40, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    const gutter = editor.gutterWidth();
    var down = testMouse(.down, gutter + 1, 1);
    try std.testing.expect(try view.dispatchMouse(&down));
    try std.testing.expectEqual(@as(usize, 2), editor.modelCursorPosition().lineNumber);
    try std.testing.expectEqual(@as(usize, 2), editor.modelCursorPosition().column);

    // The status row and the gutter are not text.
    try editor.setCursorPosition(Position.init(1, 2));
    var gutter_click = testMouse(.down, gutter -| 1, 0);
    try std.testing.expect(!try view.dispatchMouse(&gutter_click));
    try std.testing.expectEqual(@as(usize, 1), editor.modelCursorPosition().lineNumber);
    try std.testing.expectEqual(@as(usize, 2), editor.modelCursorPosition().column);

    var status_click = testMouse(.down, gutter, 5);
    try std.testing.expect(!try view.dispatchMouse(&status_click));
    try std.testing.expectEqual(@as(usize, 1), editor.modelCursorPosition().lineNumber);

    // Past the end of the line clamps to its last column.
    var past_end = testMouse(.down, gutter + 20, 0);
    try std.testing.expect(try view.dispatchMouse(&past_end));
    try std.testing.expectEqual(@as(usize, 4), editor.modelCursorPosition().column);
}

test "View: clicks account for tabs, wide characters and wrapped lines" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "ab\tcd\na何b", "test.txt", 40, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    const view = try View.init(allocator, editor);
    defer view.deinit();
    const gutter = editor.gutterWidth();

    // ab -> cells 0-1, tab -> 2-3, c -> 4, d -> 5.
    var tab_click = testMouse(.down, gutter + 4, 0);
    try std.testing.expect(try view.dispatchMouse(&tab_click));
    try std.testing.expectEqual(@as(usize, 4), editor.modelCursorPosition().column);

    // a -> cell 0, 何 -> cells 1-2, b -> cell 3.
    var wide_click = testMouse(.down, gutter + 3, 1);
    try std.testing.expect(try view.dispatchMouse(&wide_click));
    try std.testing.expectEqual(@as(usize, 5), editor.modelCursorPosition().column);
}

test "View: a click on a wrapped continuation maps to its model line" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "abcdefghij", "test.txt", 8, 4);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    const view = try View.init(allocator, editor);
    defer view.deinit();
    try std.testing.expect(editor.viewLineCount() > 1);

    const expected = try editor.positionAtViewPoint(2, 0);
    var click = testMouse(.down, editor.gutterWidth(), 1);
    try std.testing.expect(try view.dispatchMouse(&click));
    try std.testing.expectEqual(expected.lineNumber, editor.modelCursorPosition().lineNumber);
    try std.testing.expectEqual(expected.column, editor.modelCursorPosition().column);
}

test "View: shift-click extends and a drag selects without clicking" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "hello world", "test.txt", 40, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    const view = try View.init(allocator, editor);
    defer view.deinit();
    const gutter = editor.gutterWidth();

    var first = testMouse(.down, gutter, 0);
    _ = try view.dispatchMouse(&first);
    var extend = testMouse(.down, gutter + 3, 0);
    extend.mods.shift = true;
    try std.testing.expect(try view.dispatchMouse(&extend));
    const extended = editor.modelSelection();
    try std.testing.expectEqual(@as(usize, 1), extended.selectionStartColumn);
    try std.testing.expectEqual(@as(usize, 4), extended.positionColumn);

    const ClickLog = struct {
        count: usize = 0,

        fn onClick(context: ?*anyopaque, _: *ui.MouseEvent) void {
            const self: *@This() = @ptrCast(@alignCast(context orelse return));
            self.count += 1;
        }
    };
    var clicks = ClickLog{};
    try view.surface.document().root.?.addEventListener(.{
        .context = &clicks,
        .click = ClickLog.onClick,
    });

    var down = testMouse(.down, gutter, 0);
    _ = try view.dispatchMouse(&down);
    var move = testMouse(.move, gutter + 4, 0);
    try std.testing.expect(try view.dispatchMouse(&move));
    const selected = editor.modelSelection();
    try std.testing.expectEqual(@as(usize, 1), selected.startColumn);
    try std.testing.expectEqual(@as(usize, 5), selected.endColumn);
    var up = testMouse(.up, gutter + 4, 0);
    try std.testing.expect(!try view.dispatchMouse(&up));
    try std.testing.expectEqual(@as(usize, 0), clicks.count);

    // A plain press and release still clicks.
    var plain_down = testMouse(.down, gutter, 0);
    _ = try view.dispatchMouse(&plain_down);
    var plain_up = testMouse(.up, gutter, 0);
    _ = try view.dispatchMouse(&plain_up);
    try std.testing.expectEqual(@as(usize, 1), clicks.count);
}

test "View: the wheel scrolls without moving the caret and clamps" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(
        allocator,
        io,
        "line0\nline1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\nline11",
        "test.txt",
        40,
        5,
    );
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    const view = try View.init(allocator, editor);
    defer view.deinit();
    try std.testing.expectEqual(@as(usize, 1), editor.topViewLine());

    var down = ui.MouseEvent{ .kind = .wheel, .x = 1, .y = 0, .delta_y = 3 };
    try std.testing.expect(!try view.dispatchMouse(&down));
    try std.testing.expectEqual(@as(usize, 4), editor.topViewLine());
    try std.testing.expectEqual(@as(usize, 1), editor.modelCursorPosition().lineNumber);

    try view.refresh();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);
    const row = try rowText(view, allocator, 0);
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "line3") != null);
    // The caret is off-screen, so the hardware cursor has no cell.
    try std.testing.expectEqual(@as(?Cell, null), view.cursorCell());

    // The status row does not scroll.
    var status = ui.MouseEvent{ .kind = .wheel, .x = 1, .y = 4, .delta_y = 3 };
    try std.testing.expect(!try view.dispatchMouse(&status));
    try std.testing.expectEqual(@as(usize, 4), editor.topViewLine());

    var up = ui.MouseEvent{ .kind = .wheel, .x = 1, .y = 0, .delta_y = -3 };
    _ = try view.dispatchMouse(&up);
    try std.testing.expectEqual(@as(usize, 1), editor.topViewLine());

    var end = ui.MouseEvent{ .kind = .wheel, .x = 1, .y = 0, .delta_y = 100 };
    _ = try view.dispatchMouse(&end);
    const max_top = editor.viewLineCount() - editor.textHeight() + 1;
    try std.testing.expectEqual(max_top, editor.topViewLine());

    // The next cursor move reveals the caret again.
    try editor.moveDown(false);
    try std.testing.expect(editor.topViewLine() <= editor.modelCursorPosition().lineNumber);
}

test "View: matching brackets are highlighted while the cursor is on one" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "(a)\n(\n)\nx", "test.zig", 20, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    try editor.setCursorPosition(Position.init(1, 2));
    try view.refresh();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    const gutter = editor.gutterWidth();
    const bracket_bg = ui.cell.packColor(color(bracket_match_background));
    var grid = view.surface.grid();
    try std.testing.expectEqual(bracket_bg, grid.bg[grid.index(gutter, 0)]);
    try std.testing.expectEqual(bracket_bg, grid.bg[grid.index(gutter + 2, 0)]);

    // Cursor off any bracket clears the highlights.
    try editor.setCursorPosition(Position.init(4, 1));
    try view.refresh();
    try view.render(&out.writer);
    grid = view.surface.grid();
    try std.testing.expect(grid.bg[grid.index(gutter, 0)] != bracket_bg);
    try std.testing.expect(grid.bg[grid.index(gutter + 2, 0)] != bracket_bg);

    // A pair spanning lines highlights both brackets.
    try editor.setCursorPosition(Position.init(2, 2));
    try view.refresh();
    try view.render(&out.writer);
    grid = view.surface.grid();
    try std.testing.expectEqual(bracket_bg, grid.bg[grid.index(gutter, 1)]);
    try std.testing.expectEqual(bracket_bg, grid.bg[grid.index(gutter, 2)]);
}

test "View: a focused widget hides bracket highlights" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "(a)", "test.zig", 20, 4);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();
    try editor.setCursorPosition(Position.init(1, 2));

    var overlay = TestOverlay{ .focused = true };
    try view.addOverlayWidget(overlay.overlay());
    try view.refresh();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);
    const gutter = editor.gutterWidth();
    const bracket_bg = ui.cell.packColor(color(bracket_match_background));
    const grid = view.surface.grid();
    try std.testing.expect(grid.bg[grid.index(gutter, 0)] != bracket_bg);
}

test "View: typing an auto-closed bracket highlights the pair" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "", "test.zig", 20, 4);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    try editor.typeCharacter("(");
    try view.refresh();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    const gutter = editor.gutterWidth();
    const bracket_bg = ui.cell.packColor(color(bracket_match_background));
    const grid = view.surface.grid();
    try std.testing.expectEqual(bracket_bg, grid.bg[grid.index(gutter, 0)]);
    try std.testing.expectEqual(bracket_bg, grid.bg[grid.index(gutter + 1, 0)]);
}

test "View: bracket highlights stay on their wrapped segment" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "(abcdefghij)", "test.zig", 10, 4);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try std.testing.expect(editor.viewLineCount() > 1);

    const view = try View.init(allocator, editor);
    defer view.deinit();
    try editor.setCursorPosition(Position.init(1, 2));
    try view.refresh();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    const gutter = editor.gutterWidth();
    const bracket_bg = ui.cell.packColor(color(bracket_match_background));
    const grid = view.surface.grid();
    // The opening bracket is on the first segment.
    try std.testing.expectEqual(bracket_bg, grid.bg[grid.index(gutter, 0)]);
    // The last continuation is "j)"; its closing bracket is one cell in.
    try std.testing.expectEqual(bracket_bg, grid.bg[grid.index(gutter + 1, 2)]);
    // Previous continuations must not get a mis-mapped cell at their start.
    try std.testing.expect(grid.bg[grid.index(gutter, 1)] != bracket_bg);
    try std.testing.expect(grid.bg[grid.index(gutter, 2)] != bracket_bg);
}

test "View: find decorations stay on their wrapped segment" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "abcdefghij", "test.txt", 11, 4);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try std.testing.expect(editor.viewLineCount() > 1);

    const view = try View.init(allocator, editor);
    defer view.deinit();
    try view.setDecorations(&[_]editorBrowser.Decoration{
        .{ .range = Range.init(1, 7, 1, 11), .kind = .find_match },
    });
    try view.refresh();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    const gutter = editor.gutterWidth();
    const match_bg = ui.cell.packColor(color(find_match_background));
    const grid = view.surface.grid();
    // "ghij" is the whole second segment: cells 0..3.
    var cell: usize = 0;
    while (cell < 4) : (cell += 1) {
        try std.testing.expectEqual(match_bg, grid.bg[grid.index(gutter + cell, 1)]);
    }
    try std.testing.expect(grid.bg[grid.index(gutter + 4, 1)] != match_bg);
    cell = 0;
    while (cell < 5) : (cell += 1) {
        try std.testing.expect(grid.bg[grid.index(gutter + cell, 0)] != match_bg);
    }
}

test "View: bracket highlights include the synthetic wrap indentation" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "    (abcdefghij)", "test.zig", 11, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try std.testing.expect(editor.viewLineCount() > 1);

    const view = try View.init(allocator, editor);
    defer view.deinit();
    try editor.setCursorPosition(Position.init(1, 6));
    try view.refresh();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    const gutter = editor.gutterWidth();
    const cols = view.surface.document().cols;
    const rows = editor.textHeight();
    const bracket_bg = ui.cell.packColor(color(bracket_match_background));
    const grid = view.surface.grid();

    var found_open = false;
    var found_close = false;
    var row: usize = 0;
    while (row < rows) : (row += 1) {
        var col = gutter;
        while (col < cols) : (col += 1) {
            const cluster = grid.cluster[grid.index(col, row)];
            if (cluster == '(') {
                found_open = true;
                try std.testing.expectEqual(bracket_bg, grid.bg[grid.index(col, row)]);
            } else if (cluster == ')') {
                found_close = true;
                try std.testing.expectEqual(bracket_bg, grid.bg[grid.index(col, row)]);
            }
        }
    }
    try std.testing.expect(found_open);
    try std.testing.expect(found_close);

    // Synthetic indentation cells are not bracket cells.
    row = 1;
    while (row < rows) : (row += 1) {
        try std.testing.expect(grid.bg[grid.index(gutter, row)] != bracket_bg);
    }
}

test "View: right column paints markers and the overlapping thumb" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const text = try numberedLines(allocator, 20);
    defer allocator.free(text);
    const editor = try Editor.createFromText(allocator, io, text, "test.txt", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();
    try editor.setCursorPosition(Position.init(8, 1));
    try view.setDecorations(&[_]editorBrowser.Decoration{
        .{ .range = Range.init(1, 1, 1, 2), .kind = .find_match },
        .{ .range = Range.init(10, 1, 10, 2), .kind = .find_match },
    });
    try view.refresh();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    const cols = view.surface.document().cols;
    const grid = view.surface.grid();
    try std.testing.expectEqual(@as(usize, 2), view.scrollbar_width);
    const marker_col = cols - 2;
    const thumb_col = cols - 1;
    try std.testing.expectEqual(marker_col, editor.textAreaRight());

    const find_fg = ui.cell.packColor(color(overview_find_color));
    const thumb_fg = ui.cell.packColor(color(scrollbar_thumb_color));

    // Twenty lines in a seven-row track need a 1.5-cell thumb. The cursor
    // scrolls the viewport, so the exact thumb position starts at the lower
    // half of row 0; half-cell glyphs render that edge.
    try std.testing.expectEqual(@as(u32, '▗'), grid.cluster[grid.index(marker_col, 0)]);
    try std.testing.expectEqual(@as(u32, '▄'), grid.cluster[grid.index(thumb_col, 0)]);
    try std.testing.expectEqual(thumb_fg, grid.fg[grid.index(marker_col, 0)]);
    try std.testing.expectEqual(thumb_fg, grid.fg[grid.index(thumb_col, 0)]);
    try std.testing.expectEqual(@as(u32, '▐'), grid.cluster[grid.index(marker_col, 1)]);
    try std.testing.expectEqual(@as(u32, '█'), grid.cluster[grid.index(thumb_col, 1)]);
    try std.testing.expectEqual(thumb_fg, grid.fg[grid.index(marker_col, 1)]);
    try std.testing.expectEqual(thumb_fg, grid.fg[grid.index(thumb_col, 1)]);
    try std.testing.expectEqual(@as(u32, '▝'), grid.cluster[grid.index(marker_col, 2)]);
    try std.testing.expectEqual(@as(u32, '▀'), grid.cluster[grid.index(thumb_col, 2)]);
    try std.testing.expectEqual(thumb_fg, grid.fg[grid.index(marker_col, 2)]);
    try std.testing.expectEqual(thumb_fg, grid.fg[grid.index(thumb_col, 2)]);
    // Find markers use the first lane: right half of the first cell.
    try std.testing.expectEqual(@as(u32, '▐'), grid.cluster[grid.index(marker_col, 3)]);
    try std.testing.expectEqual(@as(u32, ' '), grid.cluster[grid.index(thumb_col, 3)]);
    try std.testing.expectEqual(find_fg, grid.fg[grid.index(marker_col, 3)]);

    // The shared area is two cells wide: the cell immediately to its left is
    // the end of the text area, not another scrollbar column.
    try std.testing.expectEqual(@as(u32, 0), grid.cluster[grid.index(marker_col - 1, 0)]);
    try std.testing.expectEqual(@as(u32, 0), grid.cluster[grid.index(marker_col - 1, 3)]);
}

test "View: short document has no scrollbar thumb" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "a\nb", "test.txt", 20, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();
    try view.setDecorations(&[_]editorBrowser.Decoration{
        .{ .range = Range.init(2, 1, 2, 2), .kind = .find_match },
    });
    try view.refresh();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    const cols = view.surface.document().cols;
    const grid = view.surface.grid();
    const marker_col = cols - 2;
    const thumb_col = cols - 1;
    const find_fg = ui.cell.packColor(color(overview_find_color));

    // Line 2 maps below the cursor row but no thumb is needed. Find uses the
    // first lane, so only the first cell's right half is filled.
    try std.testing.expectEqual(@as(u32, '▐'), grid.cluster[grid.index(marker_col, 1)]);
    try std.testing.expectEqual(@as(u32, ' '), grid.cluster[grid.index(thumb_col, 1)]);
    try std.testing.expectEqual(find_fg, grid.fg[grid.index(marker_col, 1)]);
    const thumb_fg = ui.cell.packColor(color(scrollbar_thumb_color));
    var row: usize = 0;
    while (row < editor.textHeight()) : (row += 1) {
        try std.testing.expect(grid.fg[grid.index(marker_col, row)] != thumb_fg);
        try std.testing.expect(grid.fg[grid.index(thumb_col, row)] != thumb_fg);
    }
}

test "View: mouse target distinguishes overview ruler and scrollbar" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const text = try numberedLines(allocator, 20);
    defer allocator.free(text);
    const editor = try Editor.createFromText(allocator, io, text, "test.txt", 40, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();
    const cols = view.surface.document().cols;

    const scrollbar = try view.mouseTargetAt(cols - 1, 0);
    try std.testing.expectEqual(editorBrowser.MouseTargetType.scrollbar, scrollbar.type);
    const ruler = try view.mouseTargetAt(cols - 2, 0);
    try std.testing.expectEqual(editorBrowser.MouseTargetType.scrollbar, ruler.type);

    const caret_before = editor.modelCursorPosition();
    var down = testMouse(.down, cols - 1, 4);
    try std.testing.expect(!try view.dispatchMouse(&down));
    var up = testMouse(.up, cols - 1, 4);
    try std.testing.expect(!try view.dispatchMouse(&up));
    try std.testing.expect(editor.topViewLine() > 1);
    try std.testing.expectEqual(caret_before.lineNumber, editor.modelCursorPosition().lineNumber);
    try std.testing.expectEqual(caret_before.column, editor.modelCursorPosition().column);

    // Dragging the thumb maps row deltas through ScrollbarState.
    try std.testing.expect(editor.setTopViewLine(1));
    try view.refresh();
    var press = testMouse(.down, cols - 1, 0);
    try std.testing.expect(!try view.dispatchMouse(&press));
    var drag = testMouse(.move, cols - 1, 4);
    try std.testing.expect(!try view.dispatchMouse(&drag));
    var release = testMouse(.up, cols - 1, 4);
    try std.testing.expect(!try view.dispatchMouse(&release));
    try std.testing.expect(editor.topViewLine() > 1);
    try std.testing.expectEqual(caret_before.lineNumber, editor.modelCursorPosition().lineNumber);
    try std.testing.expectEqual(caret_before.column, editor.modelCursorPosition().column);
}

test "View: narrow terminal hides the scrollbar columns" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "abc", "test.txt", 4, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();
    try std.testing.expectEqual(@as(usize, 0), view.scrollbar_width);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    const cols = view.surface.document().cols;
    const target = try view.mouseTargetAt(cols - 1, 0);
    try std.testing.expect(target.type != .scrollbar);

    const grid = view.surface.grid();
    var row: usize = 0;
    while (row < editor.textHeight()) : (row += 1) {
        var col: usize = 0;
        while (col < cols) : (col += 1) {
            try std.testing.expect(grid.cluster[grid.index(col, row)] != '█');
        }
    }
}

test "View: overview markers honor the per-decoration flag" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "a\nb\nc", "test.txt", 40, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var markers = std.array_list.Managed(decorationsOverviewRuler.Decoration).init(allocator);
    defer markers.deinit();
    try view.replaceModelDecorations(DecorationOwner.bracket, &[_]editorBrowser.Decoration{
        .{ .range = Range.init(1, 1, 1, 2), .kind = .bracket_match, .show_in_overview_ruler = false },
        .{ .range = Range.init(2, 1, 2, 2), .kind = .find_scope },
        .{ .range = Range.init(3, 1, 3, 2), .kind = .bracket_match },
    });
    try view.appendOverviewMarkers(&markers);
    try std.testing.expectEqual(@as(usize, 1), markers.items.len);
    try std.testing.expectEqual(@as(usize, 3), markers.items[0].start_line_number);
    try std.testing.expectEqual(overview_bracket_color, markers.items[0].color);
}

test "View: overview markers follow wrapped view lines" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "abcdefghij", "test.txt", 10, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    try std.testing.expect(editor.viewLineCount() > 1);

    const view = try View.init(allocator, editor);
    defer view.deinit();

    var markers = std.array_list.Managed(decorationsOverviewRuler.Decoration).init(allocator);
    defer markers.deinit();
    try view.replaceModelDecorations(DecorationOwner.find, &[_]editorBrowser.Decoration{
        .{ .range = Range.init(1, 1, 1, 2), .kind = .find_match },
        .{ .range = Range.init(1, 7, 1, 9), .kind = .find_match },
    });
    try view.appendOverviewMarkers(&markers);
    try std.testing.expectEqual(@as(usize, 2), markers.items.len);
    try std.testing.expectEqual(@as(usize, 1), markers.items[0].start_line_number);
    try std.testing.expectEqual(@as(usize, 2), markers.items[1].start_line_number);
}

test "View: three overview lanes use half-cell glyphs" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "a\nb\nc\nd", "test.txt", 40, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();
    try editor.setCursorPosition(Position.init(1, 1));
    try view.setDecorations(&[_]editorBrowser.Decoration{
        .{ .range = Range.init(2, 1, 2, 2), .kind = .find_match },
        .{ .range = Range.init(3, 1, 3, 2), .kind = .bracket_match },
        .{ .range = Range.init(4, 1, 4, 2), .kind = .word_highlight },
    });
    try view.refresh();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    const cols = view.surface.document().cols;
    const grid = view.surface.grid();
    const first = cols - 2;
    const second = cols - 1;

    // Cursor: half-height upper edge across the full 1.5-cell width.
    try std.testing.expectEqual(@as(u32, '▝'), grid.cluster[grid.index(first, 0)]);
    try std.testing.expectEqual(@as(u32, '▀'), grid.cluster[grid.index(second, 0)]);
    // Find: left lane, right half of the first cell.
    try std.testing.expectEqual(@as(u32, '▐'), grid.cluster[grid.index(first, 1)]);
    try std.testing.expectEqual(@as(u32, ' '), grid.cluster[grid.index(second, 1)]);
    // Bracket: right lane, right half of the second cell.
    try std.testing.expectEqual(@as(u32, ' '), grid.cluster[grid.index(first, 2)]);
    try std.testing.expectEqual(@as(u32, '▐'), grid.cluster[grid.index(second, 2)]);
    // Word: center lane, left half of the second cell.
    try std.testing.expectEqual(@as(u32, ' '), grid.cluster[grid.index(first, 3)]);
    try std.testing.expectEqual(@as(u32, '▌'), grid.cluster[grid.index(second, 3)]);
}

test "View: half-cell thumb uses quadrant edges" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const text = try numberedLines(allocator, 13);
    defer allocator.free(text);
    const editor = try Editor.createFromText(allocator, io, text, "test.txt", 40, 6);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();
    try std.testing.expect(editor.setTopViewLine(2));
    try view.refresh();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    const cols = view.surface.document().cols;
    const grid = view.surface.grid();
    const first = cols - 2;
    const second = cols - 1;

    // The thumb starts at half a cell and is one cell tall: lower half of row
    // 0, upper half of row 1.
    try std.testing.expectEqual(@as(u32, '▗'), grid.cluster[grid.index(first, 0)]);
    try std.testing.expectEqual(@as(u32, '▄'), grid.cluster[grid.index(second, 0)]);
    try std.testing.expectEqual(@as(u32, '▝'), grid.cluster[grid.index(first, 1)]);
    try std.testing.expectEqual(@as(u32, '▀'), grid.cluster[grid.index(second, 1)]);
    try std.testing.expectEqual(@as(u32, 0), grid.cluster[grid.index(first, 2)]);
}

test "View: indent guides mark leading whitespace and blank lines" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const text =
        "if x:\n" ++
        "    if y:\n" ++
        "        z()\n" ++
        "\n" ++
        "        w()\n" ++
        "    end\n" ++
        "end";
    const editor = try Editor.createFromText(allocator, io, text, "test.zig", 40, 9);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();
    try view.refresh();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    const gutter = editor.gutterWidth();
    const grid = view.surface.grid();
    const guide_fg = ui.cell.packColor(color(indent_guide_color));

    // Level 1 on the first indented line.
    try std.testing.expectEqual(@as(u32, '│'), grid.cluster[grid.index(gutter, 1)]);
    try std.testing.expectEqual(guide_fg, grid.fg[grid.index(gutter, 1)]);

    // Level 2 adds a guide at the next indentation column.
    try std.testing.expectEqual(@as(u32, '│'), grid.cluster[grid.index(gutter, 2)]);
    try std.testing.expectEqual(@as(u32, '│'), grid.cluster[grid.index(gutter + 4, 2)]);

    // The blank line inherits both guides from the surrounding block.
    try std.testing.expectEqual(@as(u32, '│'), grid.cluster[grid.index(gutter, 3)]);
    try std.testing.expectEqual(@as(u32, '│'), grid.cluster[grid.index(gutter + 4, 3)]);

    // The unindented first and last lines have no guides.
    try std.testing.expectEqual(@as(u32, 'i'), grid.cluster[grid.index(gutter, 0)]);
    try std.testing.expectEqual(@as(u32, 'e'), grid.cluster[grid.index(gutter, 6)]);
}

test "View: bracket guides follow pairs and highlight the active pair" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const text =
        "fn main() {\n" ++
        "    if (x) {\n" ++
        "        y();\n" ++
        "    }\n" ++
        "}";
    const editor = try Editor.createFromText(allocator, io, text, "test.zig", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();
    try editor.setCursorPosition(Position.init(2, 1));
    try view.refresh();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    const gutter = editor.gutterWidth();
    const grid = view.surface.grid();
    const active_fg = ui.cell.packColor(color(bracket_guide_active_color));
    const inner_fg = ui.cell.packColor(color(bracket_guide_colors[1]));

    // The opening line keeps its text; a guide is not painted over `f`.
    try std.testing.expectEqual(@as(u32, 'f'), grid.cluster[grid.index(gutter, 0)]);

    // Cursor line 2 is inside the outer pair, which is highlighted at column 0.
    try std.testing.expectEqual(@as(u32, '│'), grid.cluster[grid.index(gutter, 1)]);
    try std.testing.expectEqual(active_fg, grid.fg[grid.index(gutter, 1)]);
    try std.testing.expectEqual(@as(u32, '│'), grid.cluster[grid.index(gutter, 2)]);
    try std.testing.expectEqual(active_fg, grid.fg[grid.index(gutter, 2)]);
    try std.testing.expectEqual(@as(u32, '│'), grid.cluster[grid.index(gutter, 3)]);
    try std.testing.expectEqual(active_fg, grid.fg[grid.index(gutter, 3)]);

    // The inner pair has its own guide at column 4 and is not active.
    try std.testing.expectEqual(@as(u32, '│'), grid.cluster[grid.index(gutter + 4, 2)]);
    try std.testing.expectEqual(inner_fg, grid.fg[grid.index(gutter + 4, 2)]);
}

test "View: active indentation guide follows the cursor scope" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const text =
        "root\n" ++
        "    child\n" ++
        "        grand\n" ++
        "    sibling\n" ++
        "root";
    const editor = try Editor.createFromText(allocator, io, text, "test.zig", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();
    try editor.setCursorPosition(Position.init(2, 1));
    try view.refresh();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try view.render(&out.writer);

    const gutter = editor.gutterWidth();
    const grid = view.surface.grid();
    const active_fg = ui.cell.packColor(color(indent_guide_active_color));
    const normal_fg = ui.cell.packColor(color(indent_guide_color));

    // The whole cursor scope (rows 1-3) highlights level 1 at column 0.
    try std.testing.expectEqual(@as(u32, '│'), grid.cluster[grid.index(gutter, 1)]);
    try std.testing.expectEqual(active_fg, grid.fg[grid.index(gutter, 1)]);
    try std.testing.expectEqual(@as(u32, '│'), grid.cluster[grid.index(gutter, 2)]);
    try std.testing.expectEqual(active_fg, grid.fg[grid.index(gutter, 2)]);
    try std.testing.expectEqual(@as(u32, '│'), grid.cluster[grid.index(gutter, 3)]);
    try std.testing.expectEqual(active_fg, grid.fg[grid.index(gutter, 3)]);

    // Level 2 on `grand` remains a normal guide.
    try std.testing.expectEqual(@as(u32, '│'), grid.cluster[grid.index(gutter + 4, 2)]);
    try std.testing.expectEqual(normal_fg, grid.fg[grid.index(gutter + 4, 2)]);
}

test "View: contribution highlights are stored as model decorations" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "alpha beta alpha", "test.txt", 40, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const view = try View.init(allocator, editor);
    defer view.deinit();
    try view.setDecorations(&[_]editorBrowser.Decoration{
        .{ .range = Range.init(1, 1, 1, 6), .kind = .find_match },
        .{ .range = Range.init(1, 12, 1, 17), .kind = .find_match },
    });

    const decorations = try editor.model.getAllDecorations(1, false);
    defer allocator.free(decorations);
    try std.testing.expectEqual(@as(usize, 2), decorations.len);
    try std.testing.expectEqualStrings("findMatch", decorations[0].options.className.?);

    try view.setDecorations(&.{});
    const cleared = try editor.model.getAllDecorations(1, false);
    defer allocator.free(cleared);
    try std.testing.expectEqual(@as(usize, 0), cleared.len);
}

test "view: snippet placeholder decoration classes map to cell flags" {
    try std.testing.expectEqual(CellFlag.snippet_placeholder, decorationBit("snippet-placeholder").?);
    try std.testing.expectEqual(CellFlag.finish_snippet_placeholder, decorationBit("finish-snippet-placeholder").?);
    try std.testing.expectEqual(CellFlag.value_set_replacement, decorationBit("valueSetReplacement").?);
}
