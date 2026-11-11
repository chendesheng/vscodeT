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

const ui = @import("ui");
const Position = @import("../common/core/position.zig").Position;
const Range = @import("../common/core/range.zig").Range;

/// Mirrors upstream `OverlayWidgetPositionPreference`.
pub const OverlayWidgetPositionPreference = enum {
    top_right_corner,
    bottom_right_corner,
    top_center,
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

/// Mirrors upstream `ContentWidgetPositionPreference`. Upstream also has
/// `EXACT`; the terminal anchors a widget to a line and flips it above or
/// below, which is the pair of preferences the hover widget uses.
pub const ContentWidgetPositionPreference = enum { above, below };

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

/// Mirrors the portable subset of upstream `MouseTargetType`.
pub const MouseTargetType = enum {
    unknown,
    gutter_line_numbers,
    content_text,
    content_empty,
    content_widget,
    overlay_widget,
    status,
};

pub const ContentEmptyDetail = struct {
    /// The pointer is below the last view line.
    is_after_lines: bool,
    /// Cells between the pointer and the end of the line, when the pointer is
    /// to the right of the text. The terminal has whole cells only, so a
    /// distance of 0 is the only representable "close enough" case.
    horizontal_distance_to_text: usize = 0,
};

pub const MouseTargetDetail = union(enum) {
    content_empty: ContentEmptyDetail,
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

/// A highlighted model range the view knows how to paint. Upstream find uses
/// model decorations with CSS classes; the terminal view takes the ranges
/// directly and maps them to cells.
pub const DecorationKind = enum {
    find_match,
    current_find_match,
    find_scope,
    bracket_match,
    hover_highlight,
    word_highlight_text,
    word_highlight,
    word_highlight_strong,
};

pub const Decoration = struct {
    range: Range,
    kind: DecorationKind,
};
