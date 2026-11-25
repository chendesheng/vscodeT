// Workbench command registration and the CommandPalette pick source. The
// palette reads MenuRegistry on demand. Legacy registrations retain their
// callback-based enablement until each owner ports its context expression.
const std = @import("std");
const Allocator = std.mem.Allocator;
const platform_commands = @import("../../platform/commands/common/commands.zig");
const commands_quick_access = @import("../../platform/quickinput/browser/commandsQuickAccess.zig");
const CommandPick = commands_quick_access.CommandPick;
const CommandPickSource = commands_quick_access.CommandPickSource;

const actions = @import("../../platform/actions/common/actions.zig");
const contextkey = @import("../../platform/contextkey/common/contextkey.zig");
const palette = actions.menu_ids.CommandPalette;

pub const CommandInfo = struct {
    id: []const u8,
    label: []const u8,
    category: []const u8 = "",
    description: []const u8 = "",
    /// Editor commands are omitted while the workbench has no active tab.
    requires_editor: bool = false,
    show_in_palette: bool = true,
    precondition: ?*const fn (context: *anyopaque) bool = null,
    context: *anyopaque,
    run: *const fn (context: *anyopaque) anyerror!void,
};

pub const CommandRegistry = struct {
    allocator: Allocator,
    infos: std.array_hash_map.String(CommandInfo) = .empty,
    menus: actions.MenuRegistry,
    context_keys: ?contextkey.IContextKeyService = null,
    platform: platform_commands.CommandRegistry,
    editor_available_context: ?*anyopaque = null,
    is_editor_available: ?*const fn (context: *anyopaque) bool = null,

    pub fn init(allocator: Allocator) CommandRegistry {
        return .{
            .allocator = allocator,
            .menus = actions.MenuRegistry.init(allocator),
            .platform = platform_commands.CommandRegistry.init(allocator),
        };
    }

    pub fn deinit(self: *CommandRegistry) void {
        self.platform.deinit();
        self.infos.deinit(self.allocator);
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

    pub fn register(self: *CommandRegistry, info: CommandInfo) !void {
        try self.infos.ensureUnusedCapacity(self.allocator, 1);
        try self.platform.commands.ensureUnusedCapacity(1);
        const previous = self.infos.getIndex(info.id);
        const old_info = self.infos.get(info.id);
        const old_command = self.platform.get(info.id);
        if (previous) |i| self.infos.keys()[i] = info.id;
        self.infos.putAssumeCapacity(info.id, info);
        try self.platform.register(.{ .id = info.id, .context = info.context, .run = info.run });
        errdefer {
            if (old_info) |old| {
                self.infos.keys()[previous.?] = old.id;
                self.infos.putAssumeCapacity(old.id, old);
            } else _ = self.infos.orderedRemove(info.id);
            if (old_command) |old| self.platform.register(old) catch unreachable else self.platform.unregister(info.id);
        }
        const was_visible = if (old_info) |old| old.show_in_palette else false;
        const command = actions.ICommandAction{ .id = info.id, .title = info.label, .category = info.category };
        if (info.show_in_palette) {
            if (was_visible) {
                self.menus.getMenuItemPtr(palette, info.id).?.command = command;
                self.menus.on_did_change.fire(.{ .menu = palette }) catch |err| std.log.err("Menu listener failed: {s}", .{@errorName(err)});
            } else {
                try self.menus.appendMenuItem(palette, .{ .command = command });
            }
        } else if (was_visible) self.removePaletteEntry(info.id);
    }

    fn removePaletteEntry(self: *CommandRegistry, id: []const u8) void {
        const registration = actions.MenuRegistry.Registration{ .registry = &self.menus, .menu = palette, .command_id = id };
        registration.dispose();
    }

    pub fn execute(self: *const CommandRegistry, id: []const u8) !void {
        _ = try self.platform.execute(id);
    }

    /// Removes a command from both the picker metadata and the execution
    /// registry. Used by built-in extension disposal.
    pub fn unregister(self: *CommandRegistry, id: []const u8) void {
        const removed = self.infos.fetchOrderedRemove(id) orelse return;
        self.platform.unregister(id);
        if (removed.value.show_in_palette) self.removePaletteEntry(id);
    }

    pub fn get(self: *const CommandRegistry, id: []const u8) ?CommandInfo {
        return self.infos.get(id);
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
            const info = self.get(item.command.id);
            if (info) |legacy| {
                if (legacy.precondition) |enabled| if (!enabled(legacy.context)) continue;
                if (legacy.requires_editor and !self.editorAvailable()) continue;
            }
            try picks.append(.{
                .command_id = item.command.id,
                .label = item.command.title,
                .category = item.command.category orelse "",
                .description = if (info) |legacy| legacy.description else "",
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

    try registry.register(.{
        .id = "workbench.action.files.save",
        .label = "Save",
        .category = "File",
        .context = &state,
        .run = State.run,
    });
    try registry.register(.{
        .id = "actions.find",
        .label = "Find",
        .requires_editor = true,
        .context = &state,
        .run = State.run,
    });

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
