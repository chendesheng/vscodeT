// Port of the terminal view-container registration in
// src/vs/workbench/contrib/terminal/browser/terminal.contribution.ts.
// "terminal" is the native alias for the upstream TERMINAL_VIEW_ID.
const views = @import("../../../common/views.zig");

pub const container_id = "terminal";

pub fn registerViewContainer(registry: *views.ViewContainersRegistry) !void {
    _ = try registry.register(.{
        .id = container_id,
        .title = "Terminal",
        .glyph = '>',
        .hide_if_empty = true,
        .order = 3,
    }, .panel, .{ .is_default = true, .do_not_register_open_command = true });
}
