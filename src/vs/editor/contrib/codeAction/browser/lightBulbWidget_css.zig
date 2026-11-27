// Port of `src/vs/editor/contrib/codeAction/browser/lightBulbWidget.css`.
// Cell glyphs replace icon fonts. Pseudo-elements, opacity, pixel geometry,
// descendant selectors and custom properties are not supported; the host
// resolves theme colors before registering the sheet.
const ui = @import("ui");
pub const base: u16 = 0x0150;
pub const Class = enum(u16) { light_bulb_widget = base, codicon_light_bulb, codicon_lightbulb_autofix, codicon_sparkle_filled };
pub const Colors = struct {
    normal: ui.Color = .{ .r = 235, .g = 200, .b = 62 },
    preferred: ui.Color = .{ .r = 235, .g = 200, .b = 62 },
    ai: ui.Color = .{ .r = 235, .g = 200, .b = 62 },
};
fn styles(colors: Colors) [4]ui.Style {
    return .{
        .{ .display = .flex, .align_items = .center, .justify_content = .center, .pointer = .pointer, .white_space = .pre },
        .{ .color = colors.normal },
        .{ .color = colors.preferred },
        .{ .color = colors.ai },
    };
}
const default_styles = styles(.{});
pub const sheet = ui.css.Sheet{ .base = base, .styles = &default_styles };
pub fn registerTheme(doc: *ui.Document, colors: Colors) !void {
    const themed_styles = styles(colors);
    _ = try doc.registerSheet(.{ .base = base, .styles = &themed_styles });
}
