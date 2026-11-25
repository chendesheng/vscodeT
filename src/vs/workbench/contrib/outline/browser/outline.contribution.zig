// Port of the view registration in src/vs/workbench/contrib/outline/browser/outline.contribution.ts.
// The terminal uses the native outline ID and explicit pane factory.
const views = @import("../../../common/views.zig");

pub fn registerViews(registry: *views.ViewsRegistry) !void {
    try registry.registerViews(&.{.{ .id = "outline", .name = "Outline", .order = 2, .weight = 30, .collapsed = true }}, "explorer");
}
