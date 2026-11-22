// Port of `src/vs/editor/browser/viewParts/blockDecorations/blockDecorations.css`.
//
// Terminal adaptation: `pointer-events: none` lives on the `Node` API because
// it is not a `Style` property. `box-sizing: border-box` is not modeled; the
// compositor already subtracts border cells from the block size.

const ui = @import("ui");

pub const base: u16 = 0x0000;

pub const Class = enum(u16) {
    block_decorations_container = base,
    block_decorations_block = base + 1,
};

const styles = [_]ui.Style{
    // .monaco-editor .blockDecorations-container
    .{
        .position = .absolute,
        .top = .{ .cells = 0 },
    },
    // .monaco-editor .blockDecorations-block
    .{
        .position = .absolute,
    },
};

pub const sheet = ui.css.Sheet{ .base = base, .styles = &styles };
