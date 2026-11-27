// Terminal adapter for the Extensions side panel.
//
// The portable contribution owns the view, model, query and enablement
// state. This adapter supplies the native host capabilities it needs: opening
// the extension manifest through the editor opener, requesting a frame,
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
            },
        },
    );
    workbench.extensions_view = contribution;
    workbench.extensions_list = contribution.list();
}

pub fn detach(workbench: *TerminalWorkbench) void {
    if (workbench.extensions_view) |contribution| {
        contribution.deinit();
        workbench.extensions_view = null;
    }
    workbench.extensions_list = null;
}

fn openExtension(context: *anyopaque, path: []const u8) anyerror!void {
    const workbench: *TerminalWorkbench = @ptrCast(@alignCast(context));
    workbench.requestOpenPath(path);
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
