// Port of `src/vs/editor/contrib/inlayHints/browser/inlayHintsContribution.ts`
// and the dynamically generated inlay CSS rules in inlayHintsController.ts.
// Inline decoration classes use the existing line-renderer paint path; the
// terminal maps fonts/pixel padding to fixed cell colors and spaces.
const std = @import("std");
const ui = @import("ui");
pub const hint_class = "inlay-hint";
pub const type_class = "inlay-hint-type";
pub const parameter_class = "inlay-hint-parameter";
pub const link_class = "inlay-hint-link";
pub const Theme = struct {
    foreground: ui.Color = .{ .r = 170, .g = 170, .b = 170 },
    background: ui.Color = .{ .r = 48, .g = 48, .b = 48 },
    type_foreground: ui.Color = .{ .r = 170, .g = 170, .b = 170 },
    type_background: ui.Color = .{ .r = 48, .g = 48, .b = 48 },
    parameter_foreground: ui.Color = .{ .r = 170, .g = 170, .b = 170 },
    parameter_background: ui.Color = .{ .r = 48, .g = 48, .b = 48 },
};
pub fn applyPaint(style: *ui.style.PaintStyle, classes: []const u8, theme: Theme) void {
    var iter = std.mem.tokenizeScalar(u8, classes, ' ');
    while (iter.next()) |name| {
        if (std.mem.eql(u8, name, type_class)) {
            style.color = theme.type_foreground;
            style.background = theme.type_background;
        } else if (std.mem.eql(u8, name, parameter_class)) {
            style.color = theme.parameter_foreground;
            style.background = theme.parameter_background;
        } else if (std.mem.eql(u8, name, hint_class)) {
            style.color = theme.foreground;
            style.background = theme.background;
        } else if (std.mem.eql(u8, name, link_class)) style.underline = true;
    }
}
