// Port of `src/vs/editor/contrib/rename/browser/renameWidget.css`.
// Terminal cells replace pixel padding, rounded corners, shadow and CSS selectors.
const ui = @import("ui");
pub const base: u16 = 0x0190;
pub const Class = enum(u16) { rename_box = base, preview, rename_input_with_button, rename_input, rename_label };
pub const Colors = struct {
    background: ui.Color = .{ .r = 37, .g = 37, .b = 38 },
    foreground: ui.Color = .{ .r = 204, .g = 204, .b = 204 },
    input_background: ui.Color = .{ .r = 30, .g = 30, .b = 30 },
    input_foreground: ui.Color = .{ .r = 204, .g = 204, .b = 204 },
    border: ui.Color = .{ .r = 69, .g = 69, .b = 69 },
};
fn styles(colors: Colors) [5]ui.Style {
    return .{
        .{ .width = .{ .percent = 100 }, .height = .{ .percent = 100 }, .display = .flex, .flex_direction = .column, .background = colors.background, .color = colors.foreground, .z_index = 100, .border_style = .rounded, .border_color = colors.border, .overflow = .hidden },
        .{},
        .{ .position = .relative, .height = .{ .cells = 1 }, .background = colors.input_background },
        .{ .color = colors.input_foreground },
        .{ .dim = true, .white_space = .nowrap },
    };
}
const defaults = styles(.{});
pub const sheet = ui.css.Sheet{ .base = base, .styles = &defaults };
pub fn registerTheme(doc: *ui.Document, colors: Colors) !void {
    const themed = styles(colors);
    _ = try doc.registerSheet(.{ .base = base, .styles = &themed });
}
