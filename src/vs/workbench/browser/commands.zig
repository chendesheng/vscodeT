// Workbench command registration and the CommandPalette pick source. The
// palette reads MenuRegistry and the contributed context expressions. The
// executable handler and registration order come solely from CommandsRegistry.
const std = @import("std");
const Allocator = std.mem.Allocator;
const platform_commands = @import("../../platform/commands/common/commands.zig");
const commands_quick_access = @import("../../platform/quickinput/browser/commandsQuickAccess.zig");
const CommandPick = commands_quick_access.CommandPick;
const CommandPickSource = commands_quick_access.CommandPickSource;

const actions = @import("../../platform/actions/common/actions.zig");
const contextkey = @import("../../platform/contextkey/common/contextkey.zig");
const KeybindingsRegistry = @import("../../platform/keybinding/common/keybindingsRegistry.zig").KeybindingsRegistry;
const InstantiationService = @import("../../platform/instantiation/common/instantiationService.zig").InstantiationService;
const palette = actions.menu_ids.CommandPalette;

/// Owns a registration's menu/action disposables. The executable command
/// and its callback live only in CommandsRegistry, not in a second table.
pub const CommandRegistration = struct {
    descriptor: actions.ICommandAction,
    action_registration: ?*actions.ActionRegistration = null,
    palette_registration: ?actions.MenuRegistry.Registration = null,
    requires_editor: bool = false,

    pub fn isInPalette(self: CommandRegistration) bool {
        return if (self.action_registration) |action| action.palette_item != null else self.palette_registration != null;
    }
};

pub const CommandOptions = struct {
    show_in_palette: bool = true,
    requires_editor: bool = false,
};

pub const CommandRegistry = struct {
    allocator: Allocator,
    registrations: std.StringHashMapUnmanaged(CommandRegistration) = .empty,
    menus: actions.MenuRegistry,
    bindings: KeybindingsRegistry,
    context_keys: ?contextkey.IContextKeyService = null,
    platform: platform_commands.CommandRegistry,
    editor_available_context: ?*anyopaque = null,
    is_editor_available: ?*const fn (context: *anyopaque) bool = null,

    pub fn init(allocator: Allocator) CommandRegistry {
        return .{
            .allocator = allocator,
            .menus = actions.MenuRegistry.init(allocator),
            .bindings = KeybindingsRegistry.init(allocator),
            .platform = platform_commands.CommandRegistry.init(allocator),
        };
    }

    pub fn deinit(self: *CommandRegistry) void {
        var iterator = self.registrations.valueIterator();
        while (iterator.next()) |registration| if (registration.action_registration) |action| action.dispose();
        self.bindings.deinit();
        self.platform.deinit();
        self.registrations.deinit(self.allocator);
        self.menus.deinit();
    }

    pub fn setEditorAvailability(
        self: *CommandRegistry,
        context: *anyopaque,
        callback: *const fn (context: *anyopaque) bool,
    ) void {
        self.editor_available_context = context;
        self.is_editor_available = callback;
    }

    pub fn registerAction(self: *CommandRegistry, instantiation: *InstantiationService, desc: actions.Action2) !void {
        try self.registrations.ensureUnusedCapacity(self.allocator, 1);
        const registration = try actions.registerAction2(.{
            .instantiation = instantiation,
            .commands = &self.platform,
            .menus = &self.menus,
            .keybindings = &self.bindings,
        }, desc);
        self.registrations.putAssumeCapacity(desc.command.id, .{ .descriptor = desc.command, .action_registration = registration });
    }

    /// Editor commands reach the palette only for a workbench with an active
    /// editor, mirroring getCodeEditorCommandPicks in editorCommandsQuickAccess.
    pub fn registerEditorAction(self: *CommandRegistry, instantiation: *InstantiationService, action: actions.Action2) !void {
        try self.registerAction(instantiation, action);
        self.registrations.getPtr(action.command.id).?.requires_editor = true;
    }

    /// Extension API registration: the handler belongs to CommandsRegistry,
    /// while the actual ICommandAction and its visibility belong to MenuRegistry.
    pub fn registerCommand(self: *CommandRegistry, command: platform_commands.Command, descriptor: actions.ICommandAction, options: CommandOptions) !void {
        if (!std.mem.eql(u8, command.id, descriptor.id)) return error.CommandIdMismatch;
        try self.registrations.ensureUnusedCapacity(self.allocator, 1);
        try self.platform.commands.ensureUnusedCapacity(1);
        const previous_command = self.platform.get(command.id);
        try self.platform.register(command);
        errdefer if (previous_command) |old| self.platform.register(old) catch unreachable else self.platform.unregister(command.id);
        var registration: CommandRegistration = .{ .descriptor = descriptor, .requires_editor = options.requires_editor };
        // Register metadata before menu events, like the platform command.
        // Retain the old value until the replacement has committed.
        const previous = self.registrations.fetchRemove(command.id);
        self.registrations.putAssumeCapacity(command.id, registration);
        errdefer {
            _ = self.registrations.remove(command.id);
            if (previous) |old| self.registrations.putAssumeCapacity(old.key, old.value);
        }
        const was_visible = if (previous) |old| old.value.isInPalette() else false;
        if (options.show_in_palette) {
            if (was_visible) {
                const item = self.menus.getMenuItemPtr(palette, command.id).?;
                item.command = descriptor;
                item.when = null;
                registration.palette_registration = .{ .registry = &self.menus, .menu = palette, .command_id = command.id };
                self.menus.on_did_change.fire(.{ .menu = palette }) catch {};
            } else {
                registration.palette_registration = try self.menus.appendMenuItemTracked(palette, .{ .command = descriptor });
            }
        } else if (was_visible) {
            const item = self.menus.getMenuItemPtr(palette, command.id).?;
            (actions.MenuRegistry.Registration{ .registry = &self.menus, .menu = palette, .command_id = command.id, .when = item.when }).dispose();
        }
        if (previous) |old| if (old.value.action_registration) |action| {
            // The explicit palette row is now owned by the extension
            // registration; dispose the previous action's other contributions.
            action.palette_item = null;
            action.dispose();
        };
        self.registrations.getPtr(command.id).?.* = registration;
    }

    pub fn execute(self: *const CommandRegistry, id: []const u8) !void {
        _ = try self.platform.execute(id);
    }

    pub fn unregister(self: *CommandRegistry, id: []const u8) void {
        const removed = self.registrations.fetchRemove(id) orelse return;
        if (removed.value.action_registration) |registration| return registration.dispose();
        self.platform.unregister(id);
        if (removed.value.palette_registration) |registration| registration.dispose();
    }

    pub fn get(self: *const CommandRegistry, id: []const u8) ?platform_commands.Command {
        return self.platform.get(id);
    }

    pub fn getRegistration(self: *const CommandRegistry, id: []const u8) ?CommandRegistration {
        return self.registrations.get(id);
    }

    pub fn source(self: *CommandRegistry) CommandPickSource {
        return .{ .context = self, .get_picks = getPicks };
    }

    fn editorAvailable(self: *const CommandRegistry) bool {
        if (self.is_editor_available) |callback| {
            return callback(self.editor_available_context orelse return false);
        }
        return true;
    }

    fn getPicks(context: *anyopaque, allocator: Allocator) anyerror![]CommandPick {
        const self: *CommandRegistry = @ptrCast(@alignCast(context));
        var picks = std.array_list.Managed(CommandPick).init(allocator);
        errdefer picks.deinit();
        for (self.menus.getMenuItems(palette)) |entry| {
            if (entry != .command) continue;
            const item = entry.command;
            if (item.when) |condition| {
                const keys = self.context_keys orelse continue;
                if (!keys.contextMatchesRules(condition)) continue;
            }
            if (item.command.precondition) |condition| {
                const keys = self.context_keys orelse continue;
                if (!keys.contextMatchesRules(condition)) continue;
            }
            if (self.getRegistration(item.command.id)) |registration| {
                if (registration.requires_editor and !self.editorAvailable()) continue;
            }
            try picks.append(.{
                .command_id = item.command.id,
                .label = item.command.title,
                .category = item.command.category orelse "",
                .description = item.command.tooltip orelse "",
            });
        }
        return try picks.toOwnedSlice();
    }
};

test "CommandRegistry: registers once, filters editor commands and lists picks" {
    const State = struct {
        ran: usize = 0,
        editor: bool = false,
        fn run(context: *anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.ran += 1;
        }
        fn hasEditor(context: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.editor;
        }
    };

    var state = State{};
    var registry = CommandRegistry.init(std.testing.allocator);
    defer registry.deinit();
    registry.setEditorAvailability(&state, State.hasEditor);

    try registry.registerCommand(.{ .id = "workbench.action.files.save", .context = &state, .run = State.run }, .{ .id = "workbench.action.files.save", .title = "Save", .category = "File" }, .{});
    try registry.registerCommand(.{ .id = "actions.find", .context = &state, .run = State.run }, .{ .id = "actions.find", .title = "Find" }, .{ .requires_editor = true });

    var picks = std.array_list.Managed(CommandPick).init(std.testing.allocator);
    defer picks.deinit();
    var source = registry.source();
    const all = try source.get_picks(source.context, std.testing.allocator);
    defer std.testing.allocator.free(all);
    try picks.appendSlice(all);
    try std.testing.expectEqual(@as(usize, 1), picks.items.len);

    state.editor = true;
    const with_editor = try source.get_picks(source.context, std.testing.allocator);
    defer std.testing.allocator.free(with_editor);
    try std.testing.expectEqual(@as(usize, 2), with_editor.len);

    try registry.execute("workbench.action.files.save");
    try std.testing.expectEqual(@as(usize, 1), state.ran);
}

test "palette reads contributed menu items and evaluates their live context" {
    const allocator = std.testing.allocator;
    var registry = CommandRegistry.init(allocator);
    defer registry.deinit();
    var keys = contextkey.ContextKeyService.init(allocator);
    defer keys.deinit();
    registry.context_keys = keys.interface();
    const visible = try keys.createKey("visible", .{ .boolean = true });
    const enabled = try keys.createKey("enabled", .{ .boolean = false });
    var expressions = contextkey.ContextKeyExpr.init(allocator);
    defer expressions.deinit();
    const registration = try registry.menus.appendMenuItemTracked(palette, .{
        .command = .{ .id = "test.contributed", .title = "Contributed Action", .precondition = try expressions.has("enabled") },
        .when = try expressions.has("visible"),
    });
    const source = registry.source();
    const Check = struct {
        fn count(picker: CommandPickSource, expected: usize) !void {
            const items = try picker.get_picks(picker.context, std.testing.allocator);
            defer std.testing.allocator.free(items);
            try std.testing.expectEqual(expected, items.len);
            if (items.len > 0) try std.testing.expectEqualStrings("Contributed Action", items[0].label);
        }
    };
    try Check.count(source, 0);
    enabled.set(.{ .boolean = true });
    try Check.count(source, 1);
    visible.set(.{ .boolean = false });
    try Check.count(source, 0);
    registration.dispose();
    visible.set(.{ .boolean = true });
    try Check.count(source, 0);
}

test "extension commands use registry metadata and live palette preconditions" {
    const allocator = std.testing.allocator;
    var registry = CommandRegistry.init(allocator);
    defer registry.deinit();
    var keys = contextkey.ContextKeyService.init(allocator);
    defer keys.deinit();
    registry.context_keys = keys.interface();
    const enabled = try keys.createKey("extension.enabled", .{ .boolean = false });
    const condition: contextkey.Expr = .{ .Defined = "extension.enabled" };
    const State = struct {
        count: usize = 0,
        fn run(context: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
        }
    };
    var first = State{};
    var replacement = State{};
    const id = "extension.first";
    try registry.registerCommand(.{ .id = id, .context = &first, .run = State.run }, .{ .id = id, .title = "First", .precondition = &condition }, .{});
    try registry.registerCommand(.{ .id = "extension.second", .context = &first, .run = State.run }, .{ .id = "extension.second", .title = "Second" }, .{});
    const source = registry.source();
    {
        const picks = try source.get_picks(source.context, allocator);
        defer allocator.free(picks);
        try std.testing.expectEqual(@as(usize, 1), picks.len);
        try std.testing.expectEqualStrings("Second", picks[0].label);
    }
    enabled.set(.{ .boolean = true });
    try registry.registerCommand(.{ .id = id, .context = &replacement, .run = State.run }, .{ .id = id, .title = "Replacement", .precondition = &condition }, .{});
    try std.testing.expectEqual(@as(usize, 2), registry.platform.commands.items.len);
    try std.testing.expectEqualStrings(id, registry.platform.commands.items[0].id);
    {
        const picks = try source.get_picks(source.context, allocator);
        defer allocator.free(picks);
        try std.testing.expectEqual(@as(usize, 2), picks.len);
        try std.testing.expectEqualStrings("Replacement", picks[0].label);
    }
    try registry.execute(id);
    try std.testing.expectEqual(@as(usize, 0), first.count);
    try std.testing.expectEqual(@as(usize, 1), replacement.count);
    registry.unregister(id);
    try std.testing.expect(registry.get(id) == null);
    try std.testing.expect(registry.getRegistration(id) == null);
    const picks = try source.get_picks(source.context, allocator);
    defer allocator.free(picks);
    try std.testing.expectEqual(@as(usize, 1), picks.len);
    try std.testing.expectEqualStrings("Second", picks[0].label);
}
