// Cell layout port of vscode/src/vs/workbench/contrib/scm/browser/media/scm.css.
// One-cell rows replace the browser's pixel heights. Rounded borders use
// terminal cell strokes when available.
const ui = @import("ui");

pub const base: u16 = 0x00b0;
pub const gutter = 2;
pub const right_inset = 1;
pub const dropdown_width = 3;
pub const action_button_row = 2;
pub const inline_action_width = 3;

pub const Class = enum(u16) {
    scm_editor = base,
    button_container,
    primary_button,
    dropdown_button,
    history_item,
    graph_container,
    history_label,
    history_badges,
    history_action,
};

const styles = [_]ui.Style{
    .{ .height = .{ .cells = 1 }, .overflow = .hidden, .border_style = .rounded },
    .{ .display = .flex, .height = .{ .cells = 1 }, .overflow = .hidden, .border_style = .rounded },
    .{ .display = .flex, .height = .{ .cells = 1 }, .flex_grow = 1, .justify_content = .center, .overflow = .hidden },
    .{ .position = .relative, .display = .flex, .height = .{ .cells = 1 }, .width = .{ .cells = dropdown_width }, .flex_shrink = 0, .justify_content = .center },
    .{ .display = .flex, .align_items = .center, .overflow = .hidden },
    .{ .display = .flex, .padding = .{ .left = 1 }, .flex_shrink = 0, .white_space = .pre },
    .{ .white_space = .pre, .overflow = .hidden, .flex_grow = 1, .flex_shrink = 1, .padding = .{ .left = 1 } },
    .{ .display = .flex, .flex_shrink = 0 },
    .{ .display = .flex, .justify_content = .center, .width = .{ .cells = inline_action_width }, .flex_shrink = 0, .pointer = .pointer },
};

pub const sheet = ui.css.Sheet{ .base = base, .styles = &styles };
