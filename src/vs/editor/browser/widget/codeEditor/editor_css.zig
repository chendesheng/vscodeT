// Port of the editor viewport rules in
// src/vs/editor/browser/widget/codeEditor/editor.css.
// The terminal view supplies cell viewport dimensions and theme colors.
// Additional widget and decoration rules belong to their owning view parts.
const ui = @import("ui");

pub const base: u16 = 0x0080;
pub const Class = enum(u16) {
    monaco_editor = base,
    overflow_guard = base + 1,
};

const styles = [_]ui.Style{
    .{ .position = .relative, .overflow = .visible },
    .{ .position = .relative, .overflow = .hidden },
};

pub const sheet = ui.css.Sheet{ .base = base, .styles = &styles };
