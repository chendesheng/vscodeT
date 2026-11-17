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
const Emitter = @import("../../../base/common/event.zig").Emitter;
const ArrayList = std.array_list.Managed;
const actions = @import("actions.zig");
const action_module = @import("../../action/common/action.zig");
const commands = @import("../../commands/common/commands.zig");
const contextkey = @import("../../contextkey/common/contextkey.zig");
const base_actions = @import("../../../base/common/actions.zig");
const storage_mod = @import("../../storage/common/storage.zig");
const keybinding_registry_mod = @import("../../keybinding/common/keybindingsRegistry.zig");
const us_layout = @import("../../keybinding/common/usLayoutResolvedKeybinding.zig");
const platform = @import("../../../base/common/platform.zig");
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

pub const MenuActions = struct {
    arena: std.heap.ArenaAllocator,
    groups: []const MenuGroup,

    pub fn deinit(self: *MenuActions) void {
        self.arena.deinit();
    }
};

pub const Menu = struct {
    allocator: Allocator,
    service: *MenuService,
    id: MenuId,
    context: contextkey.IContext,
    arena: std.heap.ArenaAllocator,
    groups: []const MenuGroup,
    menu_ids: std.StringHashMap(void),
    context_keys: std.StringHashMap(void),
    onDidChange: Emitter(void),
    registry_listener: usize,
    context_listener: ?usize = null,

    pub fn deinit(self: *Menu) void {
        self.service.registry.on_did_change.unlisten(self.registry_listener);
        if (self.context_listener) |id| {
            if (self.service.context_service) |service| service.onDidChangeContext.unlisten(id);
        }
        self.onDidChange.deinit();
        freeMenuIds(self.allocator, &self.menu_ids);
        freeMenuIds(self.allocator, &self.context_keys);
        self.arena.deinit();
    }

    pub fn getActions(self: *const Menu) []const MenuGroup {
        return self.groups;
    }

    /// Rebuilds the menu from the registry. Upstream also recomputes when
    /// context keys change; the terminal host has no observable
    /// `IContextKeyService` yet, so only registry changes are tracked.
    pub fn refresh(self: *Menu) !void {
        self.arena.deinit();
        self.arena = std.heap.ArenaAllocator.init(self.allocator);
        freeMenuIds(self.allocator, &self.menu_ids);
        freeMenuIds(self.allocator, &self.context_keys);
        self.groups = try self.service.buildGroups(self.arena.allocator(), self.id, self.context, &self.menu_ids, &self.context_keys);
    }

    fn onRegistryChange(event: actions.MenuChangeEvent, menu: *Menu) anyerror!void {
        if (!menu.menu_ids.contains(event.menu.id)) return;
        menu.refresh() catch {};
        try menu.onDidChange.fire({});
    }

    /// Context keys drive visibility/precondition/toggled state. Refresh only
    /// when a changed key is one the menu actually depends on (upstream
    /// `affectsSome`).
    fn onContextChange(event: contextkey.ContextKeyChangeEvent, menu: *Menu) anyerror!void {
        var affected = false;
        var iterator = menu.context_keys.iterator();
        while (iterator.next()) |entry| {
            const single = [_][]const u8{entry.key_ptr.*};
            if (event.affectsSome(&single)) {
                affected = true;
                break;
            }
        }
        if (!affected) return;
        menu.refresh() catch {};
        try menu.onDidChange.fire({});
    }
};

pub const MenuItemAction = struct {
    item: ICommandAction,
    enabled: bool,
    checked: ?bool,
    hidden: bool,
    is_modified_from_default: bool,
    label: []const u8,
    keybinding_label: ?[]const u8,
    tooltip: []const u8,
    group_title: ?[]const u8,
    alt: ?*const IAction = null,
    command_registry: ?*commands.CommandRegistry,
    menu: MenuId,
    hide_state: *MenuHideState,

    pub fn toggleHidden(self: *MenuItemAction) void {
        self.hide_state.updateHidden(self.menu, self.item.id, !self.hide_state.isHidden(self.menu, self.item.id));
    }

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

    /// Default keybinding label, as a keybinding service would report it.
    pub fn keybindingLabel(self: *const MenuItemAction) ?[]const u8 {
        return self.keybinding_label;
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

fn addMenuId(allocator: Allocator, set: *std.StringHashMap(void), id: MenuId) !void {
    if (set.contains(id.id)) return;
    try set.put(try allocator.dupe(u8, id.id), {});
}

fn collectEntryKeys(allocator: Allocator, set: *std.StringHashMap(void), entry: *const MenuEntry) !void {
    const when = switch (entry.*) {
        .command => |item| item.when,
        .submenu => |item| item.when,
    };
    if (when) |expression| try addKeys(allocator, set, expression);
    switch (entry.*) {
        .command => |item| {
            if (item.command.precondition) |expression| try addKeys(allocator, set, expression);
            if (item.command.toggled) |expression| try addKeys(allocator, set, expression);
            if (item.command.toggle_info) |info| try addKeys(allocator, set, info.condition);
        },
        .submenu => |item| {
            if (item.toggled) |expression| try addKeys(allocator, set, expression);
        },
    }
}

fn addKeys(allocator: Allocator, set: *std.StringHashMap(void), expression: *const contextkey.Expr) !void {
    const keys = try expression.keys(allocator);
    defer allocator.free(keys);
    for (keys) |key| {
        if (set.contains(key)) continue;
        try set.put(try allocator.dupe(u8, key), {});
    }
}

fn freeMenuIds(allocator: Allocator, set: *std.StringHashMap(void)) void {
    var iterator = set.iterator();
    while (iterator.next()) |entry| allocator.free(entry.key_ptr.*);
    set.deinit();
    set.* = std.StringHashMap(void).init(allocator);
}

pub const MenuService = struct {
    allocator: Allocator,
    registry: *MenuRegistry,
    command_registry: ?*commands.CommandRegistry,
    hide_state: MenuHideState,
    keybindings: ?*keybinding_registry_mod.KeybindingsRegistry = null,
    context_service: ?*contextkey.ContextKeyService = null,
    os: platform.OperatingSystem = platform.OS,

    pub fn useContextService(self: *MenuService, service: *contextkey.ContextKeyService) void {
        self.context_service = service;
    }

    pub fn initWithKeybindings(
        allocator: Allocator,
        registry: *MenuRegistry,
        command_registry: ?*commands.CommandRegistry,
        keybindings: *keybinding_registry_mod.KeybindingsRegistry,
    ) MenuService {
        var service = init(allocator, registry, command_registry);
        service.keybindings = keybindings;
        return service;
    }

    pub fn resetHiddenStates(self: *MenuService, menu: ?MenuId) void {
        self.hide_state.reset(menu);
    }

    fn keybindingLabel(self: *MenuService, allocator: Allocator, command_id: []const u8, context: contextkey.IContext) !?[]const u8 {
        const registry = self.keybindings orelse return null;
        const items = try registry.getDefaultKeybindingsForOS(allocator, self.os);
        // Items are arena-allocated by the menu; only their decoded keybindings
        // need the normal cleanup path, which the arena performs on deinit.
        for (items) |item| {
            if (item.command == null or !std.mem.eql(u8, item.command.?, command_id)) continue;
            if (item.when) |expression| {
                if (!expression.evaluate(context)) continue;
            }
            const keybinding = item.keybinding orelse continue;
            const resolved = try us_layout.USLayoutResolvedKeybinding.resolveKeybinding(allocator, keybinding, self.os) orelse continue;
            if (resolved.base.getLabel()) |label| return label;
        }
        return null;
    }

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

    /// One-shot resolution without listeners (upstream `getMenuActions`).
    pub fn getMenuActions(self: *MenuService, allocator: Allocator, id: MenuId, context: contextkey.IContext) !MenuActions {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        var menu_ids = std.StringHashMap(void).init(allocator);
        defer freeMenuIds(allocator, &menu_ids);
        var context_keys = std.StringHashMap(void).init(allocator);
        defer freeMenuIds(allocator, &context_keys);
        const groups = try self.buildGroups(arena.allocator(), id, context, &menu_ids, &context_keys);
        return .{ .arena = arena, .groups = groups };
    }

    /// Context keys referenced by a menu, in first-seen order; caller frees.
    pub fn getMenuContexts(self: *MenuService, allocator: Allocator, id: MenuId) ![]const []const u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var menu_ids = std.StringHashMap(void).init(allocator);
        defer freeMenuIds(allocator, &menu_ids);
        var context_keys = std.StringHashMap(void).init(allocator);
        defer freeMenuIds(allocator, &context_keys);
        const empty_context = contextkey.IContext{
            .context = @ptrFromInt(1),
            .get_value = emptyGetValue,
        };
        _ = try self.buildGroups(arena.allocator(), id, empty_context, &menu_ids, &context_keys);
        const result = try allocator.alloc([]const u8, context_keys.count());
        var index: usize = 0;
        var iterator = context_keys.iterator();
        while (iterator.next()) |entry| : (index += 1) {
            result[index] = try allocator.dupe(u8, entry.key_ptr.*);
        }
        return result;
    }

    fn emptyGetValue(_: *anyopaque, _: []const u8) contextkey.ContextKeyValue {
        return .undefined_value;
    }

    /// Resolves a menu: visibility filtering, upstream sorting/grouping, group
    /// titles, enablement/toggled state and flattened submenus.
    pub fn createMenu(self: *MenuService, allocator: Allocator, id: MenuId, context: contextkey.IContext) !*Menu {
        const menu = try allocator.create(Menu);
        errdefer allocator.destroy(menu);
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        var menu_ids = std.StringHashMap(void).init(allocator);
        errdefer freeMenuIds(allocator, &menu_ids);
        var context_keys = std.StringHashMap(void).init(allocator);
        errdefer freeMenuIds(allocator, &context_keys);
        const groups = try self.buildGroups(arena.allocator(), id, context, &menu_ids, &context_keys);
        menu.* = .{
            .allocator = allocator,
            .service = self,
            .id = id,
            .context = context,
            .arena = arena,
            .groups = groups,
            .menu_ids = menu_ids,
            .context_keys = context_keys,
            .onDidChange = Emitter(void).init(allocator),
            .registry_listener = try self.registry.on_did_change.listen(menu, Menu.onRegistryChange),
        };
        if (self.context_service) |context_service| {
            menu.context_listener = try context_service.onDidChangeContext.listen(menu, Menu.onContextChange);
        }
        return menu;
    }

    fn buildGroups(self: *MenuService, allocator: Allocator, id: MenuId, context: contextkey.IContext, menu_ids: *std.StringHashMap(void), context_keys: *std.StringHashMap(void)) ![]const MenuGroup {
        const meta_allocator = self.allocator;
        try addMenuId(meta_allocator, menu_ids, id);
        var visible = ArrayList(*const MenuEntry).init(allocator);
        defer visible.deinit();
        for (self.registry.getMenuItems(id)) |*entry| {
            try collectEntryKeys(meta_allocator, context_keys, entry);
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
                        const checked = toggleState(item.command, context);
                        const label = if (checked == true) blk: {
                            if (item.command.toggle_info) |info| {
                                if (info.title) |title| break :blk title;
                            }
                            break :blk item.command.title;
                        } else item.command.title;
                        const action = try allocator.create(MenuItemAction);
                        action.* = .{
                            .item = item.command,
                            .enabled = if (item.command.precondition) |when| when.evaluate(context) else true,
                            .checked = checked,
                            .hidden = self.hide_state.isHidden(id, item.command.id),
                            .is_modified_from_default = self.hide_state.isModifiedFromDefault(id, item.command.id),
                            .label = label,
                            .keybinding_label = self.keybindingLabel(allocator, item.command.id, context) catch null,
                            .tooltip = item.command.tooltip orelse "",
                            .group_title = group_title,
                            .command_registry = self.command_registry,
                            .menu = id,
                            .hide_state = &self.hide_state,
                        };
                        if (item.alt) |alt| {
                            const alt_action = try allocator.create(MenuItemAction);
                            const alt_checked = toggleState(alt, context);
                            alt_action.* = .{
                                .item = alt,
                                .enabled = if (alt.precondition) |when| when.evaluate(context) else true,
                                .checked = alt_checked,
                                .hidden = self.hide_state.isHidden(id, alt.id),
                                .is_modified_from_default = self.hide_state.isModifiedFromDefault(id, alt.id),
                                .label = if (alt_checked == true) blk: {
                                    if (alt.toggle_info) |info| {
                                        if (info.title) |title| break :blk title;
                                    }
                                    break :blk alt.title;
                                } else alt.title,
                                .keybinding_label = self.keybindingLabel(allocator, alt.id, context) catch null,
                                .tooltip = alt.tooltip orelse "",
                                .group_title = group_title,
                                .command_registry = self.command_registry,
                                .menu = id,
                                .hide_state = &self.hide_state,
                            };
                            const alt_interface = alt_action.interface();
                            const alt_storage = try allocator.create(IAction);
                            alt_storage.* = alt_interface;
                            action.alt = alt_storage;
                        }
                        try group_actions.append(action.interface());
                    },
                    .submenu => |submenu| {
                        const submenu_groups = try self.buildGroups(allocator, submenu.submenu, context, menu_ids, context_keys);
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

fn toggleState(command: ICommandAction, context: contextkey.IContext) ?bool {
    if (command.toggled) |toggled| return toggled.evaluate(context);
    if (command.toggle_info) |info| return info.condition.evaluate(context);
    return null;
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
    defer {
        menu.deinit();
        allocator.destroy(menu);
    }

    const groups = menu.getActions();
    try std.testing.expectEqual(@as(usize, 2), groups.len);
    try std.testing.expectEqualStrings("navigation", groups[0].id);
    try std.testing.expectEqualStrings("Navigation", groups[0].title.?);
    try std.testing.expectEqual(@as(usize, 2), groups[0].actions.len);
    try std.testing.expectEqualStrings("a", groups[0].actions[0].id());
    try std.testing.expect(!groups[0].actions[0].enabled());
    try std.testing.expectEqualStrings("b", groups[0].actions[1].id());

    context.enabled = true;
    context.checked = true;
    var enabled_menu = try service.createMenu(allocator, MenuIdTest, context.context());
    defer {
        enabled_menu.deinit();
        allocator.destroy(enabled_menu);
    }
    try std.testing.expect(enabled_menu.getActions()[0].actions[0].enabled());
    try std.testing.expect(enabled_menu.getActions()[1].actions[0].checked().?);
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
    defer {
        menu.deinit();
        allocator.destroy(menu);
    }

    try std.testing.expectEqual(@as(usize, 1), menu.getActions().len);
    try std.testing.expectEqual(@as(usize, 1), menu.getActions()[0].actions.len);
    try std.testing.expectEqualStrings("submenuitem.test.child", menu.getActions()[0].actions[0].id());
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

test "menu refreshes and emits changes on registry updates" {
    const allocator = std.testing.allocator;
    var registry = MenuRegistry.init(allocator);
    defer registry.deinit();

    const menu_id = MenuId{ .id = "test.live" };
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

    var menu = try service.createMenu(allocator, menu_id, Context.context());
    defer {
        menu.deinit();
        allocator.destroy(menu);
    }

    var changes: usize = 0;
    const Listener = struct {
        fn onChange(_: void, counter: *usize) anyerror!void {
            counter.* += 1;
        }
    };
    _ = try menu.onDidChange.listen(&changes, Listener.onChange);

    try registry.appendMenuItem(menu_id, .{ .command = .{ .id = "late", .title = "Late" } });
    try std.testing.expectEqual(@as(usize, 1), changes);
    try std.testing.expectEqual(@as(usize, 1), menu.getActions().len);
    try std.testing.expectEqualStrings("late", menu.getActions()[0].actions[0].id());
}

test "menu tracks nested submenu registrations" {
    const allocator = std.testing.allocator;
    var registry = MenuRegistry.init(allocator);
    defer registry.deinit();

    const parent = MenuId{ .id = "test.parent.live" };
    const child = MenuId{ .id = "test.child.live" };
    try registry.appendSubmenuItem(parent, .{ .title = "Child", .submenu = child });
    try registry.appendMenuItem(child, .{ .command = .{ .id = "one", .title = "One" } });

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
    defer {
        menu.deinit();
        allocator.destroy(menu);
    }

    var changes: usize = 0;
    const Listener = struct {
        fn onChange(_: void, counter: *usize) anyerror!void {
            counter.* += 1;
        }
    };
    _ = try menu.onDidChange.listen(&changes, Listener.onChange);

    try registry.appendMenuItem(child, .{ .command = .{ .id = "two", .title = "Two" } });
    try std.testing.expectEqual(@as(usize, 1), changes);
    const submenu_action: *SubmenuItemAction = @ptrCast(@alignCast(menu.getActions()[0].actions[0].context));
    try std.testing.expectEqual(@as(usize, 2), submenu_action.actions.len);
}

test "menu actions expose keybinding labels" {
    const allocator = std.testing.allocator;
    const key_codes = @import("../../../base/common/keyCodes.zig");
    var registry = MenuRegistry.init(allocator);
    defer registry.deinit();
    var keybindings = keybinding_registry_mod.KeybindingsRegistry.init(allocator);
    defer keybindings.deinit();
    var registration = try keybindings.registerKeybindingRule(.{
        .id = "test.labelled",
        .weight = 200,
        .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyK) },
    });
    defer registration.dispose();

    const menu_id = MenuId{ .id = "test.labels" };
    try registry.appendMenuItem(menu_id, .{ .command = .{ .id = "test.labelled", .title = "Labelled" } });

    const Context = struct {
        fn context() contextkey.IContext {
            return .{ .context = @ptrFromInt(1), .get_value = getValue };
        }
        fn getValue(_: *anyopaque, _: []const u8) contextkey.ContextKeyValue {
            return .undefined_value;
        }
    };

    var service = MenuService.initWithKeybindings(allocator, &registry, null, &keybindings);
    defer service.deinit();
    var menu = try service.createMenu(allocator, menu_id, Context.context());
    defer {
        menu.deinit();
        allocator.destroy(menu);
    }

    const action: *MenuItemAction = @ptrCast(@alignCast(menu.getActions()[0].actions[0].context));
    try std.testing.expect(action.keybindingLabel() != null);
    try std.testing.expect(action.keybindingLabel().?.len > 0);
}

test "menus refresh when context keys change" {
    const allocator = std.testing.allocator;
    var registry = MenuRegistry.init(allocator);
    defer registry.deinit();
    var context_keys = contextkey.ContextKeyService.init(allocator);
    defer context_keys.deinit();
    var factory = contextkey.ContextKeyExpr.init(allocator);
    defer factory.deinit();

    const menu_id = MenuId{ .id = "test.context.refresh" };
    try registry.appendMenuItem(menu_id, .{
        .command = .{ .id = "conditional", .title = "Conditional" },
        .when = try factory.has("show"),
    });

    var service = MenuService.init(allocator, &registry, null);
    defer service.deinit();
    service.useContextService(&context_keys);

    var menu = try service.createMenu(allocator, menu_id, context_keys.interface().getContext());
    defer {
        menu.deinit();
        allocator.destroy(menu);
    }
    try std.testing.expectEqual(@as(usize, 0), menu.getActions().len);

    var changes: usize = 0;
    const Listener = struct {
        fn onChange(_: void, counter: *usize) anyerror!void {
            counter.* += 1;
        }
    };
    _ = try menu.onDidChange.listen(&changes, Listener.onChange);

    const unrelated = try context_keys.createKey("other", .{ .boolean = true });
    unrelated.set(.{ .boolean = true });
    try std.testing.expectEqual(@as(usize, 0), changes);

    const key = try context_keys.createKey("show", .{ .boolean = true });
    key.set(.{ .boolean = true });
    try std.testing.expectEqual(@as(usize, 1), changes);
    try std.testing.expectEqual(@as(usize, 1), menu.getActions().len);
}

test "live menus unsubscribe from registry and context changes" {
    const allocator = std.testing.allocator;
    var registry = MenuRegistry.init(allocator);
    defer registry.deinit();
    var context_keys = contextkey.ContextKeyService.init(allocator);
    defer context_keys.deinit();

    const menu_id = MenuId{ .id = "test.unsubscribe" };
    var service = MenuService.init(allocator, &registry, null);
    defer service.deinit();
    service.useContextService(&context_keys);

    const Context = struct {
        fn context() contextkey.IContext {
            return .{ .context = @ptrFromInt(1), .get_value = getValue };
        }
        fn getValue(_: *anyopaque, _: []const u8) contextkey.ContextKeyValue {
            return .undefined_value;
        }
    };

    var menu = try service.createMenu(allocator, menu_id, Context.context());
    try std.testing.expectEqual(@as(usize, 1), registry.on_did_change.listenerCount());
    try std.testing.expectEqual(@as(usize, 1), context_keys.onDidChangeContext.listenerCount());

    menu.deinit();
    allocator.destroy(menu);
    try std.testing.expectEqual(@as(usize, 0), registry.on_did_change.listenerCount());
    try std.testing.expectEqual(@as(usize, 0), context_keys.onDidChangeContext.listenerCount());
}

test "createMenu collects menu items only once" {
    const allocator = std.testing.allocator;
    var registry = MenuRegistry.init(allocator);
    defer registry.deinit();
    var service = MenuService.init(allocator, &registry, null);
    defer service.deinit();

    const menu_id = MenuId{ .id = "test.collect.once" };
    const Context = struct {
        fn context() contextkey.IContext {
            return .{ .context = @ptrFromInt(1), .get_value = getValue };
        }
        fn getValue(_: *anyopaque, _: []const u8) contextkey.ContextKeyValue {
            return .undefined_value;
        }
    };

    var menu = try service.createMenu(allocator, menu_id, Context.context());
    defer {
        menu.deinit();
        allocator.destroy(menu);
    }
    try std.testing.expectEqual(@as(usize, 1), registry.getMenuItemsCallCount(menu_id));
}

test "one-shot getMenuActions evaluates each row context independently" {
    const allocator = std.testing.allocator;
    var registry = MenuRegistry.init(allocator);
    defer registry.deinit();
    var factory = contextkey.ContextKeyExpr.init(allocator);
    defer factory.deinit();
    const menu_id = MenuId{ .id = "test.row.context" };

    try registry.appendMenuItem(menu_id, .{
        .command = .{ .id = "file", .title = "File" },
        .when = try factory.equals("viewItem", .{ .string = "file" }),
    });
    try registry.appendMenuItem(menu_id, .{
        .command = .{ .id = "folder", .title = "Folder" },
        .when = try factory.equals("viewItem", .{ .string = "folder" }),
    });

    var service = MenuService.init(allocator, &registry, null);
    defer service.deinit();

    var expected = std.array_list.Managed([]const u8).init(allocator);
    defer expected.deinit();
    for (0..100) |index| {
        var row_context = contextkey.ContextKeyService.init(allocator);
        defer row_context.deinit();
        const key = try row_context.createKey("viewItem", .{ .string = if (index % 2 == 0) "file" else "folder" });
        key.set(.{ .string = if (index % 2 == 0) "file" else "folder" });
        try expected.append(if (index % 2 == 0) "file" else "folder");

        var menu_actions = try service.getMenuActions(allocator, menu_id, row_context.interface().getContext());
        defer menu_actions.deinit();
        try std.testing.expectEqual(@as(usize, 1), menu_actions.groups.len);
        try std.testing.expectEqual(@as(usize, 1), menu_actions.groups[0].actions.len);
        try std.testing.expectEqualStrings(expected.items[index], menu_actions.groups[0].actions[0].id());
    }

    const contexts = try service.getMenuContexts(allocator, menu_id);
    defer {
        for (contexts) |context| allocator.free(context);
        allocator.free(contexts);
    }
    try std.testing.expectEqual(@as(usize, 1), contexts.len);
    try std.testing.expectEqualStrings("viewItem", contexts[0]);
}

test "one-shot menus observe registrations synchronously" {
    const allocator = std.testing.allocator;
    var registry = MenuRegistry.init(allocator);
    defer registry.deinit();
    var factory = contextkey.ContextKeyExpr.init(allocator);
    defer factory.deinit();
    var service = MenuService.init(allocator, &registry, null);
    defer service.deinit();
    const menu_id = MenuId{ .id = "test.sync.registration" };

    _ = try registry.appendMenuItem(menu_id, .{ .command = .{ .id = "b", .title = "B" } });

    const GetIds = struct {
        fn run(alloc: Allocator, svc: *MenuService, id: MenuId) ![]const []const u8 {
            var menu_actions = try svc.getMenuActions(alloc, id, emptyContext());
            defer menu_actions.deinit();
            var ids = std.array_list.Managed([]const u8).init(alloc);
            for (menu_actions.groups) |group| for (group.actions) |action| try ids.append(try alloc.dupe(u8, action.id()));
            return ids.toOwnedSlice();
        }
        fn emptyContext() contextkey.IContext {
            return .{ .context = @ptrFromInt(1), .get_value = getValue };
        }
        fn getValue(_: *anyopaque, _: []const u8) contextkey.ContextKeyValue {
            return .undefined_value;
        }
    };

    const first = try GetIds.run(allocator, &service, menu_id);
    defer {
        for (first) |id| allocator.free(id);
        allocator.free(first);
    }
    try std.testing.expectEqual(@as(usize, 1), first.len);

    const registration = try registry.appendMenuItemTracked(menu_id, .{
        .command = .{ .id = "a", .title = "A" },
        .when = try factory.not("missing"),
    });
    const second = try GetIds.run(allocator, &service, menu_id);
    defer {
        for (second) |id| allocator.free(id);
        allocator.free(second);
    }
    try std.testing.expectEqual(@as(usize, 2), second.len);
    try std.testing.expectEqualStrings("a", second[0]);
    try std.testing.expectEqualStrings("b", second[1]);

    const contexts = try service.getMenuContexts(allocator, menu_id);
    defer {
        for (contexts) |key| allocator.free(key);
        allocator.free(contexts);
    }
    try std.testing.expectEqual(@as(usize, 1), contexts.len);
    try std.testing.expectEqualStrings("missing", contexts[0]);

    registration.dispose();
    const third = try GetIds.run(allocator, &service, menu_id);
    defer {
        for (third) |id| allocator.free(id);
        allocator.free(third);
    }
    try std.testing.expectEqual(@as(usize, 1), third.len);
}

test "one-shot and persistent menus use the same group and item ordering" {
    const allocator = std.testing.allocator;
    var registry = MenuRegistry.init(allocator);
    defer registry.deinit();
    var factory = contextkey.ContextKeyExpr.init(allocator);
    defer factory.deinit();
    var service = MenuService.init(allocator, &registry, null);
    defer service.deinit();
    const menu_id = MenuId{ .id = "test.ordering" };

    try registry.appendMenuItem(menu_id, .{ .command = .{ .id = "z", .title = "Z" } });
    try registry.appendMenuItem(menu_id, .{
        .command = .{ .id = "hidden", .title = "Hidden" },
        .when = try factory.has("hidden"),
    });
    try registry.appendMenuItem(menu_id, .{ .command = .{ .id = "a", .title = "A" } });
    try registry.appendMenuItem(menu_id, .{ .command = .{ .id = "first", .title = "First" }, .order = -1 });
    try registry.appendMenuItem(menu_id, .{
        .command = .{ .id = "navigation", .title = "Navigation" },
        .group = "navigation",
    });
    try registry.appendMenuItem(menu_id, .{
        .command = .{ .id = "localized", .title = "AAA" },
        .group = "primary",
    });
    try registry.appendMenuItem(menu_id, .{ .command = .{ .id = "middle", .title = "BBB" }, .group = "primary" });
    try registry.appendMenuItem(menu_id, .{ .command = .{ .id = "tie", .title = "BBC" }, .group = "primary" });

    const Context = struct {
        fn context() contextkey.IContext {
            return .{ .context = @ptrFromInt(1), .get_value = getValue };
        }
        fn getValue(_: *anyopaque, _: []const u8) contextkey.ContextKeyValue {
            return .undefined_value;
        }
    };

    var menu = try service.createMenu(allocator, menu_id, Context.context());
    defer {
        menu.deinit();
        allocator.destroy(menu);
    }
    var one_shot = try service.getMenuActions(allocator, menu_id, Context.context());
    defer one_shot.deinit();

    const Snapshot = struct {
        fn groups(alloc: Allocator, menu_groups: []const MenuGroup) ![]const []const []const u8 {
            var result = std.array_list.Managed([]const []const u8).init(alloc);
            for (menu_groups) |group| {
                var ids = std.array_list.Managed([]const u8).init(alloc);
                for (group.actions) |action| try ids.append(try alloc.dupe(u8, action.id()));
                try result.append(try ids.toOwnedSlice());
            }
            return result.toOwnedSlice();
        }
        fn freeGroups(alloc: Allocator, groups_value: []const []const []const u8) void {
            for (groups_value) |ids| {
                for (ids) |id| alloc.free(id);
                alloc.free(ids);
            }
            alloc.free(groups_value);
        }
    };

    const persistent = try Snapshot.groups(allocator, menu.getActions());
    defer Snapshot.freeGroups(allocator, persistent);
    const one = try Snapshot.groups(allocator, one_shot.groups);
    defer Snapshot.freeGroups(allocator, one);

    try std.testing.expectEqual(persistent.len, one.len);
    for (persistent, one) |expected, actual| {
        try std.testing.expectEqual(expected.len, actual.len);
        for (expected, actual) |expected_id, actual_id| {
            try std.testing.expectEqualStrings(expected_id, actual_id);
        }
    }

    try std.testing.expectEqual(@as(usize, 3), persistent.len);
    try std.testing.expectEqualStrings("navigation", persistent[0][0]);
    try std.testing.expectEqualStrings("localized", persistent[1][0]);
    try std.testing.expectEqualStrings("middle", persistent[1][1]);
    try std.testing.expectEqualStrings("tie", persistent[1][2]);
    try std.testing.expectEqualStrings("first", persistent[2][0]);
    try std.testing.expectEqualStrings("a", persistent[2][1]);
    try std.testing.expectEqualStrings("z", persistent[2][2]);
}

test "one-shot menus omit empty submenus and observe nested registrations" {
    const allocator = std.testing.allocator;
    var registry = MenuRegistry.init(allocator);
    defer registry.deinit();
    var service = MenuService.init(allocator, &registry, null);
    defer service.deinit();
    const parent = MenuId{ .id = "test.parent.submenu" };
    const child = MenuId{ .id = "test.child.submenu" };
    const nested = MenuId{ .id = "test.nested.submenu" };

    const parent_registration = try registry.appendSubmenuItemTracked(parent, .{ .title = "Submenu", .submenu = child });
    defer parent_registration.dispose();
    const child_registration = try registry.appendSubmenuItemTracked(child, .{ .title = "Nested submenu", .submenu = nested });
    defer child_registration.dispose();

    const Context = struct {
        fn context() contextkey.IContext {
            return .{ .context = @ptrFromInt(1), .get_value = getValue };
        }
        fn getValue(_: *anyopaque, _: []const u8) contextkey.ContextKeyValue {
            return .undefined_value;
        }
    };

    var before = try service.getMenuActions(allocator, parent, Context.context());
    defer before.deinit();
    try std.testing.expectEqual(@as(usize, 0), before.groups.len);

    const nested_registration = try registry.appendMenuItemTracked(nested, .{ .command = .{ .id = "nested", .title = "Nested" } });

    var during = try service.getMenuActions(allocator, parent, Context.context());
    defer during.deinit();
    try std.testing.expectEqual(@as(usize, 1), during.groups.len);
    try std.testing.expectEqual(@as(usize, 1), during.groups[0].actions.len);
    const submenu_action: *SubmenuItemAction = @ptrCast(@alignCast(during.groups[0].actions[0].context));
    try std.testing.expectEqual(@as(usize, 1), submenu_action.actions.len);
    const nested_action: *SubmenuItemAction = @ptrCast(@alignCast(submenu_action.actions[0].context));
    try std.testing.expectEqual(@as(usize, 1), nested_action.actions.len);
    try std.testing.expectEqualStrings("nested", nested_action.actions[0].id());

    nested_registration.dispose();

    var after = try service.getMenuActions(allocator, parent, Context.context());
    defer after.deinit();
    try std.testing.expectEqual(@as(usize, 0), after.groups.len);
}

test "one-shot menus observe implicit command palette items synchronously" {
    const allocator = std.testing.allocator;
    var registry = MenuRegistry.init(allocator);
    defer registry.deinit();
    var service = MenuService.init(allocator, &registry, null);
    defer service.deinit();

    const Contains = struct {
        fn run(alloc: Allocator, svc: *MenuService) !bool {
            var menu_actions = try svc.getMenuActions(alloc, actions.menu_ids.CommandPalette, context());
            defer menu_actions.deinit();
            for (menu_actions.groups) |group| {
                for (group.actions) |action| {
                    if (std.mem.eql(u8, action.id(), "implicit.command")) return true;
                }
            }
            return false;
        }
        fn context() contextkey.IContext {
            return .{ .context = @ptrFromInt(1), .get_value = getValue };
        }
        fn getValue(_: *anyopaque, _: []const u8) contextkey.ContextKeyValue {
            return .undefined_value;
        }
    };

    const before = try Contains.run(allocator, &service);
    const registration = try registry.addCommandTracked(.{ .id = "implicit.command", .title = "Implicit" });
    const during = try Contains.run(allocator, &service);
    registration.dispose();
    const after = try Contains.run(allocator, &service);

    try std.testing.expect(!before);
    try std.testing.expect(during);
    try std.testing.expect(!after);
}

test "one-shot menus evaluate submenu toggle state without checking children" {
    const allocator = std.testing.allocator;
    var registry = MenuRegistry.init(allocator);
    defer registry.deinit();
    var factory = contextkey.ContextKeyExpr.init(allocator);
    defer factory.deinit();
    var context_keys = contextkey.ContextKeyService.init(allocator);
    defer context_keys.deinit();
    var service = MenuService.init(allocator, &registry, null);
    defer service.deinit();

    const parent = MenuId{ .id = "test.toggle.parent" };
    const child = MenuId{ .id = "test.toggle.child" };
    const parent_registration = try registry.appendSubmenuItemTracked(parent, .{
        .title = "Submenu",
        .submenu = child,
        .toggled = try factory.has("submenuActive"),
    });
    defer parent_registration.dispose();
    const child_registration = try registry.appendMenuItemTracked(child, .{ .command = .{ .id = "child", .title = "Child" } });
    defer child_registration.dispose();

    const active = try context_keys.createKey("submenuActive", .{ .boolean = false });

    const Snapshot = struct {
        fn run(alloc: Allocator, svc: *MenuService, keys: *contextkey.ContextKeyService) !struct { checked: ?bool, child_checked: ?bool } {
            var menu_actions = try svc.getMenuActions(alloc, parent, keys.interface().getContext());
            defer menu_actions.deinit();
            const submenu: *SubmenuItemAction = @ptrCast(@alignCast(menu_actions.groups[0].actions[0].context));
            return .{
                .checked = submenu.checked,
                .child_checked = submenu.actions[0].checked(),
            };
        }
    };

    active.set(.{ .boolean = false });
    const inactive = try Snapshot.run(allocator, &service, &context_keys);
    active.set(.{ .boolean = true });
    const active_state = try Snapshot.run(allocator, &service, &context_keys);

    try std.testing.expectEqual(@as(?bool, false), inactive.checked);
    try std.testing.expect(inactive.child_checked == null);
    try std.testing.expectEqual(@as(?bool, true), active_state.checked);
    try std.testing.expect(active_state.child_checked == null);

    const contexts = try service.getMenuContexts(allocator, parent);
    defer {
        for (contexts) |key| allocator.free(key);
        allocator.free(contexts);
    }
    try std.testing.expectEqual(@as(usize, 1), contexts.len);
    try std.testing.expectEqualStrings("submenuActive", contexts[0]);
}

test "one-shot menus give actions their group title and keep plain separators" {
    const allocator = std.testing.allocator;
    var registry = MenuRegistry.init(allocator);
    defer registry.deinit();
    var factory = contextkey.ContextKeyExpr.init(allocator);
    defer factory.deinit();
    var service = MenuService.init(allocator, &registry, null);
    defer service.deinit();
    const parent = MenuId{ .id = "test.titles.parent" };
    const canvas = MenuId{ .id = "test.titles.canvas" };

    const files = try registry.appendMenuItemTracked(parent, .{ .command = .{ .id = "files", .title = "Files" }, .group = "navigation" });
    defer files.dispose();
    const canvas_submenu = try registry.appendSubmenuItemTracked(parent, .{ .title = "Canvas", .submenu = canvas, .group = "2_tools" });
    defer canvas_submenu.dispose();
    const recent = try registry.appendMenuItemTracked(canvas, .{ .command = .{ .id = "recent", .title = "Recent Plan" }, .group = "0_recent" });
    defer recent.dispose();
    const plan = try registry.appendMenuItemTracked(canvas, .{ .command = .{ .id = "plan", .title = "Plan" }, .group = "1_available" });
    defer plan.dispose();
    const hidden = try registry.appendMenuItemTracked(canvas, .{
        .command = .{ .id = "hidden", .title = "Hidden" },
        .group = "3_discover",
        .when = try factory.has("missing"),
    });
    defer hidden.dispose();
    const create = try registry.appendMenuItemTracked(canvas, .{ .command = .{ .id = "create", .title = "Create a Canvas" }, .group = "3_discover", .order = 1 });
    defer create.dispose();
    const browse = try registry.appendMenuItemTracked(canvas, .{ .command = .{ .id = "browse", .title = "Browse Canvases" }, .group = "3_discover", .order = 2 });
    defer browse.dispose();

    try registry.appendMenuGroup(parent, "2_tools", "Tools");
    try registry.appendMenuGroup(canvas, "0_recent", "Recent");
    try registry.appendMenuGroup(canvas, "3_discover", "Discover More");

    const Context = struct {
        fn context() contextkey.IContext {
            return .{ .context = @ptrFromInt(1), .get_value = getValue };
        }
        fn getValue(_: *anyopaque, _: []const u8) contextkey.ContextKeyValue {
            return .undefined_value;
        }
    };

    var menu_actions = try service.getMenuActions(allocator, parent, Context.context());
    defer menu_actions.deinit();
    try std.testing.expectEqual(@as(usize, 2), menu_actions.groups.len);
    try std.testing.expectEqualStrings("navigation", menu_actions.groups[0].id);
    try std.testing.expectEqual(@as(usize, 1), menu_actions.groups[0].actions.len);
    const files_action: *MenuItemAction = @ptrCast(@alignCast(menu_actions.groups[0].actions[0].context));
    try std.testing.expect(files_action.group_title == null);

    try std.testing.expectEqualStrings("2_tools", menu_actions.groups[1].id);
    const canvas_action: *SubmenuItemAction = @ptrCast(@alignCast(menu_actions.groups[1].actions[0].context));
    try std.testing.expectEqualStrings("Tools", canvas_action.group_title.?);
    try std.testing.expectEqual(@as(usize, 6), canvas_action.actions.len);

    const expected_ids = [_][]const u8{ "recent", "sep", "plan", "sep", "create", "browse" };
    const expected_titles = [_]?[]const u8{ "Recent", null, null, null, "Discover More", "Discover More" };
    for (canvas_action.actions, 0..) |action, index| {
        try std.testing.expectEqualStrings(expected_ids[index], action.id());
        if (std.mem.eql(u8, action.id(), "sep")) {
            const separator_action: *base_actions.Separator = @ptrCast(@alignCast(action.context));
            try std.testing.expect(separator_action.label_text == null);
        } else {
            const item_action: *MenuItemAction = @ptrCast(@alignCast(action.context));
            if (expected_titles[index]) |title| {
                try std.testing.expectEqualStrings(title, item_action.group_title.?);
            } else {
                try std.testing.expect(item_action.group_title == null);
            }
        }
    }
}

test "latest menu group description applies until disposed" {
    const allocator = std.testing.allocator;
    var registry = MenuRegistry.init(allocator);
    defer registry.deinit();
    var service = MenuService.init(allocator, &registry, null);
    defer service.deinit();
    const menu_id = MenuId{ .id = "test.group.stack" };
    const item_registration = try registry.appendMenuItemTracked(menu_id, .{
        .command = .{ .id = "create", .title = "Create a Canvas" },
        .group = "3_discover",
    });
    defer item_registration.dispose();

    const Context = struct {
        fn context() contextkey.IContext {
            return .{ .context = @ptrFromInt(1), .get_value = getValue };
        }
        fn getValue(_: *anyopaque, _: []const u8) contextkey.ContextKeyValue {
            return .undefined_value;
        }
    };

    var menu = try service.createMenu(allocator, menu_id, Context.context());
    defer {
        menu.deinit();
        allocator.destroy(menu);
    }

    const title = struct {
        fn get(menu_value: *Menu) ?[]const u8 {
            const action: *MenuItemAction = @ptrCast(@alignCast(menu_value.getActions()[0].actions[0].context));
            return action.group_title;
        }
    }.get;

    try std.testing.expect(title(menu) == null);
    const original = try registry.appendMenuGroupTracked(menu_id, "3_discover", "Discover More");
    try std.testing.expectEqualStrings("Discover More", title(menu).?);
    const override = try registry.appendMenuGroupTracked(menu_id, "3_discover", "Explore");
    try std.testing.expectEqualStrings("Explore", title(menu).?);
    override.dispose();
    try std.testing.expectEqualStrings("Discover More", title(menu).?);
    original.dispose();
    try std.testing.expect(title(menu) == null);
}

test "one-shot menus observe registered title, order and group changes" {
    const allocator = std.testing.allocator;
    var registry = MenuRegistry.init(allocator);
    defer registry.deinit();
    var service = MenuService.init(allocator, &registry, null);
    defer service.deinit();
    const menu_id = MenuId{ .id = "test.mutations" };

    const dynamic_registration = try registry.appendMenuItemTracked(menu_id, .{
        .command = .{ .id = "dynamic", .title = "A" },
        .group = "primary",
    });
    defer dynamic_registration.dispose();
    const fixed_registration = try registry.appendMenuItemTracked(menu_id, .{
        .command = .{ .id = "fixed", .title = "B" },
        .group = "primary",
    });
    defer fixed_registration.dispose();

    const Snapshot = struct {
        const Group = struct { id: []const u8, labels: []const []const u8 };
        fn run(alloc: Allocator, svc: *MenuService, id: MenuId) ![]const Group {
            var menu_actions = try svc.getMenuActions(alloc, id, context());
            defer menu_actions.deinit();
            var result = std.array_list.Managed(Group).init(alloc);
            for (menu_actions.groups) |group| {
                var labels = std.array_list.Managed([]const u8).init(alloc);
                for (group.actions) |action| try labels.append(try alloc.dupe(u8, action.label()));
                try result.append(.{ .id = try alloc.dupe(u8, group.id), .labels = try labels.toOwnedSlice() });
            }
            return result.toOwnedSlice();
        }
        fn free(alloc: Allocator, groups: []const Group) void {
            for (groups) |group| {
                alloc.free(group.id);
                for (group.labels) |label| alloc.free(label);
                alloc.free(group.labels);
            }
            alloc.free(groups);
        }
        fn context() contextkey.IContext {
            return .{ .context = @ptrFromInt(1), .get_value = getValue };
        }
        fn getValue(_: *anyopaque, _: []const u8) contextkey.ContextKeyValue {
            return .undefined_value;
        }
    };

    const first = try Snapshot.run(allocator, &service, menu_id);
    defer Snapshot.free(allocator, first);
    try std.testing.expectEqual(@as(usize, 1), first.len);
    try std.testing.expectEqualStrings("A", first[0].labels[0]);
    try std.testing.expectEqualStrings("B", first[0].labels[1]);

    const dynamic = registry.getMenuItemPtr(menu_id, "dynamic").?;
    dynamic.command.title = "Z";
    const second = try Snapshot.run(allocator, &service, menu_id);
    defer Snapshot.free(allocator, second);
    try std.testing.expectEqualStrings("B", second[0].labels[0]);
    try std.testing.expectEqualStrings("Z", second[0].labels[1]);

    dynamic.order = -1;
    const third = try Snapshot.run(allocator, &service, menu_id);
    defer Snapshot.free(allocator, third);
    try std.testing.expectEqualStrings("Z", third[0].labels[0]);
    try std.testing.expectEqualStrings("B", third[0].labels[1]);

    dynamic.group = "navigation";
    const fourth = try Snapshot.run(allocator, &service, menu_id);
    defer Snapshot.free(allocator, fourth);
    try std.testing.expectEqual(@as(usize, 2), fourth.len);
    try std.testing.expectEqualStrings("navigation", fourth[0].id);
    try std.testing.expectEqualStrings("Z", fourth[0].labels[0]);
    try std.testing.expectEqualStrings("primary", fourth[1].id);
    try std.testing.expectEqualStrings("B", fourth[1].labels[0]);
}

test "one-shot menus reevaluate enablement, toggled state and alternates" {
    const allocator = std.testing.allocator;
    var registry = MenuRegistry.init(allocator);
    defer registry.deinit();
    var factory = contextkey.ContextKeyExpr.init(allocator);
    defer factory.deinit();
    var context_keys = contextkey.ContextKeyService.init(allocator);
    defer context_keys.deinit();
    var service = MenuService.init(allocator, &registry, null);
    defer service.deinit();
    service.useContextService(&context_keys);
    const menu_id = MenuId{ .id = "test.reevaluate" };

    try registry.appendMenuItem(menu_id, .{
        .command = .{
            .id = "command",
            .title = "Command",
            .precondition = try factory.has("enabled"),
            .toggled = try factory.has("toggled"),
            .toggle_info = .{ .condition = try factory.has("toggled"), .title = "Toggled" },
        },
        .alt = .{ .id = "alt", .title = "Alternate", .precondition = try factory.has("enabled") },
    });

    const enabled = try context_keys.createKey("enabled", .{ .boolean = true });
    const toggled = try context_keys.createKey("toggled", .{ .boolean = false });
    const context = context_keys.interface().getContext();

    var menu = try service.createMenu(allocator, menu_id, context);
    defer {
        menu.deinit();
        allocator.destroy(menu);
    }

    const Check = struct {
        fn run(groups: []const MenuGroup, iteration: usize) !void {
            const action: *MenuItemAction = @ptrCast(@alignCast(groups[0].actions[0].context));
            if (iteration == 0) {
                try std.testing.expect(action.enabled);
                try std.testing.expectEqual(@as(?bool, false), action.checked);
                try std.testing.expectEqualStrings("Command", action.label);
                try std.testing.expect(action.alt.?.enabled());
            } else {
                try std.testing.expect(!action.enabled);
                try std.testing.expectEqual(@as(?bool, true), action.checked);
                try std.testing.expectEqualStrings("Toggled", action.label);
                try std.testing.expect(!action.alt.?.enabled());
            }
        }
    };

    for (0..2) |pass| {
        enabled.set(.{ .boolean = true });
        toggled.set(.{ .boolean = false });
        for (0..2) |iteration| {
            if (pass == 0) {
                try Check.run(menu.getActions(), iteration);
            } else {
                var one_shot = try service.getMenuActions(allocator, menu_id, context);
                defer one_shot.deinit();
                try Check.run(one_shot.groups, iteration);
            }
            enabled.set(.{ .boolean = false });
            toggled.set(.{ .boolean = true });
        }
    }
}

test "menu hidden-by-default state tracks divergence and resets" {
    const allocator = std.testing.allocator;
    var registry = MenuRegistry.init(allocator);
    defer registry.deinit();
    var service = MenuService.init(allocator, &registry, null);
    defer service.deinit();
    const menu_id = MenuId{ .id = "test.hidden.modified" };

    try registry.appendMenuItem(menu_id, .{ .command = .{ .id = "hiddenByDefault", .title = "Hidden By Default" }, .is_hidden_by_default = true });
    try registry.appendMenuItem(menu_id, .{ .command = .{ .id = "visibleByDefault", .title = "Visible By Default" } });

    const Context = struct {
        fn context() contextkey.IContext {
            return .{ .context = @ptrFromInt(1), .get_value = getValue };
        }
        fn getValue(_: *anyopaque, _: []const u8) contextkey.ContextKeyValue {
            return .undefined_value;
        }
    };

    const Flags = struct {
        fn read(alloc: Allocator, svc: *MenuService, id: MenuId) ![2]bool {
            var menu_actions = try svc.getMenuActions(alloc, id, context());
            defer menu_actions.deinit();
            const first: *MenuItemAction = @ptrCast(@alignCast(menu_actions.groups[0].actions[0].context));
            const second: *MenuItemAction = @ptrCast(@alignCast(menu_actions.groups[0].actions[1].context));
            return .{ first.is_modified_from_default, second.is_modified_from_default };
        }
        fn context() contextkey.IContext {
            return .{ .context = @ptrFromInt(1), .get_value = getValue };
        }
        fn getValue(_: *anyopaque, _: []const u8) contextkey.ContextKeyValue {
            return .undefined_value;
        }
    };

    const initial = try Flags.read(allocator, &service, menu_id);
    try std.testing.expectEqual([2]bool{ false, false }, initial);

    var menu_actions = try service.getMenuActions(allocator, menu_id, Context.context());
    const first: *MenuItemAction = @ptrCast(@alignCast(menu_actions.groups[0].actions[0].context));
    first.toggleHidden();
    menu_actions.deinit();

    menu_actions = try service.getMenuActions(allocator, menu_id, Context.context());
    const second: *MenuItemAction = @ptrCast(@alignCast(menu_actions.groups[0].actions[1].context));
    second.toggleHidden();
    menu_actions.deinit();

    const modified = try Flags.read(allocator, &service, menu_id);
    try std.testing.expectEqual([2]bool{ true, true }, modified);

    service.resetHiddenStates(menu_id);
    const reset = try Flags.read(allocator, &service, menu_id);
    try std.testing.expectEqual([2]bool{ false, false }, reset);
}

test "one-shot menu contexts observe changes to registered expressions" {
    const allocator = std.testing.allocator;
    var registry = MenuRegistry.init(allocator);
    defer registry.deinit();
    var factory = contextkey.ContextKeyExpr.init(allocator);
    defer factory.deinit();
    var service = MenuService.init(allocator, &registry, null);
    defer service.deinit();
    const menu_id = MenuId{ .id = "test.context.mutations" };

    const item = try registry.appendMenuItemTracked(menu_id, .{
        .command = .{
            .id = "command",
            .title = "Command",
            .precondition = try factory.has("enabled"),
            .toggled = try factory.has("toggled"),
        },
        .when = try factory.has("visible"),
    });
    defer item.dispose();

    const Sort = struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    };
    const Contexts = struct {
        fn read(alloc: Allocator, svc: *MenuService, id: MenuId) ![]const []const u8 {
            const contexts = try svc.getMenuContexts(alloc, id);
            std.mem.sort([]const u8, @constCast(contexts), {}, Sort.lessThan);
            return contexts;
        }
    };
    const Free = struct {
        fn run(alloc: Allocator, contexts: []const []const u8) void {
            for (contexts) |key| alloc.free(key);
            alloc.free(contexts);
        }
    };

    const first = try Contexts.read(allocator, &service, menu_id);
    defer Free.run(allocator, first);
    try std.testing.expectEqual(@as(usize, 3), first.len);
    try std.testing.expectEqualStrings("enabled", first[0]);
    try std.testing.expectEqualStrings("toggled", first[1]);
    try std.testing.expectEqualStrings("visible", first[2]);

    const mutable = registry.getMenuItemPtr(menu_id, "command").?;
    mutable.when = try factory.has("newVisible");
    mutable.command.precondition = try factory.has("newEnabled");
    mutable.command.toggled = try factory.has("newToggled");

    const second = try Contexts.read(allocator, &service, menu_id);
    defer Free.run(allocator, second);
    try std.testing.expectEqual(@as(usize, 3), second.len);
    try std.testing.expectEqualStrings("newEnabled", second[0]);
    try std.testing.expectEqualStrings("newToggled", second[1]);
    try std.testing.expectEqualStrings("newVisible", second[2]);
}

test "one-shot menus observe implicit palette exclusions from alternate changes" {
    const allocator = std.testing.allocator;
    var registry = MenuRegistry.init(allocator);
    defer registry.deinit();
    var service = MenuService.init(allocator, &registry, null);
    defer service.deinit();

    const first = try registry.addCommandTracked(.{ .id = "testo/prefix/first", .title = "First" });
    defer first.dispose();
    const second = try registry.addCommandTracked(.{ .id = "testo/prefix/second", .title = "Second" });
    defer second.dispose();

    const explicit = try registry.appendMenuItemTracked(actions.menu_ids.CommandPalette, .{
        .command = .{ .id = "testo/prefix/explicit", .title = "Explicit" },
        .alt = .{ .id = "testo/prefix/first", .title = "First" },
    });
    defer explicit.dispose();

    const Snapshot = struct {
        fn run(alloc: Allocator, svc: *MenuService) ![]const []const u8 {
            var menu_actions = try svc.getMenuActions(alloc, actions.menu_ids.CommandPalette, context());
            defer menu_actions.deinit();
            var labels = std.array_list.Managed([]const u8).init(alloc);
            for (menu_actions.groups) |group| {
                for (group.actions) |action| {
                    if (std.mem.startsWith(u8, action.id(), "testo/prefix/")) {
                        try labels.append(try alloc.dupe(u8, action.label()));
                    }
                }
            }
            return labels.toOwnedSlice();
        }
        fn context() contextkey.IContext {
            return .{ .context = @ptrFromInt(1), .get_value = getValue };
        }
        fn getValue(_: *anyopaque, _: []const u8) contextkey.ContextKeyValue {
            return .undefined_value;
        }
    };

    const first_snapshot = try Snapshot.run(allocator, &service);
    defer {
        for (first_snapshot) |label| allocator.free(label);
        allocator.free(first_snapshot);
    }
    try std.testing.expectEqual(@as(usize, 2), first_snapshot.len);
    try std.testing.expectEqualStrings("Explicit", first_snapshot[0]);
    try std.testing.expectEqualStrings("Second", first_snapshot[1]);

    registry.getMenuItemPtr(actions.menu_ids.CommandPalette, "testo/prefix/explicit").?.alt = .{
        .id = "testo/prefix/second",
        .title = "Second",
    };

    const second_snapshot = try Snapshot.run(allocator, &service);
    defer {
        for (second_snapshot) |label| allocator.free(label);
        allocator.free(second_snapshot);
    }
    try std.testing.expectEqual(@as(usize, 2), second_snapshot.len);
    try std.testing.expectEqualStrings("Explicit", second_snapshot[0]);
    try std.testing.expectEqualStrings("First", second_snapshot[1]);
}
