const std = @import("std");
const Allocator = std.mem.Allocator;
const Uri = std.Uri;
const Emitter = @import("../basics/event.zig").Emitter;
const StringHashMap = std.StringHashMap;
const getConfigurationValue = @import("../languages/configuration.zig").getConfigurationValue;
const IConfigurationChangeEvent = @import("../languages/configuration.zig").IConfigurationChangeEvent;
const IConfigurationChange = @import("../languages/configuration.zig").IConfigurationChange;
const IConfigurationOverrides = @import("../languages/configuration.zig").IConfigurationOverrides;
const IConfigurationService = @import("../languages/configuration.zig").IConfigurationService;
const IConfigurationValue = @import("../languages/configuration.zig").IConfigurationValue;

pub const TestConfigurationService = struct {
    allocator: Allocator,
    configuration: StringHashMap([]const u8),
    onDidChangeConfigurationEmitter: Emitter(IConfigurationChangeEvent),
    overrideIdentifiers: StringHashMap([]const []const u8),

    pub fn init(allocator: Allocator, configuration: ?StringHashMap([]const u8)) TestConfigurationService {
        return .{
            .allocator = allocator,
            .overrideIdentifiers = StringHashMap([]const []const u8).init(allocator),
            .configuration = configuration orelse StringHashMap([]const u8).init(allocator),
            .onDidChangeConfigurationEmitter = Emitter(IConfigurationChangeEvent).init(allocator),
        };
    }

    pub fn reloadConfiguration() void {}

    pub fn getValue(self: *TestConfigurationService, comptime T: type, section: ?[]const u8, overrides: ?IConfigurationOverrides) !?T {
        // var configuration;
        // const overrides = if (isConfigurationOverrides(arg1)) arg1 else if (isConfigurationOverrides(arg2)) arg2 else undefined;
        // if (overrides) {
        //if (overrides.resource) {
        //configuration = self.configurationByRoot.findSubstr(overrides.resource.fsPath);
        //}
        //}
        //configuration = configuration ? configuration : self.configuration;
        //if (arg1) |_arg1| {
        //return (configuration[_arg1] ?? getConfigurationValue(configuration, _arg1));
        //}
        //return configuration;
        _ = self;
        _ = section;
        _ = overrides;
        return null;
    }

    pub fn updateValue(self: *TestConfigurationService, key: []const u8, value: anytype) void {
        _ = self;
        _ = key;
        _ = value;
    }

    pub fn setUserConfiguration(self: *TestConfigurationService, key: []const u8, value: anytype, root: ?Uri) void {
        _ = self;
        _ = key;
        _ = value;
        _ = root;
    }

    pub fn setOverrideIdentifiers(self: *TestConfigurationService, key: []const u8, identifiers: []const []const u8) !void {
        try self.overrideIdentifiers.put(key, identifiers);
    }

    pub fn inspect(self: *TestConfigurationService, comptime T: type, key: []const u8, overrides: ?IConfigurationOverrides) IConfigurationValue(T) {
        const value = try self.getValue(key, overrides);
        return .{ .value = value, .defaultValue = undefined, .userValue = value, .userLocalValue = value, .overrideIdentifiers = self.overrideIdentifiers.get(key) };
    }

    pub fn keys(self: *TestConfigurationService) !StringHashMap([]const u8) {
        var result = StringHashMap([]const u8).init(self.allocator);
        try result.put("default", &[_][]const u8{});
        try result.put("policy", &[_][]const u8{});
        try result.put("user", &[_][]const u8{});
        try result.put("workspace", &[_][]const u8{});
        try result.put("workspaceFolder", &[_][]const u8{});
        return result;
    }

    pub fn getConfigurationData(self: *TestConfigurationService) ?StringHashMap([]const u8) {
        _ = self;
        return null;
    }
};
