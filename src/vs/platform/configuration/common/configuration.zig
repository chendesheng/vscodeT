// Port of the portable value types and tree helpers in
// `src/vs/platform/configuration/common/configuration.ts`.
//
// Terminal adaptation: settings values are `std.json.Value` (owned by a
// configuration model's arena) instead of JavaScript's untyped objects. The
// `addToValueTree`/`removeFromValueTree`/`getConfigurationValue`/`merge`
// helpers keep upstream's dotted-key semantics and `__proto__` guard. Language
// override identifiers, policy values, application/remote/profile scopes and
// configuration editing are separate modules and are not part of this file.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The value stored for one settings key. All strings, arrays and objects are
/// allocated in the owning configuration model's arena.
pub const Value = std.json.Value;

pub const ConfigurationScope = enum(u8) {
    APPLICATION = 1,
    MACHINE,
    APPLICATION_MACHINE,
    WINDOW,
    RESOURCE,
    LANGUAGE_OVERRIDABLE,
    MACHINE_OVERRIDABLE,
};

pub const ConfigurationTarget = enum(u8) {
    APPLICATION = 1,
    USER,
    USER_LOCAL,
    USER_REMOTE,
    WORKSPACE,
    WORKSPACE_FOLDER,
    DEFAULT,
    MEMORY,

    pub fn toString(self: ConfigurationTarget) []const u8 {
        return switch (self) {
            .APPLICATION => "APPLICATION",
            .USER => "USER",
            .USER_LOCAL => "USER_LOCAL",
            .USER_REMOTE => "USER_REMOTE",
            .WORKSPACE => "WORKSPACE",
            .WORKSPACE_FOLDER => "WORKSPACE_FOLDER",
            .DEFAULT => "DEFAULT",
            .MEMORY => "MEMORY",
        };
    }
};

/// `IConfigurationOverrides`: a resource selects the workspace folder whose
/// settings apply; the override identifier selects a language-specific block.
/// The latter is parsed but not resolved by this port yet.
pub const Overrides = struct {
    override_identifier: ?[]const u8 = null,
    resource: ?[]const u8 = null,
};

/// `IConfigurationChange`. The keys are borrowed from the service for the
/// duration of the change event.
pub const Change = struct {
    source: ConfigurationTarget,
    keys: []const []const u8,
    overrides: []const OverrideChange = &.{},
};

pub const OverrideChange = struct {
    identifier: []const u8,
    keys: []const []const u8,
};

/// `IInspectValue` for one scope. Values are borrowed from the owning model.
pub const InspectValue = struct {
    value: ?*const Value = null,
    override_value: ?*const Value = null,
};

/// Borrowed result of `IConfigurationService.inspect`. Pointers stay valid
/// until the service reloads its settings.
pub const ConfigurationValue = struct {
    default: ?*const Value = null,
    user: ?*const Value = null,
    workspace: ?*const Value = null,
    workspace_folder: ?*const Value = null,
    value: ?*const Value = null,
    override_identifiers: []const []const u8 = &.{},
};

/// The portable subset of upstream IConfigurationService: read/update a
/// setting and observe its change event. Read-only test adapters may omit
/// editing and notification operations.
pub const configuration_service_id = @import("../../instantiation/common/instantiation.zig").ServiceIdentifier(IConfigurationService, "configurationService");

pub const IConfigurationService = struct {
    context: *anyopaque,
    get_value: *const fn (context: *anyopaque, key: []const u8) ?*const Value,
    get_value_with_overrides: ?*const fn (*anyopaque, []const u8, Overrides) ?*const Value = null,
    update_value: ?*const fn (*anyopaque, []const u8, ?Value, ConfigurationTarget) anyerror!void = null,
    on_did_change_configuration: ?*@import("../../../base/common/event.zig").Emitter(Change) = null,

    pub fn updateValue(self: IConfigurationService, key: []const u8, value: ?Value, target: ConfigurationTarget) !void {
        const update = self.update_value orelse return error.ConfigurationReadOnly;
        try update(self.context, key, value, target);
    }

    pub fn getValue(self: IConfigurationService, key: []const u8) ?*const Value {
        return self.get_value(self.context, key);
    }

    pub fn getValueWithOverrides(self: IConfigurationService, key: []const u8, overrides: Overrides) ?*const Value {
        return if (self.get_value_with_overrides) |get| get(self.context, key, overrides) else self.getValue(key);
    }

    pub fn getBool(self: IConfigurationService, key: []const u8, default: bool) bool {
        const value = self.getValue(key) orelse return default;
        return switch (value.*) {
            .bool => |b| b,
            else => default,
        };
    }

    pub fn getString(self: IConfigurationService, key: []const u8) ?[]const u8 {
        const value = self.getValue(key) orelse return null;
        return switch (value.*) {
            .string => |str| str,
            else => null,
        };
    }
};

/// Matches upstream `IConfigurationChangeEvent.affectsConfiguration`: a key
/// change affects both the key itself and its descendants, and a changed child
/// affects its ancestors.
pub fn affectsConfiguration(change: Change, section: []const u8) bool {
    if (affectsKeys(change.keys, section)) return true;
    for (change.overrides) |override_change| {
        if (affectsKeys(override_change.keys, section)) return true;
    }
    return false;
}

fn affectsKeys(keys: []const []const u8, section: []const u8) bool {
    for (keys) |key| {
        if (std.mem.eql(u8, key, section)) return true;
        if (isPathPrefix(key, section)) return true;
        if (isPathPrefix(section, key)) return true;
    }
    return false;
}

/// Override-aware `affectsConfiguration`: language-override changes only affect
/// a query that names the same override identifier.
pub fn affectsConfigurationWithOverrides(change: Change, section: []const u8, override_identifier: ?[]const u8) bool {
    if (affectsKeys(change.keys, section)) return true;
    const identifier = override_identifier orelse return false;
    for (change.overrides) |override_change| {
        if (!std.mem.eql(u8, override_change.identifier, identifier)) continue;
        for (override_change.keys) |key| {
            if (std.mem.eql(u8, key, section) or isPathPrefix(key, section) or isPathPrefix(section, key)) return true;
        }
    }
    return false;
}

fn isPathPrefix(prefix: []const u8, value: []const u8) bool {
    return value.len > prefix.len and
        std.mem.startsWith(u8, value, prefix) and
        value[prefix.len] == '.';
}

pub const Keys = struct {
    default: []const []const u8 = &.{},
    policy: []const []const u8 = &.{},
    user: []const []const u8 = &.{},
    workspace: []const []const u8 = &.{},
    workspace_folder: []const []const u8 = &.{},
};

/// Returns true when a value is a JSON object. Arrays are not flattened.
pub fn isObject(value: Value) bool {
    return value == .object;
}

/// Deep-copies a JSON value into `allocator`.
pub fn cloneValue(allocator: Allocator, value: Value) Allocator.Error!Value {
    return switch (value) {
        .null => .null,
        .bool => |inner| .{ .bool = inner },
        .integer => |inner| .{ .integer = inner },
        .float => |inner| .{ .float = inner },
        .number_string => |inner| .{ .number_string = try allocator.dupe(u8, inner) },
        .string => |inner| .{ .string = try allocator.dupe(u8, inner) },
        .array => |inner| blk: {
            var copy = std.json.Array.init(allocator);
            errdefer copy.deinit();
            try copy.ensureTotalCapacity(inner.items.len);
            for (inner.items) |item| {
                copy.appendAssumeCapacity(try cloneValue(allocator, item));
            }
            break :blk .{ .array = copy };
        },
        .object => |inner| blk: {
            var copy: std.json.ObjectMap = .empty;
            errdefer copy.deinit(allocator);
            try copy.ensureTotalCapacity(allocator, inner.count());
            var iterator = inner.iterator();
            while (iterator.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, "__proto__")) continue;
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                copy.putAssumeCapacity(key, try cloneValue(allocator, entry.value_ptr.*));
            }
            break :blk .{ .object = copy };
        },
    };
}

/// Recursively merges `source` into `target`. Objects merge key by key; every
/// other value replaces the target. Both values are cloned into `allocator`
/// when needed, so they may come from different arenas.
pub fn mergeInto(allocator: Allocator, target: *Value, source: Value) Allocator.Error!void {
    if (target.* != .object or source != .object) {
        target.* = try cloneValue(allocator, source);
        return;
    }

    var iterator = source.object.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "__proto__")) continue;
        if (target.object.getPtr(entry.key_ptr.*)) |existing| {
            if (existing.* == .object and entry.value_ptr.* == .object) {
                try mergeInto(allocator, existing, entry.value_ptr.*);
            } else {
                existing.* = try cloneValue(allocator, entry.value_ptr.*);
            }
        } else {
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key);
            try target.object.put(allocator, key, try cloneValue(allocator, entry.value_ptr.*));
        }
    }
}

/// `addToValueTree`: inserts `value` at the dotted `key` path, creating
/// intermediate objects. A non-object intermediate value is a conflict and
/// leaves the tree unchanged, as upstream does.
pub fn addToValueTree(allocator: Allocator, root: *Value, key: []const u8, value: Value) !void {
    if (root.* != .object or key.len == 0) return;

    var segments = std.mem.splitScalar(u8, key, '.');
    var segment = segments.next() orelse return;
    var current = root;

    while (segments.next()) |next| {
        if (current.object.getPtr(segment)) |existing| {
            if (existing.* != .object) return;
            current = existing;
        } else {
            const name = try allocator.dupe(u8, segment);
            errdefer allocator.free(name);
            try current.object.put(allocator, name, .{ .object = .empty });
            current = current.object.getPtr(segment).?;
        }
        segment = next;
    }

    const name = try allocator.dupe(u8, segment);
    errdefer allocator.free(name);
    try current.object.put(allocator, name, try cloneValue(allocator, value));
}

/// `removeFromValueTree`: removes a dotted key and any now-empty parents.
pub fn removeFromValueTree(root: *Value, key: []const u8) void {
    if (root.* != .object or key.len == 0) return;
    _ = removeInner(root, key);
}

fn removeInner(value: *Value, key: []const u8) bool {
    if (value.* != .object or key.len == 0) return false;
    const dot = std.mem.indexOfScalar(u8, key, '.');
    const segment = if (dot) |index| key[0..index] else key;
    if (dot == null) {
        _ = value.object.orderedRemove(segment);
        return value.object.count() == 0;
    }

    const child = value.object.getPtr(segment) orelse return false;
    const empty = removeInner(child, key[dot.? + 1 ..]);
    if (empty) _ = value.object.orderedRemove(segment);
    return value.object.count() == 0;
}

/// `getConfigurationValue`: walks a dotted section path. An empty section
/// returns the root object.
pub fn getConfigurationValue(root: *const Value, section: []const u8) ?*const Value {
    if (section.len == 0) return root;

    var current = root;
    var iterator = std.mem.splitScalar(u8, section, '.');
    while (iterator.next()) |segment| {
        if (current.* != .object) return null;
        current = current.object.getPtr(segment) orelse return null;
    }
    return current;
}

/// `merge`: a mutable variant used by tests and callers that already own the
/// destination arena.
pub fn merge(allocator: Allocator, base: *Value, add: Value, overwrite: bool) !void {
    if (base.* != .object or add != .object) return;
    var iterator = add.object.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "__proto__")) continue;
        if (base.object.getPtr(entry.key_ptr.*)) |existing| {
            if (existing.* == .object and entry.value_ptr.* == .object) {
                try merge(allocator, existing, entry.value_ptr.*, overwrite);
            } else if (overwrite) {
                existing.* = try cloneValue(allocator, entry.value_ptr.*);
            }
        } else {
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key);
            try base.object.put(allocator, key, try cloneValue(allocator, entry.value_ptr.*));
        }
    }
}

test "configuration value tree: dotted keys and removal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = Value{ .object = .empty };
    const number = std.json.Value{ .integer = 4 };
    try addToValueTree(allocator, &tree, "editor.tabSize", number);
    try addToValueTree(allocator, &tree, "editor.insertSpaces", .{ .bool = true });

    try std.testing.expectEqual(@as(i64, 4), getConfigurationValue(&tree, "editor.tabSize").?.integer);
    try std.testing.expect(getConfigurationValue(&tree, "editor.insertSpaces").?.bool);

    removeFromValueTree(&tree, "editor.tabSize");
    try std.testing.expect(getConfigurationValue(&tree, "editor.tabSize") == null);
    try std.testing.expect(getConfigurationValue(&tree, "editor.insertSpaces") != null);
}

test "configuration value tree: merge is recursive and arrays replace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var base = try cloneValue(allocator, .{ .object = .empty });
    try addToValueTree(allocator, &base, "files.exclude.build", .{ .bool = true });
    try addToValueTree(allocator, &base, "files.exclude.keep", .{ .bool = true });

    var add = try cloneValue(allocator, .{ .object = .empty });
    try addToValueTree(allocator, &add, "files.exclude.build", .{ .bool = false });

    try mergeInto(allocator, &base, add);
    try std.testing.expect(getConfigurationValue(&base, "files.exclude.keep").?.bool);
    try std.testing.expect(!getConfigurationValue(&base, "files.exclude.build").?.bool);
}

test "configuration change: affects nested keys" {
    const keys = [_][]const u8{"files"};
    const change = Change{ .source = .WORKSPACE, .keys = &keys };
    try std.testing.expect(affectsConfiguration(change, "files"));
    try std.testing.expect(affectsConfiguration(change, "files.exclude"));
    try std.testing.expect(!affectsConfiguration(change, "file"));
    try std.testing.expect(!affectsConfiguration(change, "explorer.excludeGitIgnore"));
}

/// Structural JSON value equality (used by configuration updates).
pub fn jsonValuesEqual(a: std.json.Value, b: std.json.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => |value| value == b.bool,
        .integer => |value| value == b.integer,
        .float => |value| value == b.float,
        .number_string => |value| std.mem.eql(u8, value, b.number_string),
        .string => |value| std.mem.eql(u8, value, b.string),
        .array => |array| blk: {
            if (array.items.len != b.array.items.len) break :blk false;
            for (array.items, b.array.items) |item_a, item_b| {
                if (!jsonValuesEqual(item_a, item_b)) break :blk false;
            }
            break :blk true;
        },
        .object => |object| blk: {
            if (object.count() != b.object.count()) break :blk false;
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                const other = b.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!jsonValuesEqual(entry.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
    };
}
