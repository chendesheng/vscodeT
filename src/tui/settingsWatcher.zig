// TUI adapter that watches the settings files read by
// `ConfigurationService` and reloads the service when one changes.
//
// This is the terminal consumer for the ported file watcher. It uses
// non-recursive requests for the user settings file, the workspace file and
// every folder's `.vscode/settings.json`; missing files are suspended and
// retried by `BaseWatcher`, so creating a settings file later is picked up.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const common = @import("../vs/platform/files/common/watcher.zig");
const files = @import("../vs/platform/files/common/files.zig");
const WatchRequest = common.WatchRequest;
const FileChange = files.FileChange;
const universal_mod = @import("../vs/platform/files/node/watcher/watcher.zig");
const UniversalWatcher = universal_mod.UniversalWatcher;
const configuration_mod = @import("../vs/workbench/services/configuration/browser/configurationService.zig");
const ConfigurationService = configuration_mod.ConfigurationService;

pub const ReloadCallback = struct {
    context: *anyopaque,
    callback: *const fn (context: *anyopaque) void,
};

pub const SettingsWatcher = struct {
    allocator: Allocator,
    io: Io,
    configuration: *ConfigurationService,
    watcher: *UniversalWatcher,
    on_reload: ?ReloadCallback = null,
    reload_count: usize = 0,
    last_reload_failed: bool = false,

    pub fn init(
        allocator: Allocator,
        io: Io,
        configuration: *ConfigurationService,
    ) !*SettingsWatcher {
        const self = try allocator.create(SettingsWatcher);
        errdefer allocator.destroy(self);

        const watcher = try UniversalWatcher.init(allocator, io);
        errdefer watcher.deinit();

        self.* = .{
            .allocator = allocator,
            .io = io,
            .configuration = configuration,
            .watcher = watcher,
        };
        _ = try watcher.on_change.listen(self, onFileChanges);
        try self.update();
        return self;
    }

    pub fn deinit(self: *SettingsWatcher) void {
        self.watcher.deinit();
        self.allocator.destroy(self);
    }

    pub fn setOnReload(self: *SettingsWatcher, callback: ?ReloadCallback) void {
        self.on_reload = callback;
    }

    pub fn update(self: *SettingsWatcher) !void {
        const paths = try self.configuration.settingsFilePaths(self.allocator);
        defer self.configuration.freeSettingsFilePaths(self.allocator, paths);

        var requests = std.array_list.Managed(WatchRequest).init(self.allocator);
        defer requests.deinit();
        for (paths) |path| {
            try requests.append(.{
                .path = path,
                .recursive = false,
            });
        }
        try self.watcher.watch(requests.items);
    }

    pub fn poll(self: *SettingsWatcher, now_ms: i64) !bool {
        return self.watcher.poll(now_ms);
    }

    pub fn waitHandle(self: *const SettingsWatcher) @import("../vs/platform/files/node/watcher/parcel/watcherLib/root.zig").WaitHandle {
        return self.watcher.waitHandle();
    }

    pub fn nextTimeout(self: *const SettingsWatcher, now_ms: i64) ?u32 {
        return self.watcher.nextTimeout(now_ms);
    }

    fn onFileChanges(changes: []const FileChange, self: *SettingsWatcher) !void {
        if (changes.len == 0) return;
        self.configuration.reload() catch {
            self.last_reload_failed = true;
            return;
        };
        self.last_reload_failed = false;
        self.reload_count += 1;
        if (self.on_reload) |callback| callback.callback(callback.context);
    }
};

test "SettingsWatcher: reloads when a settings file changes" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".vscode");

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buffer);
    const root = path_buffer[0..root_len];
    const settings_path = try std.fs.path.join(allocator, &.{ root, ".vscode", "settings.json" });
    defer allocator.free(settings_path);

    var file = try tmp.dir.createFile(io, ".vscode/settings.json", .{});
    try file.writeStreamingAll(io, "{\"editor.tabSize\": 2}");
    file.close(io);

    const context = try @import("../vs/workbench/services/workspaces/common/workspaceContextService.zig").WorkspaceContextService.initWithFolders(
        allocator,
        "test",
        &.{root},
    );
    defer context.deinit();
    const configuration = try ConfigurationService.init(allocator, io, context, .{});
    defer configuration.deinit();

    var watcher = try SettingsWatcher.init(allocator, io, configuration);
    defer watcher.deinit();

    var file_write = try tmp.dir.createFile(io, ".vscode/settings.json", .{ .truncate = true });
    try file_write.writeStreamingAll(io, "{\"editor.tabSize\": 6}");
    file_write.close(io);

    const deadline = std.Io.Timestamp.now(io, .real).toMilliseconds() + 3000;
    while (std.Io.Timestamp.now(io, .real).toMilliseconds() < deadline and watcher.reload_count == 0) {
        _ = try watcher.poll(std.Io.Timestamp.now(io, .real).toMilliseconds());
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(watcher.reload_count > 0);
    try std.testing.expectEqual(@as(i64, 6), configuration.getValue("editor.tabSize", .{ .resource = settings_path }).?.integer);
}
