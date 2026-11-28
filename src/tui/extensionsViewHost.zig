// Terminal adapter for the Extensions side panel.
//
// The portable contribution owns the view, model, query and enablement
// state. This adapter supplies the native host capabilities it needs: opening
// the extension details through the editor opener, requesting a frame,
// showing status text, the context-menu/notification services and the current
// theme palette. It also mounts and disposes the pane-composite container.
const std = @import("std");
const ui = @import("ui");
const TerminalWorkbench = @import("workbenchWindow.zig").TerminalWorkbench;
const viewlet = @import("../vs/workbench/contrib/extensions/browser/extensionsViewlet.zig");
const ExtensionsViewPaneContainer = viewlet.ExtensionsViewPaneContainer;
const theme_colors_mod = @import("../vs/workbench/browser/themeColors.zig");

pub fn attach(workbench: *TerminalWorkbench) !void {
    if (workbench.extensions_view != null) return;
    if (workbench.extensions_service) |service| {
        service.attachWindow(&workbench.window_events);
        try service.attachWorkspace(workbench.workspace);
        service.quick_input = workbench.quick_input_api;
        service.pane_service = workbench.pane_composite_api;
        service.dialog_service = workbench.dialog_api;
    }
    const contribution = try ExtensionsViewPaneContainer.attach(
        workbench.allocator,
        &workbench.sidebar_part,
        &workbench.view_descriptor_service,
        .{
            .service = workbench.extensions_service,
            .host = .{
                .context = workbench,
                .open_extension = openExtension,
                .request_frame = requestFrame,
                .status = showStatus,
                .context_menu = workbench.context_menu_api,
                .notifications = workbench.notification_api,
                .theme = .{ .context = workbench, .get = themePalette },
                .window = &workbench.window_events,
            },
        },
    );
    workbench.extensions_view = contribution;
    workbench.extensions_list = contribution.list();
}

pub fn detach(workbench: *TerminalWorkbench) void {
    if (workbench.extensions_service) |service| service.detachWindow();
    if (workbench.extensions_view) |contribution| {
        contribution.deinit();
        workbench.extensions_view = null;
    }
    workbench.extensions_list = null;
}

fn openExtension(context: *anyopaque, identifier: []const u8) anyerror!void {
    const workbench: *TerminalWorkbench = @ptrCast(@alignCast(context));
    const service = workbench.extensions_service orelse return;
    try workbench.editor_opening.openExtension(service, identifier);
    if (workbench.activeTab()) |tab| tab.setThemeColors(workbench.theme_palette);
    workbench.requestFrame();
}

fn requestFrame(context: *anyopaque) void {
    const workbench: *TerminalWorkbench = @ptrCast(@alignCast(context));
    workbench.requestFrame();
}

fn showStatus(context: *anyopaque, message: []const u8) void {
    const workbench: *TerminalWorkbench = @ptrCast(@alignCast(context));
    workbench.setStatusHint("{s}", .{message});
}

fn themePalette(context: *anyopaque) ?*const theme_colors_mod.ThemeColors {
    const workbench: *TerminalWorkbench = @ptrCast(@alignCast(context));
    return workbench.theme_palette;
}
