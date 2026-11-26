// Port of `src/vs/editor/contrib/codelens/browser/codelensWidget.css`.
// A one-cell row replaces browser font sizing; selectors, icon font metrics,
// fade-in animation and custom properties are omitted. Resolved theme colors
// and indentation are supplied by the caller.
const ui = @import("ui");
pub const base: u16 = 0x00f0;
pub const Class = enum(u16) { codelens_decoration = base, link = base + 1 };
const styles = [_]ui.Style{
    .{ .display = .flex, .flex_direction = .row, .align_items = .center, .overflow = .hidden, .white_space = .nowrap, .height = .{ .cells = 1 }, .dim = true },
    .{ .pointer = .pointer, .underline = false },
};
pub const sheet = ui.css.Sheet{ .base = base, .styles = &styles };
