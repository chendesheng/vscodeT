// Port of the structural rules in
// `src/vs/editor/browser/viewParts/viewLines/viewLines.css`.
//
// The terminal view line is a `ui` element, so the absolute positioning and the
// nowrap line container map directly. Omitted rules are browser-only or themed:
// `mtkcontrol`, `mtkfullwidth`, `mtkoverflow`, `mtkw`, `mtkz`, the descendant
// span rule and `box-sizing`. The view already maps whitespace and token
// colors through the paint adapter.

const ui = @import("ui");

pub const base: u16 = 0x0010;

pub const Class = enum(u16) {
    view_lines = base,
    view_line = base + 1,
};

const styles = [_]ui.Style{
    // .monaco-editor .view-lines
    .{
        .white_space = .nowrap,
    },
    // .monaco-editor .view-line
    .{
        .position = .absolute,
        .width = .{ .percent = 100 },
    },
};

pub const sheet = ui.css.Sheet{ .base = base, .styles = &styles };
