// Port of the Explorer view-container registration in
// src/vs/workbench/contrib/files/browser/explorerViewlet.ts.
// The terminal's existing activity ID is the native alias for VIEWLET_ID.
const views = @import("../../../common/views.zig");

pub fn registerViewContainer(registry: *views.ViewContainersRegistry) !void {
    _ = try registry.register(.{
        .id = "explorer",
        .title = "Explorer",
        .glyph = '\u{f07b}',
        .order = 0,
    }, .sidebar, .{ .is_default = true });
}
