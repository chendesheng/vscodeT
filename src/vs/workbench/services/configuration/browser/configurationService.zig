// Port of the workspace-aware configuration service in
// `src/vs/workbench/services/configuration/browser/configurationService.ts`.
//
// The terminal workbench has no profile, remote, policy, application or
// extension-host services, so this port resolves the scopes it can read:
// registered defaults, one user settings file, the workspace file's `settings`
// block, and each workspace folder's `.vscode/settings.json`. Folder settings
// override workspace settings, which override user settings, which override
// defaults. `getValue`/`inspect` expose the same precedence through
// `ConfigurationModel`.
//
// Settings files are read with VS Code's JSONC allowances (comments and
// trailing commas). The TUI settings watcher calls `reload` automatically when
// one of these files changes. `updateValue` (setting editing), language
// override identifiers (`[typescript]` blocks), policy/application/remote
// scopes and trusted-workspace filtering are not ported.
//
// Async terminal adaptation: `readSources` reads the raw settings files and is
// safe on a worker thread; `applySources` parses/merges/commits and fires
// `onDidChangeConfiguration` on the TUI thread. `SettingsWatcher` uses this
// split for file-watcher reloads, while startup and tests keep the synchronous
// `reload`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const configuration = @import("../../../../platform/configuration/common/configuration.zig");
const configurationModels = @import("../../../../platform/configuration/common/configurationModels.zig");
const registry_mod = @import("../../../../platform/configuration/common/configurationRegistry.zig");
const workspace_context = @import("../../workspaces/common/workspaceContextService.zig");
const event = @import("../../../../base/common/event.zig");

const ConfigurationModel = configurationModels.ConfigurationModel;
const ConfigurationRegistry = registry_mod.ConfigurationRegistry;
const WorkspaceContextService = workspace_context.WorkspaceContextService;
const Emitter = event.Emitter;

pub const max_settings_file_size: usize = 10 * 1024 * 1024;

pub const Value = configuration.Value;
pub const Overrides = configuration.Overrides;
pub const Change = configuration.Change;

pub const Options = struct {
    /// Absolute paths to the user settings files, in precedence order (later
    /// files override earlier ones). The first layer is typically the VS Code
    /// profile's `User/settings.json`, the last the terminal's own file. When
    /// empty only defaults and workspace/folder settings are read.
    user_settings_paths: []const []const u8 = &.{},
    /// Additional JSON default fragments registered by the composition root
    /// after the generic terminal defaults (later defaults win).
    defaults_json: []const []const u8 = &.{},
};

pub const ConfigurationService = struct {
    allocator: Allocator,
    io: Io,
    workspace: *WorkspaceContextService,
    /// Owned copies of `Options.user_settings_paths`.
    user_settings_paths: []const []u8,

    registry: *ConfigurationRegistry,
    defaults: ConfigurationModel,
    user: ConfigurationModel,
    workspace_model: ConfigurationModel,
    scratch: std.heap.ArenaAllocator,
    folders: std.StringHashMap(*ConfigurationModel),
    workspace_consolidated: ConfigurationModel,
    folder_consolidated: std.StringHashMap(*ConfigurationModel),

    change_emitter: Emitter(configuration.Change),
    /// When false, workspace/folder values for restricted settings are ignored.
    trusted: bool = true,

    pub fn init(
        allocator: Allocator,
        io: Io,
        workspace: *WorkspaceContextService,
        options: Options,
    ) !*ConfigurationService {
        const self = try allocator.create(ConfigurationService);
        errdefer allocator.destroy(self);

        const registry = try ConfigurationRegistry.init(allocator);
        errdefer registry.deinit();
        try registry.registerDefaultsJson(registry_mod.tui_defaults_json);
        for (options.defaults_json) |defaults| {
            try registry.registerDefaultsJson(defaults);
        }

        self.* = .{
            .allocator = allocator,
            .io = io,
            .workspace = workspace,
            .user_settings_paths = &.{},
            .registry = registry,
            .defaults = try ConfigurationModel.initEmpty(allocator),
            .user = try ConfigurationModel.initEmpty(allocator),
            .workspace_model = try ConfigurationModel.initEmpty(allocator),
            .scratch = std.heap.ArenaAllocator.init(allocator),
            .folders = std.StringHashMap(*ConfigurationModel).init(allocator),
            .workspace_consolidated = try ConfigurationModel.initEmpty(allocator),
            .folder_consolidated = std.StringHashMap(*ConfigurationModel).init(allocator),
            .change_emitter = Emitter(configuration.Change).init(allocator),
        };
        errdefer self.deinit();

        // Own the path list before the fallible load. The helper's errdefers
        // only cover the allocation itself; once committed, `deinit` owns it.
        self.user_settings_paths = try dupePaths(allocator, options.user_settings_paths);

        try self.load();
        return self;
    }

    pub fn deinit(self: *ConfigurationService) void {
        self.scratch.deinit();
        self.change_emitter.deinit();
        deinitFolderModels(self.allocator, &self.folder_consolidated);
        deinitFolderModels(self.allocator, &self.folders);
        self.workspace_consolidated.deinit();
        self.workspace_model.deinit();
        self.user.deinit();
        self.defaults.deinit();
        self.registry.deinit();
        freePaths(self.allocator, self.user_settings_paths);
        self.allocator.destroy(self);
    }

    /// Reloads every settings file and emits `onDidChangeConfiguration`.
    /// The terminal has no file watcher, so the host calls this explicitly.
    pub fn reload(self: *ConfigurationService) !void {
        try self.load();
    }

    /// Serializes the effective configuration scopes for the extension host's
    /// `$initializeConfiguration`/`$acceptConfigurationChanged` payload,
    /// mirroring `IConfigurationData` (`getConfigurationData` upstream).
    pub fn getConfigurationData(self: *ConfigurationService, arena: Allocator) !Value {
        var root: std.json.ObjectMap = .empty;
        try root.put(arena, "defaults", try modelJson(arena, &self.defaults));
        try root.put(arena, "policy", try emptyModelJson(arena));
        try root.put(arena, "application", try emptyModelJson(arena));
        try root.put(arena, "userLocal", try modelJson(arena, &self.user));
        try root.put(arena, "userRemote", try emptyModelJson(arena));
        try root.put(arena, "workspace", try modelJson(arena, &self.workspace_model));

        var folders = std.json.Array.init(arena);
        for (self.workspace.getWorkspace().folders.items) |folder| {
            const model = self.folder_consolidated.get(folder.resource) orelse continue;
            var pair = std.json.Array.init(arena);
            try pair.append(try fileUriJson(arena, folder.resource));
            try pair.append(try modelJson(arena, model));
            try folders.append(.{ .array = pair });
        }
        try root.put(arena, "folders", .{ .array = folders });
        try root.put(arena, "configurationScopes", .{ .array = std.json.Array.init(arena) });
        return .{ .object = root };
    }

    /// Updates workspace trust and reloads the effective configuration.
    pub fn updateWorkspaceTrust(self: *ConfigurationService, trusted: bool) !void {
        if (self.trusted == trusted) return;
        // Upstream reparses the cached workspace models and notifies the
        // restricted keys affected by the trust transition. This port keeps
        // the raw models and filters them when resolving values, so the
        // cached keys are sufficient; no disk reload is needed.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var changed_keys: std.StringArrayHashMapUnmanaged(void) = .empty;
        try self.collectTrustChangedKeys(arena.allocator(), &changed_keys, &self.user, false);
        try self.collectTrustChangedKeys(arena.allocator(), &changed_keys, &self.workspace_model, true);
        var folders = self.folders.valueIterator();
        while (folders.next()) |model| try self.collectTrustChangedKeys(arena.allocator(), &changed_keys, model.*, true);
        self.trusted = trusted;
        if (changed_keys.count() != 0) self.change_emitter.fire(.{ .source = .WORKSPACE, .keys = changed_keys.keys() }) catch {};
    }

    fn collectTrustChangedKeys(self: *ConfigurationService, allocator: Allocator, changed_keys: *std.StringArrayHashMapUnmanaged(void), model: *const ConfigurationModel, workspace_scope: bool) !void {
        for (model.getKeys()) |key| try self.collectTrustChangedKey(allocator, changed_keys, key, workspace_scope);
        for (model.overrides) |override| {
            for (override.keys) |key| try self.collectTrustChangedKey(allocator, changed_keys, key, workspace_scope);
        }
    }

    fn collectTrustChangedKey(self: *ConfigurationService, allocator: Allocator, changed_keys: *std.StringArrayHashMapUnmanaged(void), key: []const u8, workspace_scope: bool) !void {
        const property = self.registry.getConfigurationProperties().get(key);
        if (if (property) |registered| registered.restricted else workspace_scope)
            try changed_keys.put(allocator, try allocator.dupe(u8, key), {});
    }

    pub fn onDidChangeConfiguration(
        self: *ConfigurationService,
        ctx: anytype,
        callback: fn (change: configuration.Change, ctx: @TypeOf(ctx)) anyerror!void,
    ) !void {
        _ = try self.change_emitter.listen(ctx, callback);
    }

    /// ID-returning form of `onDidChangeConfiguration`, matching upstream's
    /// `IDisposable` subscription. Callers that outlive the listener use this
    /// so the subscription can be removed.
    pub fn listenConfigurationChange(
        self: *ConfigurationService,
        ctx: anytype,
        callback: fn (change: configuration.Change, ctx: @TypeOf(ctx)) anyerror!void,
    ) !usize {
        return self.change_emitter.listen(ctx, callback);
    }

    pub fn unlistenConfigurationChange(self: *ConfigurationService, id: usize) void {
        self.change_emitter.unlisten(id);
    }

    /// Reads all scopes into temporary models first, so a failed read leaves
    /// the previously loaded configuration intact.
    fn load(self: *ConfigurationService) !void {
        var sources = try self.readSources(self.allocator, self.io);
        defer sources.deinit();
        try self.applySources(&sources);
    }

    /// Raw settings-file contents, read on the async Io by the watcher. The
    /// parsing/merge/commit stays on the TUI thread so `onDidChangeConfiguration`
    /// and the model swap happen on the event loop, matching upstream's
    /// `fileService.readFile` + configuration-cache flow.
    pub const FolderSettings = struct {
        text: ?[]u8,
    };

    pub const Sources = struct {
        allocator: Allocator,
        user: []?[]u8,
        workspace: ?[]u8,
        folders: []FolderSettings,

        pub fn deinit(self: *Sources) void {
            for (self.user) |maybe_text| {
                if (maybe_text) |text| self.allocator.free(text);
            }
            self.allocator.free(self.user);
            if (self.workspace) |text| self.allocator.free(text);
            for (self.folders) |folder| {
                if (folder.text) |text| self.allocator.free(text);
            }
            self.allocator.free(self.folders);
            self.* = undefined;
        }
    };

    /// Reads the user, workspace and folder settings files. Safe to run on a
    /// worker thread: it allocates with `allocator` and touches no model state.
    pub fn readSources(self: *const ConfigurationService, allocator: Allocator, io: Io) !Sources {
        const user = try allocator.alloc(?[]u8, self.user_settings_paths.len);
        @memset(user, null);
        errdefer {
            for (user) |maybe_text| if (maybe_text) |text| allocator.free(text);
            allocator.free(user);
        }
        for (self.user_settings_paths, 0..) |path, index| {
            user[index] = try readSettingsFileOpt(allocator, io, path);
        }

        const workspace_path = self.workspace.getWorkspace().configuration;
        const workspace_text: ?[]u8 = if (workspace_path) |path|
            try readSettingsFileOpt(allocator, io, path)
        else
            null;
        errdefer if (workspace_text) |text| allocator.free(text);

        const workspace_folders = self.workspace.getWorkspace().folders.items;
        const folders = try allocator.alloc(FolderSettings, workspace_folders.len);
        var initialized: usize = 0;
        errdefer {
            for (folders[0..initialized]) |folder| {
                if (folder.text) |text| allocator.free(text);
            }
            allocator.free(folders);
        }
        for (workspace_folders, 0..) |folder, index| {
            const path = try std.fs.path.join(allocator, &.{ folder.resource, ".vscode", "settings.json" });
            defer allocator.free(path);
            folders[index] = .{
                .text = try readSettingsFileOpt(allocator, io, path),
            };
            initialized += 1;
        }

        return .{ .allocator = allocator, .user = user, .workspace = workspace_text, .folders = folders };
    }

    /// Parses the already-read sources and commits the new effective models on
    /// the TUI thread. The sources remain owned by the caller.
    pub fn applySources(self: *ConfigurationService, sources: *const Sources) !void {
        var new_defaults = try self.registry.buildDefaultModel(self.allocator);
        errdefer new_defaults.deinit();
        var new_user = try self.userModelFromSources(sources);
        errdefer new_user.deinit();
        var new_workspace = try self.workspaceModelFromText(sources.workspace);
        errdefer new_workspace.deinit();

        var new_folders = std.StringHashMap(*ConfigurationModel).init(self.allocator);
        errdefer deinitFolderModels(self.allocator, &new_folders);
        const workspace_folders = self.workspace.getWorkspace().folders.items;
        for (workspace_folders, 0..) |folder, index| {
            if (index >= sources.folders.len) break;
            const model = try self.allocator.create(ConfigurationModel);
            errdefer self.allocator.destroy(model);
            model.* = if (sources.folders[index].text) |text|
                try ConfigurationModel.fromJson(self.allocator, text)
            else
                try ConfigurationModel.initEmpty(self.allocator);
            errdefer model.deinit();
            try new_folders.put(folder.resource, model);
        }

        var new_workspace_consolidated = try mergeModels(
            self.allocator,
            &.{ &new_defaults, &new_user, &new_workspace },
        );
        errdefer new_workspace_consolidated.deinit();

        var new_folder_consolidated = std.StringHashMap(*ConfigurationModel).init(self.allocator);
        errdefer deinitFolderModels(self.allocator, &new_folder_consolidated);
        var folder_iterator = new_folders.iterator();
        while (folder_iterator.next()) |entry| {
            const consolidated = try self.allocator.create(ConfigurationModel);
            errdefer self.allocator.destroy(consolidated);
            consolidated.* = try mergeModels(
                self.allocator,
                &.{ &new_defaults, &new_user, &new_workspace, entry.value_ptr.* },
            );
            errdefer consolidated.deinit();
            try new_folder_consolidated.put(entry.key_ptr.*, consolidated);
        }

        // Compare the old and new scopes before releasing their arenas. Like
        // upstream's compareAndUpdate*Configuration, removed settings and
        // override changes count, but unchanged settings do not.
        var change_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer change_arena.deinit();
        var change = configurationModels.ConfigurationChange.init(change_arena.allocator());
        try change.compare(&self.defaults, &new_defaults);
        try change.compare(&self.user, &new_user);
        try change.compare(&self.workspace_model, &new_workspace);
        var previous_folders = self.folders.iterator();
        while (previous_folders.next()) |entry| {
            try change.compare(entry.value_ptr.*, new_folders.get(entry.key_ptr.*));
        }
        var current_folders = new_folders.iterator();
        while (current_folders.next()) |entry| {
            if (!self.folders.contains(entry.key_ptr.*)) try change.compare(null, entry.value_ptr.*);
        }

        // Commit. No fallible operations follow, so the errdefers above do not
        // run after the old models are released.
        self.defaults.deinit();
        self.defaults = new_defaults;
        self.user.deinit();
        self.user = new_user;
        self.workspace_model.deinit();
        self.workspace_model = new_workspace;

        deinitFolderModels(self.allocator, &self.folders);
        self.folders = new_folders;
        deinitFolderModels(self.allocator, &self.folder_consolidated);
        self.folder_consolidated = new_folder_consolidated;
        self.workspace_consolidated.deinit();
        self.workspace_consolidated = new_workspace_consolidated;

        // A native file-watcher reload reads all scopes in a single batch.
        // Preserve its single notification, with the merged affected keys.
        if (change.keys.items.len != 0 or change.overrides.items.len != 0)
            self.change_emitter.fire(change.event(.USER)) catch {};
    }

    fn userModelFromSources(self: *ConfigurationService, sources: *const Sources) !ConfigurationModel {
        if (sources.user.len == 0) return ConfigurationModel.initEmpty(self.allocator);
        if (sources.user.len == 1) {
            return if (sources.user[0]) |text|
                ConfigurationModel.fromJson(self.allocator, text)
            else
                ConfigurationModel.initEmpty(self.allocator);
        }

        var models = std.array_list.Managed(*ConfigurationModel).init(self.allocator);
        defer models.deinit();
        defer {
            for (models.items) |model| {
                model.deinit();
                self.allocator.destroy(model);
            }
        }
        for (sources.user) |maybe_text| {
            const text = maybe_text orelse continue;
            const model = try self.allocator.create(ConfigurationModel);
            errdefer self.allocator.destroy(model);
            model.* = try ConfigurationModel.fromJson(self.allocator, text);
            try models.append(model);
        }
        if (models.items.len == 0) return ConfigurationModel.initEmpty(self.allocator);
        const pointers = try self.allocator.alloc(*const ConfigurationModel, models.items.len);
        defer self.allocator.free(pointers);
        for (models.items, 0..) |model, index| pointers[index] = model;
        return ConfigurationModel.merge(self.allocator, pointers);
    }

    fn workspaceModelFromText(self: *ConfigurationService, text: ?[]const u8) !ConfigurationModel {
        const content = text orelse return ConfigurationModel.initEmpty(self.allocator);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const sanitized = try configurationModels.stripJsonc(arena.allocator(), content);
        const raw = std.json.parseFromSliceLeaky(Value, arena.allocator(), sanitized, .{
            .duplicate_field_behavior = .use_last,
        }) catch return ConfigurationModel.initEmpty(self.allocator);
        if (raw != .object) return ConfigurationModel.initEmpty(self.allocator);
        const settings = raw.object.get("settings") orelse
            return ConfigurationModel.initEmpty(self.allocator);
        return ConfigurationModel.fromValue(self.allocator, settings);
    }

    pub fn interface(self: *ConfigurationService) configuration.IConfigurationService {
        return .{ .context = self, .get_value = getValueForInterface, .get_value_with_overrides = getValueWithOverridesForInterface, .update_value = updateValueForInterface, .on_did_change_configuration = &self.change_emitter };
    }

    fn updateValueForInterface(context: *anyopaque, key: []const u8, value: ?Value, target: configuration.ConfigurationTarget) !void {
        const self: *ConfigurationService = @ptrCast(@alignCast(context));
        try self.updateValue(key, value, target);
    }

    fn getValueForInterface(context: *anyopaque, key: []const u8) ?*const Value {
        const self: *ConfigurationService = @ptrCast(@alignCast(context));
        return self.getValue(key, .{});
    }

    fn getValueWithOverridesForInterface(context: *anyopaque, key: []const u8, overrides: configuration.Overrides) ?*const Value {
        const self: *ConfigurationService = @ptrCast(@alignCast(context));
        return self.getValue(key, overrides);
    }

    /// Returns the effective value for `section`, or a folder-specific value
    /// when `overrides.resource` names a workspace folder. The pointer is owned
    /// by the service and stays valid until the next reload.
    pub fn getValue(
        self: *ConfigurationService,
        section: []const u8,
        overrides: configuration.Overrides,
    ) ?*const Value {
        const property = self.registry.getConfigurationProperties().get(section);
        const ignore_workspace = if (property) |registered| !self.allowsWorkspaceValue(registered) else !self.trusted;
        if (ignore_workspace) {
            _ = self.scratch.reset(.retain_capacity);
            var merged = mergeModels(self.scratch.allocator(), &.{ &self.defaults, &self.user }) catch return null;
            if (overrides.override_identifier) |identifier| {
                var overridden = merged.override(self.scratch.allocator(), identifier) catch return null;
                if (overridden.getValue(section)) |value| return value;
                return if (property) |registered| &registered.default else null;
            }
            if (merged.getValue(section)) |value| return value;
            return if (property) |registered| &registered.default else null;
        }
        const model = self.effectiveModel(overrides) orelse return null;
        if (overrides.override_identifier) |identifier| {
            _ = self.scratch.reset(.retain_capacity);
            var overridden = model.override(self.scratch.allocator(), identifier) catch return null;
            return overridden.getValue(section);
        }
        return model.getValue(section);
    }

    /// Convenience for boolean settings such as `explorer.excludeGitIgnore`.
    pub fn getBool(self: *ConfigurationService, section: []const u8, default: bool) bool {
        const value = self.getValue(section, .{}) orelse return default;
        return switch (value.*) {
            .bool => |inner| inner,
            else => default,
        };
    }

    pub fn inspect(
        self: *ConfigurationService,
        section: []const u8,
        overrides: configuration.Overrides,
    ) configuration.ConfigurationValue {
        const folder_model = self.folderModel(overrides.resource);
        const effective = self.effectiveModel(overrides) orelse &self.workspace_consolidated;
        var value = effective.getValue(section);
        var override_identifiers: []const []const u8 = &.{};
        var allow_workspace = true;
        if (self.registry.getConfigurationProperties().get(section)) |property| {
            allow_workspace = self.allowsWorkspaceValue(property);
        } else if (!self.trusted) {
            allow_workspace = false;
        }
        if (!allow_workspace) {
            _ = self.scratch.reset(.retain_capacity);
            var merged = mergeModels(self.scratch.allocator(), &.{ &self.defaults, &self.user }) catch return .{};
            if (overrides.override_identifier) |identifier| {
                const overridden = merged.override(self.scratch.allocator(), identifier) catch null;
                value = if (overridden) |model| model.getValue(section) else merged.getValue(section);
            } else {
                value = merged.getValue(section);
            }
        } else if (overrides.override_identifier) |identifier| {
            _ = self.scratch.reset(.retain_capacity);
            const overridden = effective.override(self.scratch.allocator(), identifier) catch null;
            if (overridden) |model| value = model.getValue(section);
        }
        if (overrides.override_identifier) |identifier| {
            const ids = self.scratch.allocator().alloc([]const u8, 1) catch null;
            if (ids) |slice| {
                slice[0] = identifier;
                override_identifiers = slice;
            }
        }
        return .{
            .default = self.defaults.getValue(section),
            .user = self.user.getValue(section),
            .workspace = if (allow_workspace) self.workspace_model.getValue(section) else null,
            .workspace_folder = if (allow_workspace) (if (folder_model) |model| model.getValue(section) else null) else null,
            .value = value,
            .override_identifiers = override_identifiers,
        };
    }

    fn allowsWorkspaceValue(self: *ConfigurationService, property: registry_mod.Property) bool {
        if (property.restricted and !self.trusted) return false;
        return switch (property.scope) {
            .APPLICATION, .MACHINE, .APPLICATION_MACHINE, .MACHINE_OVERRIDABLE => false,
            else => true,
        };
    }

    /// Returns the settings files this service reads. The watcher uses the
    /// same list so both always agree on the watched scopes. The caller owns
    /// the paths and the outer slice.
    /// Writes a user setting to the highest-precedence user settings file and
    /// reloads the effective model. JSONC comments are not preserved when the
    /// file has to be rewritten; the terminal keeps the parsed value tree.
    pub fn updateValue(self: *ConfigurationService, key: []const u8, value: ?std.json.Value, target: configuration.ConfigurationTarget) !void {
        if (target != .USER) return error.UnsupportedConfigurationTarget;
        if (self.user_settings_paths.len == 0) return error.NoWritableUserSettings;
        const path = self.user_settings_paths[self.user_settings_paths.len - 1];

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();
        var root: std.json.Value = .{ .object = .{} };
        if (Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(max_settings_file_size))) |bytes| {
            defer self.allocator.free(bytes);
            var sanitized = std.array_list.Managed(u8).init(arena_allocator);
            try sanitized.appendSlice(try configurationModels.stripJsonc(arena_allocator, bytes));
            if (std.json.parseFromSliceLeaky(std.json.Value, arena_allocator, sanitized.items, .{})) |parsed| {
                if (std.meta.activeTag(parsed) == .object) root = parsed;
            } else |_| {}
        } else |_| {}

        if (value == null or std.meta.activeTag(value.?) == .null) {
            _ = root.object.orderedRemove(key);
        } else {
            try root.object.put(arena_allocator, key, value.?);
        }

        if (std.fs.path.dirname(path)) |dir| Io.Dir.cwd().createDirPath(self.io, dir) catch {};
        var out: Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        try std.json.Stringify.value(root, .{}, &out.writer);
        try out.writer.writeByte('\n');
        try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = out.written() });
        try self.reload();
    }

    pub fn settingsFilePaths(self: *const ConfigurationService, allocator: Allocator) ![]const []u8 {
        var paths = std.array_list.Managed([]u8).init(allocator);
        errdefer {
            for (paths.items) |path| allocator.free(path);
            paths.deinit();
        }

        for (self.user_settings_paths) |path| {
            try paths.append(try allocator.dupe(u8, path));
        }
        if (self.workspace.getWorkspace().configuration) |path| {
            try paths.append(try allocator.dupe(u8, path));
        }
        for (self.workspace.getWorkspace().folders.items) |folder| {
            const path = try std.fs.path.join(allocator, &.{ folder.resource, ".vscode", "settings.json" });
            try paths.append(path);
        }
        return try paths.toOwnedSlice();
    }

    pub fn freeSettingsFilePaths(self: *const ConfigurationService, allocator: Allocator, paths: []const []u8) void {
        _ = self;
        for (paths) |path| allocator.free(path);
        allocator.free(paths);
    }

    fn dupePaths(allocator: Allocator, paths: []const []const u8) ![]const []u8 {
        const copies = try allocator.alloc([]u8, paths.len);
        errdefer allocator.free(copies);
        var initialized: usize = 0;
        errdefer {
            for (copies[0..initialized]) |path| allocator.free(path);
        }
        for (paths, 0..) |path, index| {
            copies[index] = try allocator.dupe(u8, path);
            initialized += 1;
        }
        return copies;
    }

    fn freePaths(allocator: Allocator, paths: []const []u8) void {
        for (paths) |path| allocator.free(path);
        if (paths.len > 0) allocator.free(paths);
    }

    pub fn keys(self: *const ConfigurationService) configuration.Keys {
        return .{
            .default = self.defaults.getKeys(),
            .user = self.user.getKeys(),
            .workspace = self.workspace_model.getKeys(),
            .workspace_folder = &.{},
        };
    }

    fn effectiveModel(self: *const ConfigurationService, overrides: configuration.Overrides) ?*const ConfigurationModel {
        if (self.folderConsolidated(overrides.resource)) |model| return model;
        return &self.workspace_consolidated;
    }

    fn folderModel(self: *const ConfigurationService, resource: ?[]const u8) ?*const ConfigurationModel {
        const path = resource orelse return null;
        const folder = self.workspace.getWorkspaceFolder(path) orelse return null;
        return self.folders.get(folder.resource);
    }

    fn folderConsolidated(self: *const ConfigurationService, resource: ?[]const u8) ?*const ConfigurationModel {
        const path = resource orelse return null;
        const folder = self.workspace.getWorkspaceFolder(path) orelse return null;
        return self.folder_consolidated.get(folder.resource);
    }

    /// Merges every user layer in precedence order (later files win). A
    /// missing or unparsable file behaves like an empty layer, exactly like a
    /// single user settings file did before the VS Code profile was added.
    fn readUserModel(self: *ConfigurationService) !ConfigurationModel {
        if (self.user_settings_paths.len == 0) {
            return ConfigurationModel.initEmpty(self.allocator);
        }
        if (self.user_settings_paths.len == 1) {
            return self.readModel(self.user_settings_paths[0]);
        }

        var models = std.array_list.Managed(*ConfigurationModel).init(self.allocator);
        defer models.deinit();
        defer {
            for (models.items) |model| {
                model.deinit();
                self.allocator.destroy(model);
            }
        }
        for (self.user_settings_paths) |path| {
            const model = try self.allocator.create(ConfigurationModel);
            errdefer self.allocator.destroy(model);
            model.* = try self.readModel(path);
            try models.append(model);
        }

        const pointers = try self.allocator.alloc(*const ConfigurationModel, models.items.len);
        defer self.allocator.free(pointers);
        for (models.items, 0..) |model, index| pointers[index] = model;
        return ConfigurationModel.merge(self.allocator, pointers);
    }

    fn readModel(self: *ConfigurationService, path: ?[]const u8) !ConfigurationModel {
        const value = path orelse return ConfigurationModel.initEmpty(self.allocator);
        const text = (try self.readSettingsFile(value)) orelse return ConfigurationModel.initEmpty(self.allocator);
        defer self.allocator.free(text);
        return ConfigurationModel.fromJson(self.allocator, text);
    }

    fn readWorkspaceModel(self: *ConfigurationService) !ConfigurationModel {
        const path = self.workspace.getWorkspace().configuration orelse
            return ConfigurationModel.initEmpty(self.allocator);
        const text = (try self.readSettingsFile(path)) orelse
            return ConfigurationModel.initEmpty(self.allocator);
        defer self.allocator.free(text);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const sanitized = try configurationModels.stripJsonc(arena.allocator(), text);
        const raw = std.json.parseFromSliceLeaky(Value, arena.allocator(), sanitized, .{
            .duplicate_field_behavior = .use_last,
        }) catch return ConfigurationModel.initEmpty(self.allocator);
        if (raw != .object) return ConfigurationModel.initEmpty(self.allocator);
        const settings = raw.object.get("settings") orelse
            return ConfigurationModel.initEmpty(self.allocator);
        return ConfigurationModel.fromValue(self.allocator, settings);
    }

    fn readFolderModel(self: *ConfigurationService, folder: []const u8) !ConfigurationModel {
        const path = try std.fs.path.join(self.allocator, &.{ folder, ".vscode", "settings.json" });
        defer self.allocator.free(path);
        const text = (try self.readSettingsFile(path)) orelse
            return ConfigurationModel.initEmpty(self.allocator);
        defer self.allocator.free(text);
        return ConfigurationModel.fromJson(self.allocator, text);
    }

    fn readSettingsFile(self: *ConfigurationService, path: []const u8) !?[]u8 {
        return readSettingsFileOpt(self.allocator, self.io, path);
    }
};

/// The terminal can replace the workspace/profile settings source while a
/// window is open. Keep the IConfigurationService identity and event stable
/// for contributed commands and context consumers, as in VS Code.
pub const ConfigurationServiceBinding = struct {
    service: ?*ConfigurationService = null,
    listener: ?event.SignalSubscription = null,
    on_did_change_configuration: Emitter(configuration.Change),

    pub fn init(allocator: Allocator) ConfigurationServiceBinding {
        return .{ .on_did_change_configuration = .init(allocator) };
    }

    pub fn deinit(self: *ConfigurationServiceBinding) void {
        if (self.listener) |listener| listener.dispose();
        self.on_did_change_configuration.deinit();
    }

    pub fn bind(self: *ConfigurationServiceBinding, service: ?*ConfigurationService) !void {
        if (self.service == service) return;
        if (self.listener) |listener| listener.dispose();
        self.listener = null;
        self.service = service;
        if (service) |current| self.listener = try current.change_emitter.listenDisposable(self, forwardChange);
        // Replacing the full settings model invalidates config context values
        // the same way an upstream default-configuration reset does.
        self.on_did_change_configuration.fire(.{ .source = .DEFAULT, .keys = &.{} }) catch {};
    }

    pub fn interface(self: *ConfigurationServiceBinding) configuration.IConfigurationService {
        return .{ .context = self, .get_value = getValue, .get_value_with_overrides = getValueWithOverrides, .update_value = updateValue, .on_did_change_configuration = &self.on_did_change_configuration };
    }

    fn getValue(context: *anyopaque, key: []const u8) ?*const Value {
        const self: *ConfigurationServiceBinding = @ptrCast(@alignCast(context));
        const service = self.service orelse return null;
        return service.getValue(key, .{});
    }

    fn getValueWithOverrides(context: *anyopaque, key: []const u8, overrides: configuration.Overrides) ?*const Value {
        const self: *ConfigurationServiceBinding = @ptrCast(@alignCast(context));
        const service = self.service orelse return null;
        return service.getValue(key, overrides);
    }

    fn updateValue(context: *anyopaque, key: []const u8, value: ?Value, target: configuration.ConfigurationTarget) !void {
        const self: *ConfigurationServiceBinding = @ptrCast(@alignCast(context));
        const service = self.service orelse return error.ConfigurationUnavailable;
        try service.updateValue(key, value, target);
    }

    fn forwardChange(change: configuration.Change, self: *ConfigurationServiceBinding) !void {
        try self.on_did_change_configuration.fire(change);
    }
};

fn emptyModelJson(arena: Allocator) !Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(arena, "contents", .{ .object = .empty });
    try object.put(arena, "keys", .{ .array = std.json.Array.init(arena) });
    try object.put(arena, "overrides", .{ .array = std.json.Array.init(arena) });
    return .{ .object = object };
}

fn modelJson(arena: Allocator, model: *const ConfigurationModel) !Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(arena, "contents", try configuration.cloneValue(arena, model.contents));

    var keys = std.json.Array.init(arena);
    for (model.getKeys()) |key| try keys.append(.{ .string = try arena.dupe(u8, key) });
    try object.put(arena, "keys", .{ .array = keys });

    var overrides = std.json.Array.init(arena);
    for (model.overrides) |override| {
        var entry: std.json.ObjectMap = .empty;
        var identifiers = std.json.Array.init(arena);
        for (override.identifiers) |identifier| try identifiers.append(.{ .string = try arena.dupe(u8, identifier) });
        try entry.put(arena, "identifiers", .{ .array = identifiers });
        var override_keys = std.json.Array.init(arena);
        for (override.keys) |key| try override_keys.append(.{ .string = try arena.dupe(u8, key) });
        try entry.put(arena, "keys", .{ .array = override_keys });
        try entry.put(arena, "contents", try configuration.cloneValue(arena, override.contents));
        try overrides.append(.{ .object = entry });
    }
    try object.put(arena, "overrides", .{ .array = overrides });
    return .{ .object = object };
}

fn fileUriJson(arena: Allocator, path: []const u8) !Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(arena, "$mid", .{ .integer = 1 });
    try object.put(arena, "scheme", .{ .string = "file" });
    try object.put(arena, "authority", .{ .string = "" });
    try object.put(arena, "path", .{ .string = try arena.dupe(u8, path) });
    try object.put(arena, "query", .{ .string = "" });
    try object.put(arena, "fragment", .{ .string = "" });
    return .{ .object = object };
}

fn mergeModels(
    allocator: Allocator,
    models: []const *const ConfigurationModel,
) !ConfigurationModel {
    return ConfigurationModel.merge(allocator, models);
}

fn deinitFolderModels(
    allocator: Allocator,
    map: *std.StringHashMap(*ConfigurationModel),
) void {
    var iterator = map.valueIterator();
    while (iterator.next()) |model| {
        model.*.deinit();
        allocator.destroy(model.*);
    }
    map.deinit();
}

// ---------------------------------------------------------------------------
// Settings-file watcher
//
// Terminal host for the watcher wiring that upstream keeps in the browser
// `ConfigurationService` (a file-service change event triggers
// `reloadConfiguration`). Subscribe to changes from the shared file service,
// debounce changes affecting configured resources, and apply completed reads on the window.
// ---------------------------------------------------------------------------

const files = @import("../../../../platform/files/common/files.zig");
const watch_service = @import("../../../../platform/files/node/watcher/fileWatcherService.zig");
const dispatch = @import("../../../../base/common/windowDispatch.zig");
const FileChange = files.FileChange;

pub const ReloadCallback = struct {
    context: *anyopaque,
    callback: *const fn (context: *anyopaque) void,
};

/// Reads one settings file. Missing/unreadable files are treated as absent;
/// only allocation failures escape, matching the synchronous readers above.
fn readSettingsFileOpt(allocator: Allocator, io: Io, path: []const u8) !?[]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_settings_file_size)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
}

const AsyncReloadResult = union(enum) {
    sources: ConfigurationService.Sources,
    err: anyerror,
};

const AsyncReloadJob = struct {
    watcher: *SettingsWatcher,
    future: Io.Future(AsyncReloadResult),

    io: Io,

    fn deinit(self: *AsyncReloadJob, allocator: Allocator) void {
        allocator.destroy(self);
    }
};

fn runAsyncReload(job: *AsyncReloadJob) AsyncReloadResult {
    defer job.watcher.reload_ready.post();
    const service = job.watcher.configuration_service;
    return .{ .sources = service.readSources(job.watcher.allocator, job.io) catch |err| return .{ .err = err } };
}

pub const SettingsWatcher = struct {
    allocator: Allocator,
    io: Io,
    configuration_service: *ConfigurationService,
    service: *watch_service.FileWatcherService,
    subscriptions: std.ArrayList(*watch_service.WatchHandle) = .empty,
    change_listener: usize,
    reload_timer: dispatch.Task,
    reload_ready: dispatch.Task,
    on_reload: ?ReloadCallback = null,
    reload_count: usize = 0,
    last_reload_failed: bool = false,
    /// When set, settings files are read on this Io and the models are applied
    /// on the window thread when the read completes. Null keeps the synchronous test/startup
    /// path.
    async_io: ?Io = null,
    reload_job: ?*AsyncReloadJob = null,
    reload_pending: bool = false,

    pub fn init(
        allocator: Allocator,
        io: Io,
        configuration_service: *ConfigurationService,
        service: *watch_service.FileWatcherService,
        window: *dispatch.Queue,
    ) !*SettingsWatcher {
        const self = try allocator.create(SettingsWatcher);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .configuration_service = configuration_service,
            .service = service,
            .change_listener = try service.on_did_change.listen(self, onFileChanges),
            .reload_timer = .{ .queue = window, .context = self, .run = reload },
            .reload_ready = .{ .queue = window, .context = self, .run = finishReload, .progress = true },
        };
        errdefer service.on_did_change.unlisten(self.change_listener);
        try self.setExtraPaths(&.{});
        return self;
    }

    pub fn deinit(self: *SettingsWatcher) void {
        self.service.on_did_change.unlisten(self.change_listener);
        self.reload_timer.schedule(null);
        self.cancelReload();
        self.disposeSubscriptions(&self.subscriptions);
        self.allocator.destroy(self);
    }

    fn disposeSubscriptions(self: *SettingsWatcher, subscriptions: *std.ArrayList(*watch_service.WatchHandle)) void {
        for (subscriptions.items) |handle| handle.dispose();
        subscriptions.deinit(self.allocator);
    }

    pub fn setExtraPaths(self: *SettingsWatcher, paths: []const []const u8) !void {
        const settings = try self.configuration_service.settingsFilePaths(self.allocator);
        defer self.configuration_service.freeSettingsFilePaths(self.allocator, settings);
        var next: std.ArrayList(*watch_service.WatchHandle) = .empty;
        errdefer self.disposeSubscriptions(&next);
        try next.ensureTotalCapacity(self.allocator, settings.len + paths.len);
        for (settings) |path| next.appendAssumeCapacity(try self.service.watch(path, .{ .recursive = false }));
        for (paths) |path| next.appendAssumeCapacity(try self.service.watch(path, .{ .recursive = false }));
        self.disposeSubscriptions(&self.subscriptions);
        self.subscriptions = next;
    }

    pub fn setAsyncIo(self: *SettingsWatcher, io: Io) void {
        self.async_io = io;
    }

    pub fn setOnReload(self: *SettingsWatcher, callback: ?ReloadCallback) void {
        self.on_reload = callback;
    }

    fn requestAsyncReload(self: *SettingsWatcher) void {
        const async_io = self.async_io orelse return;
        if (self.reload_job != null) {
            self.reload_pending = true;
            return;
        }
        const job = self.allocator.create(AsyncReloadJob) catch return;
        job.* = .{
            .watcher = self,
            .future = undefined,
            .io = async_io,
        };
        job.future = async_io.async(runAsyncReload, .{job});
        self.reload_job = job;
    }

    fn finishReload(ctx: *anyopaque, _: i64, _: bool) bool {
        const self: *SettingsWatcher = @ptrCast(@alignCast(ctx));
        const job = self.reload_job orelse return false;
        const result = job.future.await(job.io);
        self.reload_job = null;
        job.deinit(self.allocator);
        defer if (self.reload_pending) {
            self.reload_pending = false;
            self.requestAsyncReload();
        };
        switch (result) {
            .sources => |sources_value| {
                var sources = sources_value;
                defer sources.deinit();
                self.configuration_service.applySources(&sources) catch {
                    self.last_reload_failed = true;
                    return true;
                };
                self.last_reload_failed = false;
                self.reload_count += 1;
                if (self.on_reload) |callback| callback.callback(callback.context);
            },
            .err => self.last_reload_failed = true,
        }
        return true;
    }

    pub fn cancelReload(self: *SettingsWatcher) void {
        self.reload_pending = false;
        const job = self.reload_job orelse return;
        self.reload_job = null;
        const result = job.future.cancel(job.io);
        self.reload_ready.schedule(null);
        if (result == .sources) {
            var sources = result.sources;
            sources.deinit();
        }
        job.deinit(self.allocator);
    }

    fn onFileChanges(changes: []const FileChange, self: *SettingsWatcher) !void {
        var file_changes = try files.FileChangesEvent.init(self.allocator, changes, @import("builtin").os.tag == .windows);
        defer file_changes.deinit();
        for (self.subscriptions.items) |handle| {
            if (file_changes.contains(handle.path, &.{})) {
                self.reload_timer.schedule(@import("../../../../base/common/timeCompat.zig").milliTimestamp() + 100);
                return;
            }
        }
    }

    fn reload(ctx: *anyopaque, _: i64, _: bool) bool {
        const self: *SettingsWatcher = @ptrCast(@alignCast(ctx));
        if (self.async_io != null) {
            self.requestAsyncReload();
            return false;
        }
        self.configuration_service.reload() catch {
            self.last_reload_failed = true;
            return true;
        };
        self.last_reload_failed = false;
        self.reload_count += 1;
        if (self.on_reload) |callback| callback.callback(callback.context);
        return true;
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

    const context = try @import("../../workspaces/common/workspaceContextService.zig").WorkspaceContextService.initWithFolders(
        allocator,
        "test",
        &.{root},
    );
    defer context.deinit();
    const service = try ConfigurationService.init(allocator, io, context, .{});
    defer service.deinit();

    var window = dispatch.Queue{ .io = std.testing.io };
    const file_service = try watch_service.FileWatcherService.init(allocator, io);
    defer file_service.deinit();
    file_service.client.attachWindow(&window);
    const watcher = try SettingsWatcher.init(allocator, io, service, file_service, &window);
    defer watcher.deinit();

    const ready_by = std.Io.Timestamp.now(io, .real).toMilliseconds() + 3000;
    while (!file_service.isReady() and std.Io.Timestamp.now(io, .real).toMilliseconds() < ready_by)
        io.sleep(.fromMilliseconds(5), .awake) catch {};
    try std.testing.expect(file_service.isReady());
    var file_write = try tmp.dir.createFile(io, ".vscode/settings.json", .{ .truncate = true });
    try file_write.writeStreamingAll(io, "{\"editor.tabSize\": 6}");
    file_write.close(io);

    const deadline = std.Io.Timestamp.now(io, .real).toMilliseconds() + 3000;
    while (std.Io.Timestamp.now(io, .real).toMilliseconds() < deadline and watcher.reload_count == 0) {
        _ = window.dispatch(std.Io.Timestamp.now(io, .real).toMilliseconds());
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(watcher.reload_count > 0);
    try std.testing.expectEqual(@as(i64, 6), service.getValue("editor.tabSize", .{ .resource = settings_path }).?.integer);
}
