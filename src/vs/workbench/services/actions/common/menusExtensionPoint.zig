// Port of CommandsTableRenderer in `src/vs/workbench/services/actions/common/menusExtensionPoint.ts`.
// Terminal keybindings are shown in their platform-specific manifest form;
// the graphical KeybindingLabel and context-menu DOM are not available.
const std = @import("std");
const builtin = @import("builtin");
const features = @import("../../extensionManagement/common/extensionFeatures.zig");
const Allocator = std.mem.Allocator;

const Command = struct {
    id: []const u8,
    title: []const u8 = "",
    keys: std.ArrayList([]const u8) = .empty,
    menus: std.ArrayList([]const u8) = .empty,
};
fn commandFor(commands: *std.ArrayList(Command), allocator: Allocator, id: []const u8) !*Command {
    for (commands.items) |*command| if (std.mem.eql(u8, command.id, id)) return command;
    try commands.append(allocator, .{ .id = id });
    return &commands.items[commands.items.len - 1];
}
fn addUnique(list: *std.ArrayList([]const u8), allocator: Allocator, value: []const u8) !void {
    for (list.items) |entry| if (std.mem.eql(u8, entry, value)) return;
    try list.append(allocator, value);
}
fn shouldRender(manifest: std.json.Value) bool {
    return features.contribution(manifest, "commands") != .null;
}
fn keybinding(allocator: Allocator, commands: *std.ArrayList(Command), raw: std.json.Value) !void {
    const id = features.asString(features.property(raw, "command"));
    const platform_key = switch (builtin.os.tag) {
        .macos => "mac",
        .windows => "win",
        else => "linux",
    };
    const specific = features.asString(features.property(raw, platform_key));
    const key = if (specific.len > 0) specific else features.asString(features.property(raw, "key"));
    if (id.len == 0 or key.len == 0) return;
    const command = try commandFor(commands, allocator, id);
    try addUnique(&command.keys, allocator, key);
}
fn render(allocator: Allocator, manifest: std.json.Value) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var commands: std.ArrayList(Command) = .empty;
    const menus = features.contribution(manifest, "menus");
    for (features.items(features.contribution(manifest, "commands"))) |raw| {
        const id = features.asString(features.property(raw, "command"));
        if (id.len == 0) continue;
        const command = try commandFor(&commands, scratch, id);
        command.title = features.asString(features.property(raw, "title"));
        var explicit = false;
        for (features.items(features.property(menus, "commandPalette"))) |entry| if (std.mem.eql(u8, features.asString(features.property(entry, "command")), id)) {
            explicit = true;
            break;
        };
        if (!explicit) try addUnique(&command.menus, scratch, "commandPalette");
    }
    if (menus == .object) {
        var contexts = menus.object.iterator();
        while (contexts.next()) |context| for (features.items(context.value_ptr.*)) |entry| {
            if (std.mem.eql(u8, features.asString(features.property(entry, "when")), "false")) continue;
            const id = features.asString(features.property(entry, "command"));
            if (id.len == 0) continue;
            const command = try commandFor(&commands, scratch, id);
            try addUnique(&command.menus, scratch, context.key_ptr.*);
        };
    }
    const keys = features.contribution(manifest, "keybindings");
    if (keys == .array) {
        for (keys.array.items) |raw| try keybinding(scratch, &commands, raw);
    } else if (keys == .object) try keybinding(scratch, &commands, keys);
    var table: features.Table = .{ .allocator = scratch, .headers = &.{ "ID", "Title", "Keyboard Shortcuts", "Menu Contexts" } };
    for (commands.items) |command| try table.append(&.{ command.id, command.title, try std.mem.join(scratch, ", ", command.keys.items), try std.mem.join(scratch, ", ", command.menus.items) });
    table.sort();
    return table.markdown(allocator);
}

pub const commands_feature: features.Descriptor = .{ .id = "commands", .label = "Commands", .should_render = shouldRender, .render = render };
