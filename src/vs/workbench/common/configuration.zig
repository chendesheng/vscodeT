// Port of the configuration migration registry and workbench contribution in
// `src/vs/workbench/common/configuration.ts`. The local service exposes user,
// workspace and workspace-folder files (including combined language scopes).
// A migration edits those files without rewriting unrelated JSONC text. Remote
// and application stores are not present in the terminal service.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../base/common/event.zig").Emitter;
const jsonEdit = @import("../../base/common/jsonEdit.zig");
const configurationModels = @import("../../platform/configuration/common/configurationModels.zig");
const ConfigurationService = @import("../services/configuration/browser/configurationService.zig").ConfigurationService;

/// The rename migration form used by the diff editor helper. The registry
/// owns the descriptors, not the setting values or the underlying service.
pub const ConfigurationMigration = struct {
    key: []const u8,
    rename_to: []const u8,
    includeApplication: bool = false,
};

pub const ConfigurationMigrationRegistry = struct {
    allocator: Allocator,
    migrations: std.ArrayList(ConfigurationMigration) = .empty,
    on_did_register: Emitter([]const ConfigurationMigration),

    pub fn init(allocator: Allocator) ConfigurationMigrationRegistry {
        return .{ .allocator = allocator, .on_did_register = .init(allocator) };
    }

    pub fn deinit(self: *ConfigurationMigrationRegistry) void {
        self.on_did_register.deinit();
        self.migrations.deinit(self.allocator);
    }

    pub fn registerConfigurationMigrations(self: *ConfigurationMigrationRegistry, migrations: []const ConfigurationMigration) !void {
        try self.migrations.appendSlice(self.allocator, migrations);
        try self.on_did_register.fire(migrations);
    }
};

/// Returns the edited JSONC document only when an old key was present in an
/// actual configuration scope. Arbitrary nested setting values, comments and
/// strings containing the key are not configuration scopes.
pub fn migrateConfigurationText(allocator: Allocator, text: []const u8, workspace_file: bool, migrations: []const ConfigurationMigration) !?[]u8 {
    var owned: ?[]u8 = null;
    errdefer if (owned) |value| allocator.free(value);
    for (migrations) |migration| {
        while (true) {
            const source: []const u8 = if (owned) |value| value else text;
            var scratch = std.heap.ArenaAllocator.init(allocator);
            defer scratch.deinit();
            const a = scratch.allocator();
            const sanitized = try configurationModels.stripJsonc(a, source);
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, sanitized, .{ .duplicate_field_behavior = .use_last }) catch break;
            if (parsed != .object) break;
            var scope = try jsonEdit.rootSpan(sanitized);
            if (workspace_file) {
                const root = try jsonEdit.objectProperties(a, sanitized, scope);
                const settings = jsonEdit.findProperty(root, "settings") orelse break;
                if (sanitized[settings.value_span.start] != '{') break;
                scope = settings.value_span;
            }
            const properties = try jsonEdit.objectProperties(a, sanitized, scope);
            var edit = try jsonEdit.renameProperty(allocator, a, source, properties, migration.key, migration.rename_to);
            if (edit == null) for (properties) |property| {
                if (property.key.len < 2 or property.key[0] != '[' or property.key[property.key.len - 1] != ']' or sanitized[property.value_span.start] != '{') continue;
                const overrides = try jsonEdit.objectProperties(a, sanitized, property.value_span);
                edit = try jsonEdit.renameProperty(allocator, a, source, overrides, migration.key, migration.rename_to);
                if (edit != null) break;
            };
            const replacement = edit orelse break;
            if (owned) |previous| allocator.free(previous);
            owned = replacement;
        }
    }
    return owned;
}

pub const ConfigurationMigrationWorkbenchContribution = struct {
    pub const ID = "workbench.contrib.configurationMigration";
    allocator: Allocator,
    registry: ConfigurationMigrationRegistry,
    configuration: ?*ConfigurationService = null,
    registry_listener: ?usize = null,
    folder_listener: ?usize = null,
    started: bool = false,

    pub fn init(allocator: Allocator) ConfigurationMigrationWorkbenchContribution {
        return .{ .allocator = allocator, .registry = ConfigurationMigrationRegistry.init(allocator) };
    }

    pub fn deinit(self: *ConfigurationMigrationWorkbenchContribution) void {
        self.detach();
        if (self.registry_listener) |id| self.registry.on_did_register.unlisten(id);
        self.registry.deinit();
    }

    pub fn bind(self: *ConfigurationMigrationWorkbenchContribution, configuration: ?*ConfigurationService) !void {
        self.detach();
        self.configuration = configuration;
        if (self.started) try self.attach();
    }

    pub fn start(context: *anyopaque) !void {
        const self: *ConfigurationMigrationWorkbenchContribution = @ptrCast(@alignCast(context));
        if (self.started) return;
        self.started = true;
        self.registry_listener = try self.registry.on_did_register.listen(self, onRegistered);
        try self.attach();
    }

    fn attach(self: *ConfigurationMigrationWorkbenchContribution) !void {
        const config = self.configuration orelse return;
        self.folder_listener = try config.workspace.on_did_add_folder.listen(self, onFolderAdded);
        try self.migrateConfigurations(self.registry.migrations.items);
    }

    fn detach(self: *ConfigurationMigrationWorkbenchContribution) void {
        if (self.folder_listener) |id| self.configuration.?.workspace.on_did_add_folder.unlisten(id);
        self.folder_listener = null;
        self.configuration = null;
    }

    fn onRegistered(migrations: []const ConfigurationMigration, self: *ConfigurationMigrationWorkbenchContribution) !void {
        try self.migrateConfigurations(migrations);
    }

    fn onFolderAdded(resource: []const u8, self: *ConfigurationMigrationWorkbenchContribution) !void {
        const config = self.configuration orelse return;
        const edit: SourceMigration = .{ .migrations = self.registry.migrations.items };
        try config.editConfigurationSources(resource, edit.interface());
    }

    fn migrateConfigurations(self: *ConfigurationMigrationWorkbenchContribution, migrations: []const ConfigurationMigration) !void {
        const config = self.configuration orelse return;
        const edit: SourceMigration = .{ .migrations = migrations };
        try config.editConfigurationSources(null, edit.interface());
    }

    const SourceMigration = struct {
        migrations: []const ConfigurationMigration,
        fn interface(self: *const SourceMigration) ConfigurationService.SourceEditor {
            return .{ .context = self, .edit = apply };
        }
        fn apply(context: *const anyopaque, allocator: Allocator, text: []const u8, workspace_file: bool) !?[]u8 {
            const self: *const SourceMigration = @ptrCast(@alignCast(context));
            return migrateConfigurationText(allocator, text, workspace_file, self.migrations);
        }
    };
};
