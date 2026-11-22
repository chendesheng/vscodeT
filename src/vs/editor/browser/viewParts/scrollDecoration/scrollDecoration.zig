// Port of the portable visibility decision of
// `src/vs/editor/browser/viewParts/scrollDecoration/scrollDecoration.ts`.
//
// Terminal adaptation: upstream renders a CSS box-shadow over the top of the
// scrolled content. A cell grid paints one dim row background at the top of the
// text viewport while the document is scrolled; the terminal has no alpha, so
// the shadow is a solid `scrollbar.shadow` row tint rather than a blurred
// translucent shadow.

const std = @import("std");
const ui = @import("ui");

/// The shadow is visible only after the first view line has scrolled away.
pub fn isVisible(top_view_line: usize) bool {
    return top_view_line > 1;
}

/// One-row shadow tint for the first visible text row.
pub fn shadowColor(theme_color: ?ui.Color) ui.Color {
    return theme_color orelse .{ .r = 0, .g = 0, .b = 0 };
}

test "scroll decoration: visible only after scrolling" {
    try std.testing.expect(!isVisible(1));
    try std.testing.expect(isVisible(2));
}
