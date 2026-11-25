// Port of the main container in src/vs/workbench/browser/media/style.css.
// Font metrics and elevation shadows require a browser compositor. The host
// supplies the cell viewport and the platform class at startup.
const ui = @import("ui");
pub const base: u16 = 0x00c0;
pub const Class = enum(u16) { monaco_workbench = base, windows, linux, mac };
const styles = [_]ui.Style{
    .{ .position = .relative, .overflow = .hidden, .z_index = 1 },
    .{},
    .{},
    .{},
};
pub const sheet = ui.css.Sheet{ .base = base, .styles = &styles };
