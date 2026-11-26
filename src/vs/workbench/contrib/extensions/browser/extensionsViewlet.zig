// Port of the terminal subset of
// `src/vs/workbench/contrib/extensions/browser/extensionsViewlet.ts`.
//
// The upstream `ExtensionsViewPaneContainer` builds the side bar container and
// its view descriptors through the views registry; the terminal contribution
// owns the mounted `ViewPaneContainer`, the single combined Extensions view
// and its pane callbacks. The browser container header's search box lives in
// the view body here, and the container hosts one merged view (Installed +
// Built-in list) instead of upstream's per-query views.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const views = @import("../../../common/views.zig");
const SidebarPart = @import("../../../browser/parts/sidebar/sidebarPart.zig").SidebarPart;
const ViewDescriptorService = @import("../../../services/views/browser/viewDescriptorService.zig").ViewDescriptorService;
const ViewContainerModel = @import("../../../services/views/common/viewContainerModel.zig").ViewContainerModel;
const pane_container = @import("../../../browser/parts/views/viewPaneContainer.zig");
const Pane = pane_container.Pane;
const view_mod = @import("extensionsViews.zig");
const ExtensionsListView = view_mod.ExtensionsListView;
const service_mod = @import("extensionsWorkbenchService.zig");
const model = @import("../common/extensions.zig");

pub const ExtensionsViewPaneContainer = struct {
    allocator: Allocator,
    sidebar: *SidebarPart,
    descriptors: *ViewDescriptorService,
    model: *ViewContainerModel,
    panes: []Pane,
    container: *pane_container.ViewPaneContainer,
    view: *ExtensionsListView,

    pub const Options = struct {
        service: ?*service_mod.ExtensionsWorkbenchService = null,
        host: view_mod.Host,
    };

    pub fn attach(
        allocator: Allocator,
        sidebar: *SidebarPart,
        descriptors: *ViewDescriptorService,
        options: Options,
    ) !*ExtensionsViewPaneContainer {
        const self = try allocator.create(ExtensionsViewPaneContainer);
        errdefer allocator.destroy(self);

        const view = try ExtensionsListView.init(allocator, .{ .service = options.service, .host = options.host });
        errdefer view.deinit();

        const view_model = try allocator.create(ViewContainerModel);
        errdefer allocator.destroy(view_model);
        view_model.* = ViewContainerModel.init(allocator, .{
            .id = model.VIEW_ID,
            .title = "Extensions",
            .icon = "",
        });
        errdefer view_model.deinit();

        const panes = try allocator.alloc(Pane, 1);
        errdefer allocator.free(panes);
        panes[0] = .{
            .id = model.VIEW_ID,
            .title = "Extensions",
            .context = self,
            .render_body = renderBody,
            .handle_key = handleKey,
            .handle_mouse = handleMouse,
            .set_focused = setFocused,
            .title_actions = titleActions,
        };

        const container = try sidebar.createViewPaneContainer(descriptors, view_model, panes);
        self.* = .{
            .allocator = allocator,
            .sidebar = sidebar,
            .descriptors = descriptors,
            .model = view_model,
            .panes = panes,
            .container = container,
            .view = view,
        };
        return self;
    }

    pub fn deinit(self: *ExtensionsViewPaneContainer) void {
        const allocator = self.allocator;
        self.sidebar.disposeViewPaneContainer(self.descriptors, self.container);
        self.view.deinit();
        self.model.deinit();
        allocator.destroy(self.model);
        allocator.free(self.panes);
        allocator.destroy(self);
    }

    pub fn setService(self: *ExtensionsViewPaneContainer, service: ?*service_mod.ExtensionsWorkbenchService) !void {
        try self.view.setService(service);
    }

    pub fn list(self: *ExtensionsViewPaneContainer) *ExtensionsListView {
        return self.view;
    }

    fn renderBody(context: *anyopaque, grid: *ui.CellGrid, rect: ui.Rect, focused: bool) anyerror!void {
        const self: *ExtensionsViewPaneContainer = @ptrCast(@alignCast(context));
        try self.view.render(grid, rect, focused);
    }

    fn handleKey(context: *anyopaque, event: *ui.KeyEvent) anyerror!bool {
        const self: *ExtensionsViewPaneContainer = @ptrCast(@alignCast(context));
        return self.view.handleKey(event);
    }

    fn handleMouse(context: *anyopaque, event: *const ui.MouseEvent, rect: ui.Rect) anyerror!bool {
        const self: *ExtensionsViewPaneContainer = @ptrCast(@alignCast(context));
        return self.view.handleMouse(event, rect);
    }

    fn setFocused(context: *anyopaque, focused: bool) void {
        const self: *ExtensionsViewPaneContainer = @ptrCast(@alignCast(context));
        self.view.setFocused(focused);
    }

    fn titleActions(context: *anyopaque) []const views.TitleAction {
        const self: *ExtensionsViewPaneContainer = @ptrCast(@alignCast(context));
        return self.view.titleActions();
    }
};
