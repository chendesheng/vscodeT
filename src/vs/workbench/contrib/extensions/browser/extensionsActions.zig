// Port of management actions in
// `src/vs/workbench/contrib/extensions/browser/extensionsActions.ts`.
// The terminal projects the action/dropdown groups into its shared context
// menu; command execution continues through ExtensionsWorkbenchService.
const std = @import("std");
const model = @import("../common/extensions.zig");
const Service = @import("extensionsWorkbenchService.zig").ExtensionsWorkbenchService;
const Menu = @import("../../../../platform/contextview/browser/contextMenuService.zig").Menu;

pub const EnablementAction = struct {
    context: *anyopaque,
    run: *const fn (*anyopaque, []const u8, bool, bool) anyerror!void,
};

const Command = struct {
    service: *Service,
    identifier: []const u8,
    operation: enum { install, uninstall, version, channel, restart, auto_update, publisher_auto_update, enable, disable },
    workspace: bool = false,
    prerelease: bool = false,
    enablement: ?EnablementAction = null,

    pub fn run(self: *Command) !void {
        switch (self.operation) {
            .install => if (self.service.availableUpdate(self.identifier) orelse self.service.galleryInfo(self.identifier)) |entry| try self.service.install(entry.*),
            .uninstall => try self.service.uninstall(self.identifier),
            .version => try self.service.showVersions(self.identifier),
            .channel => try self.service.switchReleaseChannel(self.identifier, self.prerelease),
            .restart => try self.service.restartExtensions(),
            .auto_update => if (self.service.find(self.identifier)) |extension| try self.service.updateAutoUpdateEnablementFor(extension.*, !self.service.isAutoUpdateEnabledFor(extension.*)),
            .publisher_auto_update => if (self.service.find(self.identifier)) |extension| try self.service.updatePublisherAutoUpdate(extension.publisherIdentifier(), !self.service.isPublisherAutoUpdateEnabled(extension.publisherIdentifier())),
            .enable, .disable => {
                const enable = self.operation == .enable;
                if (self.enablement) |callback| return callback.run(callback.context, self.identifier, enable, self.workspace);
                const state: model.EnablementState = if (self.workspace) (if (enable) .EnabledWorkspace else .DisabledWorkspace) else if (enable) .EnabledGlobally else .DisabledGlobally;
                _ = try self.service.requestEnablement(self.identifier, state);
            },
        }
    }
};

pub fn addManagementActions(menu: *Menu, service: *Service, extension: *const model.IExtension, enablement: ?EnablementAction) !void {
    const identifier = try menu.arena.allocator().dupe(u8, extension.identifier);
    if (extension.state == .Uninstalled) {
        if (extension.vsix_url != null) try menu.addAction("extensions.install", "Install", null, Command{ .service = service, .identifier = identifier, .operation = .install });
    } else {
        const enable = !extension.isEnabled();
        try menu.addAction(if (enable) "extensions.enableGlobally" else "extensions.disableGlobally", if (enable) "Enable" else "Disable", null, Command{ .service = service, .identifier = identifier, .operation = if (enable) .enable else .disable, .enablement = enablement });
        if (extension.state == .Installed and service.enablement.has_workspace) {
            try menu.addAction(if (enable) "extensions.enableForWorkspace" else "extensions.disableForWorkspace", if (enable) "Enable (Workspace)" else "Disable (Workspace)", null, Command{ .service = service, .identifier = identifier, .operation = if (enable) .enable else .disable, .workspace = true, .enablement = enablement });
        }
    }
    if (extension.state == .Installed and !extension.is_builtin) {
        if (service.availableUpdate(identifier) != null) try menu.addAction("extensions.update", "Update", null, Command{ .service = service, .identifier = identifier, .operation = .install });
        try menu.addAction("extensions.uninstall", "Uninstall", null, Command{ .service = service, .identifier = identifier, .operation = .uninstall });
    }
    if (service.runtimeState(identifier) == .RestartExtensions) try menu.addAction("extensions.runtimeState", "Restart Extensions", null, Command{ .service = service, .identifier = identifier, .operation = .restart });
    if (!extension.is_builtin and service.gallery_url != null) {
        try menu.addAction("extensions.installAnotherVersion", "Install Another Version…", null, Command{ .service = service, .identifier = identifier, .operation = .version });
        const prerelease = !(if (service.findLocal(identifier)) |local| local.is_pre_release else extension.is_pre_release);
        try menu.addAction(if (prerelease) "extensions.installPreReleaseVersion" else "extensions.installReleaseVersion", if (prerelease) "Switch to Pre-Release Version" else "Switch to Release Version", null, Command{ .service = service, .identifier = identifier, .operation = .channel, .prerelease = prerelease });
    }
    if (service.canTogglePublisherAutoUpdate() and !extension.is_builtin) {
        try menu.addAction("workbench.extensions.action.toggleAutoUpdatesForPublisher", "Auto Update All (From Publisher)", service.isPublisherAutoUpdateEnabled(extension.publisherIdentifier()), Command{ .service = service, .identifier = identifier, .operation = .publisher_auto_update });
    }
    if (service.canToggleAutoUpdate(extension.*)) {
        try menu.addAction("workbench.extensions.action.toggleAutoUpdateForExtension", "Auto Update", service.isAutoUpdateEnabledFor(extension.*), Command{ .service = service, .identifier = identifier, .operation = .auto_update });
    }
}
