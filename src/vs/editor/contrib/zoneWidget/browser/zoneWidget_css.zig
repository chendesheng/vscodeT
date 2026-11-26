// Port of `src/vs/editor/contrib/zoneWidget/browser/zoneWidget.css`.
// The zone's frame and geometry are cell-valued; no CSS selector engine.
const ui = @import("ui");
pub const base: u16 = 0x0100;
pub const Class = enum(u16) { zone_widget = base, zone_widget_container = base + 1 };
const styles = [_]ui.Style{
    .{ .position = .absolute, .z_index = 10, .overflow = .hidden },
    .{ .position = .relative, .overflow = .hidden },
};
pub const sheet = ui.css.Sheet{ .base = base, .styles = &styles };
