// Port of `src/vs/editor/contrib/hover/browser/hover.css`.
// Theme variables are resolved by the editor's host. The native cell border
// substitutes for a CSS radius; shadows, pixel units, browser selection and
// selector matching have no terminal counterpart.
const ui = @import("ui");
const Theme = @import("../../../../base/browser/ui/hover/hoverWidget.zig").Theme;

pub const base: u16 = 0x0140;
pub const Class = enum(u16) {
    monaco_hover = base,
    focused = base + 1,
    verbosity_actions = base + 2,
    verbosity_action = base + 3,
    verbosity_action_disabled = base + 4,
};

fn styles(theme: Theme) [5]ui.Style {
    return .{
        .{ .background = theme.background, .color = theme.foreground, .border_color = theme.border, .border_style = .rounded },
        .{ .border_color = theme.focused_border },
        .{ .position = .absolute, .overflow = .hidden },
        .{ .pointer = .pointer, .text_align = .center },
        .{ .pointer = .default, .dim = true },
    };
}
const default_styles = styles(.{});
pub const sheet = ui.css.Sheet{ .base = base, .styles = &default_styles };

pub fn registerTheme(doc: *ui.Document, theme: Theme) !void {
    const themed_styles = styles(theme);
    _ = try doc.registerSheet(.{ .base = base, .styles = &themed_styles });
}
