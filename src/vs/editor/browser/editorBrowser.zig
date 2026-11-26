//! Terminal adaptation of the editor widget contracts in
//! `src/vs/editor/browser/editorBrowser.ts`.
//!
//! Upstream, a widget owns an `HTMLElement` that the editor positions in pixels
//! and appends to its overlay/content widget containers. Here a widget builds a
//! `ui.Node` subtree and the host places it on terminal cells.
//!
//! The document is rebuilt on every frame, so `build` is called each time and
//! must recreate its listeners. State (value, cursor, focus) belongs to the
//! widget's own struct, not to the nodes.
//!
//! `RetainedViewPartHost` is the terminal adaptation for views that keep their
//! nodes across frames: it reports only the DOM deltas. `rebuildSubtree` relies
//! on `BoxTree.rebuildSubtree` to refresh the element style and inherited
//! pointer, so the host does not issue a zero-delta translation afterwards.

const ui = @import("ui");
const Position = @import("../common/core/position.zig").Position;
const Range = @import("../common/core/range.zig").Range;

/// Portable commands on the upstream IDiffEditor. Concrete terminal
/// widgets expose this interface to ICodeEditorService without exporting
/// their native View type.
pub const IDiffEditor = struct {
    context: *anyopaque,
    switch_side: *const fn (*anyopaque) anyerror!void,
    exit_compare_move: *const fn (*anyopaque) anyerror!void,
    revert_focused: *const fn (*anyopaque) anyerror!void,
    collapse_all: *const fn (*anyopaque) anyerror!void,
    show_all: *const fn (*anyopaque) anyerror!void,
    accessible_next: *const fn (*anyopaque) anyerror!void,
    accessible_previous: *const fn (*anyopaque) anyerror!void,
    run_gutter_hunk: ?*const fn (*anyopaque, []const u8) anyerror!void = null,

    pub fn runGutterHunk(self: IDiffEditor, id: []const u8) !void {
        if (self.run_gutter_hunk) |run| try run(self.context, id);
    }

    pub fn switchSide(self: IDiffEditor) !void {
        try self.switch_side(self.context);
    }
    pub fn exitCompareMove(self: IDiffEditor) !void {
        try self.exit_compare_move(self.context);
    }
    pub fn revertFocusedRangeMappings(self: IDiffEditor) !void {
        try self.revert_focused(self.context);
    }
    pub fn collapseAllUnchangedRegions(self: IDiffEditor) !void {
        try self.collapse_all(self.context);
    }
    pub fn showAllUnchangedRegions(self: IDiffEditor) !void {
        try self.show_all(self.context);
    }
    pub fn accessibleDiffViewerNext(self: IDiffEditor) !void {
        try self.accessible_next(self.context);
    }
    pub fn accessibleDiffViewerPrev(self: IDiffEditor) !void {
        try self.accessible_previous(self.context);
    }
};

/// Terminal adaptation of the editor's focused widget key-event target.
pub const IEditorKeyTarget = struct {
    context: *anyopaque,
    dispatch_fn: *const fn (*anyopaque, *ui.KeyEvent) bool,

    pub fn dispatchKey(self: IEditorKeyTarget, event: *ui.KeyEvent) bool {
        return self.dispatch_fn(self.context, event);
    }
};

/// Model-anchored view zone. The terminal uses cell heights rather than
/// CSS pixels. The delegate builds a document-owned subtree when its zone
/// enters the viewport (and when the zone is explicitly laid out again).
pub const IViewZone = struct {
    after_line_number: usize,
    after_column: ?usize = null,
    after_column_affinity: @import("../common/model.zig").PositionAffinity = .None,
    ordinal: ?i32 = null,
    height_in_lines: usize = 1,
    min_width: usize = 0,
    show_in_hidden_areas: bool = false,
    suppress_mouse_down: bool = false,
    /// Terminal-only windowing for large zone content: preserve the full
    /// whitespace height while asking the delegate to build visible rows.
    clip_to_viewport: bool = false,
    context: ?*anyopaque = null,
    build: ?Build = null,
    build_margin: ?Build = null,
    update: ?Update = null,
    update_margin: ?Update = null,
    on_computed_height: ?*const fn (?*anyopaque, usize) void = null,
    on_dom_node_top: ?*const fn (?*anyopaque, f64) void = null,

    pub const Update = *const fn (?*anyopaque, *ui.Node, RenderInfo) anyerror!void;
    pub const Build = *const fn (?*anyopaque, *ui.Document, RenderInfo) anyerror!*ui.Node;
    pub const RenderInfo = struct {
        width: usize,
        height: usize,
        scroll_left: usize,
        visible_start_row: usize = 0,
        visible_end_row: ?usize = null,
    };
};

/// Transaction-scoped counterpart of upstream IViewZoneChangeAccessor.
/// Zig passes the updated zone value to layoutZone rather than mutating a
/// borrowed JavaScript object.
pub const IViewZoneChangeAccessor = struct {
    context: *anyopaque,
    add_zone: *const fn (*anyopaque, IViewZone) anyerror![]const u8,
    remove_zone: *const fn (*anyopaque, []const u8) anyerror!void,
    layout_zone: *const fn (*anyopaque, []const u8, IViewZone) anyerror!void,

    pub fn addZone(self: IViewZoneChangeAccessor, zone: IViewZone) ![]const u8 {
        return self.add_zone(self.context, zone);
    }

    pub fn removeZone(self: IViewZoneChangeAccessor, id: []const u8) !void {
        return self.remove_zone(self.context, id);
    }

    pub fn layoutZone(self: IViewZoneChangeAccessor, id: []const u8, zone: IViewZone) !void {
        return self.layout_zone(self.context, id, zone);
    }
};

/// Mirrors upstream `OverlayWidgetPositionPreference`.
pub const OverlayWidgetPositionPreference = enum {
    top_right_corner,
    bottom_right_corner,
    top_center,
    /// Terminal adaptation: upstream sticky scroll uses TOP_CENTER with a
    /// cancelled right offset to obtain a full-width top-left overlay. The
    /// terminal expresses that placement directly.
    top_left_corner,
};

/// Mirrors upstream `IOverlayWidget`. Positions are computed by the host: a
/// widget reports its size in cells and the host anchors the container.
pub const IOverlayWidget = struct {
    context: *anyopaque,

    /// Unique identifier; used for removal and diagnostics.
    get_id: *const fn (context: *anyopaque) []const u8,

    get_position: *const fn (context: *anyopaque) OverlayWidgetPositionPreference,

    /// Width in cells at the given editor width.
    width: *const fn (context: *anyopaque, cols: usize) usize,

    /// Height in cells.
    height: *const fn (context: *anyopaque) usize,

    /// Builds the widget subtree. The host has already appended the returned
    /// node to a container sized by `width`/`height`; fill that container
    /// (`width: 100%`, `height: 100%` is the usual root style).
    build: *const fn (context: *anyopaque, doc: *ui.Document) anyerror!*ui.Node,

    /// The node that should take focus while `is_focused` is true.
    focus_node: *const fn (context: *anyopaque) ?*ui.Node,

    /// Whether the widget currently owns focus. The host re-focuses
    /// `focus_node` after each rebuild so focus survives the new tree.
    is_focused: *const fn (context: *anyopaque) bool,
};

/// Exact widgets start at the anchor cell. Popups may move to fit.
pub const ContentWidgetPositionPreference = enum { above, below, exact };

/// Mirrors upstream `IContentWidgetPosition`.
pub const IContentWidgetPosition = struct {
    position: Position,
    preference: ContentWidgetPositionPreference,
};

/// Mirrors upstream `IContentWidget`. Upstream positions the widget in pixels
/// next to a model position; here the host maps the position to a view line
/// and a cell column and clamps the box to the text area.
pub const IContentWidget = struct {
    context: *anyopaque,

    /// Unique identifier; used for removal and diagnostics.
    get_id: *const fn (context: *anyopaque) []const u8,

    /// Null hides the widget for this frame.
    get_position: *const fn (context: *anyopaque) ?IContentWidgetPosition,

    /// Width in cells at the given editor width.
    width: *const fn (context: *anyopaque, cols: usize) usize,

    /// Height in cells.
    height: *const fn (context: *anyopaque) usize,

    /// Builds the widget subtree; the host wraps it in an absolutely
    /// positioned container of `width` x `height`.
    build: *const fn (context: *anyopaque, doc: *ui.Document) anyerror!*ui.Node,

    /// The node that should take focus while `is_focused` is true.
    focus_node: *const fn (context: *anyopaque) ?*ui.Node,

    /// Whether the widget currently owns focus.
    is_focused: *const fn (context: *anyopaque) bool,
};

/// Terminal adaptation: explicit box-tree operations for a retained view part.
///
/// The editor view turns off the box tree's automatic mutation invalidation
/// after the first full solve and drives retained subtrees itself. A view part
/// that keeps its DOM nodes across frames (gutter rows, scrollbar cells, the
/// status row, widget containers) reports each DOM delta through this host so
/// only the changed subtree is rebuilt and laid out. `failed` tells the view
/// that a parent box was missing and it must fall back to a full box solve.
pub const RetainedViewPartHost = struct {
    tree: *ui.BoxTree,
    doc: *ui.Document,
    failed: bool = false,
    ops: Ops = .{},

    pub const Ops = struct {
        added: usize = 0,
        rebuilt: usize = 0,
        translated: usize = 0,
        removed: usize = 0,

        pub fn total(self: Ops) usize {
            return self.added + self.rebuilt + self.translated + self.removed;
        }
    };

    /// Drops the box subtree of a node that is about to be destroyed.
    pub fn removeSubtree(self: *RetainedViewPartHost, node: *ui.Node) void {
        self.tree.removeSubtree(node);
        self.ops.removed += 1;
    }

    /// Builds the box for a newly attached DOM node and lays it out.
    pub fn addSubtree(self: *RetainedViewPartHost, node: *ui.Node) !void {
        const box = (try self.tree.addSubtree(node)) orelse {
            self.failed = true;
            return;
        };
        self.ops.added += 1;
        try ui.layout.layoutSubtree(self.tree, self.doc, box);
    }

    /// Rebuilds a retained node's box children from its current DOM, refreshes
    /// the element style and inherited pointer (the box copies both at build
    /// time) and lays it out. `rebuildSubtree` performs the refresh itself, so
    /// no zero-delta translation is needed here (terminal adapter cleanup).
    pub fn rebuildSubtree(self: *RetainedViewPartHost, node: *ui.Node) !void {
        const box = (try self.tree.rebuildSubtree(node)) orelse {
            self.failed = true;
            return;
        };
        self.ops.rebuilt += 1;
        try ui.layout.layoutSubtree(self.tree, self.doc, box);
    }

    /// Shifts a retained subtree by a row delta without rebuilding its boxes.
    pub fn translateSubtree(self: *RetainedViewPartHost, node: *ui.Node, dy: f64) void {
        if (self.tree.translateSubtree(node, 0, dy)) {
            self.ops.translated += 1;
        } else {
            self.failed = true;
        }
    }
};

/// Mirrors the portable subset of upstream `MouseTargetType`.
pub const MouseTargetType = enum {
    unknown,
    textarea,
    gutter_glyph_margin,
    gutter_line_numbers,
    gutter_line_decorations,
    gutter_view_zone,
    content_text,
    content_empty,
    content_widget,
    content_view_zone,
    scrollbar,
    overview_ruler,
    overlay_widget,
    status,
    outside_editor,
};

pub const ContentEmptyDetail = struct {
    /// The pointer is below the last view line.
    is_after_lines: bool,
    /// Cells between the pointer and the end of the line, when the pointer is
    /// to the right of the text. The terminal has whole cells only, so a
    /// distance of 0 is the only representable "close enough" case.
    horizontal_distance_to_text: usize = 0,
};

pub const ViewZoneTargetData = struct {
    view_zone_id: []const u8,
    position_before: ?Position = null,
    position_after: ?Position = null,
    position: Position,
    after_line_number: usize,
};

pub const MouseTargetDetail = union(enum) {
    content_empty: ContentEmptyDetail,
    view_zone: ViewZoneTargetData,
};

/// Mirrors upstream `IMouseTarget`.
pub const MouseTarget = struct {
    element: ?*ui.Node = null,
    position: ?Position = null,
    mouse_column: usize = 0,
    range: ?Range = null,
    type: MouseTargetType = .unknown,
    detail: ?MouseTargetDetail = null,
};

/// A highlighted model range handed to a decoration sink. The sink
/// materializes it as a `TextModel` decoration with the corresponding class
/// name and options; painting and the overview ruler read the model
/// decoration back.
pub const DecorationKind = enum {
    find_match,
    current_find_match,
    find_scope,
    bracket_match,
    hover_highlight,
    word_highlight_text,
    word_highlight,
    word_highlight_strong,
    search_range_highlight,
    marker_selection_highlight,
};

pub const Decoration = struct {
    range: Range,
    kind: DecorationKind,
    /// Contribution-specific override for the overview-ruler marker. The kind
    /// still decides whether it has a marker color at all.
    show_in_overview_ruler: bool = true,
};

/// Turns portable `Decoration` values into model decorations. The view owner
/// supplies the materialization (class names, colors); the editor layer only
/// forwards ranges.
pub const DecorationSink = struct {
    context: ?*anyopaque = null,
    set: ?*const fn (context: ?*anyopaque, decorations: []const Decoration) void = null,
};
