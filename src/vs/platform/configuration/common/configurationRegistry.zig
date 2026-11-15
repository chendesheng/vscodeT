// Port of the default-configuration subset of
// `src/vs/platform/configuration/common/configurationRegistry.ts`.
//
// Upstream keeps a global registry of JSON schemas, default values, policy
// metadata and experiment overrides. This port keeps an owned registry of
// default settings documents and the configuration scope enum; schema
// validation, policy/experiment metadata, excluded properties and the Settings
// editor schema are not ported.

const std = @import("std");
const Allocator = std.mem.Allocator;
const configurationModels = @import("./configurationModels.zig");
const ConfigurationModel = configurationModels.ConfigurationModel;

pub const ConfigurationScope = enum(u8) {
    APPLICATION = 1,
    MACHINE,
    APPLICATION_MACHINE,
    WINDOW,
    RESOURCE,
    LANGUAGE_OVERRIDABLE,
    MACHINE_OVERRIDABLE,
};

pub const ConfigurationRegistry = struct {
    allocator: Allocator,
    defaults: std.array_list.Managed(*ConfigurationModel),

    pub fn init(allocator: Allocator) !*ConfigurationRegistry {
        const self = try allocator.create(ConfigurationRegistry);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .defaults = std.array_list.Managed(*ConfigurationModel).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *ConfigurationRegistry) void {
        for (self.defaults.items) |model| {
            model.deinit();
            self.allocator.destroy(model);
        }
        self.defaults.deinit();
        self.allocator.destroy(self);
    }

    /// Registers a JSON settings document as configuration defaults. Later
    /// registrations override earlier ones, matching upstream's
    /// default-configuration contribution order.
    pub fn registerDefaultsJson(self: *ConfigurationRegistry, text: []const u8) !void {
        const model = try self.allocator.create(ConfigurationModel);
        errdefer self.allocator.destroy(model);
        model.* = try ConfigurationModel.fromJson(self.allocator, text);
        errdefer model.deinit();
        try self.defaults.append(model);
    }

    /// Produces the merged default model. The caller owns the returned model.
    pub fn buildDefaultModel(self: *const ConfigurationRegistry, allocator: Allocator) !ConfigurationModel {
        var models = std.array_list.Managed(*const ConfigurationModel).init(allocator);
        defer models.deinit();
        for (self.defaults.items) |model| try models.append(model);
        return ConfigurationModel.merge(allocator, models.items);
    }
};

/// The defaults registered by the terminal workbench. `explorer.excludeGitIgnore`
/// is on by default here: the Explorer hid `.gitignore` entries before the
/// configuration service existed, and the TUI keeps that behavior unless the
/// user disables it in settings. `files.exclude` matches VS Code's default VCS
/// and OS metadata excludes.
pub const tui_defaults_json =
    \\{
    \\  "files": {
    \\    "exclude": {
    \\      "**/.git": true,
    \\      "**/.svn": true,
    \\      "**/.hg": true,
    \\      "**/.jj": true,
    \\      "**/.DS_Store": true,
    \\      "**/Thumbs.db": true
    \\    }
    \\  },
    \\  "explorer": {
    \\    "excludeGitIgnore": true
    \\  }
    \\}
;

test "ConfigurationRegistry: later defaults win and build a merged model" {
    const allocator = std.testing.allocator;
    const registry = try ConfigurationRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerDefaultsJson("{\"editor.tabSize\": 4}");
    try registry.registerDefaultsJson("{\"editor.tabSize\": 2, \"files.eol\": \"\\n\"}");

    var model = try registry.buildDefaultModel(allocator);
    defer model.deinit();

    try std.testing.expectEqual(@as(i64, 2), model.getValue("editor.tabSize").?.integer);
    try std.testing.expectEqualStrings("\n", model.getValue("files.eol").?.string);
}

test "ConfigurationRegistry: terminal defaults hide VCS metadata and ignore files" {
    const allocator = std.testing.allocator;
    const registry = try ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerDefaultsJson(tui_defaults_json);

    var model = try registry.buildDefaultModel(allocator);
    defer model.deinit();

    try std.testing.expect(model.getValue("explorer.excludeGitIgnore").?.bool);
    const exclude = model.getValue("files.exclude").?;
    try std.testing.expect(exclude.object.get("**/.git").?.bool);
    try std.testing.expect(exclude.object.get("**/.DS_Store").?.bool);
}
