// Cell layout of paneview.css and paneviewlet.css from the pinned VS Code tree.
const ui = @import("ui");

const base: u16 = 0x00c0;
pub const Class = enum(u16) { pane_header = base, twisty, title, actions, action_item };

const styles = [_]ui.Style{
    .{ .display = .flex, .align_items = .center, .width = .{ .percent = 100 }, .height = .{ .cells = 1 }, .overflow = .hidden },
    .{ .padding = .{ .left = 1 }, .flex_shrink = 0 },
    .{ .padding = .{ .left = 1, .right = 1 }, .min_width = .{ .cells = 0 }, .overflow = .hidden, .white_space = .pre, .bold = true },
    .{ .display = .flex, .height = .{ .percent = 100 }, .align_items = .center, .flex_shrink = 0, .padding = .{ .right = 1 } },
    .{ .display = .flex, .height = .{ .percent = 100 }, .align_items = .center, .justify_content = .center, .flex_shrink = 0 },
};

pub const sheet = ui.css.Sheet{ .base = base, .styles = &styles };
