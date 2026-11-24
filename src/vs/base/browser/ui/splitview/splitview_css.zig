// Port of the split-view leaf rules in src/vs/base/browser/ui/splitview/splitview.css.
// The grid supplies both dimensions. The workbench paints the sash and
// separator in cells and mounts the positioned leaf elements in the grid.
const ui = @import("ui");

pub const base: u16 = 0x0060;
pub const Class = enum(u16) {
    split_view_view = base,
    hidden_view = base + 1,
};

const styles = [_]ui.Style{
    .{ .position = .absolute, .white_space = .normal },
    .{ .display = .none },
};

pub const sheet = ui.css.Sheet{ .base = base, .styles = &styles };
