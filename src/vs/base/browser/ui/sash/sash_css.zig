// Port of `src/vs/base/browser/ui/sash/sash.css`.
// The terminal uses one cell for the sash size and a paint-only style for
// the hover/active pseudo-element. Browser touch, transitions, debugging rules,
// platform cursor aliases, and orthogonal drag handles are omitted. Limit
// and disabled styles require the corresponding sash states.

const ui = @import("ui");

pub const base: u16 = 0x0030;

pub const Class = enum(u16) {
    sash = base,
    vertical = base + 1,
    horizontal = base + 2,
};

const styles = [_]ui.Style{
    // .monaco-sash
    .{ .position = .absolute, .z_index = 35 },
    // .monaco-sash.vertical
    .{ .pointer = .ew_resize, .top = .{ .cells = 0 }, .width = .{ .cells = 1 }, .height = .{ .percent = 100 } },
    // .monaco-sash.horizontal
    .{ .pointer = .ns_resize, .left = .{ .cells = 0 }, .width = .{ .percent = 100 }, .height = .{ .cells = 1 } },
};

pub const sheet = ui.css.Sheet{ .base = base, .styles = &styles };

/// Direct-painted dividers use the same declarations as document nodes.
pub fn pointer(class: Class) ui.Pointer {
    return styles[@backingInt(class) - base].pointer orelse .default;
}

/// .monaco-sash.hover:before and .monaco-sash.active:before
pub fn hoverStyle(hover_border: ?ui.Color) ui.HoverStyle {
    return .{ .background = hover_border orelse .{ .r = 0, .g = 0x7f, .b = 0xd4 } };
}
