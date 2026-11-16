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
    index: usize,
    selected: bool,
    focused: bool,
    focused_selection: bool,
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
