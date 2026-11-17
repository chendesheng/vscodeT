// Port of `src/vs/platform/actions/common/menuService.ts` (the portable menu
// resolution pipeline).
//
// Terminal adaptations and current scope:
// - `MenuService` is bound to explicit `MenuRegistry`/`CommandRegistry`
//   instances. `when`/`precondition`/`toggled` evaluation takes an `IContext`
//   instead of an `IContextKeyService`.
// - Persisted hide state, menu change events/dependency tracking, implicit
//   command-palette items and keybinding labels are not ported; the TUI does
//   not have a menu UI yet. Items are returned with their group title,
//   enablement and toggled state, which is the data the menu UI consumes.
// - Actions own their backing structs in the returned `Menu` arena.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const actions = @import("actions.zig");
const action_module = @import("../../action/common/action.zig");
const commands = @import("../../commands/common/commands.zig");
const contextkey = @import("../../contextkey/common/contextkey.zig");
const base_actions = @import("../../../base/common/actions.zig");
const storage_mod = @import("../../storage/common/storage.zig");
const InMemoryStorageService = storage_mod.InMemoryStorageService;
const StorageScope = storage_mod.StorageScope;
const StorageTarget = storage_mod.StorageTarget;

const IAction = base_actions.IAction;
const MenuId = actions.MenuId;
const MenuEntry = actions.MenuEntry;
const MenuRegistry = actions.MenuRegistry;
const ICommandAction = action_module.ICommandAction;

pub const MenuGroup = struct {
    id: []const u8,
    title: ?[]const u8,
    actions: []const IAction,
};

pub const Menu = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    groups: []const MenuGroup,

    pub fn deinit(self: *Menu) void {
        self.arena.deinit();
    }
};

pub const MenuItemAction = struct {
    item: ICommandAction,
    enabled: bool,
    checked: ?bool,
    hidden: bool,
    is_modified_from_default: bool,
    label: []const u8,
    tooltip: []const u8,
    group_title: ?[]const u8,
    alt: ?*const IAction = null,
    command_registry: ?*commands.CommandRegistry,

    pub fn interface(self: *MenuItemAction) IAction {
        return .{
            .context = self,
            .get_id = getId,
            .get_label = getLabel,
            .get_tooltip = getTooltip,
            .get_class = getClass,
            .get_enabled = getEnabled,
            .get_checked = getChecked,
            .alt = self.alt,
            .run = run,
        };
    }

    fn getId(context: *anyopaque) []const u8 {
        const self: *MenuItemAction = @ptrCast(@alignCast(context));
        return self.item.id;
    }

    fn getLabel(context: *anyopaque) []const u8 {
        const self: *MenuItemAction = @ptrCast(@alignCast(context));
        return self.label;
    }

    fn getTooltip(context: *anyopaque) []const u8 {
        const self: *MenuItemAction = @ptrCast(@alignCast(context));
        return self.tooltip;
    }

    fn getClass(_: *anyopaque) ?[]const u8 {
        return null;
    }

    fn getEnabled(context: *anyopaque) bool {
        const self: *MenuItemAction = @ptrCast(@alignCast(context));
        return self.enabled;
    }

    fn getChecked(context: *anyopaque) ?bool {
        const self: *MenuItemAction = @ptrCast(@alignCast(context));
        return self.checked;
    }

    fn run(context: *anyopaque, _: ?*const anyopaque) anyerror!void {
        const self: *MenuItemAction = @ptrCast(@alignCast(context));
        const registry = self.command_registry orelse return;
        _ = try registry.execute(self.item.id);
    }
};

pub const SubmenuItemAction = struct {
    id: []const u8,
    title: []const u8,
    actions: []const IAction,
    checked: ?bool,
    group_title: ?[]const u8,

    pub fn interface(self: *SubmenuItemAction) IAction {
        return .{
            .context = self,
            .get_id = getId,
            .get_label = getLabel,
            .get_tooltip = getTooltip,
            .get_class = getClass,
            .get_enabled = getEnabled,
            .get_checked = getChecked,
            .run = run,
        };
    }

    fn getId(context: *anyopaque) []const u8 {
        const self: *SubmenuItemAction = @ptrCast(@alignCast(context));
        return self.id;
    }

    fn getLabel(context: *anyopaque) []const u8 {
        const self: *SubmenuItemAction = @ptrCast(@alignCast(context));
        return self.title;
    }

    fn getTooltip(_: *anyopaque) []const u8 {
        return "";
    }

    fn getClass(_: *anyopaque) ?[]const u8 {
        return "submenu";
    }

    fn getEnabled(_: *anyopaque) bool {
        return true;
    }

    fn getChecked(context: *anyopaque) ?bool {
        const self: *SubmenuItemAction = @ptrCast(@alignCast(context));
        return self.checked;
    }

    fn run(_: *anyopaque, _: ?*const anyopaque) anyerror!void {}
};

/// In-memory view of the persisted "hidden menu items" state. Upstream stores
/// this in the profile storage (`menu.hiddenCommands`) and reloads it on change;
/// the terminal host has no storage service yet, so the state lives in memory
/// for the session and `MenuService.deinit` releases it.
pub const MenuHideState = struct {
    pub const storage_key = "menu.hiddenCommands";

    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    hidden: std.StringHashMap(std.StringHashMap(bool)),
    defaults: std.StringHashMap(std.StringHashMap(bool)),
    storage: ?*InMemoryStorageService = null,

    pub fn init(allocator: Allocator) MenuHideState {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .hidden = std.StringHashMap(std.StringHashMap(bool)).init(allocator),
            .defaults = std.StringHashMap(std.StringHashMap(bool)).init(allocator),
        };
    }

    /// Loads the persisted `Record<menuId, commandId[]>` state from the
    /// profile storage, matching upstream `menu.hiddenCommands`.
    pub fn initWithStorage(allocator: Allocator, storage: *InMemoryStorageService) MenuHideState {
        var self = init(allocator);
        self.storage = storage;
        self.load() catch {};
        return self;
    }

    fn load(self: *MenuHideState) !void {
        const storage = self.storage orelse return;
        const raw = storage.get(storage_key, .profile, null) orelse return;
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, raw, .{}) catch return;
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |object| object,
            else => return,
        };
        var iterator = object.iterator();
        while (iterator.next()) |entry| {
            const command_list = switch (entry.value_ptr.*) {
                .array => |array| array,
                else => continue,
            };
            for (command_list.items) |command| {
                const id = switch (command) {
                    .string => |text| text,
                    else => continue,
                };
                if (self.hidden.getPtr(entry.key_ptr.*) == null) {
                    const key = try self.arena.allocator().dupe(u8, entry.key_ptr.*);
                    try self.hidden.put(key, std.StringHashMap(bool).init(self.allocator));
                }
                const map = self.hidden.getPtr(entry.key_ptr.*).?;
                try map.put(try self.arena.allocator().dupe(u8, id), true);
            }
        }
    }

    fn persist(self: *MenuHideState) void {
        const storage = self.storage orelse return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        var root = std.json.ObjectMap{};
        var menus = self.hidden.iterator();
        while (menus.next()) |entry| {
            var array: std.array_list.Managed(std.json.Value) = .init(arena_allocator);
            var commands_iter = entry.value_ptr.iterator();
            while (commands_iter.next()) |command| {
                array.append(.{ .string = command.key_ptr.* }) catch return;
            }
            root.put(arena_allocator, entry.key_ptr.*, .{ .array = array }) catch return;
        }

        var out: std.Io.Writer.Allocating = .init(arena_allocator);
        defer out.deinit();
        std.json.Stringify.value(std.json.Value{ .object = root }, .{}, &out.writer) catch return;
        storage.store(storage_key, .{ .string = out.written() }, .profile, .machine) catch return;
    }

    pub fn deinit(self: *MenuHideState) void {
        var hidden_iterator = self.hidden.valueIterator();
        while (hidden_iterator.next()) |map| map.deinit();
        self.hidden.deinit();
        self.arena.deinit();
        var defaults_iterator = self.defaults.valueIterator();
        while (defaults_iterator.next()) |map| map.deinit();
        self.defaults.deinit();
    }

    pub fn setDefaultState(self: *MenuHideState, menu: MenuId, command_id: []const u8, hidden: bool) void {
        const map = self.defaults.getOrPut(menu.id) catch return;
        if (!map.found_existing) map.value_ptr.* = std.StringHashMap(bool).init(self.allocator);
        map.value_ptr.put(command_id, hidden) catch {};
    }

    pub fn isHidden(self: *MenuHideState, menu: MenuId, command_id: []const u8) bool {
        const hidden_by_default = self.isHiddenByDefault(menu, command_id);
        const state = if (self.hidden.getPtr(menu.id)) |map| map.get(command_id) orelse false else false;
        return if (hidden_by_default) !state else state;
    }

    pub fn isModifiedFromDefault(self: *MenuHideState, menu: MenuId, command_id: []const u8) bool {
        return self.isHidden(menu, command_id) != self.isHiddenByDefault(menu, command_id);
    }

    pub fn updateHidden(self: *MenuHideState, menu: MenuId, command_id: []const u8, hidden: bool) void {
        const hidden_by_default = self.isHiddenByDefault(menu, command_id);
        const value = if (hidden_by_default) !hidden else hidden;
        if (self.hidden.getPtr(menu.id) == null) {
            const key = self.arena.allocator().dupe(u8, menu.id) catch return;
            self.hidden.put(key, std.StringHashMap(bool).init(self.allocator)) catch return;
        }
        const map = self.hidden.getPtr(menu.id).?;
        if (value) {
            const command_key = self.arena.allocator().dupe(u8, command_id) catch return;
            map.put(command_key, true) catch return;
        } else {
            _ = map.fetchRemove(command_id);
            if (map.count() == 0) {
                if (self.hidden.fetchRemove(menu.id)) |removed| {
                    var removed_map = removed.value;
                    removed_map.deinit();
                }
            }
        }
        self.persist();
    }

    pub fn reset(self: *MenuHideState, menu: ?MenuId) void {
        if (menu) |id| {
            if (self.hidden.fetchRemove(id.id)) |removed| {
                var removed_map = removed.value;
                removed_map.deinit();
            }
            self.persist();
            return;
        }
        var iterator = self.hidden.valueIterator();
        while (iterator.next()) |map| map.deinit();
        self.hidden.clearRetainingCapacity();
        self.persist();
    }

    fn isHiddenByDefault(self: *MenuHideState, menu: MenuId, command_id: []const u8) bool {
        if (self.defaults.getPtr(menu.id)) |map| return map.get(command_id) orelse false;
        return false;
    }
};

pub const MenuService = struct {
    allocator: Allocator,
    registry: *MenuRegistry,
    command_registry: ?*commands.CommandRegistry,
    hide_state: MenuHideState,

    pub fn init(allocator: Allocator, registry: *MenuRegistry, command_registry: ?*commands.CommandRegistry) MenuService {
        return .{
            .allocator = allocator,
            .registry = registry,
            .command_registry = command_registry,
            .hide_state = MenuHideState.init(allocator),
        };
    }

    pub fn initWithStorage(allocator: Allocator, registry: *MenuRegistry, command_registry: ?*commands.CommandRegistry, storage: *InMemoryStorageService) MenuService {
        return .{
            .allocator = allocator,
            .registry = registry,
            .command_registry = command_registry,
            .hide_state = MenuHideState.initWithStorage(allocator, storage),
        };
    }

    pub fn deinit(self: *MenuService) void {
        self.hide_state.deinit();
    }

    /// Resolves a menu: visibility filtering, upstream sorting/grouping, group
    /// titles, enablement/toggled state and flattened submenus.
    pub fn createMenu(self: *MenuService, allocator: Allocator, id: MenuId, context: contextkey.IContext) !Menu {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const groups = try self.buildGroups(arena.allocator(), id, context);
        return .{ .allocator = allocator, .arena = arena, .groups = groups };
    }

    fn buildGroups(self: *MenuService, allocator: Allocator, id: MenuId, context: contextkey.IContext) ![]const MenuGroup {
        var visible = ArrayList(*const MenuEntry).init(allocator);
        defer visible.deinit();
        for (self.registry.getMenuItems(id)) |*entry| {
            const when = switch (entry.*) {
                .command => |item| item.when,
                .submenu => |item| item.when,
            };
            if (when) |expression| {
                if (!expression.evaluate(context)) continue;
            }
            try visible.append(entry);
        }
        std.mem.sort(*const MenuEntry, visible.items, {}, entryLessThan);

        var groups = ArrayList(MenuGroup).init(allocator);
        var index: usize = 0;
        while (index < visible.items.len) {
            const group_name = groupOf(visible.items[index]);
            const start = index;
            while (index < visible.items.len and std.mem.eql(u8, groupOf(visible.items[index]), group_name)) : (index += 1) {}

            var group_actions = ArrayList(IAction).init(allocator);
            const group_title = self.registry.getMenuGroupTitle(id, group_name);
            for (visible.items[start..index]) |entry| {
                switch (entry.*) {
                    .command => |item| {
                        self.hide_state.setDefaultState(id, item.command.id, item.is_hidden_by_default);
                        const action = try allocator.create(MenuItemAction);
                        action.* = .{
                            .item = item.command,
                            .enabled = if (item.command.precondition) |when| when.evaluate(context) else true,
                            .checked = if (item.command.toggled) |toggled| toggled.evaluate(context) else null,
                            .hidden = self.hide_state.isHidden(id, item.command.id),
                            .is_modified_from_default = self.hide_state.isModifiedFromDefault(id, item.command.id),
                            .label = item.command.title,
                            .tooltip = item.command.tooltip orelse "",
                            .group_title = group_title,
                            .command_registry = self.command_registry,
                        };
                        if (item.alt) |alt| {
                            const alt_action = try allocator.create(MenuItemAction);
                            alt_action.* = .{
                                .item = alt,
                                .enabled = if (alt.precondition) |when| when.evaluate(context) else true,
                                .checked = if (alt.toggled) |toggled| toggled.evaluate(context) else null,
                                .hidden = self.hide_state.isHidden(id, alt.id),
                                .is_modified_from_default = self.hide_state.isModifiedFromDefault(id, alt.id),
                                .label = alt.title,
                                .tooltip = alt.tooltip orelse "",
                                .group_title = group_title,
                                .command_registry = self.command_registry,
                            };
                            const alt_interface = alt_action.interface();
                            const alt_storage = try allocator.create(IAction);
                            alt_storage.* = alt_interface;
                            action.alt = alt_storage;
                        }
                        try group_actions.append(action.interface());
                    },
                    .submenu => |submenu| {
                        const submenu_groups = try self.buildGroups(allocator, submenu.submenu, context);
                        var flattened = ArrayList(IAction).init(allocator);
                        var first_group = true;
                        for (submenu_groups) |submenu_group| {
                            if (submenu_group.actions.len == 0) continue;
                            if (!first_group) {
                                try flattened.append(try separator(allocator, null));
                            }
                            first_group = false;
                            try flattened.appendSlice(submenu_group.actions);
                        }
                        if (flattened.items.len == 0) continue;

                        const action = try allocator.create(SubmenuItemAction);
                        action.* = .{
                            .id = try std.fmt.allocPrint(allocator, "submenuitem.{s}", .{submenu.submenu.id}),
                            .title = submenu.title,
                            .actions = try flattened.toOwnedSlice(),
                            .checked = if (submenu.toggled) |toggled| toggled.evaluate(context) else null,
                            .group_title = group_title,
                        };
                        try group_actions.append(action.interface());
                    },
                }
            }
            if (group_actions.items.len > 0) {
                try groups.append(.{
                    .id = group_name,
                    .title = group_title,
                    .actions = try group_actions.toOwnedSlice(),
                });
            }
        }
        return groups.toOwnedSlice();
    }
};

fn separator(allocator: Allocator, label: ?[]const u8) !IAction {
    const value = try allocator.create(base_actions.Separator);
    value.* = .{ .label_text = label };
    return value.interface();
}

fn groupOf(entry: *const MenuEntry) []const u8 {
    return switch (entry.*) {
        .command => |item| item.group,
        .submenu => |item| item.group,
    };
}

fn titleOf(entry: *const MenuEntry) []const u8 {
    return switch (entry.*) {
        .command => |item| item.command.title,
        .submenu => |item| item.title,
    };
}

fn orderOf(entry: *const MenuEntry) i64 {
    return switch (entry.*) {
        .command => |item| item.order,
        .submenu => |item| item.order,
    };
}

fn entryLessThan(_: void, a: *const MenuEntry, b: *const MenuEntry) bool {
    const a_group = groupOf(a);
    const b_group = groupOf(b);
    if (!std.mem.eql(u8, a_group, b_group)) {
        // Falsy groups come last.
        if (a_group.len == 0) return false;
        if (b_group.len == 0) return true;
        // `navigation` comes first.
        if (std.mem.eql(u8, a_group, "navigation")) return true;
        if (std.mem.eql(u8, b_group, "navigation")) return false;
        const order = std.mem.order(u8, a_group, b_group);
        if (order != .eq) return order == .lt;
    }

    const a_order = orderOf(a);
    const b_order = orderOf(b);
    if (a_order != b_order) return a_order < b_order;

    return std.mem.order(u8, titleOf(a), titleOf(b)) == .lt;
}

test "menu grouping, visibility, enablement and toggled state" {
    const allocator = std.testing.allocator;
    var factory = contextkey.ContextKeyExpr.init(allocator);
    defer factory.deinit();

    var registry = MenuRegistry.init(allocator);
    defer registry.deinit();

    const MenuIdTest = MenuId{ .id = "test.menu" };
    try registry.appendMenuGroup(MenuIdTest, "navigation", "Navigation");
    try registry.appendMenuItem(MenuIdTest, .{
        .command = .{ .id = "b", .title = "B" },
        .group = "navigation",
        .order = 2,
    });
    try registry.appendMenuItem(MenuIdTest, .{
        .command = .{ .id = "a", .title = "A", .precondition = try factory.has("enabled") },
        .group = "navigation",
        .order = 1,
    });
    try registry.appendMenuItem(MenuIdTest, .{
        .command = .{ .id = "hidden", .title = "Hidden" },
        .when = try factory.equals("view", .{ .string = "other" }),
    });
    try registry.appendMenuGroup(MenuIdTest, "2_group", "Group 2");
    try registry.appendMenuItem(MenuIdTest, .{
        .command = .{ .id = "c", .title = "C", .toggled = try factory.equals("checked", .{ .boolean = true }) },
        .group = "2_group",
    });

    var service = MenuService.init(allocator, &registry, null);
    defer service.deinit();
    const Context = struct {
        enabled: bool = false,
        checked: bool = false,
        fn context(self: *@This()) contextkey.IContext {
            return .{ .context = self, .get_value = getValue };
        }
        fn getValue(context_ptr: *anyopaque, key: []const u8) contextkey.ContextKeyValue {
            const self: *@This() = @ptrCast(@alignCast(context_ptr));
            if (std.mem.eql(u8, key, "enabled")) return .{ .boolean = self.enabled };
            if (std.mem.eql(u8, key, "checked")) return .{ .boolean = self.checked };
            return .undefined_value;
        }
    };
    var context = Context{};

    var menu = try service.createMenu(allocator, MenuIdTest, context.context());
    defer menu.deinit();

    try std.testing.expectEqual(@as(usize, 2), menu.groups.len);
    try std.testing.expectEqualStrings("navigation", menu.groups[0].id);
    try std.testing.expectEqualStrings("Navigation", menu.groups[0].title.?);
    try std.testing.expectEqual(@as(usize, 2), menu.groups[0].actions.len);
    try std.testing.expectEqualStrings("a", menu.groups[0].actions[0].id());
    try std.testing.expect(!menu.groups[0].actions[0].enabled());
    try std.testing.expectEqualStrings("b", menu.groups[0].actions[1].id());

    context.enabled = true;
    context.checked = true;
    var enabled_menu = try service.createMenu(allocator, MenuIdTest, context.context());
    defer enabled_menu.deinit();
    try std.testing.expect(enabled_menu.groups[0].actions[0].enabled());
    try std.testing.expect(enabled_menu.groups[1].actions[0].checked().?);
}

test "menu submenus flatten and drop empty branches" {
    const allocator = std.testing.allocator;
    var registry = MenuRegistry.init(allocator);
    defer registry.deinit();

    const parent = MenuId{ .id = "test.parent" };
    const child = MenuId{ .id = "test.child" };
    const empty = MenuId{ .id = "test.empty" };

    try registry.appendSubmenuItem(parent, .{ .title = "Child", .submenu = child });
    try registry.appendSubmenuItem(parent, .{ .title = "Empty", .submenu = empty });
    try registry.appendMenuItem(child, .{ .command = .{ .id = "child.command", .title = "Child Command" } });

    var service = MenuService.init(allocator, &registry, null);
    defer service.deinit();
    const Context = struct {
        fn context() contextkey.IContext {
            return .{ .context = @ptrFromInt(1), .get_value = getValue };
        }
        fn getValue(_: *anyopaque, _: []const u8) contextkey.ContextKeyValue {
            return .undefined_value;
        }
    };

    var menu = try service.createMenu(allocator, parent, Context.context());
    defer menu.deinit();

    try std.testing.expectEqual(@as(usize, 1), menu.groups.len);
    try std.testing.expectEqual(@as(usize, 1), menu.groups[0].actions.len);
    try std.testing.expectEqualStrings("submenuitem.test.child", menu.groups[0].actions[0].id());
}

test "menu hide state inverts hidden-by-default items" {
    const allocator = std.testing.allocator;
    var state = MenuHideState.init(allocator);
    defer state.deinit();

    const menu = MenuId{ .id = "test.hide" };
    state.setDefaultState(menu, "visible", false);
    state.setDefaultState(menu, "hiddenByDefault", true);

    try std.testing.expect(!state.isHidden(menu, "visible"));
    try std.testing.expect(state.isHidden(menu, "hiddenByDefault"));
    try std.testing.expect(!state.isModifiedFromDefault(menu, "visible"));

    state.updateHidden(menu, "visible", true);
    try std.testing.expect(state.isHidden(menu, "visible"));
    try std.testing.expect(state.isModifiedFromDefault(menu, "visible"));

    // Showing a hidden-by-default item stores the inverse.
    state.updateHidden(menu, "hiddenByDefault", false);
    try std.testing.expect(!state.isHidden(menu, "hiddenByDefault"));
    try std.testing.expect(state.isModifiedFromDefault(menu, "hiddenByDefault"));

    state.reset(menu);
    try std.testing.expect(!state.isHidden(menu, "visible"));
    try std.testing.expect(state.isHidden(menu, "hiddenByDefault"));
    try std.testing.expect(!state.isModifiedFromDefault(menu, "visible"));
}

test "menu hide state persists through storage" {
    const allocator = std.testing.allocator;
    var registry = MenuRegistry.init(allocator);
    defer registry.deinit();
    var storage = InMemoryStorageService.init(allocator);
    defer storage.deinit();

    const menu = MenuId{ .id = "test.persist" };

    var first = MenuService.initWithStorage(allocator, &registry, null, &storage);
    first.hide_state.setDefaultState(menu, "command", false);
    first.hide_state.updateHidden(menu, "command", true);
    try std.testing.expect(first.hide_state.isHidden(menu, "command"));
    first.deinit();

    var second = MenuService.initWithStorage(allocator, &registry, null, &storage);
    defer second.deinit();
    try std.testing.expect(second.hide_state.isHidden(menu, "command"));

    second.hide_state.reset(null);
    var third = MenuService.initWithStorage(allocator, &registry, null, &storage);
    defer third.deinit();
    try std.testing.expect(!third.hide_state.isHidden(menu, "command"));
}
