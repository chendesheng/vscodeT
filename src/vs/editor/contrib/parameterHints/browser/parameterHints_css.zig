// Port of `src/vs/editor/contrib/parameterHints/browser/parameterHints.css`.
// Cell sizing replaces pixel padding/font metrics; shadows, radii, selectors,
// pseudo-elements and browser link hover/scrollbar styling are omitted.
const ui = @import("ui");
pub const base: u16 = 0x0180;
pub const Class = enum(u16) {
    parameter_hints_widget = base,
    phwrapper,
    body,
    signature,
    code,
    docs,
    controls,
    button,
    overloads,
    parameter_active,
    documentation_parameter,
};
pub const Colors = struct {
    background: ui.Color = .{ .r = 37, .g = 37, .b = 38 },
    foreground: ui.Color = .{ .r = 204, .g = 204, .b = 204 },
    border: ui.Color = .{ .r = 69, .g = 69, .b = 69 },
    highlight: ui.Color = .{ .r = 75, .g = 160, .b = 230 },
};
fn styles(colors: Colors) [11]ui.Style {
    return .{
        .{ .width = .{ .percent = 100 }, .height = .{ .percent = 100 }, .display = .flex, .flex_direction = .column, .border_style = .rounded, .border_color = colors.border, .background = colors.background, .color = colors.foreground, .overflow = .hidden, .z_index = 39 },
        .{ .display = .flex, .flex_direction = .row, .width = .{ .percent = 100 }, .height = .{ .percent = 100 } },
        .{ .display = .flex, .flex_direction = .column, .flex_grow = 1 },
        .{ .white_space = .pre_wrap },
        .{ .white_space = .pre_wrap },
        .{ .white_space = .pre_wrap, .overflow_wrap = .break_word },
        .{ .display = .flex, .flex_direction = .column, .align_items = .center, .width = .{ .cells = 5 }, .flex_shrink = 0 },
        .{ .pointer = .pointer, .text_align = .center },
        .{ .text_align = .center },
        .{ .bold = true, .color = colors.highlight },
        .{ .bold = true },
    };
}
const defaults = styles(.{});
pub const sheet = ui.css.Sheet{ .base = base, .styles = &defaults };
pub fn registerTheme(doc: *ui.Document, colors: Colors) !void {
    const themed = styles(colors);
    _ = try doc.registerSheet(.{ .base = base, .styles = &themed });
}
