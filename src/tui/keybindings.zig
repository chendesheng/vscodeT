// Terminal host over the ported keybinding registry/resolver.
//
// Upstream's `AbstractKeybindingService` is browser-shaped (status messages,
// telemetry, IME, document focus). The TUI keeps the same resolution pipeline
// (registry -> resolver -> command) but exposes a direct `dispatch` call for a
// decoded `ui.input.KeyEvent`. Terminal adaptation:
// - `Alt` maps to `alt`, there is no terminal `meta`/Windows key.
// - Shift is taken from the decoded modifiers; uppercase characters are not
//   re-interpreted (the editor handles text input separately).
// - Pending chords are stored as owned dispatch strings until the sequence
//   resolves or is reset.
const std = @import("std");
const Allocator = std.mem.Allocator;
const input = @import("ui").input;
const key_codes = @import("../vs/base/common/keyCodes.zig");
const key_bindings = @import("../vs/base/common/keybindings.zig");
const platform = @import("../vs/base/common/platform.zig");
const contextkey = @import("../vs/platform/contextkey/common/contextkey.zig");
const commands = @import("../vs/platform/commands/common/commands.zig");
const registry_module = @import("../vs/platform/keybinding/common/keybindingsRegistry.zig");
const resolver_module = @import("../vs/platform/keybinding/common/keybindingResolver.zig");
const us_module = @import("../vs/platform/keybinding/common/usLayoutResolvedKeybinding.zig");
const item_module = @import("../vs/platform/keybinding/common/resolvedKeybindingItem.zig");
const ResolvedKeybindingItem = item_module.ResolvedKeybindingItem;
const USLayoutResolvedKeybinding = us_module.USLayoutResolvedKeybinding;

pub const TuiKeybindings = struct {
    allocator: Allocator,
    registry: registry_module.KeybindingsRegistry,
    resolver: resolver_module.KeybindingResolver,
    /// `KeybindingResolver` borrows the slice of resolved items below.
    defaults: []const *const ResolvedKeybindingItem,
    resolvedKeybindings: std.array_list.Managed(*USLayoutResolvedKeybinding),
    resolvedItems: std.array_list.Managed(*ResolvedKeybindingItem),
    pending: std.array_list.Managed([]u8),
    commands: ?*commands.CommandRegistry,

    pub fn init(
        allocator: Allocator,
        rules: []const registry_module.IKeybindingRule,
        command_registry: ?*commands.CommandRegistry,
    ) !TuiKeybindings {
        var registry = registry_module.KeybindingsRegistry.init(allocator);
        errdefer registry.deinit();
        if (command_registry) |value| registry.setCommandRegistry(value);

        for (rules) |rule| {
            var registration = try registry.registerKeybindingRule(rule);
            registration.disposed = true; // owned for the host lifetime
        }

        const registry_items = try registry.getDefaultKeybindings(allocator);
        defer allocator.free(registry_items);

        var resolved_keybindings = std.array_list.Managed(*USLayoutResolvedKeybinding).init(allocator);
        errdefer {
            for (resolved_keybindings.items) |resolved| {
                resolved.deinit();
                allocator.destroy(resolved);
            }
            resolved_keybindings.deinit();
        }
        var resolved_items = std.array_list.Managed(*ResolvedKeybindingItem).init(allocator);
        errdefer {
            for (resolved_items.items) |item| {
                item.deinit(allocator);
                allocator.destroy(item);
            }
            resolved_items.deinit();
        }
        var defaults = std.array_list.Managed(*const ResolvedKeybindingItem).init(allocator);
        errdefer defaults.deinit();

        for (registry_items) |registry_item| {
            const keybinding = registry_item.keybinding orelse continue;
            const resolved = (try USLayoutResolvedKeybinding.resolveKeybinding(allocator, keybinding, platform.OS)) orelse continue;
            const resolved_ptr = try allocator.create(USLayoutResolvedKeybinding);
            errdefer allocator.destroy(resolved_ptr);
            resolved_ptr.* = resolved;
            try resolved_keybindings.append(resolved_ptr);

            const item = try allocator.create(ResolvedKeybindingItem);
            errdefer allocator.destroy(item);
            item.* = try ResolvedKeybindingItem.init(
                allocator,
                resolved_ptr.interface(),
                registry_item.command,
                registry_item.commandArgs,
                registry_item.when,
                true,
                registry_item.extensionId,
                registry_item.isBuiltinExtension,
                false,
            );
            try resolved_items.append(item);
            try defaults.append(item);
        }

        const defaults_owned = try defaults.toOwnedSlice();
        errdefer allocator.free(defaults_owned);

        var resolver = try resolver_module.KeybindingResolver.init(allocator, defaults_owned, &.{});
        errdefer resolver.deinit();

        return .{
            .allocator = allocator,
            .registry = registry,
            .resolver = resolver,
            .defaults = defaults_owned,
            .resolvedKeybindings = resolved_keybindings,
            .resolvedItems = resolved_items,
            .pending = std.array_list.Managed([]u8).init(allocator),
            .commands = command_registry,
        };
    }

    pub fn deinit(self: *TuiKeybindings) void {
        self.clearPending();
        self.pending.deinit();
        self.resolver.deinit();
        self.allocator.free(self.defaults);
        for (self.resolvedItems.items) |item| {
            item.deinit(self.allocator);
            self.allocator.destroy(item);
        }
        self.resolvedItems.deinit();
        for (self.resolvedKeybindings.items) |resolved| {
            resolved.deinit();
            self.allocator.destroy(resolved);
        }
        self.resolvedKeybindings.deinit();
        self.registry.deinit();
    }

    pub fn clearPending(self: *TuiKeybindings) void {
        for (self.pending.items) |chord| self.allocator.free(chord);
        self.pending.clearRetainingCapacity();
    }

    pub fn inChordMode(self: *const TuiKeybindings) bool {
        return self.pending.items.len > 0;
    }

    /// Resolves and, when a command registry is attached, executes the command.
    /// Returns the command id for a completed keybinding, or null while a chord
    /// is incomplete or when nothing matches.
    pub fn dispatch(self: *TuiKeybindings, event: input.KeyEvent, context: contextkey.IContext) !?[]const u8 {
        const chord = (try dispatchString(self.allocator, event)) orelse {
            self.clearPending();
            return null;
        };
        defer self.allocator.free(chord);

        const result = try self.resolver.resolve(context, self.pending.items, chord);
        switch (result.kind) {
            .MoreChordsNeeded => {
                try self.pending.append(try self.allocator.dupe(u8, chord));
                return null;
            },
            .NoMatchingKb => {
                self.clearPending();
                return null;
            },
            .KbFound => {
                self.clearPending();
                const command_id = result.commandId orelse return null;
                if (self.commands) |command_registry| {
                    _ = try command_registry.execute(command_id);
                }
                return command_id;
            },
        }
    }
};

/// Context with no defined keys, for hosts that do not model context keys yet.
pub const empty_context = contextkey.IContext{
    .context = @ptrFromInt(1),
    .get_value = struct {
        fn getValue(_: *anyopaque, _: []const u8) contextkey.ContextKeyValue {
            return .undefined_value;
        }
    }.getValue,
};

/// `ctrl+shift+alt+key` dispatch string for a decoded terminal key, or null for
/// keys that cannot participate in a shortcut (bulk text/paste markers).
pub fn dispatchString(allocator: Allocator, event: input.KeyEvent) !?[]u8 {
    const key_code = keyCodeFor(event) orelse return null;
    // Terminals deliver shifted letters as uppercase characters; infer shift so
    // `Shift+B` and `B` do not collapse to the same chord.
    const uppercase = switch (event.key) {
        .char => |codepoint| codepoint >= 'A' and codepoint <= 'Z',
        else => false,
    };
    const chord = key_bindings.KeyCodeChord.init(
        event.mods.ctrl,
        event.mods.shift or uppercase or std.meta.activeTag(event.key) == .backtab,
        event.mods.alt,
        false,
        key_code,
    );
    return us_module.USLayoutResolvedKeybinding.getDispatchStr(allocator, chord);
}

pub fn keyCodeFor(event: input.KeyEvent) ?key_codes.KeyCode {
    return switch (event.key) {
        .enter => .Enter,
        .tab, .backtab => .Tab,
        .escape => .Escape,
        .backspace => .Backspace,
        .delete => .Delete,
        .insert => .Insert,
        .left => .LeftArrow,
        .right => .RightArrow,
        .up => .UpArrow,
        .down => .DownArrow,
        .home => .Home,
        .end => .End,
        .page_up => .PageUp,
        .page_down => .PageDown,
        .char => |codepoint| charKeyCode(codepoint),
        .text, .paste_start, .paste_end => null,
    };
}

fn charKeyCode(codepoint: u21) ?key_codes.KeyCode {
    if (codepoint > 127) return null;
    const character: u8 = @intCast(codepoint);

    if (character >= 'a' and character <= 'z') {
        return @fromBackingInt(@intCast(@backingInt(key_codes.KeyCode.KeyA) + (character - 'a')));
    }
    if (character >= 'A' and character <= 'Z') {
        return @fromBackingInt(@intCast(@backingInt(key_codes.KeyCode.KeyA) + (character - 'A')));
    }
    if (character >= '0' and character <= '9') {
        return @fromBackingInt(@intCast(@backingInt(key_codes.KeyCode.Digit0) + (character - '0')));
    }
    return switch (character) {
        ' ' => .Space,
        ';' => .Semicolon,
        '=' => .Equal,
        ',' => .Comma,
        '-' => .Minus,
        '.' => .Period,
        '/' => .Slash,
        '`' => .Backquote,
        '[' => .BracketLeft,
        '\\' => .Backslash,
        ']' => .BracketRight,
        '\'' => .Quote,
        else => null,
    };
}

const TestContext = struct {
    enabled: bool = false,

    fn context(self: *TestContext) contextkey.IContext {
        return .{ .context = self, .get_value = getValue };
    }

    fn getValue(context_ptr: *anyopaque, key: []const u8) contextkey.ContextKeyValue {
        const self: *TestContext = @ptrCast(@alignCast(context_ptr));
        if (std.mem.eql(u8, key, "enabled")) return .{ .boolean = self.enabled };
        return .undefined_value;
    }
};

test "dispatch resolves a simple shortcut" {
    const allocator = std.testing.allocator;
    const rules = [_]registry_module.IKeybindingRule{.{
        .id = "save",
        .weight = 0,
        .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyS) },
    }};
    var host = try TuiKeybindings.init(allocator, &rules, null);
    defer host.deinit();

    var context = TestContext{};
    const event = input.KeyEvent{ .key = .{ .char = 's' }, .mods = .{ .ctrl = true } };
    const command = try host.dispatch(event, context.context());
    try std.testing.expect(command != null);
    try std.testing.expectEqualStrings("save", command.?);
    try std.testing.expect(!host.inChordMode());

    const plain = input.KeyEvent{ .key = .{ .char = 's' } };
    try std.testing.expect((try host.dispatch(plain, context.context())) == null);
}

test "dispatch respects when clauses" {
    const allocator = std.testing.allocator;
    var factory = contextkey.ContextKeyExpr.init(allocator);
    defer factory.deinit();

    const rules = [_]registry_module.IKeybindingRule{.{
        .id = "enabled.command",
        .weight = 0,
        .when = try factory.has("enabled"),
        .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyE) },
    }};
    var host = try TuiKeybindings.init(allocator, &rules, null);
    defer host.deinit();

    var context = TestContext{};
    const event = input.KeyEvent{ .key = .{ .char = 'e' }, .mods = .{ .ctrl = true } };
    try std.testing.expect((try host.dispatch(event, context.context())) == null);

    context.enabled = true;
    const command = try host.dispatch(event, context.context());
    try std.testing.expectEqualStrings("enabled.command", command.?);
}

test "dispatch tracks multi-chord keybindings" {
    const allocator = std.testing.allocator;
    const rules = [_]registry_module.IKeybindingRule{.{
        .id = "comment",
        .weight = 0,
        .bindings = .{ .primary = key_codes.KeyChord(
            key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyK),
            key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyC),
        ) },
    }};
    var host = try TuiKeybindings.init(allocator, &rules, null);
    defer host.deinit();

    var context = TestContext{};
    const first = input.KeyEvent{ .key = .{ .char = 'k' }, .mods = .{ .ctrl = true } };
    const second = input.KeyEvent{ .key = .{ .char = 'c' }, .mods = .{ .ctrl = true } };

    try std.testing.expect((try host.dispatch(first, context.context())) == null);
    try std.testing.expect(host.inChordMode());
    const command = try host.dispatch(second, context.context());
    try std.testing.expectEqualStrings("comment", command.?);
    try std.testing.expect(!host.inChordMode());
}

test "dispatch executes through the command registry" {
    const allocator = std.testing.allocator;
    const Counter = struct {
        count: usize = 0,
        fn run(context: *anyopaque) anyerror!void {
            const counter: *@This() = @ptrCast(@alignCast(context));
            counter.count += 1;
        }
    };
    var counter = Counter{};
    var command_registry = commands.CommandRegistry.init(allocator);
    defer command_registry.deinit();
    try command_registry.register(.{ .id = "increment", .context = &counter, .run = Counter.run });

    const rules = [_]registry_module.IKeybindingRule{.{
        .id = "increment",
        .weight = 0,
        .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyI) },
    }};
    var host = try TuiKeybindings.init(allocator, &rules, &command_registry);
    defer host.deinit();

    var context = TestContext{};
    _ = try host.dispatch(.{ .key = .{ .char = 'i' }, .mods = .{ .ctrl = true } }, context.context());
    try std.testing.expectEqual(@as(usize, 1), counter.count);
}

test "dispatch keys cover navigation and punctuation" {
    const allocator = std.testing.allocator;
    const left = try dispatchString(allocator, .{ .key = .left });
    defer if (left) |value| allocator.free(value);
    try std.testing.expectEqualStrings("LeftArrow", left.?);

    const quote = try dispatchString(allocator, .{ .key = .{ .char = '\'' }, .mods = .{ .ctrl = true } });
    defer if (quote) |value| allocator.free(value);
    try std.testing.expectEqualStrings("ctrl+'", quote.?);

    const uppercase = try dispatchString(allocator, .{ .key = .{ .char = 'B' }, .mods = .{ .alt = true } });
    defer if (uppercase) |value| allocator.free(value);
    try std.testing.expectEqualStrings("shift+alt+B", uppercase.?);

    const text = try dispatchString(allocator, .{ .key = .{ .text = "abc" } });
    try std.testing.expect(text == null);

    const backtab = try dispatchString(allocator, .{ .key = .backtab });
    defer if (backtab) |value| allocator.free(value);
    try std.testing.expectEqualStrings("shift+Tab", backtab.?);
}
