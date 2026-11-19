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
    /// Absolute path to the user settings file. When null only defaults and
    /// workspace/folder settings are read.
    user_settings_path: ?[]const u8 = null,
    /// Additional JSON default fragments registered by the composition root
    /// after the generic terminal defaults (later defaults win).
    defaults_json: []const []const u8 = &.{},
};

pub const ConfigurationService = struct {
    allocator: Allocator,
    io: Io,
    workspace: *WorkspaceContextService,
    user_settings_path: ?[]u8,

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

        const user_settings_path = if (options.user_settings_path) |path|
            try allocator.dupe(u8, path)
        else
            null;
        errdefer if (user_settings_path) |path| allocator.free(path);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .workspace = workspace,
            .user_settings_path = user_settings_path,
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
        if (self.user_settings_path) |path| self.allocator.free(path);
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
        self.trusted = trusted;
        try self.reload();
    }

    pub fn onDidChangeConfiguration(
        self: *ConfigurationService,
        ctx: anytype,
        callback: fn (change: configuration.Change, ctx: @TypeOf(ctx)) anyerror!void,
    ) !void {
        _ = try self.change_emitter.listen(ctx, callback);
    }

    /// Reads all scopes into temporary models first, so a failed read leaves
    /// the previously loaded configuration intact.
    fn load(self: *ConfigurationService) !void {
        var new_defaults = try self.registry.buildDefaultModel(self.allocator);
        errdefer new_defaults.deinit();
        var new_user = try self.readModel(self.user_settings_path);
        errdefer new_user.deinit();
        var new_workspace = try self.readWorkspaceModel();
        errdefer new_workspace.deinit();

        var new_folders = std.StringHashMap(*ConfigurationModel).init(self.allocator);
        errdefer deinitFolderModels(self.allocator, &new_folders);
        for (self.workspace.getWorkspace().folders.items) |folder| {
            const model = try self.allocator.create(ConfigurationModel);
            errdefer self.allocator.destroy(model);
            model.* = try self.readFolderModel(folder.resource);
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

        self.fireChangeEvent();
    }

    pub fn interface(self: *ConfigurationService) configuration.IConfigurationService {
        return .{ .context = self, .get_value = getValueForInterface };
    }

    fn getValueForInterface(context: *anyopaque, key: []const u8) ?*const Value {
        const self: *ConfigurationService = @ptrCast(@alignCast(context));
        return self.getValue(key, .{});
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
    pub fn settingsFilePaths(self: *const ConfigurationService, allocator: Allocator) ![]const []u8 {
        var paths = std.array_list.Managed([]u8).init(allocator);
        errdefer {
            for (paths.items) |path| allocator.free(path);
            paths.deinit();
        }

        if (self.user_settings_path) |path| {
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
        return Io.Dir.cwd().readFileAlloc(
            self.io,
            path,
            self.allocator,
            .limited(max_settings_file_size),
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
    }

    fn fireChangeEvent(self: *ConfigurationService) void {
        var affected_keys = std.array_list.Managed([]const u8).init(self.allocator);
        defer affected_keys.deinit();

        for (self.defaults.getKeys()) |key| appendUnique(&affected_keys, key) catch return;
        for (self.user.getKeys()) |key| appendUnique(&affected_keys, key) catch return;
        for (self.workspace_model.getKeys()) |key| appendUnique(&affected_keys, key) catch return;
        var iterator = self.folders.valueIterator();
        while (iterator.next()) |model| {
            for (model.*.getKeys()) |key| appendUnique(&affected_keys, key) catch return;
        }

        self.change_emitter.fire(.{
            .source = .USER,
            .keys = affected_keys.items,
        }) catch {};
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

fn appendUnique(list: *std.array_list.Managed([]const u8), key: []const u8) !void {
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, key)) return;
    }
    try list.append(key);
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
