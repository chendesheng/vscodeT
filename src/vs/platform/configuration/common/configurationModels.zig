// Port of the portable parts of
// `src/vs/platform/configuration/common/configurationModels.ts`.
//
// `ConfigurationModel` owns one scope's normalized settings tree: dotted keys
// are expanded into nested objects, `keys` keeps the original top-level keys
// for change detection, and `merge` overlays models with upstream's recursive
// object merge. The parser accepts JSON with `//` and `/* */` comments and
// trailing commas, like VS Code's settings files.
//
// Override-identifier parsing (`[typescript]` blocks), top-level
// scope/restricted/include/exclude filtering and override-preserving merges are
// ported. Not ported: raw-model/source tracking, nested property-schema
// filtering and `Configuration`'s policy/application/remote/memory stores. The workbench
// `ConfigurationService` composes the scopes this port does support.

const std = @import("std");
const Allocator = std.mem.Allocator;
const configuration = @import("./configuration.zig");
const Value = configuration.Value;

/// An immutable settings snapshot. The arena owns the whole JSON tree; a
/// reload builds a new model and releases the old one, so value lifetimes stay
/// simple and no recursive per-value `deinit` is needed.
pub const OverrideIdentifier = struct {
    identifiers: []const []const u8,
    keys: []const []const u8,
    contents: Value,
};

pub const PropertySchemaEntry = struct {
    key: []const u8,
    scope: configuration.ConfigurationScope = .WINDOW,
    restricted: bool = false,
};

pub const ParseOptions = struct {
    exclude: []const []const u8 = &.{},
    include: []const []const u8 = &.{},
    scopes: []const configuration.ConfigurationScope = &.{},
    skip_restricted: bool = false,
    skip_unregistered: bool = false,
    schemas: []const PropertySchemaEntry = &.{},
    /// Excluded (`included: false`) property schemas: they bypass
    /// `skipRestricted` but still participate in scope filtering.
    excluded_schemas: []const PropertySchemaEntry = &.{},
};

pub const ConfigurationModel = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    contents: Value = .{ .object = .empty },
    keys: std.array_list.Managed([]const u8),
    overrides: []const OverrideIdentifier = &.{},

    pub fn initEmpty(allocator: Allocator) !ConfigurationModel {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .contents = .{ .object = .empty },
            .keys = std.array_list.Managed([]const u8).init(allocator),
            .overrides = &.{},
        };
    }

    pub fn deinit(self: *ConfigurationModel) void {
        self.keys.deinit();
        self.arena.deinit();
    }

    /// Parses one settings document. Invalid JSON yields an empty model, as
    /// upstream's parser reports the error and keeps the previous model.
    pub fn fromJson(allocator: Allocator, text: []const u8) !ConfigurationModel {
        return fromJsonWithOptions(allocator, text, .{});
    }

    pub fn fromJsonWithOptions(allocator: Allocator, text: []const u8, options: ParseOptions) !ConfigurationModel {
        // Parse the raw JSONC in a scratch arena; only the normalized tree is
        // retained in the model arena.
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const sanitized = try stripJsonc(scratch.allocator(), text);
        const raw = std.json.parseFromSliceLeaky(Value, scratch.allocator(), sanitized, .{
            .duplicate_field_behavior = .use_last,
        }) catch return initEmpty(allocator);
        return fromValueWithOptions(allocator, raw, options);
    }

    fn fromValueWithOptions(allocator: Allocator, raw: Value, options: ParseOptions) !ConfigurationModel {
        var model = try initEmpty(allocator);
        errdefer model.deinit();
        if (raw != .object) return model;

        const arena = model.arena.allocator();
        var normalized: Value = .{ .object = .empty };
        var overrides = std.array_list.Managed(OverrideIdentifier).init(arena);
        defer overrides.deinit();
        var iterator = raw.object.iterator();
        while (iterator.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, "__proto__")) continue;
            if (isOverrideIdentifierKey(entry.key_ptr.*)) {
                const identifiers = try parseOverrideIdentifiers(arena, entry.key_ptr.*);
                var override_contents: Value = .{ .object = .empty };
                var override_keys = std.array_list.Managed([]const u8).init(arena);
                switch (entry.value_ptr.*) {
                    .object => |object| {
                        var inner = object.iterator();
                        while (inner.next()) |inner_entry| {
                            const filtered = try filterValue(arena, inner_entry.key_ptr.*, inner_entry.value_ptr.*, options) orelse continue;
                            try configuration.addToValueTree(arena, &override_contents, inner_entry.key_ptr.*, filtered);
                            try override_keys.append(try arena.dupe(u8, inner_entry.key_ptr.*));
                        }
                    },
                    else => continue,
                }
                try overrides.append(.{ .identifiers = identifiers, .keys = try override_keys.toOwnedSlice(), .contents = override_contents });
                continue;
            }
            const filtered = try filterValue(arena, entry.key_ptr.*, entry.value_ptr.*, options) orelse continue;
            try configuration.addToValueTree(arena, &normalized, entry.key_ptr.*, filtered);
            try model.keys.append(try arena.dupe(u8, entry.key_ptr.*));
        }
        model.contents = normalized;
        model.overrides = try overrides.toOwnedSlice();
        return model;
    }

    /// Builds a model from an already parsed JSON value and explicit keys.
    pub fn init(allocator: Allocator, value: Value, keys: []const []const u8) !ConfigurationModel {
        var model = try initEmpty(allocator);
        errdefer model.deinit();
        const arena = model.arena.allocator();
        model.contents = try configuration.cloneValue(arena, value);
        for (keys) |key| try model.keys.append(try arena.dupe(u8, key));
        return model;
    }

    /// Builds a model with explicit override entries.
    pub fn initWithOverrides(allocator: Allocator, value: Value, keys: []const []const u8, overrides: []const OverrideIdentifier) !ConfigurationModel {
        var model = try init(allocator, value, keys);
        errdefer model.deinit();
        const arena = model.arena.allocator();
        var cloned = std.array_list.Managed(OverrideIdentifier).init(arena);
        for (overrides) |override_value| {
            var identifiers = std.array_list.Managed([]const u8).init(arena);
            for (override_value.identifiers) |identifier| try identifiers.append(try arena.dupe(u8, identifier));
            var override_keys = std.array_list.Managed([]const u8).init(arena);
            for (override_value.keys) |key| try override_keys.append(try arena.dupe(u8, key));
            try cloned.append(.{
                .identifiers = try identifiers.toOwnedSlice(),
                .keys = try override_keys.toOwnedSlice(),
                .contents = try configuration.cloneValue(arena, override_value.contents),
            });
        }
        model.overrides = try cloned.toOwnedSlice();
        return model;
    }

    /// Builds a model from an already parsed JSON object, for `.code-workspace`
    /// files whose `settings` member is itself the raw settings object.
    pub fn fromValue(allocator: Allocator, value: Value) !ConfigurationModel {
        return fromValueWithOptions(allocator, value, .{});
    }

    pub fn isEmpty(self: *const ConfigurationModel) bool {
        return self.keys.items.len == 0 and self.contents.object.count() == 0;
    }

    pub fn getValue(self: *const ConfigurationModel, section: []const u8) ?*const Value {
        return configuration.getConfigurationValue(&self.contents, section);
    }

    pub fn getKeys(self: *const ConfigurationModel) []const []const u8 {
        return self.keys.items;
    }

    pub fn setValue(self: *ConfigurationModel, key: []const u8, value: Value) !void {
        const arena = self.arena.allocator();
        try configuration.addToValueTree(arena, &self.contents, key, value);
        if (!self.hasKey(key)) try self.keys.append(try arena.dupe(u8, key));
        if (isOverrideIdentifierKey(key)) try self.updateOverride(key, value, arena);
    }

    fn updateOverride(self: *ConfigurationModel, key: []const u8, value: Value, arena: Allocator) !void {
        const identifiers = try parseOverrideIdentifiers(arena, key);
        var override_keys = std.array_list.Managed([]const u8).init(arena);
        if (value == .object) {
            var iterator = value.object.iterator();
            while (iterator.next()) |entry| try override_keys.append(try arena.dupe(u8, entry.key_ptr.*));
        }
        var overrides = std.array_list.Managed(OverrideIdentifier).init(arena);
        var replaced = false;
        for (self.overrides) |existing| {
            if (!replaced and sameIdentifiers(existing.identifiers, identifiers)) {
                try overrides.append(.{
                    .identifiers = identifiers,
                    .keys = try override_keys.toOwnedSlice(),
                    .contents = try configuration.cloneValue(arena, value),
                });
                replaced = true;
            } else {
                try overrides.append(existing);
            }
        }
        if (!replaced) {
            try overrides.append(.{
                .identifiers = identifiers,
                .keys = try override_keys.toOwnedSlice(),
                .contents = try configuration.cloneValue(arena, value),
            });
        }
        self.overrides = try overrides.toOwnedSlice();
    }

    pub fn removeValue(self: *ConfigurationModel, key: []const u8) void {
        configuration.removeFromValueTree(&self.contents, key);
        for (self.keys.items, 0..) |existing, index| {
            if (std.mem.eql(u8, existing, key)) {
                _ = self.keys.orderedRemove(index);
                break;
            }
        }
        if (isOverrideIdentifierKey(key)) {
            const arena = self.arena.allocator();
            const identifiers = parseOverrideIdentifiers(arena, key) catch return;
            var overrides = std.array_list.Managed(OverrideIdentifier).init(arena);
            for (self.overrides) |existing| {
                if (!sameIdentifiers(existing.identifiers, identifiers)) overrides.append(existing) catch return;
            }
            self.overrides = overrides.toOwnedSlice() catch return;
        }
    }

    fn hasKey(self: *const ConfigurationModel, key: []const u8) bool {
        for (self.keys.items) |existing| {
            if (std.mem.eql(u8, existing, key)) return true;
        }
        return false;
    }

    /// Returns the model with every override block matching `identifier`
    /// merged into its contents.
    pub fn override(self: *const ConfigurationModel, allocator: Allocator, identifier: []const u8) !ConfigurationModel {
        var result = try self.clone(allocator);
        errdefer result.deinit();
        const arena = result.arena.allocator();
        // Multi-identifier overrides merge first; an identifier-only override
        // takes precedence, matching upstream's `getContentsForOverrideIdentifer`.
        for (self.overrides) |override_value| {
            if (override_value.identifiers.len <= 1) continue;
            if (!containsIdentifier(override_value.identifiers, identifier)) continue;
            if (override_value.contents != .object) continue;
            try configuration.mergeInto(arena, &result.contents, override_value.contents);
            for (override_value.keys) |key| {
                if (!result.hasKey(key)) try result.keys.append(try arena.dupe(u8, key));
            }
        }
        for (self.overrides) |override_value| {
            if (override_value.identifiers.len != 1 or !std.mem.eql(u8, override_value.identifiers[0], identifier)) continue;
            if (override_value.contents != .object) continue;
            try configuration.mergeInto(arena, &result.contents, override_value.contents);
            for (override_value.keys) |key| {
                if (!result.hasKey(key)) try result.keys.append(try arena.dupe(u8, key));
            }
        }
        return result;
    }

    /// Keys contributed by every override block whose identifiers contain
    /// `identifier`, in first-seen order without duplicates.
    pub fn getKeysForOverrideIdentifier(self: *const ConfigurationModel, allocator: Allocator, identifier: []const u8) ![]const []const u8 {
        var keys = std.array_list.Managed([]const u8).init(allocator);
        errdefer keys.deinit();
        for (self.overrides) |override_value| {
            var matches = false;
            for (override_value.identifiers) |candidate| {
                if (std.mem.eql(u8, candidate, identifier)) {
                    matches = true;
                    break;
                }
            }
            if (!matches) continue;
            for (override_value.keys) |key| {
                var exists = false;
                for (keys.items) |existing| {
                    if (std.mem.eql(u8, existing, key)) {
                        exists = true;
                        break;
                    }
                }
                if (!exists) try keys.append(key);
            }
        }
        return keys.toOwnedSlice();
    }

    /// Merges models left-to-right. Later models win on scalar/array values;
    /// objects merge recursively.
    pub fn merge(allocator: Allocator, models: []const *const ConfigurationModel) !ConfigurationModel {
        var result = try initEmpty(allocator);
        errdefer result.deinit();
        const arena = result.arena.allocator();

        var overrides = std.array_list.Managed(OverrideIdentifier).init(arena);
        for (models) |model| {
            try configuration.mergeInto(arena, &result.contents, model.contents);
            for (model.keys.items) |key| {
                if (!result.hasKey(key)) try result.keys.append(try arena.dupe(u8, key));
            }
            for (model.overrides) |override_value| {
                var existing: ?*OverrideIdentifier = null;
                for (overrides.items) |*candidate| {
                    if (sameIdentifiers(candidate.identifiers, override_value.identifiers)) {
                        existing = candidate;
                        break;
                    }
                }
                if (existing) |target| {
                    if (override_value.contents == .object) try configuration.mergeInto(arena, &target.contents, override_value.contents);
                    for (override_value.keys) |key| {
                        var found = false;
                        for (target.keys) |existing_key| {
                            if (std.mem.eql(u8, existing_key, key)) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) target.keys = try appendKey(arena, target.keys, key);
                    }
                } else {
                    try overrides.append(try cloneOverride(arena, override_value));
                }
            }
        }
        result.overrides = try overrides.toOwnedSlice();
        return result;
    }

    pub fn clone(self: *const ConfigurationModel, allocator: Allocator) !ConfigurationModel {
        var result = try initEmpty(allocator);
        errdefer result.deinit();
        const arena = result.arena.allocator();
        result.contents = try configuration.cloneValue(arena, self.contents);
        for (self.keys.items) |key| {
            try result.keys.append(try arena.dupe(u8, key));
        }
        return result;
    }
};

fn containsIdentifier(identifiers: []const []const u8, identifier: []const u8) bool {
    for (identifiers) |candidate| {
        if (std.mem.eql(u8, candidate, identifier)) return true;
    }
    return false;
}

fn sameIdentifiers(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a) |identifier| {
        var found = false;
        for (b) |candidate| {
            if (std.mem.eql(u8, identifier, candidate)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn appendKey(arena: Allocator, keys: []const []const u8, key: []const u8) ![]const []const u8 {
    const result = try arena.alloc([]const u8, keys.len + 1);
    @memcpy(result[0..keys.len], keys);
    result[keys.len] = try arena.dupe(u8, key);
    return result;
}

fn cloneOverride(arena: Allocator, override_value: OverrideIdentifier) !OverrideIdentifier {
    var identifiers = std.array_list.Managed([]const u8).init(arena);
    for (override_value.identifiers) |identifier| try identifiers.append(try arena.dupe(u8, identifier));
    var keys = std.array_list.Managed([]const u8).init(arena);
    for (override_value.keys) |key| try keys.append(try arena.dupe(u8, key));
    return .{
        .identifiers = try identifiers.toOwnedSlice(),
        .keys = try keys.toOwnedSlice(),
        .contents = try configuration.cloneValue(arena, override_value.contents),
    };
}

fn isOverrideIdentifierKey(key: []const u8) bool {
    return key.len >= 2 and key[0] == '[' and key[key.len - 1] == ']';
}

/// Replaces comments and trailing commas with spaces while preserving the
/// original byte positions. This is the settings-file subset of upstream's
/// JSONC parser; it deliberately does not build a visitor tree.
fn isExcluded(key: []const u8, excluded: []const []const u8) bool {
    for (excluded) |pattern| {
        if (std.mem.eql(u8, key, pattern)) return true;
    }
    return false;
}

/// Parses `[x][y]` into identifiers, dropping duplicates while keeping order.
fn parseOverrideIdentifiers(arena: Allocator, key: []const u8) ![]const []const u8 {
    var identifiers = std.array_list.Managed([]const u8).init(arena);
    var index: usize = 0;
    while (index < key.len) {
        if (key[index] != '[') break;
        const end = std.mem.indexOfScalarPos(u8, key, index, ']') orelse break;
        const identifier = key[index + 1 .. end];
        var exists = false;
        for (identifiers.items) |existing| {
            if (std.mem.eql(u8, existing, identifier)) {
                exists = true;
                break;
            }
        }
        if (!exists) try identifiers.append(try arena.dupe(u8, identifier));
        index = end + 1;
    }
    return identifiers.toOwnedSlice();
}

fn shouldInclude(key: []const u8, schema: ?PropertySchemaEntry, excluded_schema: ?PropertySchemaEntry, options: ParseOptions) bool {
    for (options.exclude) |excluded| {
        if (std.mem.eql(u8, key, excluded)) return false;
    }
    for (options.include) |included| {
        if (std.mem.eql(u8, key, included)) return true;
    }
    if (options.skip_restricted and schema != null and schema.?.restricted) return false;
    if (options.skip_unregistered and schema == null and excluded_schema == null) return false;
    const effective = schema orelse excluded_schema;
    if (effective == null or options.scopes.len == 0) return true;
    for (options.scopes) |scope| {
        if (effective.?.scope == scope) return true;
    }
    return false;
}

/// Filters a value tree following upstream `filterProperty`: registered keys
/// keep their subtree, unregistered objects recurse per child, and a subtree
/// disappears when every child is filtered out.
fn filterValue(arena: Allocator, path: []const u8, value: std.json.Value, options: ParseOptions) !?std.json.Value {
    for (options.exclude) |excluded| {
        if (std.mem.eql(u8, path, excluded)) return null;
    }
    const schema = findSchema(path, options.schemas);
    const excluded_schema = findSchema(path, options.excluded_schemas);
    if (schema != null) {
        if (!shouldInclude(path, schema, excluded_schema, options)) return null;
        if (value != .object) return try configuration.cloneValue(arena, value);
    } else if (excluded_schema != null) {
        if (!shouldInclude(path, null, excluded_schema, options)) return null;
        return try configuration.cloneValue(arena, value);
    }
    for (options.include) |included| {
        if (std.mem.eql(u8, path, included)) return try configuration.cloneValue(arena, value);
    }
    switch (value) {
        .object => |object| {
            if (object.count() == 0) {
                return if (shouldInclude(path, null, null, options)) try configuration.cloneValue(arena, value) else null;
            }
            var result: std.json.Value = .{ .object = .{} };
            var included_any = false;
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                var child_path = std.array_list.Managed(u8).init(arena);
                try child_path.appendSlice(path);
                try child_path.append('.');
                try child_path.appendSlice(entry.key_ptr.*);
                const filtered = try filterValue(arena, child_path.items, entry.value_ptr.*, options) orelse continue;
                try result.object.put(arena, try arena.dupe(u8, entry.key_ptr.*), filtered);
                included_any = true;
            }
            return if (included_any) result else null;
        },
        else => {
            if (!shouldInclude(path, null, null, options)) return null;
            return try configuration.cloneValue(arena, value);
        },
    }
}

fn findSchema(key: []const u8, schemas: []const PropertySchemaEntry) ?PropertySchemaEntry {
    for (schemas) |schema| {
        if (std.mem.eql(u8, schema.key, key)) return schema;
    }
    return null;
}

pub fn stripJsonc(allocator: Allocator, text: []const u8) ![]u8 {
    const output = try allocator.dupe(u8, text);

    var in_string = false;
    var escaped = false;
    var index: usize = 0;
    while (index < output.len) {
        const ch = output[index];
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (ch == '\\') {
                escaped = true;
            } else if (ch == '"') {
                in_string = false;
            }
            index += 1;
            continue;
        }

        if (ch == '"') {
            in_string = true;
            index += 1;
            continue;
        }

        if (ch == '/' and index + 1 < output.len) {
            if (output[index + 1] == '/') {
                output[index] = ' ';
                output[index + 1] = ' ';
                index += 2;
                while (index < output.len and output[index] != '\n') : (index += 1) {
                    output[index] = ' ';
                }
                continue;
            }
            if (output[index + 1] == '*') {
                output[index] = ' ';
                output[index + 1] = ' ';
                index += 2;
                while (index + 1 < output.len and !(output[index] == '*' and output[index + 1] == '/')) : (index += 1) {
                    if (output[index] != '\n') output[index] = ' ';
                }
                if (index + 1 < output.len) {
                    output[index] = ' ';
                    output[index + 1] = ' ';
                    index += 2;
                }
                continue;
            }
        }
        index += 1;
    }

    // A comma directly before `}` or `]` is allowed by VS Code's JSONC parser.
    in_string = false;
    escaped = false;
    index = 0;
    while (index < output.len) : (index += 1) {
        const ch = output[index];
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (ch == '\\') {
                escaped = true;
            } else if (ch == '"') {
                in_string = false;
            }
            continue;
        }
        if (ch == '"') {
            in_string = true;
            continue;
        }
        if (ch != ',') continue;

        var next = index + 1;
        while (next < output.len and std.ascii.isWhitespace(output[next])) : (next += 1) {}
        if (next < output.len and (output[next] == '}' or output[next] == ']')) {
            output[index] = ' ';
        }
    }

    return output;
}

test "ConfigurationModel: dotted and nested settings are equivalent" {
    const allocator = std.testing.allocator;

    var dotted = try ConfigurationModel.fromJson(allocator, "{\"editor.tabSize\": 2}");
    defer dotted.deinit();
    var nested = try ConfigurationModel.fromJson(allocator, "{\"editor\": {\"tabSize\": 2}}");
    defer nested.deinit();

    try std.testing.expectEqual(@as(i64, 2), dotted.getValue("editor.tabSize").?.integer);
    try std.testing.expectEqual(@as(i64, 2), nested.getValue("editor.tabSize").?.integer);
    try std.testing.expectEqualStrings("editor.tabSize", dotted.getKeys()[0]);
    try std.testing.expectEqualStrings("editor", nested.getKeys()[0]);
}

test "ConfigurationModel: merge is recursive" {
    const allocator = std.testing.allocator;
    var defaults = try ConfigurationModel.fromJson(
        allocator,
        "{\"files\": {\"exclude\": {\"**/.git\": true, \"**/build\": true}}}",
    );
    defer defaults.deinit();
    var user = try ConfigurationModel.fromJson(
        allocator,
        "{\"files\": {\"exclude\": {\"**/build\": false}}, \"explorer.excludeGitIgnore\": true}",
    );
    defer user.deinit();

    const models = [_]*const ConfigurationModel{ &defaults, &user };
    var merged = try ConfigurationModel.merge(allocator, &models);
    defer merged.deinit();

    const exclude = merged.getValue("files.exclude").?;
    try std.testing.expect(exclude.object.get("**/.git").?.bool);
    try std.testing.expect(!exclude.object.get("**/build").?.bool);
    try std.testing.expect(merged.getValue("explorer.excludeGitIgnore").?.bool);
    try std.testing.expectEqual(@as(usize, 2), merged.getKeys().len);
}

test "ConfigurationModel: accepts comments and trailing commas" {
    const allocator = std.testing.allocator;
    var model = try ConfigurationModel.fromJson(allocator,
        \\{
        \\  // line comment
        \\  "editor.tabSize": 4,
        \\  /* block
        \\     comment */
        \\  "editor.insertSpaces": true,
        \\}
    );
    defer model.deinit();

    try std.testing.expectEqual(@as(i64, 4), model.getValue("editor.tabSize").?.integer);
    try std.testing.expect(model.getValue("editor.insertSpaces").?.bool);
}

test "ConfigurationModel: malformed json yields an empty model" {
    const allocator = std.testing.allocator;
    var model = try ConfigurationModel.fromJson(allocator, "{ nope");
    defer model.deinit();
    try std.testing.expect(model.isEmpty());
}
