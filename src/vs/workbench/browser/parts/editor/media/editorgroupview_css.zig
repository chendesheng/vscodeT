// Port of the mounted editor-group rules in
// src/vs/workbench/browser/parts/editor/media/editorgroupview.css.
// Group state is passed explicitly by EditorGroupView. Pixel shadows, opacity,
// outlines and pseudo-elements do not map to terminal layout boxes. Tabs and
// breadcrumbs retain their cell renderers, with title dimensions in cells.
const ui = @import("ui");

pub const base: u16 = 0x0070;
pub const Class = enum(u16) {
    editor_group_container = base,
    title = base + 1,
    editor_instance = base + 2,
    empty_editor_container = base + 3,
    grid_view_container = base + 4,
};

const styles = [_]ui.Style{
    .{ .height = .{ .percent = 100 } },
    .{ .position = .relative, .overflow = .hidden },
    .{ .height = .{ .percent = 100 } },
    .{ .display = .none },
    .{ .width = .{ .percent = 100 }, .height = .{ .percent = 100 } },
};

pub const sheet = ui.css.Sheet{ .base = base, .styles = &styles };
