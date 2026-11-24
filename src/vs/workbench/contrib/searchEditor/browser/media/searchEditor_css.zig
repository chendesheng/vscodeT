// Cell layout port of vscode/src/vs/workbench/contrib/searchEditor/browser/media/searchEditor.css.
const ui = @import("ui");
const search_css = @import("../../../search/browser/media/searchview_css.zig");

pub const base: u16 = 0x00a0;
pub const context_width = 3;
pub const context_toggle_width = search_css.icon_button_width;
pub const context_gap = 1;

pub const Class = enum(u16) { search_editor = base, context_lines_input, context_lines_toggle };
const styles = [_]ui.Style{
    .{ .display = .flex, .flex_direction = .column, .height = .{ .percent = 100 }, .overflow = .hidden },
    .{ .position = .absolute, .height = .{ .cells = 1 }, .width = .{ .cells = context_width }, .overflow = .hidden },
    .{ .position = .absolute, .height = .{ .cells = 1 }, .width = .{ .cells = context_toggle_width }, .pointer = .pointer },
};
pub const sheet = ui.css.Sheet{ .base = base, .styles = &styles };
