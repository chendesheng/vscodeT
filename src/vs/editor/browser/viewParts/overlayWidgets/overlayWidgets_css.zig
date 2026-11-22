// Port of `src/vs/editor/browser/viewParts/overlayWidgets/overlayWidgets.css`.

const ui = @import("ui");

pub const base: u16 = 0x0020;

pub const Class = enum(u16) {
    overlay_widgets = base,
};

const styles = [_]ui.Style{
    // .monaco-editor .overlayWidgets
    .{
        .position = .absolute,
        .top = .{ .cells = 0 },
        .left = .{ .cells = 0 },
    },
};

pub const sheet = ui.css.Sheet{ .base = base, .styles = &styles };
