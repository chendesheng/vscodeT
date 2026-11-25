// Port of the terminal instance/tab/profile actions from
// `src/vs/workbench/contrib/terminal/browser/terminalActions.ts` and
// `terminalTabsList.ts`. Native pickers and context menus replace browser
// action-view items. The remaining service actions are still wired by the
// terminal workbench until the editor/location services are ported.

const std = @import("std");
const TerminalService = @import("./terminalService.zig").TerminalService;
const Config = @import("../common/terminalConfiguration.zig").Config;
const Menu = @import("../../../../platform/contextview/browser/contextMenuService.zig").Menu;
const GroupIdentifier = @import("../../../common/editor.zig").GroupIdentifier;
const quick_input = @import("../../../../platform/quickinput/browser/quickInputService.zig");
const QuickPickItem = @import("../../../../platform/quickinput/common/quickInput.zig").QuickPickItem;

pub fn showSwitchPicker(service: *TerminalService, input: *quick_input.QuickInputService, handler: quick_input.PickHandler, context: *anyopaque) !void {
    const allocation = try service.allocator.create(std.heap.ArenaAllocator);
    allocation.* = .init(service.allocator);
    errdefer disposePickerArena(allocation);
    const arena = allocation.allocator();
    var items = std.array_list.Managed(QuickPickItem).init(arena);
    for (0..service.count()) |index| {
        const instance = service.at(index).?;
        try items.append(.{ .item = .{
            .id = try std.fmt.allocPrint(arena, "instance:{d}", .{instance.id}),
            .label = try arena.dupe(u8, instance.displayTitle()),
            .description = try arena.dupe(u8, instance.labels.description),
        } });
    }
    try input.showPick(items.items, .{
        .placeholder = "Switch Terminal",
        .active_id = if (service.group.active < items.items.len) items.items[service.group.active].item.id else null,
        .cleanup = disposePickerArena,
        .cleanup_context = allocation,
    }, handler, context);
}

fn disposePickerArena(context: *anyopaque) void {
    const arena: *std.heap.ArenaAllocator = @ptrCast(@alignCast(context));
    const allocator = arena.child_allocator;
    arena.deinit();
    allocator.destroy(arena);
}

pub fn appendSwitchMenu(service: *TerminalService, menu: *Menu) !void {
    const arena = menu.arena.allocator();
    for (0..service.count()) |index| {
        const instance = service.at(index).?;
        const id = try std.fmt.allocPrint(arena, "instance:{d}", .{instance.id});
        try menu.add(id, .{ .label = try arena.dupe(u8, instance.displayTitle()), .type = .radio, .checked = service.group.active == index });
    }
}

pub fn appendProfileMenu(service: *TerminalService, menu: *Menu, group_id: ?GroupIdentifier) !void {
    const arena = menu.arena.allocator();
    for (service.profiles.items, 0..) |profile, index| {
        const id = if (group_id) |id|
            try std.fmt.allocPrint(arena, "editor-profile:{d}:{d}", .{ id, index })
        else
            try std.fmt.allocPrint(arena, "profile:{d}", .{index});
        try menu.add(id, .{ .label = try arena.dupe(u8, profile.profile_name) });
    }
}

pub fn appendTabMenu(service: *TerminalService, menu: *Menu, index: usize) !void {
    const instance = service.at(index) orelse return;
    const arena = menu.arena.allocator();
    try menu.add(try std.fmt.allocPrint(arena, "split:{d}", .{instance.id}), .{ .label = "Split Terminal" });
    const range = service.group.groupRange(index);
    if (range.end - range.first > 1) {
        try menu.add(try std.fmt.allocPrint(arena, "unsplit:{d}", .{instance.id}), .{ .label = "Unsplit Terminal" });
    }
    if (instance.tab_selected) {
        var selected: usize = 0;
        for (service.group.instances.items) |candidate| selected += @intFromBool(candidate.tab_selected);
        if (selected > 1) try menu.add(try std.fmt.allocPrint(arena, "join:{d}", .{instance.id}), .{ .label = "Join Terminals" });
    }
    try menu.add(try std.fmt.allocPrint(arena, "rename:{d}", .{instance.id}), .{ .label = "Rename Terminal" });
    try menu.add(try std.fmt.allocPrint(arena, "move:{d}", .{instance.id}), .{ .label = "Move Terminal into Editor Area" });
    try menu.add(try std.fmt.allocPrint(arena, "kill:{d}", .{instance.id}), .{ .label = "Kill Terminal" });
    try menu.separator();
    try appendTabListActions(Config.load(service.options.configuration), menu);
}

pub fn appendTabListActions(config: Config, menu: *Menu) !void {
    const move_left = config.tabs_location == .right;
    try menu.add(if (move_left) "tabs:left" else "tabs:right", .{ .label = if (move_left) "Move Tabs Left" else "Move Tabs Right" });
    try menu.add("tabs:hide", .{ .label = "Hide Tabs" });
}
