// Port of `src/vs/editor/contrib/message/browser/messageController.css`.
// Fixed-cell layout replaces pixel padding and the triangular border anchor;
// animation, custom properties and descendant matching are omitted.
const ui = @import("ui");
pub const base: u16 = 0x0160;
pub const Class = enum(u16) { monaco_editor_overlaymessage = base, message };
pub const Colors = struct {
    foreground: ui.Color = .{ .r = 204, .g = 204, .b = 204 },
    background: ui.Color = .{ .r = 37, .g = 37, .b = 38 },
    border: ui.Color = .{ .r = 0, .g = 122, .b = 204 },
};
fn styles(colors: Colors) [2]ui.Style {
    return .{
        .{ .width = .{ .percent = 100 }, .height = .{ .percent = 100 }, .z_index = 10000 },
        .{ .width = .{ .percent = 100 }, .height = .{ .percent = 100 }, .border_style = .rounded, .border_color = colors.border, .color = colors.foreground, .background = colors.background, .white_space = .pre_wrap, .overflow = .hidden },
    };
}
const default_styles = styles(.{});
pub const sheet = ui.css.Sheet{ .base = base, .styles = &default_styles };
pub fn registerTheme(doc: *ui.Document, colors: Colors) !void {
    const themed_styles = styles(colors);
    _ = try doc.registerSheet(.{ .base = base, .styles = &themed_styles });
}
