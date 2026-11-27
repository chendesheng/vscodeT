// Terminal host for the user-keybindings half of
// `src/vs/workbench/services/keybinding/browser/keybindingService.ts`.
//
// Upstream `UserKeybindings` watches the user data profile file through the
// file service. The terminal reads the same JSONC array from the discovered
// paths (VS Code profile first, TUI override last) and rebuilds the items when
// the profile resource watcher reports a change. The loader owns the 50 ms
// scheduler, worker, snapshot and onDidChange event; startup loads synchronously.
// The terminal file watcher reports writes through onDidFilesChange (a separate
// FileService.onDidRunOperation stream is not yet ported).
//
// Parsed items are `ResolvedKeybindingItem`s with `isDefault = false`:
// - non-removal entries become user bindings (resolved against the terminal's
//   Ctrl-only key map, exactly like the default rules);
// - `-command` entries are removals. Passing them as resolver overrides lets
//   the ported `KeybindingResolver.handleRemovals` subtract the matching
//   default bindings from every host.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const time_compat = @import("../../../../base/common/timeCompat.zig");
const configuration_models = @import("../../../../platform/configuration/common/configurationModels.zig");
const key_bindings = @import("../../../../base/common/keybindings.zig");
const resolved_item = @import("../../../../platform/keybinding/common/resolvedKeybindingItem.zig");
const us_layout = @import("../../../../platform/keybinding/common/usLayoutResolvedKeybinding.zig");
const keybinding_io = @import("../common/keybindingIO.zig");
const configuration = @import("../../../../platform/configuration/common/configuration.zig");
const dispatch = @import("../../../../base/common/windowDispatch.zig");
const file_watch = @import("../../../../platform/files/node/watcher/fileWatcherService.zig");
const files = @import("../../../../platform/files/common/files.zig");
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const keybinding_service = @import("./keybindingService.zig");

const ResolvedKeybindingItem = resolved_item.ResolvedKeybindingItem;
const USLayoutResolvedKeybinding = us_layout.USLayoutResolvedKeybinding;

pub const max_keybindings_file_size: usize = 10 * 1024 * 1024;

pub const UserKeybindings = struct {
    allocator: Allocator,
    json_arena: std.heap.ArenaAllocator,
    key_arena: std.heap.ArenaAllocator,
    items: std.array_list.Managed(*const ResolvedKeybindingItem),
    removal_items: std.array_list.Managed(*const ResolvedKeybindingItem),
    error_count: usize = 0,
    raw_keybindings: std.ArrayList(std.json.Value) = .empty,

    pub fn load(allocator: Allocator, io: Io, paths: []const []const u8) !*UserKeybindings {
        const self = try allocator.create(UserKeybindings);
        self.* = .{
            .allocator = allocator,
            .json_arena = std.heap.ArenaAllocator.init(allocator),
            .key_arena = std.heap.ArenaAllocator.init(allocator),
            .items = std.array_list.Managed(*const ResolvedKeybindingItem).init(allocator),
            .removal_items = std.array_list.Managed(*const ResolvedKeybindingItem).init(allocator),
        };
        errdefer self.deinit();

        for (paths) |path| {
            self.loadFile(io, path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => self.error_count += 1,
            };
        }
        return self;
    }

    pub fn deinit(self: *UserKeybindings) void {
        self.raw_keybindings.deinit(self.allocator);
        self.items.deinit();
        self.removal_items.deinit();
        self.key_arena.deinit();
        self.json_arena.deinit();
        self.allocator.destroy(self);
    }

    pub fn userItems(self: *const UserKeybindings) []const *const ResolvedKeybindingItem {
        return self.items.items;
    }

    /// Removal entries for `KeybindingResolver.handleRemovals`.
    pub fn removals(self: *const UserKeybindings) []const *const ResolvedKeybindingItem {
        return self.removal_items.items;
    }

    fn loadFile(self: *UserKeybindings, io: Io, path: []const u8) !void {
        const text = Io.Dir.cwd().readFileAlloc(
            io,
            path,
            self.allocator,
            .limited(max_keybindings_file_size),
        ) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(text);

        const sanitized = configuration_models.stripJsonc(self.json_arena.allocator(), text) catch {
            self.error_count += 1;
            return;
        };
        const value = std.json.parseFromSliceLeaky(
            std.json.Value,
            self.json_arena.allocator(),
            sanitized,
            .{ .duplicate_field_behavior = .use_last },
        ) catch {
            self.error_count += 1;
            return;
        };
        if (value != .array) {
            self.error_count += 1;
            return;
        }
        for (value.array.items) |entry| {
            if (entry != .object) continue;
            try self.raw_keybindings.append(self.allocator, entry);
            const parsed = keybinding_io.readUserKeybindingItem(
                self.key_arena.allocator(),
                self.json_arena.allocator(),
                entry,
            ) catch {
                self.error_count += 1;
                continue;
            };
            const is_removal = if (parsed.command) |command|
                command.len > 0 and command[0] == '-'
            else
                false;
            self.append(parsed, is_removal) catch {
                self.error_count += 1;
            };
        }
    }

    fn append(self: *UserKeybindings, parsed: keybinding_io.UserKeybindingItem, is_removal: bool) !void {
        const allocator = self.key_arena.allocator();
        var resolved_interface: ?key_bindings.ResolvedKeybinding = null;
        if (parsed.keybinding) |keybinding| {
            if (try USLayoutResolvedKeybinding.resolveKeybinding(allocator, keybinding, keybinding_service.bindingOS())) |resolved| {
                const held = try allocator.create(USLayoutResolvedKeybinding);
                held.* = resolved;
                resolved_interface = held.interface();
            }
        }
        const item = try allocator.create(ResolvedKeybindingItem);
        item.* = try ResolvedKeybindingItem.init(
            allocator,
            resolved_interface,
            parsed.command,
            parsed.command_args,
            parsed.when,
            false,
            null,
            false,
            parsed.system_wide,
        );
        if (is_removal) {
            try self.removal_items.append(item);
        } else {
            try self.items.append(item);
        }
    }
};

/// Upstream UserKeybindings' profile watcher and reload scheduler. The
/// terminal has multiple ordered profile paths instead of IUserDataProfileService.
/// The previous immutable parsed snapshot stays alive while consumers handle
/// onDidChange and replace resolvers that borrow its entries.
pub const UserKeybindingsLoader = struct {
    allocator: Allocator,
    io: Io,
    async_io: Io,
    window: *dispatch.Queue,
    paths: []const []const u8 = &.{},
    current: ?*UserKeybindings = null,
    job: ?*ReloadJob = null,
    reload_pending: bool = false,
    file_service: ?*file_watch.FileWatcherService = null,
    file_listener: ?usize = null,
    watchers: std.ArrayList(*file_watch.WatchHandle) = .empty,
    reload_timer: dispatch.Task,
    on_did_change: Emitter(void),

    const Outcome = union(enum) { bindings: *UserKeybindings, err: anyerror };
    const ReloadJob = struct {
        allocator: Allocator,
        io: Io,
        future: Io.Future(Outcome),
        completion: dispatch.Task,
        paths: []const []const u8,

        fn destroy(self: *ReloadJob) void {
            const allocator = self.allocator;
            freePaths(allocator, self.paths);
            allocator.destroy(self);
        }
    };

    pub fn create(allocator: Allocator, io: Io, async_io: Io, window: *dispatch.Queue) !*UserKeybindingsLoader {
        const self = try allocator.create(UserKeybindingsLoader);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .async_io = async_io,
            .window = window,
            .reload_timer = .{ .queue = window, .context = self, .run = onReloadDeadline },
            .on_did_change = .init(allocator),
        };
        return self;
    }

    pub fn setPaths(self: *UserKeybindingsLoader, paths: []const []const u8, service: ?*file_watch.FileWatcherService) !void {
        const next = try copyPaths(self.allocator, paths);
        self.cancelReload();
        self.unwatch();
        freePaths(self.allocator, self.paths);
        self.paths = next;
        if (service) |file_service| {
            self.file_service = file_service;
            self.file_listener = file_service.on_did_change.listen(self, onDidFilesChange) catch null;
            for (self.paths) |path| {
                self.watch(file_service, std.fs.path.dirname(path) orelse ".");
                self.watch(file_service, path);
            }
        }
        self.reloadSync();
    }

    fn watch(self: *UserKeybindingsLoader, service: *file_watch.FileWatcherService, path: []const u8) void {
        const handle = service.watch(path, .{ .recursive = false }) catch return;
        self.watchers.append(self.allocator, handle) catch handle.dispose();
    }

    fn unwatch(self: *UserKeybindingsLoader) void {
        if (self.file_listener) |listener| self.file_service.?.on_did_change.unlisten(listener);
        self.file_listener = null;
        self.file_service = null;
        for (self.watchers.items) |handle| handle.dispose();
        self.watchers.clearRetainingCapacity();
    }

    fn onDidFilesChange(changes: []const files.FileChange, self: *UserKeybindingsLoader) !void {
        var event = try files.FileChangesEvent.init(self.allocator, changes, @import("builtin").os.tag == .windows);
        defer event.deinit();
        for (self.paths) |path| {
            if (event.contains(path, &.{})) {
                self.reload_timer.schedule(time_compat.milliTimestamp() + 50);
                return;
            }
        }
    }

    fn onReloadDeadline(ctx: *anyopaque, _: i64, _: bool) bool {
        const self: *UserKeybindingsLoader = @ptrCast(@alignCast(ctx));
        self.requestReload();
        return false;
    }

    pub fn ensureLoaded(self: *UserKeybindingsLoader) !void {
        if (self.current == null and self.paths.len > 0)
            self.current = try UserKeybindings.load(self.allocator, self.io, self.paths);
    }

    pub fn removals(self: *const UserKeybindingsLoader) []const *const ResolvedKeybindingItem {
        const bindings = self.current orelse return &.{};
        return bindings.removals();
    }

    pub fn filteredOverrides(self: *UserKeybindingsLoader, context: *anyopaque, known: *const fn (*anyopaque, []const u8) bool) ![]const *const ResolvedKeybindingItem {
        self.ensureLoaded() catch return &.{};
        const bindings = self.current orelse return &.{};
        var overrides: std.ArrayList(*const ResolvedKeybindingItem) = .empty;
        errdefer overrides.deinit(self.allocator);
        for (bindings.userItems()) |item| {
            const command = item.command orelse continue;
            if (known(context, command)) try overrides.append(self.allocator, item);
        }
        try overrides.appendSlice(self.allocator, bindings.removals());
        return overrides.toOwnedSlice(self.allocator);
    }

    pub fn reloadSync(self: *UserKeybindingsLoader) void {
        self.cancelReload();
        const next = if (self.paths.len == 0) null else UserKeybindings.load(self.allocator, self.io, self.paths) catch null;
        self.install(next);
    }

    fn install(self: *UserKeybindingsLoader, next: ?*UserKeybindings) void {
        const old = self.current;
        const previous_raw = if (old) |bindings| bindings.raw_keybindings.items else &.{};
        const next_raw = if (next) |bindings| bindings.raw_keybindings.items else &.{};
        const equal = blk: {
            if (previous_raw.len != next_raw.len) break :blk false;
            for (previous_raw, next_raw) |left, right| {
                if (!configuration.jsonValuesEqual(left, right)) break :blk false;
            }
            break :blk true;
        };
        if (equal and old != null) {
            if (next) |bindings| bindings.deinit();
            return;
        }
        self.current = next;
        defer if (old) |bindings| bindings.deinit();
        if (!equal) self.on_did_change.fire({}) catch {};
    }

    fn requestReload(self: *UserKeybindingsLoader) void {
        if (self.job != null) {
            self.reload_pending = true;
            return;
        }
        const paths = copyPaths(self.allocator, self.paths) catch return;
        const job = self.allocator.create(ReloadJob) catch {
            freePaths(self.allocator, paths);
            return;
        };
        job.* = .{
            .allocator = self.allocator,
            .io = self.async_io,
            .completion = .{ .queue = self.window, .context = self, .run = applyLoadedKeybindings, .progress = true },
            .future = undefined,
            .paths = paths,
        };
        job.future = self.async_io.async(runReload, .{job});
        self.job = job;
    }

    fn runReload(job: *ReloadJob) Outcome {
        defer job.completion.post();
        const bindings = dispatch.workerCall(job.io, UserKeybindings.load, .{ job.allocator, dispatch.backingIo(job.io), job.paths }) catch |err| return .{ .err = err };
        return .{ .bindings = bindings };
    }

    fn applyLoadedKeybindings(context: *anyopaque, _: i64, _: bool) bool {
        const self: *UserKeybindingsLoader = @ptrCast(@alignCast(context));
        const job = self.job orelse return false;
        const result = job.future.await(job.io);
        self.job = null;
        switch (result) {
            .bindings => |bindings| self.install(bindings),
            .err => {},
        }
        job.destroy();
        if (self.reload_pending) {
            self.reload_pending = false;
            self.requestReload();
        }
        return true;
    }

    pub fn cancelReload(self: *UserKeybindingsLoader) void {
        self.reload_timer.schedule(null);
        self.reload_pending = false;
        const job = self.job orelse return;
        self.job = null;
        const result = job.future.cancel(job.io);
        job.completion.schedule(null);
        if (result == .bindings) result.bindings.deinit();
        job.destroy();
    }

    pub fn destroy(self: *UserKeybindingsLoader) void {
        const allocator = self.allocator;
        self.cancelReload();
        self.unwatch();
        self.watchers.deinit(allocator);
        if (self.current) |bindings| bindings.deinit();
        freePaths(allocator, self.paths);
        self.on_did_change.deinit();
        allocator.destroy(self);
    }

    fn copyPaths(allocator: Allocator, paths: []const []const u8) ![]const []const u8 {
        const result = try allocator.alloc([]const u8, paths.len);
        errdefer allocator.free(result);
        var count: usize = 0;
        errdefer for (result[0..count]) |path| allocator.free(path);
        for (paths) |path| {
            result[count] = try allocator.dupe(u8, path);
            count += 1;
        }
        return result;
    }

    fn freePaths(allocator: Allocator, paths: []const []const u8) void {
        for (paths) |path| allocator.free(path);
        allocator.free(paths);
    }
};

test "UserKeybindings: reads later-layer overrides and removals" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTmp(&tmp, io, "vscode.json",
        \\[
        \\  { "key": "ctrl+alt+g", "command": "workbench.action.showCommands", "when": "editorTextFocus" },
        \\  { "command": "-workbench.action.toggleSidebarVisibility" }
        \\]
    );
    try writeTmp(&tmp, io, "tui.json",
        \\[
        \\  { "key": "g g", "command": "list.focusFirst", "when": "listFocus" }
        \\]
    );

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &buffer);
    const vscode_path = try std.fmt.allocPrint(allocator, "{s}/vscode.json", .{buffer[0..root_len]});
    defer allocator.free(vscode_path);
    const tui_path = try std.fmt.allocPrint(allocator, "{s}/tui.json", .{buffer[0..root_len]});
    defer allocator.free(tui_path);
    const missing_path = try std.fmt.allocPrint(allocator, "{s}/missing.json", .{buffer[0..root_len]});
    defer allocator.free(missing_path);

    const bindings = try UserKeybindings.load(allocator, io, &.{ vscode_path, tui_path, missing_path });
    defer bindings.deinit();
    try std.testing.expectEqual(@as(usize, 2), bindings.userItems().len);
    try std.testing.expectEqual(@as(usize, 1), bindings.removals().len);
    try std.testing.expectEqual(@as(usize, 0), bindings.error_count);

    const first = bindings.userItems()[0];
    try std.testing.expectEqualStrings("workbench.action.showCommands", first.command.?);
    try std.testing.expect(first.when != null);
    try std.testing.expect(!first.isDefault);
    const second = bindings.userItems()[1];
    try std.testing.expectEqualStrings("list.focusFirst", second.command.?);
    try std.testing.expectEqual(@as(usize, 2), second.chords.len);
    try std.testing.expectEqualStrings("-workbench.action.toggleSidebarVisibility", bindings.removals()[0].command.?);
}

fn writeTmp(tmp: *std.testing.TmpDir, io: Io, name: []const u8, contents: []const u8) !void {
    var file = try tmp.dir.createFile(io, name, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, contents);
}

test "UserKeybindings: unchanged raw keybindings do not emit a change event" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "keys.json", .data = "[{ \"key\": \"ctrl+j\", \"command\": \"one\" }]" });
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const path = try std.fs.path.join(allocator, &.{ root_buffer[0..root_len], "keys.json" });
    defer allocator.free(path);

    var window: dispatch.Queue = .{ .io = io };
    const loader = try UserKeybindingsLoader.create(allocator, io, io, &window);
    defer loader.destroy();
    var changes: usize = 0;
    const listener = try loader.on_did_change.listen(&changes, struct {
        fn changed(_: void, count: *usize) !void {
            count.* += 1;
        }
    }.changed);
    defer loader.on_did_change.unlisten(listener);
    try loader.setPaths(&.{path}, null);
    try std.testing.expectEqual(@as(usize, 1), changes);

    try tmp.dir.writeFile(io, .{ .sub_path = "keys.json", .data = "[{ \"command\": \"one\", \"key\": \"ctrl+j\" }]" });
    loader.reloadSync();
    try std.testing.expectEqual(@as(usize, 1), changes);

    try tmp.dir.writeFile(io, .{ .sub_path = "keys.json", .data = "[{ \"key\": \"ctrl+k\", \"command\": \"two\" }]" });
    loader.reloadSync();
    try std.testing.expectEqual(@as(usize, 2), changes);
    try std.testing.expectEqualStrings("two", loader.current.?.userItems()[0].command.?);
}
