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
    is_view_visible: *const fn (*anyopaque, []const u8) bool,
    close_view: *const fn (*anyopaque, []const u8) anyerror!void,

    pub fn isViewVisible(self: IViewsService, id: []const u8) bool {
        return self.is_view_visible(self.context, id);
    }

    pub fn closeView(self: IViewsService, id: []const u8) !void {
        try self.close_view(self.context, id);
    }

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
