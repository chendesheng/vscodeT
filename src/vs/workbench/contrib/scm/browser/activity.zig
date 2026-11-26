// Port of the count-badge and status-bar portions of SCMActiveRepositoryController from
// src/vs/workbench/contrib/scm/browser/activity.ts. The active-repository and
// resource events replace upstream observables. Title variables and explicit
// repository visibility selection still need their service contracts.
const std = @import("std");
const scm = @import("../common/scm.zig");
const configuration = @import("../../../../platform/configuration/common/configuration.zig");
const ConfigurationService = @import("../../../services/configuration/browser/configurationService.zig").ConfigurationService;
const statusbar = @import("../../../browser/parts/statusbar/statusbarPart.zig");
const ActivityService = @import("../../../services/activity/browser/activityService.zig").ActivityService;
const event = @import("../../../../base/common/event.zig");

pub const SCMActiveRepositoryController = struct {
    allocator: std.mem.Allocator,
    scm_service: scm.ISCMService,
    scm_view_service: scm.ISCMViewService,
    activity_service: *ActivityService,
    statusbar_service: *statusbar.StatusbarService,
    status_entry: ?statusbar.EntryAccessor = null,
    subscriptions: [4]?event.SignalSubscription = @splat(null),
    configuration_service: ?*ConfigurationService = null,
    configuration_listener: ?usize = null,
    count: usize = 0,
    badge_buffer: [32]u8 = undefined,

    pub fn create(allocator: std.mem.Allocator, service: scm.ISCMService, views: scm.ISCMViewService, resource_events: *event.Emitter(void), activity_service: *ActivityService, statusbar_service: *statusbar.StatusbarService, config: ?*ConfigurationService) !*SCMActiveRepositoryController {
        const self = try allocator.create(SCMActiveRepositoryController);
        self.* = .{ .allocator = allocator, .scm_service = service, .scm_view_service = views, .activity_service = activity_service, .statusbar_service = statusbar_service };
        errdefer self.destroy();
        self.subscriptions[0] = try resource_events.listenDisposable(self, onDidChangeResources);
        self.subscriptions[1] = try views.on_did_change_active_repository.listenDisposable(self, onActiveRepositoryChanged);
        self.subscriptions[2] = try service.on_did_add_repository.listenDisposable(self, onRepositoriesChanged);
        self.subscriptions[3] = try service.on_did_remove_repository.listenDisposable(self, onRepositoriesChanged);
        try self.setConfiguration(config);
        try self.updateStatusBar();
        return self;
    }

    pub fn detachConfiguration(self: *SCMActiveRepositoryController) void {
        if (self.configuration_listener) |listener| self.configuration_service.?.unlistenConfigurationChange(listener);
        self.configuration_listener = null;
        self.configuration_service = null;
    }

    pub fn setConfiguration(self: *SCMActiveRepositoryController, config: ?*ConfigurationService) !void {
        self.detachConfiguration();
        self.configuration_service = config;
        if (config) |service| self.configuration_listener = try service.listenConfigurationChange(self, onDidChangeConfiguration);
        try self.updateActivityCountBadge();
    }

    fn onDidChangeResources(_: void, self: *SCMActiveRepositoryController) !void {
        try self.updateActivityCountBadge();
        try self.updateStatusBar();
    }

    fn onActiveRepositoryChanged(_: ?scm.ActiveRepository, self: *SCMActiveRepositoryController) !void {
        try onDidChangeResources({}, self);
    }

    fn onRepositoriesChanged(_: *scm.ISCMRepository, self: *SCMActiveRepositoryController) !void {
        try self.updateActivityCountBadge();
    }

    fn onDidChangeConfiguration(change: configuration.Change, self: *SCMActiveRepositoryController) !void {
        if (configuration.affectsConfiguration(change, "scm.countBadge")) try self.updateActivityCountBadge();
    }

    fn updateActivityCountBadge(self: *SCMActiveRepositoryController) !void {
        const mode = if (self.configuration_service) |config| config.interface().getString("scm.countBadge") orelse "all" else "all";
        var count: usize = 0;
        if (std.mem.eql(u8, mode, "focused")) {
            if (self.scm_view_service.activeRepository()) |active| {
                const provider = active.repository.provider;
                count = provider.count orelse getRepositoryResourceCount(provider.*);
            }
        } else if (std.mem.eql(u8, mode, "all")) {
            for (self.scm_service.repositories()) |repository| {
                const provider = repository.provider;
                if (provider.is_hidden) continue;
                count += provider.count orelse getRepositoryResourceCount(provider.*);
            }
        }
        if (count == self.count) return;
        if (count == 0) {
            self.activity_service.removeActivity("scm", "scm.changes");
        } else {
            // NumberBadge is adapted to the terminal activity description.
            const text = try std.fmt.bufPrint(&self.badge_buffer, "{d}", .{count});
            try self.activity_service.setViewContainerActivity("scm", .{ .id = "scm.changes", .badge = .{ .description = text } });
        }
        self.count = count;
    }

    /// The native provider currently supplies one combined checkout/sync
    /// command. Its text is borrowed from the repository's stable buffer.
    fn updateStatusBar(self: *SCMActiveRepositoryController) !void {
        const commands = if (self.scm_view_service.activeRepository()) |active| active.repository.provider.status_bar_commands else &.{};
        if (commands.len == 0) {
            if (self.status_entry) |entry| entry.dispose();
            self.status_entry = null;
            return;
        }
        const command = commands[0];
        const entry: @import("../../../services/statusbar/browser/statusbar.zig").StatusbarEntry = .{
            .name = "Source Control",
            .text = command.title,
            .tooltip = command.id,
            .command = if (command.id.len == 0) null else .{ .id = command.id },
        };
        if (self.status_entry) |accessor| {
            accessor.update(entry);
        } else {
            self.status_entry = try self.statusbar_service.addEntry(entry, "workbench.scm.branch", .left, .{ .number = 100 });
        }
    }

    pub fn destroy(self: *SCMActiveRepositoryController) void {
        self.detachConfiguration();
        if (self.status_entry) |entry| entry.dispose();
        for (self.subscriptions) |subscription| if (subscription) |value| value.dispose();
        if (self.count != 0) self.activity_service.removeActivity("scm", "scm.changes");
        self.allocator.destroy(self);
    }
};

/// Port of getRepositoryResourceCount from SCM's browser/util.ts.
fn getRepositoryResourceCount(provider: scm.ISCMProvider) usize {
    var count: usize = 0;
    for (provider.groups()) |group| count += group.resources().len;
    return count;
}
