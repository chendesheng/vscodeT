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
