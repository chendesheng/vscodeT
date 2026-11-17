// Port of `src/vs/platform/keybinding/common/keybindingResolver.ts`.
//
// Terminal adaptations:
// - Items are referenced by pointer (their lifetime is owned by the caller);
//   the resolver owns only its merged list, map keys and lookup lists.
// - `IContextKeyService` users in upstream (`lookupPrimaryKeybinding`) take the
//   narrower `IContext` and evaluate the `when` expression directly.
// - The optional upstream log callback is not ported; resolution is silent.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const contextkey = @import("../../contextkey/common/contextkey.zig");
const item_module = @import("resolvedKeybindingItem.zig");
const ResolvedKeybindingItem = item_module.ResolvedKeybindingItem;

pub const ResultKind = enum {
    /// No keybinding found for this sequence of chords.
    NoMatchingKb,
    /// Several keybindings have the given sequence of chords as a prefix.
    MoreChordsNeeded,
    /// A single keybinding was found to be dispatched/invoked.
    KbFound,
};

pub const ResolutionResult = struct {
    kind: ResultKind,
    commandId: ?[]const u8 = null,
    commandArgs: ?*const anyopaque = null,
    isBubble: bool = false,
};

pub const no_matching_kb = ResolutionResult{ .kind = .NoMatchingKb };
const more_chords_needed = ResolutionResult{ .kind = .MoreChordsNeeded };

fn kbFound(command_id: ?[]const u8, command_args: ?*const anyopaque, is_bubble: bool) ResolutionResult {
    return .{
        .kind = .KbFound,
        .commandId = command_id,
        .commandArgs = command_args,
        .isBubble = is_bubble,
    };
}

pub const ItemList = []const *const ResolvedKeybindingItem;

pub const Aliases = struct {
    defaults: ItemList,
    overrides: ItemList,
    ownedItems: ArrayList(*ResolvedKeybindingItem),

    /// Releases the returned slices and any synthesized alias items.
    pub fn deinit(self: *Aliases, allocator: Allocator) void {
        allocator.free(self.defaults);
        allocator.free(self.overrides);
        for (self.ownedItems.items) |item| {
            item.deinit(allocator);
            allocator.destroy(item);
        }
        self.ownedItems.deinit();
    }
};

pub const KeybindingAlias = struct {
    command: []const u8,
    source: []const u8,
    when: *const contextkey.Expr,
};

pub const KeybindingResolver = struct {
    allocator: Allocator,
    defaultKeybindings: ItemList,
    keybindings: ItemList,
    defaultBoundCommands: std.StringHashMap(bool),
    map: std.StringHashMap(ArrayList(*const ResolvedKeybindingItem)),
    lookupMap: std.StringHashMap(ArrayList(*const ResolvedKeybindingItem)),
    ownedKeys: ArrayList([]u8),

    pub fn init(allocator: Allocator, default_keybindings: ItemList, overrides: ItemList) !KeybindingResolver {
        var combined = ArrayList(?*const ResolvedKeybindingItem).init(allocator);
        defer combined.deinit();
        for (default_keybindings) |item| try combined.append(item);
        for (overrides) |item| try combined.append(item);

        var rules = ArrayList(*const ResolvedKeybindingItem).init(allocator);
        defer rules.deinit();
        for (combined.items) |maybe| {
            if (maybe) |item| try rules.append(item);
        }

        const merged = try handleRemovals(allocator, rules.items);
        errdefer allocator.free(merged);

        var resolver = KeybindingResolver{
            .allocator = allocator,
            .defaultKeybindings = default_keybindings,
            .keybindings = merged,
            .defaultBoundCommands = std.StringHashMap(bool).init(allocator),
            .map = std.StringHashMap(ArrayList(*const ResolvedKeybindingItem)).init(allocator),
            .lookupMap = std.StringHashMap(ArrayList(*const ResolvedKeybindingItem)).init(allocator),
            .ownedKeys = ArrayList([]u8).init(allocator),
        };
        errdefer resolver.deinit();

        for (default_keybindings) |item| {
            const command = item.command orelse continue;
            if (command.len > 0 and command[0] != '-') {
                try resolver.defaultBoundCommands.put(command, true);
            }
        }

        for (merged) |item| {
            if (item.chords.len == 0) continue; // unbound
            const when = if (item.when) |expression| expression.substituteConstants() else null;
            if (when) |expression| {
                if (std.meta.activeTag(expression.*) == .False) continue;
            }
            try resolver.addKeyPress(item.chords[0], item);
        }

        return resolver;
    }

    pub fn deinit(self: *KeybindingResolver) void {
        var map_iterator = self.map.valueIterator();
        while (map_iterator.next()) |list| list.deinit();
        self.map.deinit();

        var lookup_iterator = self.lookupMap.valueIterator();
        while (lookup_iterator.next()) |list| list.deinit();
        self.lookupMap.deinit();

        for (self.ownedKeys.items) |key| self.allocator.free(key);
        self.ownedKeys.deinit();

        self.defaultBoundCommands.deinit();
        self.allocator.free(self.keybindings);
        self.keybindings = &.{};
    }

    pub fn resolve(
        self: *KeybindingResolver,
        context: contextkey.IContext,
        current_chords: []const []const u8,
        keypress: []const u8,
    ) !ResolutionResult {
        var pressed = ArrayList([]const u8).init(self.allocator);
        defer pressed.deinit();
        try pressed.appendSlice(current_chords);
        try pressed.append(keypress);

        const kb_candidates = self.map.get(pressed.items[0]) orelse return no_matching_kb;

        var lookup = ArrayList(*const ResolvedKeybindingItem).init(self.allocator);
        defer lookup.deinit();

        if (pressed.items.len < 2) {
            try lookup.appendSlice(kb_candidates.items);
        } else {
            for (kb_candidates.items) |candidate| {
                if (pressed.items.len > candidate.chords.len) continue;
                var prefix_matches = true;
                var index: usize = 1;
                while (index < pressed.items.len) : (index += 1) {
                    if (!std.mem.eql(u8, candidate.chords[index], pressed.items[index])) {
                        prefix_matches = false;
                        break;
                    }
                }
                if (prefix_matches) try lookup.append(candidate);
            }
        }

        const result = self.findCommand(context, lookup.items) orelse return no_matching_kb;

        if (pressed.items.len < result.chords.len) return more_chords_needed;
        return kbFound(result.command, result.commandArgs, result.bubble);
    }

    fn findCommand(self: *KeybindingResolver, context: contextkey.IContext, matches: []const *const ResolvedKeybindingItem) ?*const ResolvedKeybindingItem {
        _ = self;
        var index = matches.len;
        while (index > 0) {
            index -= 1;
            const item = matches[index];
            if (!contextMatchesRules(context, item.when)) continue;
            return item;
        }
        return null;
    }

    fn addKeyPress(self: *KeybindingResolver, keypress: []const u8, item: *const ResolvedKeybindingItem) !void {
        const entry = try self.map.getOrPut(try self.internKey(keypress));
        if (!entry.found_existing) {
            entry.value_ptr.* = ArrayList(*const ResolvedKeybindingItem).init(self.allocator);
        }

        const conflicts = entry.value_ptr;
        var index = conflicts.items.len;
        while (index > 0) {
            index -= 1;
            const conflict = conflicts.items[index];
            if (conflict.command != null and item.command != null and std.mem.eql(u8, conflict.command.?, item.command.?)) continue;

            // Test if the shorter keybinding is a prefix of the longer one; it
            // shadows the longer one and is considered a conflict.
            var is_shorter_kb_prefix = true;
            var chord_index: usize = 1;
            while (chord_index < conflict.chords.len and chord_index < item.chords.len) : (chord_index += 1) {
                if (!std.mem.eql(u8, conflict.chords[chord_index], item.chords[chord_index])) {
                    is_shorter_kb_prefix = false;
                    break;
                }
            }
            if (!is_shorter_kb_prefix) continue;

            if (whenIsEntirelyIncluded(conflict.when, item.when)) {
                self.removeFromLookupMap(conflict);
            }
        }

        try conflicts.append(item);
        try self.addToLookupMap(item);
    }

    fn internKey(self: *KeybindingResolver, key: []const u8) ![]const u8 {
        const copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(copy);
        try self.ownedKeys.append(copy);
        return copy;
    }

    fn addToLookupMap(self: *KeybindingResolver, item: *const ResolvedKeybindingItem) !void {
        const command = item.command orelse return;
        const entry = try self.lookupMap.getOrPut(command);
        if (!entry.found_existing) {
            entry.value_ptr.* = ArrayList(*const ResolvedKeybindingItem).init(self.allocator);
        }
        try entry.value_ptr.append(item);
    }

    fn removeFromLookupMap(self: *KeybindingResolver, item: *const ResolvedKeybindingItem) void {
        const command = item.command orelse return;
        const list = self.lookupMap.getPtr(command) orelse return;
        for (list.items, 0..) |entry, index| {
            if (entry == item) {
                _ = list.orderedRemove(index);
                return;
            }
        }
    }

    pub fn whenIsEntirelyIncluded(a: ?*const contextkey.Expr, b: ?*const contextkey.Expr) bool {
        if (b == null) return true;
        if (std.meta.activeTag(b.?.*) == .True) return true;
        if (a == null) return false;
        if (std.meta.activeTag(a.?.*) == .True) return false;
        return contextkey.implies(a.?, b.?);
    }

    pub fn getDefaultKeybindings(self: *const KeybindingResolver) ItemList {
        return self.defaultKeybindings;
    }

    pub fn getKeybindings(self: *const KeybindingResolver) ItemList {
        return self.keybindings;
    }

    pub fn getDefaultBoundCommands(self: *KeybindingResolver) *std.StringHashMap(bool) {
        return &self.defaultBoundCommands;
    }

    /// Returns the matching items most-specific first. The caller frees the
    /// returned slice (items are borrowed).
    pub fn lookupKeybindings(self: *const KeybindingResolver, allocator: Allocator, command_id: []const u8) !ItemList {
        const items = self.lookupMap.get(command_id) orelse return &.{};
        if (items.items.len == 0) return &.{};
        const result = try allocator.alloc(*const ResolvedKeybindingItem, items.items.len);
        for (items.items, 0..) |item, index| {
            result[items.items.len - 1 - index] = item;
        }
        return result;
    }

    pub fn lookupPrimaryKeybinding(
        self: *const KeybindingResolver,
        command_id: []const u8,
        context: contextkey.IContext,
        enforce_context_check: bool,
    ) ?*const ResolvedKeybindingItem {
        const items = self.lookupMap.get(command_id) orelse return null;
        if (items.items.len == 0) return null;
        if (items.items.len == 1 and !enforce_context_check) return items.items[0];

        var index = items.items.len;
        while (index > 0) {
            index -= 1;
            const item = items.items[index];
            if (contextMatchesRules(context, item.when)) return item;
        }

        if (enforce_context_check) return null;
        return items.items[items.items.len - 1];
    }

    /// Removes `-command` rules. The caller owns the returned outer slice.
    pub fn handleRemovals(allocator: Allocator, rules: ItemList) !ItemList {
        var removals = std.StringHashMap(ArrayList(*const ResolvedKeybindingItem)).init(allocator);
        defer {
            var iterator = removals.valueIterator();
            while (iterator.next()) |list| list.deinit();
            removals.deinit();
        }

        for (rules) |rule| {
            const command = rule.command orelse continue;
            if (command.len == 0 or command[0] != '-') continue;
            const key = command[1..];
            const entry = try removals.getOrPut(key);
            if (!entry.found_existing) {
                entry.value_ptr.* = ArrayList(*const ResolvedKeybindingItem).init(allocator);
            }
            try entry.value_ptr.append(rule);
        }

        if (removals.count() == 0) {
            return try allocator.dupe(*const ResolvedKeybindingItem, rules);
        }

        var result = ArrayList(*const ResolvedKeybindingItem).init(allocator);
        errdefer result.deinit();

        for (rules) |rule| {
            const command = rule.command orelse {
                try result.append(rule);
                continue;
            };
            if (command.len == 0) {
                try result.append(rule);
                continue;
            }
            if (command[0] == '-') continue;

            const command_removals = removals.get(command) orelse {
                try result.append(rule);
                continue;
            };
            if (!rule.isDefault) {
                try result.append(rule);
                continue;
            }

            var is_removed = false;
            for (command_removals.items) |removal| {
                if (isTargetedForRemoval(rule, removal.chords, removal.when)) {
                    is_removed = true;
                    break;
                }
            }
            if (!is_removed) try result.append(rule);
        }

        return result.toOwnedSlice();
    }

    /// Binds each alias command to the keybindings of its source. The caller
    /// owns both returned outer slices.
    pub fn applyAliases(
        allocator: Allocator,
        defaults: ItemList,
        overrides: ItemList,
        aliases: []const KeybindingAlias,
    ) !Aliases {
        if (aliases.len == 0) {
            return .{
                .defaults = try allocator.dupe(*const ResolvedKeybindingItem, defaults),
                .overrides = try allocator.dupe(*const ResolvedKeybindingItem, overrides),
                .ownedItems = ArrayList(*ResolvedKeybindingItem).init(allocator),
            };
        }

        var source_removals = ArrayList(*const ResolvedKeybindingItem).init(allocator);
        defer source_removals.deinit();
        for (defaults) |rule| try appendIfSourceRemoval(&source_removals, rule, aliases);
        for (overrides) |rule| try appendIfSourceRemoval(&source_removals, rule, aliases);

        var owned_items = ArrayList(*ResolvedKeybindingItem).init(allocator);
        errdefer {
            for (owned_items.items) |item| {
                item.deinit(allocator);
                allocator.destroy(item);
            }
            owned_items.deinit();
        }
        const DefaultCtx = struct {
            allocator: Allocator,
            aliases: []const KeybindingAlias,
            source_removals: []const *const ResolvedKeybindingItem,
            owned_items: *ArrayList(*ResolvedKeybindingItem),
        };

        const inherit_context = DefaultCtx{
            .allocator = allocator,
            .aliases = aliases,
            .source_removals = source_removals.items,
            .owned_items = &owned_items,
        };

        var inherited_defaults = ArrayList(*const ResolvedKeybindingItem).init(allocator);
        errdefer inherited_defaults.deinit();
        var inherited_overrides = ArrayList(*const ResolvedKeybindingItem).init(allocator);
        errdefer inherited_overrides.deinit();
        try inheritRules(&inherited_defaults, defaults, inherit_context);
        try inheritRules(&inherited_overrides, overrides, inherit_context);

        var filtered_defaults = ArrayList(*const ResolvedKeybindingItem).init(allocator);
        errdefer filtered_defaults.deinit();
        for (inherited_defaults.items) |rule| {
            var removed_with_source = false;
            for (aliases) |alias| {
                if (rule.command == null or !std.mem.eql(u8, rule.command.?, alias.command)) continue;
                for (source_removals.items) |removal| {
                    if (removal.command == null) continue;
                    const expected = try std.fmt.allocPrint(allocator, "-{s}", .{alias.source});
                    defer allocator.free(expected);
                    if (!std.mem.eql(u8, removal.command.?, expected)) continue;
                    if (isTargetedForRemoval(rule, removal.chords, null)) {
                        removed_with_source = true;
                        break;
                    }
                }
                if (removed_with_source) break;
            }
            if (!removed_with_source) try filtered_defaults.append(rule);
        }

        return .{
            .defaults = try filtered_defaults.toOwnedSlice(),
            .overrides = try inherited_overrides.toOwnedSlice(),
            .ownedItems = owned_items,
        };
    }

    fn appendIfSourceRemoval(
        list: *ArrayList(*const ResolvedKeybindingItem),
        rule: *const ResolvedKeybindingItem,
        aliases: []const KeybindingAlias,
    ) !void {
        for (aliases) |alias| {
            if (rule.command == null) continue;
            const expected = try std.fmt.allocPrint(list.allocator, "-{s}", .{alias.source});
            defer list.allocator.free(expected);
            if (std.mem.eql(u8, rule.command.?, expected)) {
                try list.append(rule);
                return;
            }
        }
    }
};

fn inheritRules(
    result: *ArrayList(*const ResolvedKeybindingItem),
    rules: ItemList,
    context: anytype,
) !void {
    for (rules) |rule| {
        try result.append(rule);
        for (context.aliases) |alias| {
            if (rule.command != null and std.mem.eql(u8, rule.command.?, alias.source)) {
                const alias_item = try context.allocator.create(ResolvedKeybindingItem);
                errdefer context.allocator.destroy(alias_item);
                alias_item.* = try ResolvedKeybindingItem.init(
                    context.allocator,
                    rule.resolvedKeybinding,
                    alias.command,
                    null,
                    alias.when,
                    true,
                    rule.extensionId,
                    rule.isBuiltinExtension,
                    false,
                );
                try context.owned_items.append(alias_item);
                try result.append(alias_item);
            }
        }
    }
}

fn contextMatchesRules(context: contextkey.IContext, rules: ?*const contextkey.Expr) bool {
    const expression = rules orelse return true;
    return expression.evaluate(context);
}

fn isTargetedForRemoval(
    default_kb: *const ResolvedKeybindingItem,
    keypress: []const []const u8,
    when: ?*const contextkey.Expr,
) bool {
    if (keypress.len > 0) {
        var index: usize = 0;
        while (index < keypress.len) : (index += 1) {
            if (index >= default_kb.chords.len) return false;
            if (!std.mem.eql(u8, keypress[index], default_kb.chords[index])) return false;
        }
    }

    // `true` means always, as does `undefined`, so they are equivalent.
    if (when) |expression| {
        if (std.meta.activeTag(expression.*) != .True) {
            const default_when = default_kb.when orelse return false;
            const default_substituted = default_when.substituteConstants();
            const removal_substituted = expression.substituteConstants();
            if (!KeybindingResolver.whenIsEntirelyIncluded(default_substituted, removal_substituted)) return false;
        }
    }
    return true;
}
