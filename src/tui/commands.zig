// TUI command table backing the command selector.
//
// Upstream workbench commands are `Action2`/menu contributions registered in
// the actions registry; this port has no menu or keybinding registry, so the
// workbench registers the commands it can actually run here and exposes them
// to the command picker through `CommandPickSource`.
//
// The metadata keeps upstream ids/labels/categories where the action exists.
// This file is TUI integration; the portable execution registry lives in
// `src/vs/platform/commands/common/commands.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const platform_commands = @import("../vs/platform/commands/common/commands.zig");
const commands_quick_access = @import("../vs/platform/quickinput/browser/commandsQuickAccess.zig");
const CommandPick = commands_quick_access.CommandPick;
const CommandPickSource = commands_quick_access.CommandPickSource;

pub const CommandInfo = struct {
    id: []const u8,
    label: []const u8,
    category: []const u8 = "",
    description: []const u8 = "",
    /// Editor commands are omitted while the workbench has no active tab.
    requires_editor: bool = false,
    context: *anyopaque,
    run: *const fn (context: *anyopaque) anyerror!void,
};

pub const CommandRegistry = struct {
    allocator: Allocator,
    infos: std.array_list.Managed(CommandInfo),
    platform: platform_commands.CommandRegistry,
    editor_available_context: ?*anyopaque = null,
    is_editor_available: ?*const fn (context: *anyopaque) bool = null,

    pub fn init(allocator: Allocator) CommandRegistry {
        return .{
            .allocator = allocator,
            .infos = std.array_list.Managed(CommandInfo).init(allocator),
            .platform = platform_commands.CommandRegistry.init(allocator),
        };
    }

    pub fn deinit(self: *CommandRegistry) void {
        self.platform.deinit();
        self.infos.deinit();
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
        for (self.infos.items, 0..) |existing, index| {
            if (std.mem.eql(u8, existing.id, info.id)) {
                self.infos.items[index] = info;
                try self.platform.register(.{
                    .id = info.id,
                    .context = info.context,
                    .run = info.run,
                });
                return;
            }
        }
        try self.infos.append(info);
        try self.platform.register(.{
            .id = info.id,
            .context = info.context,
            .run = info.run,
        });
    }

    pub fn execute(self: *const CommandRegistry, id: []const u8) !void {
        _ = try self.platform.execute(id);
    }

    pub fn get(self: *const CommandRegistry, id: []const u8) ?CommandInfo {
        for (self.infos.items) |info| {
            if (std.mem.eql(u8, info.id, id)) return info;
        }
        return null;
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
        for (self.infos.items) |info| {
            if (info.requires_editor and !self.editorAvailable()) continue;
            try picks.append(.{
                .command_id = info.id,
                .label = info.label,
                .category = info.category,
                .description = info.description,
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
