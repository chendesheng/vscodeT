// Port of the view lookup used by actions in
// `src/vs/workbench/services/views/common/viewsService.ts`.
// Terminal view identifiers carry the view type at compile time.
const instantiation = @import("../../../../platform/instantiation/common/instantiation.zig");
pub const views_service_id = instantiation.ServiceIdentifier(IViewsService, "viewsService");

pub const IViewsService = struct {
    context: *anyopaque,
    get_active_view: *const fn (*anyopaque, []const u8) ?*anyopaque,
    get_view: *const fn (*anyopaque, []const u8) ?*anyopaque,
    open_view: *const fn (*anyopaque, []const u8, bool) anyerror!?*anyopaque,

    pub fn getActiveViewWithId(self: IViewsService, comptime View: type) ?*View {
        return @ptrCast(@alignCast(self.get_active_view(self.context, View.ID) orelse return null));
    }

    pub fn getViewWithId(self: IViewsService, comptime View: type) ?*View {
        return @ptrCast(@alignCast(self.get_view(self.context, View.ID) orelse return null));
    }

    pub fn openView(self: IViewsService, comptime View: type, focus: bool) !?*View {
        return @ptrCast(@alignCast(try self.open_view(self.context, View.ID, focus) orelse return null));
    }
};
