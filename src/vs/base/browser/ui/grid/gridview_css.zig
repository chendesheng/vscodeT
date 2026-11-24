// Port of src/vs/base/browser/ui/grid/gridview.css.
// The workbench grid provides the positioned leaf rectangles.
const ui = @import("ui");

pub const base: u16 = 0x0050;
pub const Class = enum(u16) {
    monaco_grid_view = base,
};

const styles = [_]ui.Style{
    .{ .position = .relative, .overflow = .hidden, .width = .{ .percent = 100 }, .height = .{ .percent = 100 } },
};

pub const sheet = ui.css.Sheet{ .base = base, .styles = &styles };
