// Port of `src/vs/editor/browser/widget/diffEditor/style.css` (unchanged regions).
// Terminal adaptation: one cell row replaces the grid of subpixel drag strips
// and center label. Selectors, transitions, transforms, font metrics, radii,
// shadows, focus outlines and CSS theme variables are not represented here.
const ui = @import("ui");

pub const base: u16 = 0x00e0;
pub const Class = enum(u16) {
    diff_hidden_lines = base,
    top = base + 1,
    bottom = base + 2,
    center = base + 3,
    diff_hidden_lines_compact = base + 4,
    breadcrumb_item = base + 5,
    breadcrumb_label = base + 6,
};

const drag_handle: ui.Style = .{ .display = .block, .flex_shrink = 0, .width = .{ .cells = 1 }, .height = .{ .cells = 1 }, .pointer = .pointer };
const styles = [_]ui.Style{
    .{ .display = .flex, .flex_direction = .row, .align_items = .center, .height = .{ .cells = 1 }, .gap = .{ .column = 1 }, .overflow = .hidden, .pointer = .pointer },
    drag_handle,
    drag_handle,
    .{ .white_space = .nowrap, .overflow = .hidden },
    .{ .pointer = .default },
    .{ .pointer = .pointer },
    .{ .white_space = .nowrap, .overflow = .hidden },
};

pub const sheet = ui.css.Sheet{ .base = base, .styles = &styles };
