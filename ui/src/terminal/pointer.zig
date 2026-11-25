//! Mouse pointer shapes over the kitty OSC 22 protocol.
//!
//! The escape sequence is `ESC ] 22 ; <shape-name> ESC \` and the shape names
//! are the CSS `cursor` keywords, as standardized by kitty's pointer-shapes
//! protocol (also implemented by Ghostty, foot and some xterm builds):
//!
//!     <OSC> 22 ; pointer <ESC>\
//!     <OSC> 22 ; text <ESC>\
//!     <OSC> 22 ; default <ESC>\
//!
//! Only the CSS names are emitted. The protocol also accepts X11 cursor-font
//! aliases for legacy xterm compatibility, but CSS names are the portable
//! subset implemented by kitty, Ghostty and foot. Terminals without OSC 22
//! support ignore the sequence, so the host does not probe before emitting.
//!
//! The pointer is terminal-global state, not a cell attribute, so this module
//! is deliberately separate from the frame encoder: hosts resolve a shape with
//! `style.Pointer`/`Surface.pointerAt` and write it through `State`, which
//! deduplicates repeated shapes the same way the frame diff omits unchanged
//! cells.

const std = @import("std");
const style = @import("../style/style.zig");

pub const Pointer = style.Pointer;

/// The protocol name of a shape, with the CSS cursor spelling.
pub fn name(shape: Pointer) []const u8 {
    return switch (shape) {
        .default => "default",
        .alias => "alias",
        .cell => "cell",
        .copy => "copy",
        .crosshair => "crosshair",
        .e_resize => "e-resize",
        .ew_resize => "ew-resize",
        .grab => "grab",
        .grabbing => "grabbing",
        .help => "help",
        .move => "move",
        .n_resize => "n-resize",
        .ne_resize => "ne-resize",
        .nesw_resize => "nesw-resize",
        .no_drop => "no-drop",
        .not_allowed => "not-allowed",
        .ns_resize => "ns-resize",
        .nw_resize => "nw-resize",
        .nwse_resize => "nwse-resize",
        .pointer => "pointer",
        .progress => "progress",
        .s_resize => "s-resize",
        .se_resize => "se-resize",
        .sw_resize => "sw-resize",
        .text => "text",
        .vertical_text => "vertical-text",
        .w_resize => "w-resize",
        .wait => "wait",
        .zoom_in => "zoom-in",
        .zoom_out => "zoom-out",
    };
}

// Every protocol name must stay in the CSS `cursor` character set
// (`a-z0-9_-`); the hyphenated spellings above are the only difference from
// the enum tags.
comptime {
    const info = @typeInfo(Pointer).@"enum";
    for (info.field_values) |value| {
        const text = name(@fromBackingInt(@intCast(value)));
        if (text.len == 0) @compileError("empty pointer shape name");
        for (text) |ch| {
            if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '-')) {
                @compileError("invalid pointer shape name: " ++ text);
            }
        }
    }
}

/// Writes `OSC 22 ; name ST` for one shape.
pub fn writeShape(writer: *std.Io.Writer, shape: Pointer) !void {
    try writer.writeAll("\x1b]22;");
    try writer.writeAll(name(shape));
    try writer.writeAll("\x1b\\");
}

/// The last shape written to the terminal. Hosts keep one of these beside
/// their output writer; `update` only writes when the shape changes, and
/// `reset` restores `default` for an app that exits with a non-default shape.
pub const State = struct {
    emitted: Pointer = .default,

    /// Writes `shape` unless it is already the emitted shape.
    pub fn update(self: *State, writer: *std.Io.Writer, shape: Pointer) !void {
        if (self.emitted == shape) return;
        try writeShape(writer, shape);
        self.emitted = shape;
    }

    /// Restores the terminal default when a non-default shape is live.
    pub fn reset(self: *State, writer: *std.Io.Writer) !void {
        try self.update(writer, .default);
    }
};
