// Port of `src/vs/editor/contrib/peekView/browser/media/peekViewWidget.css`.
// Font sizes, shadows, pixel margins, pseudo-elements and descendant selectors
// are omitted. Title and action elements are retained cell-sized flex nodes.
const ui = @import("ui");
pub const base: u16 = 0x0110;
pub const Class = enum(u16) { peekview_widget = base, head = base + 1, peekview_title = base + 2, filename = base + 3, dirname = base + 4, meta = base + 5, peekview_actions = base + 6, body = base + 7 };
const styles = [_]ui.Style{
    .{ .position = .relative, .overflow = .hidden },
    .{ .display = .flex, .flex_direction = .row, .justify_content = .space_between, .height = .{ .cells = 1 }, .overflow = .hidden },
    .{ .display = .flex, .flex_direction = .row, .align_items = .center, .overflow = .hidden, .white_space = .nowrap },
    .{ .white_space = .nowrap, .overflow = .hidden },
    .{ .white_space = .nowrap, .overflow = .hidden, .padding = .{ .left = 1 } },
    .{ .white_space = .nowrap, .overflow = .hidden, .padding = .{ .left = 1 } },
    .{ .display = .flex, .flex_direction = .row, .justify_content = .flex_end, .flex_shrink = 0 },
    .{ .position = .relative, .overflow = .hidden },
};
pub const sheet = ui.css.Sheet{ .base = base, .styles = &styles };
