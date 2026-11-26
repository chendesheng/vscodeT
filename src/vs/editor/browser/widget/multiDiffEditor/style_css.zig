// Port of `src/vs/editor/browser/widget/multiDiffEditor/style.css`.
// Descendant selectors, pseudo-elements, box shadows, radii, font sizes,
// pixel dimensions, transitions and custom properties are omitted. The
// template applies variant classes, cell geometry and resolved theme colors.
const ui = @import("ui");
pub const base: u16 = 0x0120;
pub const Class = enum(u16) { multi_diff_editor = base, multi_diff_entry = base + 1, header = base + 2, header_content = base + 3, collapse_button = base + 4, file_path = base + 5, title = base + 6, status = base + 7, actions = base + 8, binary_file_placeholder = base + 9, active = base + 10, collapsed = base + 11, shadow = base + 12, header_focused = base + 13, focused_action = base + 14 };
const styles = [_]ui.Style{
    .{ .position = .relative, .overflow = .hidden },
    .{ .display = .flex, .flex_direction = .column, .overflow = .hidden },
    .{ .width = .{ .percent = 100 }, .height = .{ .percent = 100 }, .overflow = .hidden },
    .{ .display = .flex, .flex_direction = .row, .align_items = .center, .width = .{ .percent = 100 }, .height = .{ .percent = 100 }, .overflow = .hidden },
    .{ .pointer = .pointer, .width = .{ .cells = 3 }, .flex_shrink = 0, .text_align = .center },
    .{ .display = .flex, .flex_direction = .row, .flex_grow = 1, .min_width = .{ .cells = 0 }, .overflow = .hidden, .align_items = .center },
    .{ .white_space = .nowrap, .overflow = .hidden, .min_width = .{ .cells = 0 } },
    .{ .white_space = .nowrap, .bold = true, .flex_shrink = 0, .padding = .{ .left = 1, .right = 1 } },
    .{ .display = .flex, .flex_direction = .row, .flex_shrink = 0, .pointer = .pointer, .padding = .{ .left = 1, .right = 1 } },
    .{ .display = .flex, .flex_direction = .column, .align_items = .center, .justify_content = .center, .overflow = .hidden },
    .{ .bold = true },
    .{},
    .{}, // Browser box-shadow: the sticky state is retained, not a pixel shadow.
    .{ .underline = true }, // Cell substitute for the header focus outline.
    .{ .reverse = true }, // A focused action has a distinct cell highlight.
};
pub const sheet = ui.css.Sheet{ .base = base, .styles = &styles };
