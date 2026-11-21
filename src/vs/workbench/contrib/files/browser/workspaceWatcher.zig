// Port of `src/vs/workbench/contrib/files/browser/workspaceWatcher.ts`.
//
// Terminal adaptation: there is no `INotificationService`/opener/telemetry, so
// watcher errors are classified with the upstream ENOSPC/EUNKNOWN/ETERM
// strings and reported through the workbench logger/status callback. The
// watch requests themselves are the upstream ones: one recursive request per
// workspace folder plus `files.watcherInclude` paths, with the enabled
// `files.watcherExclude` patterns attached.

const std = @import("std");
const Allocator = std.mem.Allocator;
const files = @import("../../../../platform/files/common/files.zig");
const file_watcher_service = @import("../../../../platform/files/node/watcher/fileWatcherService.zig");
const configuration_mod = @import("../../../../platform/configuration/common/configuration.zig");
const WorkspaceContextService = @import("../../../services/workspaces/common/workspaceContextService.zig").WorkspaceContextService;
const ConfigurationService = @import("../../../services/configuration/browser/configurationService.zig").ConfigurationService;
const FileWatcherService = file_watcher_service.FileWatcherService;
const WatchHandle = file_watcher_service.WatchHandle;
const WatcherError = @import("../../../../platform/files/node/watcher/watcherClient.zig").WatcherError;

const WatchedFolder = struct {
    handles: std.array_list.Managed(*WatchHandle),

    fn deinit(self: *WatchedFolder) void {
        for (self.handles.items) |handle| handle.dispose();
        self.handles.deinit();
    }
};

pub const WorkspaceWatcher = struct {
    allocator: Allocator,
    configuration: *ConfigurationService,
    workspace: *WorkspaceContextService,
    file_service: *FileWatcherService,
    watched: std.StringHashMap(WatchedFolder),
    config_listener: ?usize = null,
    error_listener: ?@import("../../../../base/common/event.zig").Emitter(WatcherError).ListenerId = null,
    report: ReportFn,
    report_context: *anyopaque,

    pub const ReportFn = struct {
        context: *anyopaque,
        callback: *const fn (context: *anyopaque, message: []const u8) void,
    };

    pub fn init(
        allocator: Allocator,
        configuration: *ConfigurationService,
        workspace: *WorkspaceContextService,
        file_service: *FileWatcherService,
        report: ReportFn,
    ) !*WorkspaceWatcher {
        const self = try allocator.create(WorkspaceWatcher);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .configuration = configuration,
            .workspace = workspace,
            .file_service = file_service,
            .watched = std.StringHashMap(WatchedFolder).init(allocator),
            .config_listener = null,
            .error_listener = null,
            .report = report,
            .report_context = report.context,
        };
        errdefer {
            if (self.config_listener) |listener| self.configuration.unlistenConfigurationChange(listener);
            if (self.error_listener) |listener| self.file_service.on_did_error.unlisten(listener);
            self.watched.deinit();
        }

        // Upstream registers the configuration/workspace listeners before the
        // initial `refresh()`. The ported workspace context is set once during
        // startup, so the workbench calls `refresh()` when folders change.
        self.config_listener = try configuration.listenConfigurationChange(self, onConfigurationChanged);
        self.error_listener = try file_service.on_did_error.listen(self, onWatchError);
        try self.refresh();
        return self;
    }

    pub fn deinit(self: *WorkspaceWatcher) void {
        if (self.config_listener) |listener| {
            self.configuration.unlistenConfigurationChange(listener);
            self.config_listener = null;
        }
        if (self.error_listener) |listener| {
            self.file_service.on_did_error.unlisten(listener);
            self.error_listener = null;
        }
        self.unwatchAll();
        self.watched.deinit();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    /// Upstream `refresh`: unwatch everything, then watch every workspace
    /// folder with the current configuration.
    pub fn refresh(self: *WorkspaceWatcher) !void {
        self.unwatchAll();
        const folders = self.workspace.getWorkspace().folders.items;
        for (folders) |*folder| {
            if (!std.fs.path.isAbsolute(folder.resource)) continue;
            self.watchWorkspace(folder) catch |err| {
                const text = std.fmt.allocPrint(
                    self.allocator,
                    "failed to watch workspace folder {s}: {s}",
                    .{ folder.resource, @errorName(err) },
                ) catch continue;
                defer self.allocator.free(text);
                self.reportMessage(text);
            };
        }
    }

    fn watchWorkspace(self: *WorkspaceWatcher, folder: *const @import("../../../../platform/workspace/common/workspace.zig").WorkspaceFolder) !void {
        var excludes = std.array_list.Managed([]const u8).init(self.allocator);
        defer {
            for (excludes.items) |value| self.allocator.free(value);
            excludes.deinit();
        }
        try self.collectExcludes(folder.resource, &excludes);

        var paths = std.array_list.Managed([]u8).init(self.allocator);
        defer {
            for (paths.items) |path| self.allocator.free(path);
            paths.deinit();
        }
        try self.collectPaths(folder, &paths);

        var handles = std.array_list.Managed(*WatchHandle).init(self.allocator);
        errdefer {
            for (handles.items) |handle| handle.dispose();
            handles.deinit();
        }
        for (paths.items) |path| {
            const handle = try self.file_service.watch(path, .{
                .recursive = true,
                .excludes = excludes.items,
            });
            try handles.append(handle);
        }

        const key = try self.allocator.dupe(u8, folder.resource);
        errdefer self.allocator.free(key);
        try self.watched.put(key, .{ .handles = handles });
    }

    fn collectExcludes(self: *WorkspaceWatcher, folder: []const u8, out: *std.array_list.Managed([]const u8)) !void {
        const value = self.configuration.getValue("files.watcherExclude", .{ .resource = folder }) orelse return;
        if (value.* != .object) return;
        var iterator = value.object.iterator();
        while (iterator.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, "__proto__")) continue;
            const enabled = switch (entry.value_ptr.*) {
                .bool => |enabled| enabled,
                else => false,
            };
            if (!enabled) continue;
            const pattern = try self.allocator.dupe(u8, entry.key_ptr.*);
            out.append(pattern) catch |err| {
                self.allocator.free(pattern);
                return err;
            };
        }
    }

    fn collectPaths(
        self: *WorkspaceWatcher,
        folder: *const @import("../../../../platform/workspace/common/workspace.zig").WorkspaceFolder,
        out: *std.array_list.Managed([]u8),
    ) !void {
        try out.append(try std.fs.path.resolve(self.allocator, &.{folder.resource}));

        const value = self.configuration.getValue("files.watcherInclude", .{ .resource = folder.resource }) orelse return;
        if (value.* != .array) return;
        for (value.array.items) |item| {
            const include = switch (item) {
                .string => |text| text,
                else => continue,
            };
            if (include.len == 0) continue;

            const candidate = if (std.fs.path.isAbsolute(include))
                std.fs.path.resolve(self.allocator, &.{include}) catch |err| return err
            else
                std.fs.path.resolve(self.allocator, &.{ folder.resource, include }) catch |err| return err;

            if (std.fs.path.isAbsolute(include) and
                !std.mem.eql(u8, candidate, folder.resource) and
                !files.isParent(candidate, folder.resource, false))
            {
                self.allocator.free(candidate);
                continue;
            }
            out.append(candidate) catch |err| {
                self.allocator.free(candidate);
                return err;
            };
        }
    }

    fn unwatchAll(self: *WorkspaceWatcher) void {
        var keys = std.array_list.Managed([]const u8).init(self.allocator);
        defer keys.deinit();
        var iterator = self.watched.keyIterator();
        while (iterator.next()) |key| keys.append(key.*) catch {};
        for (keys.items) |key| {
            const removed = self.watched.fetchRemove(key) orelse continue;
            var value = removed.value;
            value.deinit();
            self.allocator.free(@constCast(removed.key));
        }
    }

    fn onConfigurationChanged(change: configuration_mod.Change, self: *WorkspaceWatcher) !void {
        if (configuration_mod.affectsConfiguration(change, "files.watcherExclude") or
            configuration_mod.affectsConfiguration(change, "files.watcherInclude"))
        {
            try self.refresh();
        }
    }

    fn onWatchError(watcher_error: WatcherError, self: *WorkspaceWatcher) !void {
        const message = watcher_error.message;
        if (std.mem.indexOf(u8, message, "ENOSPC") != null) {
            self.reportMessage("Unable to watch for file changes. Please exclude large folders with files.watcherExclude.");
        } else if (std.mem.indexOf(u8, message, "EUNKNOWN") != null) {
            self.reportMessage("File changes watcher stopped unexpectedly. A reload may enable the watcher again unless the workspace cannot be watched for file changes.");
        } else if (std.mem.indexOf(u8, message, "ETERM") != null) {
            self.reportMessage("File watcher terminated unexpectedly.");
        } else {
            self.reportMessage(message);
        }
    }

    fn reportMessage(self: *WorkspaceWatcher, message: []const u8) void {
        self.report.callback(self.report.context, message);
    }
};
