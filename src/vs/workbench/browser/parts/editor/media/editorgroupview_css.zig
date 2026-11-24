// Port of the mounted editor-group rules in
// src/vs/workbench/browser/parts/editor/media/editorgroupview.css.
// Group state is passed explicitly by EditorGroupView. The watermark uses a
// cell glyph in place of the SVG background. Its dimensions and breakpoint
// are in cells. Selectors, pixel shadows, opacity, outlines, radii and
// pseudo-elements are omitted. Tabs and breadcrumbs retain their cell renderers.
const ui = @import("ui");

pub const base: u16 = 0x0070;
pub const Class = enum(u16) {
    editor_group_container = base,
    title = base + 1,
    editor_instance = base + 2,
    empty_editor_container = base + 3,
    grid_view_container = base + 4,
    editor_group_watermark_wrapper = base + 5,
    editor_group_watermark = base + 6,
    letterpress = base + 7,
    shortcuts = base + 8,
    watermark_entry = base + 9,
    watermark_icon = base + 10,
    watermark_label = base + 11,
    watermark_keybinding = base + 12,
};

const styles = [_]ui.Style{
    .{ .height = .{ .percent = 100 } },
    .{ .position = .relative, .overflow = .hidden },
    .{ .height = .{ .percent = 100 } },
    .{ .display = .none },
    .{ .width = .{ .percent = 100 }, .height = .{ .percent = 100 } },
    .{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
        .overflow = .hidden,
    },
    .{ .position = .absolute, .display = .flex, .flex_direction = .column, .align_items = .center, .gap = .{ .row = 1 } },
    .{ .white_space = .pre },
    .{ .display = .flex, .flex_direction = .column, .gap = .{ .row = 1 } },
    .{
        .display = .flex,
        .align_items = .center,
        .height = .{ .cells = 1 },
        .gap = .{ .column = 1 },
        .padding = .{ .left = 1, .right = 1 },
        .pointer = .pointer,
        .white_space = .pre,
    },
    .{ .flex_shrink = 0 },
    .{ .flex_grow = 1 },
    .{ .flex_shrink = 0, .padding = .{ .left = 1, .right = 1 } },
};

pub const sheet = ui.css.Sheet{ .base = base, .styles = &styles };
