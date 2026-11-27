// Port of the Output panel registration in
// `src/vs/workbench/contrib/output/browser/output.contribution.ts`.
const views = @import("../../../common/views.zig");
const output = @import("../../../services/output/common/output.zig");
const actions = @import("../../../../platform/actions/common/actions.zig");
const ServicesAccessor = @import("../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const views_service = @import("../../../services/views/common/viewsService.zig");
const OutputView = @import("outputView.zig").OutputViewPane;

pub fn registerViewContainer(registry: *views.ViewContainersRegistry) !void {
    _ = try registry.register(.{ .id = output.OUTPUT_VIEW_ID, .title = "Output", .glyph = '≡', .hide_if_empty = true, .order = 1 }, .panel, .{});
}

pub const view_actions = [_]actions.Action2{
    .{ .command = .{ .id = "workbench.action.output.toggleOutput", .title = "View: Toggle Output", .category = "View" }, .f1 = true, .context = @constCast(&{}), .run_fn = toggle },
    .{ .command = .{ .id = "workbench.output.action.clearOutput", .title = "Clear Output" }, .f1 = true, .context = @constCast(&{}), .run_fn = clear },
};
fn toggle(_: *anyopaque, accessor: ServicesAccessor) !void {
    const api = (try accessor.get(views_service.views_service_id)).*;
    if (api.isViewVisible(OutputView.ID)) try api.closeView(OutputView.ID) else _ = try api.openView(OutputView, true);
}
fn clear(_: *anyopaque, accessor: ServicesAccessor) !void {
    const api = (try accessor.get(views_service.views_service_id)).*;
    const view = api.getViewWithId(OutputView) orelse return;
    if (view.service.active) |channel| try view.service.update(channel.descriptor.id, .Clear, null);
}
