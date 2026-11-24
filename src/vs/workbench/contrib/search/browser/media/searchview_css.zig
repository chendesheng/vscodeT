// Port of `src/vs/workbench/contrib/search/browser/media/searchview.css`.
// The terminal uses cell dimensions and single-line input boxes. Browser
// textarea mirrors, scrollbar selectors, font metrics, pixel/subpixel spacing,
// box sizing, radii, and high-contrast dashed borders have no direct equivalent.
// The result adapter applies the row rules to its windowed cell grid.

const ui = @import("ui");

pub const base: u16 = 0x0090;
pub const widgets_left = 0;
pub const widgets_right = 1;
pub const widgets_padding_top = 1;
pub const input_indent = 2;
pub const more_width = 2;

pub const Class = enum(u16) {
    search_view = base,
    search_widgets_container,
    search_widget,
    toggle_replace_button,
    search_container,
    replace_container,
    replace_input,
    replace_action_bar,
    query_details,
    more,
    file_types,
    file_types_heading,
    disabled,
};

const styles = [_]ui.Style{
    .{ .display = .flex, .flex_direction = .column, .height = .{ .percent = 100 }, .overflow = .hidden },
    .{ .position = .relative, .width = .{ .percent = 100 } },
    .{ .position = .relative, .width = .{ .percent = 100 } },
    .{
        .position = .absolute,
        .top = .{ .cells = 0 },
        .left = .{ .cells = widgets_left },
        .width = .{ .cells = input_indent - widgets_left },
        .height = .{ .percent = 100 },
        .display = .flex,
        .align_items = .center,
        .justify_content = .center,
        .pointer = .pointer,
    },
    .{ .position = .absolute, .left = .{ .cells = input_indent }, .height = .{ .cells = 1 }, .overflow = .hidden },
    .{ .position = .absolute, .left = .{ .cells = input_indent }, .height = .{ .cells = 1 }, .display = .flex },
    .{ .position = .relative, .height = .{ .cells = 1 }, .overflow = .hidden },
    .{ .position = .absolute, .right = .{ .cells = widgets_right }, .height = .{ .cells = 1 }, .pointer = .pointer },
    .{ .position = .relative, .width = .{ .percent = 100 } },
    .{ .position = .absolute, .right = .{ .cells = widgets_right }, .width = .{ .cells = more_width }, .height = .{ .cells = 1 }, .z_index = 2, .pointer = .pointer },
    .{ .position = .absolute, .left = .{ .cells = input_indent }, .height = .{ .cells = 1 }, .overflow = .hidden },
    .{ .position = .absolute, .left = .{ .cells = input_indent }, .height = .{ .cells = 1 }, .white_space = .nowrap, .overflow = .hidden },
    .{ .display = .none },
};

pub const sheet = ui.css.Sheet{ .base = base, .styles = &styles };

pub const count_badge_margin_right = 1;
pub const action_bar_padding_right = 1;
pub const action_bar_item_spacing = 2;

pub fn findInFileMatch(background: u32, removed: bool) ui.cell.PaintStyle {
    return .{ .bg = background, .attrs = if (removed) ui.cell.Attr.strikethrough else 0 };
}

pub fn replaceMatch(background: u32) ui.cell.PaintStyle {
    return .{ .bg = background };
}
