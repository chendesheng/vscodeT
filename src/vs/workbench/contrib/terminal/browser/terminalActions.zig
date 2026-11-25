// Port of the terminal instance/tab/profile actions from
// `src/vs/workbench/contrib/terminal/browser/terminalActions.ts` and
// `terminalTabsList.ts`. Native pickers and context menus replace browser
// action-view items. TerminalService owns instance/location changes; the
// terminal adapter supplies panel reveal, cell layout and focus callbacks.

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

const TerminalInstance = @import("terminalInstance.zig").TerminalInstance;
const Tab = @import("../../../browser/parts/editor/editorPane.zig").Tab;
const EditorViewFactory = @import("../../../browser/parts/editor/editorPane.zig").EditorViewFactory;
const GroupView = @import("../../../browser/parts/editor/editorGroupView.zig").EditorGroupView(*Tab);
const EditorPart = @import("../../../browser/parts/editor/editorPart.zig").EditorPart(GroupView);
const QuickPick = @import("../../../../platform/quickinput/browser/quickInput.zig").QuickPick;

/// Terminal input-box adaptation of RenameTerminalAction. Resolve the chosen
/// instance by its stable ID when the picker is accepted, not a stale pointer.
pub fn showRenamePicker(service: *TerminalService, input: *quick_input.QuickInputService, instance: *TerminalInstance) !void {
    const state = try service.allocator.create(RenameState);
    state.* = .{ .service = service, .id = instance.id };
    input.showPick(&.{}, .{ .placeholder = "Terminal Name", .allow_free_input = true, .cleanup = RenameState.dispose, .cleanup_context = state }, RenameState.accept, state) catch |err| {
        RenameState.dispose(state);
        return err;
    };
    input.picker.setValue(instance.static_title orelse instance.displayTitle()) catch |err| {
        input.hide();
        return err;
    };
}

const RenameState = struct {
    service: *TerminalService,
    id: usize,

    fn accept(context: *anyopaque, picker: *QuickPick) !void {
        const self: *RenameState = @ptrCast(@alignCast(context));
        for (0..self.service.instanceCount()) |index| {
            const instance = self.service.instanceAt(index).?;
            if (instance.id == self.id) return instance.rename(picker.value.items);
        }
    }

    fn dispose(context: *anyopaque) void {
        const self: *RenameState = @ptrCast(@alignCast(context));
        self.service.allocator.destroy(self);
    }
};

pub const MenuActionHost = struct {
    context: *anyopaque,
    part: *EditorPart,
    view_factory: EditorViewFactory,
    quick_input: *quick_input.QuickInputService,
    set_user_configuration: *const fn (*anyopaque, []const u8, std.json.Value) anyerror!void,
    reveal_panel: *const fn (*anyopaque) anyerror!void,
    reveal_editor: *const fn (*anyopaque, bool) anyerror!void,
    panel_instances_removed: *const fn (*anyopaque) anyerror!void,
};

/// The native menus encode the upstream action's instance/profile arguments
/// in their item IDs. Resolve them and execute the terminal service action.
pub fn runMenuAction(service: *TerminalService, host: MenuActionHost, action_id: []const u8) !void {
    const separator = std.mem.indexOfScalar(u8, action_id, ':') orelse return;
    const action = action_id[0..separator];
    const argument = action_id[separator + 1 ..];
    if (std.mem.eql(u8, action, "tabs")) {
        if (std.mem.eql(u8, argument, "hide")) {
            try host.set_user_configuration(host.context, "terminal.integrated.tabs.enabled", .{ .bool = false });
        } else {
            try host.set_user_configuration(host.context, "terminal.integrated.tabs.location", .{ .string = argument });
        }
        return;
    }
    if (std.mem.eql(u8, action, "editor-profile")) {
        var segments = std.mem.splitScalar(u8, argument, ':');
        const group_id = std.fmt.parseUnsigned(GroupIdentifier, segments.next() orelse return, 10) catch return;
        const index = std.fmt.parseUnsigned(usize, segments.next() orelse return, 10) catch return;
        if (index >= service.profiles.items.len) return;
        const group = host.part.service.getGroup(group_id) orelse return;
        const pane = host.part.viewForGroup(group) orelse return;
        _ = try service.createEditorWithProfile(host.view_factory, pane, service.profiles.items[index], false);
        return host.reveal_editor(host.context, false);
    }
    const id = std.fmt.parseUnsigned(usize, argument, 10) catch return;
    if (std.mem.eql(u8, action, "profile")) {
        if (id >= service.profiles.items.len) return;
        _ = try service.createWithProfile(service.profiles.items[id]);
        return host.reveal_panel(host.context);
    }
    for (0..service.count()) |index| {
        const instance = service.at(index).?;
        if (instance.id != id) continue;
        if (std.mem.eql(u8, action, "move")) {
            const pane = host.part.activeView() orelse return error.GroupPaneMissing;
            try service.moveToEditor(host.view_factory, pane, index);
            return host.reveal_editor(host.context, true);
        }
        if (std.mem.eql(u8, action, "rename")) return showRenamePicker(service, host.quick_input, instance);
        if (std.mem.eql(u8, action, "kill")) {
            service.killSelectedTabs(index);
            return host.panel_instances_removed(host.context);
        }
        if (std.mem.eql(u8, action, "split")) {
            try service.splitSelectedTabs(index);
        } else if (std.mem.eql(u8, action, "unsplit")) {
            try service.group.unsplitInstance(index);
        } else if (std.mem.eql(u8, action, "join")) {
            try service.joinSelectedTabs();
        } else {
            _ = service.setActive(index);
        }
        return host.reveal_panel(host.context);
    }
}
