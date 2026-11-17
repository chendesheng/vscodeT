// Port of `src/vs/platform/keybinding/common/keybindingsRegistry.ts`.
//
// Terminal adaptations:
// - There is no platform `Registry` extension point or global singleton; the
//   terminal owns one `KeybindingsRegistry` instance. Command+keybinding rules
//   can register into an explicit `CommandRegistry`.
// - Disposables become `Registration.dispose`, removing every item/rule with
//   the registration's group id.
// - Decoded keybindings are owned by the registry items (`IKeybindingItem.deinit`).
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const key_codes = @import("../../../base/common/keyCodes.zig");
const key_bindings = @import("../../../base/common/keybindings.zig");
const platform = @import("../../../base/common/platform.zig");
const contextkey = @import("../../contextkey/common/contextkey.zig");
const commands = @import("../../commands/common/commands.zig");

const Keybinding = key_bindings.Keybinding;
const KeybindingAlias = @import("keybindingResolver.zig").KeybindingAlias;

pub const KeybindingWeight = enum(i64) {
    EditorCore = 0,
    EditorContrib = 100,
    WorkbenchContrib = 200,
    SessionsContrib = 250,
    BuiltinExtension = 300,
    ExternalExtension = 400,
};

pub const PlatformBinding = struct {
    primary: u32,
    secondary: ?[]const u32 = null,
};

pub const IKeybindings = struct {
    primary: ?u32 = null,
    secondary: ?[]const u32 = null,
    win: ?PlatformBinding = null,
    linux: ?PlatformBinding = null,
    mac: ?PlatformBinding = null,
};

pub const IKeybindingRule = struct {
    id: []const u8,
    weight: i64,
    args: ?*const anyopaque = null,
    when: ?*const contextkey.Expr = null,
    bindings: IKeybindings = .{},
};

pub const IKeybindingItem = struct {
    keybinding: ?Keybinding,
    command: ?[]const u8,
    commandArgs: ?*const anyopaque,
    when: ?*const contextkey.Expr,
    weight1: i64,
    weight2: i64,
    extensionId: ?[]const u8 = null,
    isBuiltinExtension: bool = false,
    owned_chords: bool = true,

    pub fn deinit(self: *IKeybindingItem, allocator: Allocator) void {
        if (self.owned_chords) {
            if (self.keybinding) |keybinding| key_bindings.freeChords(allocator, keybinding);
        }
        self.keybinding = null;
    }
};

pub const IExtensionKeybindingRule = struct {
    keybinding: ?Keybinding,
    id: []const u8,
    args: ?*const anyopaque = null,
    weight: i64,
    when: ?*const contextkey.Expr = null,
    extension_id: ?[]const u8 = null,
    is_builtin_extension: bool = false,
};

pub const Registration = struct {
    registry: *KeybindingsRegistry,
    group: u64,
    disposed: bool = false,

    pub fn dispose(self: *Registration) void {
        if (self.disposed) return;
        self.disposed = true;
        self.registry.unregisterGroup(self.group);
    }
};

const ItemEntry = struct {
    group: u64,
    item: *IKeybindingItem,
};

const RuleEntry = struct {
    group: u64,
    rule: IKeybindingRule,
};

pub const KeybindingsRegistry = struct {
    allocator: Allocator,
    next_group: u64 = 0,
    items: ArrayList(ItemEntry),
    rules: ArrayList(RuleEntry),
    extension_items: ArrayList(*IKeybindingItem),
    aliases: ArrayList(KeybindingAlias),
    commands: ?*commands.CommandRegistry = null,

    pub fn init(allocator: Allocator) KeybindingsRegistry {
        return .{
            .allocator = allocator,
            .items = ArrayList(ItemEntry).init(allocator),
            .rules = ArrayList(RuleEntry).init(allocator),
            .extension_items = ArrayList(*IKeybindingItem).init(allocator),
            .aliases = ArrayList(KeybindingAlias).init(allocator),
        };
    }

    pub fn deinit(self: *KeybindingsRegistry) void {
        for (self.items.items) |entry| {
            entry.item.deinit(self.allocator);
            self.allocator.destroy(entry.item);
        }
        self.items.deinit();
        for (self.extension_items.items) |item| {
            item.deinit(self.allocator);
            self.allocator.destroy(item);
        }
        self.extension_items.deinit();
        self.rules.deinit();
        self.aliases.deinit();
    }

    pub fn setCommandRegistry(self: *KeybindingsRegistry, registry: *commands.CommandRegistry) void {
        self.commands = registry;
    }

    fn nextGroup(self: *KeybindingsRegistry) u64 {
        self.next_group += 1;
        return self.next_group;
    }

    fn bindToPlatform(rule: IKeybindingRule, os: platform.OperatingSystem) struct { primary: ?u32, secondary: ?[]const u32 } {
        const binding: ?PlatformBinding = switch (os) {
            .Windows => rule.bindings.win,
            .Macintosh => rule.bindings.mac,
            .Linux => rule.bindings.linux,
        };
        if (binding) |value| {
            return .{ .primary = value.primary, .secondary = value.secondary };
        }
        return .{ .primary = rule.bindings.primary, .secondary = rule.bindings.secondary };
    }

    /// Registers the rule for the current platform (decoding primary and
    /// secondary bindings) and keeps the rule for other platforms.
    pub fn registerKeybindingRule(self: *KeybindingsRegistry, rule: IKeybindingRule) !Registration {
        const group = self.nextGroup();
        errdefer self.unregisterGroup(group);

        try self.registerRule(group, rule, platform.OS);

        try self.rules.append(.{ .group = group, .rule = rule });
        return .{ .registry = self, .group = group };
    }

    pub fn registerCommandAndKeybindingRule(
        self: *KeybindingsRegistry,
        rule: IKeybindingRule,
        command: commands.Command,
    ) !Registration {
        const registration = try self.registerKeybindingRule(rule);
        errdefer {
            var mutable = registration;
            mutable.dispose();
        }
        if (self.commands) |registry| {
            try registry.register(command);
        }
        return registration;
    }

    fn registerRule(self: *KeybindingsRegistry, group: u64, rule: IKeybindingRule, os: platform.OperatingSystem) !void {
        const actual = bindToPlatform(rule, os);

        if (actual.primary) |primary| {
            if (try key_bindings.decodeKeybinding(self.allocator, .{ .single = primary }, os)) |keybinding| {
                try self.appendItem(group, keybinding, rule, 0);
            }
        }

        if (actual.secondary) |secondary| {
            for (secondary, 0..) |encoded, index| {
                if (try key_bindings.decodeKeybinding(self.allocator, .{ .single = encoded }, os)) |keybinding| {
                    try self.appendItem(group, keybinding, rule, -@as(i64, @intCast(index)) - 1);
                }
            }
        }
    }

    fn appendItem(self: *KeybindingsRegistry, group: u64, keybinding: Keybinding, rule: IKeybindingRule, weight2: i64) !void {
        const item = try self.allocator.create(IKeybindingItem);
        errdefer self.allocator.destroy(item);
        item.* = .{
            .keybinding = keybinding,
            .command = rule.id,
            .commandArgs = rule.args,
            .when = rule.when,
            .weight1 = rule.weight,
            .weight2 = weight2,
        };
        try self.items.append(.{ .group = group, .item = item });
    }

    /// Replaces the extension keybindings. The registry takes ownership of the
    /// decoded chords (`keybinding` must be allocated).
    pub fn setExtensionKeybindings(self: *KeybindingsRegistry, rules: []const IExtensionKeybindingRule) !void {
        for (self.extension_items.items) |item| {
            item.deinit(self.allocator);
            self.allocator.destroy(item);
        }
        self.extension_items.clearRetainingCapacity();

        for (rules) |rule| {
            const keybinding = rule.keybinding orelse continue;
            const item = try self.allocator.create(IKeybindingItem);
            errdefer self.allocator.destroy(item);
            item.* = .{
                .keybinding = keybinding,
                .command = rule.id,
                .commandArgs = rule.args,
                .when = rule.when,
                .weight1 = rule.weight,
                .weight2 = 0,
                .extensionId = rule.extension_id,
                .isBuiltinExtension = rule.is_builtin_extension orelse false,
            };
            try self.extension_items.append(item);
        }
    }

    pub fn registerKeybindingAlias(self: *KeybindingsRegistry, alias: KeybindingAlias) !void {
        try self.aliases.append(alias);
    }

    pub fn getKeybindingAliases(self: *const KeybindingsRegistry) []const KeybindingAlias {
        return self.aliases.items;
    }

    fn unregisterGroup(self: *KeybindingsRegistry, group: u64) void {
        var index: usize = 0;
        while (index < self.items.items.len) {
            if (self.items.items[index].group == group) {
                const entry = self.items.orderedRemove(index);
                entry.item.deinit(self.allocator);
                self.allocator.destroy(entry.item);
            } else {
                index += 1;
            }
        }
        index = 0;
        while (index < self.rules.items.len) {
            if (self.rules.items[index].group == group) {
                _ = self.rules.orderedRemove(index);
            } else {
                index += 1;
            }
        }
    }

    /// Returns the merged default keybindings sorted by weight/command.
    /// Items are borrowed; the caller frees only the outer slice.
    pub fn getDefaultKeybindings(self: *KeybindingsRegistry, allocator: Allocator) ![]const *const IKeybindingItem {
        var result = ArrayList(*const IKeybindingItem).init(allocator);
        errdefer result.deinit();
        for (self.items.items) |entry| try result.append(entry.item);
        for (self.extension_items.items) |item| try result.append(item);
        std.mem.sort(*const IKeybindingItem, result.items, {}, itemLessThan);
        return result.toOwnedSlice();
    }

    /// Resolves the rules for a specific OS (used by tests and other hosts).
    /// The caller owns the returned items and calls `deinitKeybindings`.
    pub fn getDefaultKeybindingsForOS(
        self: *KeybindingsRegistry,
        allocator: Allocator,
        os: platform.OperatingSystem,
    ) ![]const IKeybindingItem {
        var result = ArrayList(IKeybindingItem).init(allocator);
        errdefer {
            for (result.items) |*item| item.deinit(allocator);
            result.deinit();
        }

        for (self.rules.items) |entry| {
            const rule = entry.rule;
            const actual = bindToPlatform(rule, os);
            if (actual.primary) |primary| {
                if (try key_bindings.decodeKeybinding(allocator, .{ .single = primary }, os)) |keybinding| {
                    try result.append(.{
                        .keybinding = keybinding,
                        .command = rule.id,
                        .commandArgs = rule.args,
                        .when = rule.when,
                        .weight1 = rule.weight,
                        .weight2 = 0,
                    });
                }
            }
            if (actual.secondary) |secondary| {
                for (secondary, 0..) |encoded, index| {
                    if (try key_bindings.decodeKeybinding(allocator, .{ .single = encoded }, os)) |keybinding| {
                        try result.append(.{
                            .keybinding = keybinding,
                            .command = rule.id,
                            .commandArgs = rule.args,
                            .when = rule.when,
                            .weight1 = rule.weight,
                            .weight2 = -@as(i64, @intCast(index)) - 1,
                        });
                    }
                }
            }
        }

        std.mem.sort(IKeybindingItem, result.items, {}, itemValueLessThan);
        return result.toOwnedSlice();
    }
};

/// Frees a list returned by `getDefaultKeybindingsForOS`.
pub fn deinitKeybindings(allocator: Allocator, keybindings: []const IKeybindingItem) void {
    for (@constCast(keybindings)) |*item| item.deinit(allocator);
    allocator.free(keybindings);
}

fn itemLessThan(_: void, a: *const IKeybindingItem, b: *const IKeybindingItem) bool {
    return itemOrder(a, b) < 0;
}

fn itemValueLessThan(_: void, a: IKeybindingItem, b: IKeybindingItem) bool {
    return itemOrder(&a, &b) < 0;
}

fn itemOrder(a: *const IKeybindingItem, b: *const IKeybindingItem) i32 {
    if (a.weight1 != b.weight1) return if (a.weight1 < b.weight1) -1 else 1;
    if (a.command != null and b.command != null) {
        const order = std.mem.order(u8, a.command.?, b.command.?);
        if (order != .eq) return if (order == .lt) -1 else 1;
    }
    if (a.weight2 != b.weight2) return if (a.weight2 < b.weight2) -1 else 1;
    return 0;
}

test "registerKeybindingRule decodes primary and secondary and disposes" {
    const allocator = std.testing.allocator;
    var registry = KeybindingsRegistry.init(allocator);
    defer registry.deinit();

    var registration = try registry.registerKeybindingRule(.{
        .id = "test.command",
        .weight = @backingInt(KeybindingWeight.WorkbenchContrib),
        .bindings = .{
            .primary = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyA),
            .secondary = &.{@backingInt(key_codes.KeyCode.KeyB)},
        },
    });
    defer registration.dispose();

    const all = try registry.getDefaultKeybindings(allocator);
    defer allocator.free(all);
    try std.testing.expectEqual(@as(usize, 2), all.len);
    try std.testing.expectEqualStrings("test.command", all[0].command.?);

    registration.dispose();
    const after = try registry.getDefaultKeybindings(allocator);
    defer allocator.free(after);
    try std.testing.expectEqual(@as(usize, 0), after.len);
}

test "platform-specific binding overrides the generic one" {
    const allocator = std.testing.allocator;
    var registry = KeybindingsRegistry.init(allocator);
    defer registry.deinit();

    var registration = try registry.registerKeybindingRule(.{
        .id = "test.platform",
        .weight = 0,
        .bindings = .{
            .primary = @backingInt(key_codes.KeyCode.KeyA),
            .win = .{ .primary = @backingInt(key_codes.KeyCode.KeyB) },
        },
    });
    defer registration.dispose();

    const windows = try registry.getDefaultKeybindingsForOS(allocator, .Windows);
    defer deinitKeybindings(allocator, windows);
    try std.testing.expectEqual(@as(usize, 1), windows.len);
    try std.testing.expectEqualStrings("B", switch (windows[0].keybinding.?.chords[0]) {
        .key_code => |chord| key_codes.KeyCodeUtils.toString(chord.key_code),
        .scan_code => unreachable,
    });

    const linux = try registry.getDefaultKeybindingsForOS(allocator, .Linux);
    defer deinitKeybindings(allocator, linux);
    try std.testing.expectEqualStrings("A", switch (linux[0].keybinding.?.chords[0]) {
        .key_code => |chord| key_codes.KeyCodeUtils.toString(chord.key_code),
        .scan_code => unreachable,
    });
}
