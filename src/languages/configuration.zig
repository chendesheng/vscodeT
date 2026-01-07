const std = @import("std");
const Uri = std.Uri;
const Emitter = @import("../basics/event.zig").Emitter;

pub const IConfigurationOverrides = struct {
    overrideIdentifier: ?[]const u8,
    resource: ?Uri,
};

pub fn IConfigurationValue(comptime T: type) type {
    return struct {
        defaultValue: ?T,
        applicationValue: ?T,
        userValue: ?T,
        userLocalValue: ?T,
        userRemoteValue: ?T,
        workspaceValue: ?T,
        workspaceFolderValue: ?T,
        memoryValue: ?T,
        policyValue: ?T,
        value: ?T,

        default: ?IInspectValue(T),
        application: ?IInspectValue(T),
        user: ?IInspectValue(T),
        userLocal: ?IInspectValue(T),
        userRemote: ?IInspectValue(T),
        workspace: ?IInspectValue(T),
        workspaceFolder: ?IInspectValue(T),
        memory: ?IInspectValue(T),
        // policy: ?{ value?: T },

        overrideIdentifiers: ?[]const []const u8,
    };
}

pub fn IInspectValue(comptime T: type) type {
    return struct {
        value: ?T,
        override: ?T,
        overrides: ?[]struct {
            identifiers: ?[]const []const u8,
            value: T,
        },
    };
}

pub const ConfigurationTarget = enum(u8) {
    application = 1,
    user,
    user_local,
    user_remote,
    workspace,
    workspace_folder,
    default,
    memory,
};

pub const IConfigurationService = struct {
    // _serviceBrand: undefined,

    // onDidChangeConfiguration: Emitter(IConfigurationChangeEvent),

    // fn getConfigurationData() ?IConfigurationData;

    // // Fetches the value of the section for the given overrides.
    // // Value can be of native type or an object keyed off the section name.
    // //
    // // @param section - Section of the configuration. Can be `null` or `undefined`.
    // // @param overrides - Overrides that has to be applied while fetching
    // fn getValue() T;
    // fn getValue1(section: []const u8) T;
    // fn getValueOverride(overrides: IConfigurationOverrides) T;
    // fn getValue2(section: []const u8, overrides: IConfigurationOverrides) T;

    // // Update a configuration value.
    // //
    // // Use `target` to update the configuration in a specific `ConfigurationTarget`.
    // //
    // // Use `overrides` to update the configuration for a resource or for override identifiers or both.
    // //
    // // Passing a resource through overrides will update the configuration in the workspace folder containing that resource.
    // //
    // // *Note 1:* Updating configuration to a default value will remove the configuration from the requested target. If not target is passed, it will be removed from all writeable targets.
    // //
    // // *Note 2:* Use `undefined` value to remove the configuration from the given target. If not target is passed, it will be removed from all writeable targets.
    // //
    // // Use `donotNotifyError` and set it to `true` to surpresss errors.
    // //
    // // @param key setting to be updated
    // // @param value The new value
    // fn updateValue(key: []const u8, value: unknown)
    // fn updateValue3(key: []const u8, value: unknown, target: ConfigurationTarget)
    // fn updateValueOverrides(key: []const u8, value: unknown, overrides: IConfigurationOverrides)
    // fn updateValueOverrides4(key: []const u8, value: unknown, overrides: IConfigurationOverrides, target: ConfigurationTarget, options: ?IConfigurationUpdateOptions)

    // fn inspect(comptime T: type, key: []const u8, overrides: ?IConfigurationOverrides) IConfigurationValue(T);

    // fn reloadConfiguration(target: ?ConfigurationTarget) void;

    // fn keys() struct {
    // default: []const []const,
    // policy: []const []const,
    // user: []const []const,
    // workspace: []const []const,
    // workspaceFolder: []const []const,
    // memory: ?[]const []const,
    // };
};
