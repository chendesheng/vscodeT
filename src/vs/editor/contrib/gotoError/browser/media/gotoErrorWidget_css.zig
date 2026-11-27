// Port of `src/vs/editor/contrib/gotoError/browser/media/gotoErrorWidget.css`.
// Terminal cells replace pixel padding and opacity with a single cell inset
// and dim paint; pseudo-elements, selectors and browser text selection are
// omitted. Code-link parentheses are authored as literal text.
const ui = @import("ui");
pub const base: u16 = 0x0170;
pub const Class = enum(u16) { marker_widget = base, stale = base + 1, descriptioncontainer = base + 2, message = base + 3, details = base + 4, source = base + 5, code = base + 6, code_link = base + 7, filename = base + 8 };
const styles = [_]ui.Style{
    .{ .white_space = .nowrap, .overflow = .hidden },
    .{ .dim = true, .italic = true },
    .{ .position = .absolute, .white_space = .pre, .padding = .{ .left = 1 }, .overflow = .hidden },
    .{ .display = .flex, .flex_direction = .column },
    .{ .padding = .{ .left = 1 } },
    .{ .dim = true },
    .{ .dim = true },
    .{ .dim = true, .underline = true, .pointer = .pointer },
    .{ .pointer = .pointer, .underline = true },
};
pub const sheet = ui.css.Sheet{ .base = base, .styles = &styles };
