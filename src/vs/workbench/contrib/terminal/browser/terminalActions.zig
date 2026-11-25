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

const actions = @import("../../../../platform/actions/common/actions.zig");
const instantiation = @import("../../../../platform/instantiation/common/instantiation.zig");
const contextkey = @import("../../../../platform/contextkey/common/contextkey.zig");
const terminal_keys = @import("../common/terminalContextKey.zig").TerminalContextKeys;
const ids = @import("../common/terminal.zig").TerminalCommandId;
const ConfigurationService = @import("../../../services/configuration/browser/configurationService.zig").ConfigurationService;
const DialogService = @import("../../../../platform/dialogs/common/dialogs.zig").IDialogService;
const TerminalTabbedView = @import("terminalTabbedView.zig").TerminalTabbedView;
const groups = @import("../../../services/editor/common/editorGroupsService.zig");
const ui = @import("ui");

pub const terminal_action_services_id = instantiation.ServiceIdentifier(TerminalActionServices, "terminalActionServices");

pub const TerminalAction = enum { toggle, new, editor, editor_side, split, move_to_editor, move_to_panel, kill_editor, rename, focus_tabs, focus_next_pane, focus_previous_pane, kill, focus, focus_next, focus_previous, resize_up, resize_down };

/// Projection of upstream ITerminalServicesCollection. TerminalService owns
/// terminal creation and location changes. The native view supplies cell
/// geometry and focus/reveal hooks instead of DOM panel manipulation.
pub const TerminalActionServices = struct {
    context: *anyopaque,
    slot: *?*TerminalService,
    configuration: *?*ConfigurationService,
    configuration_api: @import("../../../../platform/configuration/common/configuration.zig").IConfigurationService,
    part: *EditorPart,
    factory: EditorViewFactory,
    tabbed_view: *TerminalTabbedView,
    input: *quick_input.QuickInputService,
    dialogs: DialogService,
    close_host: GroupView.CloseHost,
    ensure_service: *const fn (*anyopaque) anyerror!*TerminalService,
    reveal_panel: *const fn (*anyopaque) anyerror!void,
    reveal_editor: *const fn (*anyopaque, bool) anyerror!void,
    hide_panel: *const fn (*anyopaque) void,
    panel_active: *const fn (*anyopaque) bool,
    panel_rect: *const fn (*anyopaque) ui.Rect,
    panel_focused: *const fn (*anyopaque) bool,
    editor_focused: *const fn (*anyopaque) bool,
    focused_terminal: *const fn (*anyopaque) ?*TerminalInstance,
    focus_panel: *const fn (*anyopaque) void,
    layout: *const fn (*anyopaque) void,
    layout_service: @import("../../../services/layout/browser/layoutService.zig").IWorkbenchLayoutService,
    panel_instances_removed: *const fn (*anyopaque, *TerminalService) anyerror!void,

    pub const MenuKind = union(enum) { switch_instance, profiles: ?GroupIdentifier, tab: usize, tab_list };

    /// Terminal menu actions and captured arguments belong to the terminal
    /// contribution; the host supplies only the context-menu anchor.
    pub fn showMenu(self: *TerminalActionServices, kind: MenuKind, context_menu: @import("../../../../platform/contextview/browser/contextMenuService.zig").IContextMenuService, anchor: @import("../../../../platform/contextview/browser/contextMenuService.zig").Anchor) !void {
        const service = self.slot.* orelse return;
        const Context = struct {
            owner: *TerminalActionServices,
            fn run(context: *@This(), id: []const u8) !void {
                try context.owner.runMenuAction(id);
            }
        };
        const menu = try Menu.init(service.allocator, Context{ .owner = self }, Context.run);
        errdefer menu.deinit();
        switch (kind) {
            .switch_instance => try appendSwitchMenu(service, menu),
            .profiles => |group| try appendProfileMenu(service, menu, group),
            .tab => |index| try appendTabMenu(service, menu, index),
            .tab_list => try appendTabListActions(Config.load(self.configuration.*), menu),
        }
        try context_menu.showContextMenu(menu, anchor);
    }

    pub fn runMenuAction(self: *TerminalActionServices, action_id: []const u8) !void {
        const service = self.slot.* orelse return;
        const separator = std.mem.indexOfScalar(u8, action_id, ':') orelse return;
        const action = action_id[0..separator];
        const argument = action_id[separator + 1 ..];
        if (std.mem.eql(u8, action, "tabs")) {
            if (std.mem.eql(u8, argument, "hide")) {
                try self.configuration_api.updateValue("terminal.integrated.tabs.enabled", .{ .bool = false }, .USER);
            } else {
                try self.configuration_api.updateValue("terminal.integrated.tabs.location", .{ .string = argument }, .USER);
            }
            self.layout(self.context);
            return;
        }
        if (std.mem.eql(u8, action, "editor-profile")) {
            var segments = std.mem.splitScalar(u8, argument, ':');
            const group_id = std.fmt.parseUnsigned(GroupIdentifier, segments.next() orelse return, 10) catch return;
            const index = std.fmt.parseUnsigned(usize, segments.next() orelse return, 10) catch return;
            if (index >= service.profiles.items.len) return;
            const group = self.part.service.getGroup(group_id) orelse return;
            const pane = self.part.viewForGroup(group) orelse return;
            _ = try service.createEditorWithProfile(self.factory, pane, service.profiles.items[index], false);
            return self.reveal_editor(self.context, false);
        }
        const id = std.fmt.parseUnsigned(usize, argument, 10) catch return;
        if (std.mem.eql(u8, action, "profile")) {
            if (id >= service.profiles.items.len) return;
            _ = try service.createWithProfile(service.profiles.items[id]);
            return self.reveal_panel(self.context);
        }
        for (0..service.count()) |index| {
            const instance = service.at(index).?;
            if (instance.id != id) continue;
            if (std.mem.eql(u8, action, "move")) {
                const pane = self.part.activeView() orelse return error.GroupPaneMissing;
                try service.moveToEditor(self.factory, pane, index);
                return self.reveal_editor(self.context, true);
            }
            if (std.mem.eql(u8, action, "rename")) return showRenamePicker(service, self.input, instance);
            if (std.mem.eql(u8, action, "kill")) {
                service.killSelectedTabs(index);
                return self.panel_instances_removed(self.context, service);
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
            return self.reveal_panel(self.context);
        }
    }

    pub fn launchProcess(self: *TerminalActionServices, name: []const u8, executable: []const u8, args: []const []const u8, cwd: ?[]const u8) !*TerminalInstance {
        const service = try self.ensure_service(self.context);
        const instance = try service.createForTask(.{ .path = executable, .args = args, .profile_name = name }, cwd);
        self.tabbed_view.setListFocused(false);
        try self.reveal_panel(self.context);
        return instance;
    }

    pub fn newPanelTerminal(self: *TerminalActionServices) !void {
        const service = try self.ensure_service(self.context);
        _ = try service.create();
        try self.reveal_panel(self.context);
    }

    fn newEditorTerminal(self: *TerminalActionServices) !void {
        const pane = self.part.activeView() orelse return error.GroupPaneMissing;
        const service = try self.ensure_service(self.context);
        _ = try service.createEditor(self.factory, pane, null);
        try self.reveal_editor(self.context, false);
    }

    pub fn openEditorToSide(self: *TerminalActionServices, parent: ?*TerminalInstance) !void {
        const service = try self.ensure_service(self.context);
        self.layout(self.context);
        const direction = groups.preferredSideBySideGroupDirection(if (self.configuration.*) |config| config.interface() else null);
        _ = try service.createEditorToSide(self.factory, self.part, direction, parent);
        try self.reveal_editor(self.context, false);
    }

    pub fn focusPane(self: *TerminalActionServices, next: bool) bool {
        const service = self.slot.* orelse return false;
        if (!self.tabbed_view.focusPane(service, self.panel_rect(self.context), next)) return false;
        self.focus_panel(self.context);
        return true;
    }

    fn killEditorTerminal(self: *TerminalActionServices) !bool {
        const pane = self.part.activeView() orelse return false;
        const tab = pane.activeTab() orelse return false;
        if (tab.terminal_input == null) return false;
        if (!self.dialogs.hasDialog()) try self.close_host.close_tab(self.close_host.context, pane, tab);
        return true;
    }

    fn acceptSwitchPicker(context: *anyopaque, picker: *QuickPick) !void {
        const self: *TerminalActionServices = @ptrCast(@alignCast(context));
        const item = picker.activeItem() orelse return;
        if (!std.mem.startsWith(u8, item.id, "instance:")) return;
        const id = std.fmt.parseUnsigned(usize, item.id["instance:".len..], 10) catch return;
        const service = self.slot.* orelse return;
        for (0..service.count()) |index| {
            if (service.at(index).?.id != id) continue;
            _ = service.setActive(index);
            return self.reveal_panel(self.context);
        }
    }

    pub fn run(self: *TerminalActionServices, action: TerminalAction) !void {
        const current = self.slot.*;
        switch (action) {
            .toggle => {
                if (current != null and current.?.count() > 0 and self.panel_active(self.context) and self.panel_focused(self.context)) {
                    self.hide_panel(self.context);
                } else try self.reveal_panel(self.context);
            },
            .new => if (std.mem.eql(u8, Config.load(self.configuration.*).default_location, "editor")) try self.newEditorTerminal() else try self.newPanelTerminal(),
            .editor => try self.newEditorTerminal(),
            .editor_side => try self.openEditorToSide(null),
            .split => {
                if (self.editor_focused(self.context)) {
                    if (self.part.activeView()) |pane| if (pane.activeTab()) |tab| if (tab.terminalInstance()) |instance| return self.openEditorToSide(instance);
                }
                const service = current orelse return;
                try service.split(service.group.active);
                try self.reveal_panel(self.context);
            },
            .move_to_editor => {
                const service = current orelse return;
                if (service.active() == null) return;
                const pane = self.part.activeView() orelse return error.GroupPaneMissing;
                try service.moveToEditor(self.factory, pane, service.group.active);
                try self.reveal_editor(self.context, true);
            },
            .move_to_panel => {
                const service = current orelse return;
                const pane = self.part.activeView() orelse return;
                const tab = pane.activeTab() orelse return;
                if (tab.terminal_input == null) return;
                try service.moveToTerminalView(pane, tab, self.close_host);
                try self.reveal_panel(self.context);
            },
            .kill_editor => _ = try self.killEditorTerminal(),
            .rename => {
                const service = current orelse return;
                const instance = self.focused_terminal(self.context) orelse service.active() orelse return;
                try showRenamePicker(service, self.input, instance);
            },
            .focus_tabs => {
                const service = current orelse return;
                if (service.count() == 0) return;
                try self.reveal_panel(self.context);
                if (self.tabbed_view.layoutForService(self.panel_rect(self.context), service).sash_x == null) {
                    try showSwitchPicker(service, self.input, acceptSwitchPicker, self);
                } else self.tabbed_view.setListFocused(true);
            },
            .focus_next_pane, .focus_previous_pane => _ = self.focusPane(action == .focus_next_pane),
            .kill => {
                if (self.editor_focused(self.context) and try self.killEditorTerminal()) return;
                const service = current orelse return;
                service.killActive();
                try self.panel_instances_removed(self.context, service);
            },
            .focus => try self.reveal_panel(self.context),
            .focus_next, .focus_previous => {
                const service = current orelse return;
                self.tabbed_view.focusAdjacentGroup(service, self.panel_rect(self.context), action == .focus_next);
                self.focus_panel(self.context);
            },
            .resize_up, .resize_down => try self.layout_service.resizePart(.panel, 0, if (action == .resize_up) 1 else -1),
        }
    }
};

// Retain the existing native palette visibility for local action availability.
// The expressions use the upstream terminal context keys and are updated at
// the service events, not by callback-based palette inspection.
const panel_active: contextkey.Expr = .{ .And = @constCast(&[_]*const contextkey.Expr{ &terminal_keys.group_count, &terminal_keys.view_showing }) };
const active_terminal: contextkey.Expr = .{ .Or = @constCast(&[_]*const contextkey.Expr{ &terminal_keys.terminal_editor_active, &panel_active }) };

fn terminalAction(comptime action: TerminalAction, id: []const u8, title: []const u8, precondition: ?*const contextkey.Expr, f1: bool) actions.Action2 {
    return .{
        .command = .{ .id = id, .title = title, .category = if (f1) "Terminal" else null, .precondition = precondition },
        .f1 = f1,
        .context = @constCast(&{}),
        .run_fn = struct {
            fn run(_: *anyopaque, accessor: instantiation.ServicesAccessor) !void {
                try (try accessor.get(terminal_action_services_id)).run(action);
            }
        }.run,
    };
}

pub const editor_action = terminalAction(.editor, ids.editor, "Create New Terminal in Editor Area", null, true);
pub const terminal_actions = [_]actions.Action2{
    terminalAction(.toggle, ids.toggle, "Toggle Terminal", null, true),
    terminalAction(.new, ids.new, "New Terminal", null, true),
    terminalAction(.editor, ids.editor_same_group, "Create New Terminal in Editor Area", null, false),
    terminalAction(.editor_side, ids.editor_side, "Create New Terminal in Editor Area to the Side", null, true),
    terminalAction(.split, ids.split, "Split Terminal", &active_terminal, true),
    terminalAction(.move_to_editor, ids.move_to_editor, "Move Terminal into Editor Area", &terminal_keys.group_count, true),
    terminalAction(.move_to_panel, ids.move_to_panel, "Move Terminal into Panel", &terminal_keys.terminal_editor_active, true),
    terminalAction(.kill_editor, ids.kill_editor, "Kill the Active Terminal in Editor Area", &terminal_keys.terminal_editor_active, true),
    terminalAction(.rename, ids.rename, "Rename the Currently Active Terminal", &active_terminal, true),
    terminalAction(.focus_tabs, ids.focus_tabs, "Focus Terminal Tabs", &terminal_keys.group_count, true),
    terminalAction(.focus_next_pane, ids.focus_next_pane, "Focus Next Terminal in Terminal Group", &terminal_keys.split_terminal_active, true),
    terminalAction(.focus_previous_pane, ids.focus_previous_pane, "Focus Previous Terminal in Terminal Group", &terminal_keys.split_terminal_active, true),
    terminalAction(.kill, ids.kill, "Kill Terminal", null, true),
    terminalAction(.focus, ids.focus, "Focus Terminal", null, true),
    terminalAction(.focus_next, ids.focus_next, "Focus Next Terminal Group", null, true),
    terminalAction(.focus_previous, ids.focus_previous, "Focus Previous Terminal Group", null, true),
    terminalAction(.resize_up, ids.resize_up, "Resize Terminal Panel Up", null, true),
    terminalAction(.resize_down, ids.resize_down, "Resize Terminal Panel Down", null, true),
};

const terminal_resource: @import("../../../../platform/contextkey/common/contextkey.zig").Expr = .{ .Equals = .{ .key = "resourceScheme", .value = .{ .string = "vscode-terminal" } } };

/// EditorTitleContext contributions from terminalMenus.ts. The selected
/// terminal input's resource scheme is resolved by EditorTabsControl.
pub fn registerEditorTitleContext(registry: *@import("../../../../platform/actions/common/actions.zig").MenuRegistry) !void {
    const action_mod = @import("../../../../platform/actions/common/actions.zig");

    try registry.appendMenuItem(action_mod.menu_ids.EditorTitleContext, .{ .command = .{ .id = ids.move_to_panel, .title = "Move Terminal into Panel" }, .when = &terminal_resource, .group = "2_files" });
    try registry.appendMenuItem(action_mod.menu_ids.EditorTitleContext, .{ .command = .{ .id = ids.rename, .title = "Rename Terminal" }, .when = &terminal_resource, .group = "2_files" });
}
