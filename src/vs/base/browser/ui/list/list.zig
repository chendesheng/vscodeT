// Port of the portable list contracts in `src/vs/base/browser/ui/list/list.ts`.
//
// The terminal has no DOM rows or templates. Elements are carried as opaque
// pointers and the renderer draws a `Row` directly into the shared `CellGrid`;
// virtualization, scrolling and row geometry stay in `listView.zig`.

const ui = @import("ui");

pub const Element = *const anyopaque;

pub const Row = struct {
    grid: *ui.CellGrid,
    /// Absolute viewport columns/rows. The row is already clipped to the list
    /// viewport rectangle.
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    /// Cell offset from the beginning of the unclipped element.
    offset_y: usize = 0,
    index: usize,
    /// Compressed tree depth of this row (1 = top-level row). Kept on the row
    /// because the async/compressed renderer only receives the final element.
    depth: usize = 0,
    /// Collapse state of the compressed row's tree node.
    collapsed: bool = false,
    selected: bool,
    focused: bool,
    focused_selection: bool,
    /// Pointer is over this row.
    hovered: bool = false,
    /// Pointer is anywhere inside the list viewport. Trees use this for the
    /// `workbench.tree.renderIndentGuides: onHover` behavior.
    list_hovered: bool = false,
    /// Tree indentation per depth level, in cells. AbstractTree fills this from
    /// its options before invoking the renderer.
    indent: usize = 0,
    /// Whether this row should paint tree indent guides. Set by AbstractTree.
    render_indent_guides: bool = false,
    /// This row is an overlay row of the tree's sticky-scroll widget, not a
    /// list row. Renderers use it to distinguish sticky hover/focus paint and
    /// must cover the whole row so the list row below does not show through.
    sticky: bool = false,
    sticky_focused: bool = false,
    sticky_hovered: bool = false,
    /// The bottom-most painted sticky row. Renderers that cannot use terminal
    /// cell borders underline this row as a zero-row separator.
    sticky_last: bool = false,
};

/// Port of `IListVirtualDelegate`.
pub const VirtualDelegate = struct {
    context: *anyopaque,
    get_height: *const fn (context: *anyopaque, element: Element) f64,
    get_template_id: *const fn (context: *anyopaque, element: Element) usize,

    pub fn height(self: VirtualDelegate, element: Element) f64 {
        return self.get_height(self.context, element);
    }

    pub fn templateId(self: VirtualDelegate, element: Element) usize {
        return self.get_template_id(self.context, element);
    }
};

/// Port of `IListRenderer`. A terminal renderer paints cells; it has no
/// template object because the renderer owns any reusable state.
pub const Renderer = struct {
    context: *anyopaque,
    render: *const fn (context: *anyopaque, row: *const Row, element: Element) void,

    pub fn renderRow(self: Renderer, row: *const Row, element: Element) void {
        self.render(self.context, row, element);
    }
};
