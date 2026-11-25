// Port of the part container in src/vs/workbench/browser/media/part.css.
// Cell rectangles supply the border box. Sash geometry and title controls
// use their own part renderers.
const ui = @import("ui");
pub const base: u16 = 0x00d0;
pub const Class = enum(u16) { part = base, editor };
const styles = [_]ui.Style{ .{ .overflow = .hidden }, .{} };
pub const sheet = ui.css.Sheet{ .base = base, .styles = &styles };
