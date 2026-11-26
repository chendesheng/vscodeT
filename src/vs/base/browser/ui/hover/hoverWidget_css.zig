// Port of `src/vs/base/browser/ui/hover/hoverWidget.css`.
// Browser text selection, animation, font/pixel metrics and selector matching
// are omitted. The terminal scroll viewport and visible rows use cell geometry.
const ui = @import("ui");

pub const base: u16 = 0x0130;
pub const Class = enum(u16) {
    monaco_hover = base,
    monaco_hover_content = base + 1,
    hidden = base + 2,
};
const styles = [_]ui.Style{
    .{ .position = .absolute, .overflow = .hidden, .pointer = .default },
    .{ .position = .absolute, .overflow = .hidden },
    .{ .display = .none },
};
pub const sheet = ui.css.Sheet{ .base = base, .styles = &styles };
