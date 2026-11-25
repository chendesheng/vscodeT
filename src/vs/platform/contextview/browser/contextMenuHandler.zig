// Port of src/vs/platform/contextview/browser/contextMenuHandler.ts.
// A terminal context view paints a ui.ContextMenu over the cell grid.
// The action context and menu-service snapshots live until its action returns.
const std = @import("std");
const ui = @import("ui");
const api = @import("../../actions/common/menuService.zig");
const IAction = @import("../../../base/common/actions.zig").IAction;

pub const Anchor = struct {
    x: usize,
    y: usize,
    opening_press: bool = false,

    pub fn mouse(event: *const ui.MouseEvent) Anchor {
        return .{ .x = event.x, .y = event.y, .opening_press = event.kind == .down };
    }
};

pub const Menu = struct {
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(ui.ContextMenuItem) = .empty,
    resolved: std.ArrayList(api.MenuActions) = .empty,
    popup: ?*ui.ContextMenu = null,
    opening_press: bool = false,
    context: *anyopaque,
    context_type: []const u8,
    run: *const fn (*anyopaque, []const u8) anyerror!void,
    selected: ?*Entry = null,

    const Entry = struct {
        owner: *Menu,
        action: union(enum) { command: []const u8, registered: IAction },

        fn click(context: ?*anyopaque, _: ui.ContextMenuEvent) void {
            const entry: *Entry = @ptrCast(@alignCast(context.?));
            entry.owner.selected = entry;
        }
    };

    pub fn init(allocator: std.mem.Allocator, value: anytype, comptime handler: fn (*@TypeOf(value), []const u8) anyerror!void) !*Menu {
        const T = @TypeOf(value);
        const menu = try allocator.create(Menu);
        errdefer allocator.destroy(menu);
        menu.arena = .init(allocator);
        errdefer menu.arena.deinit();
        const context = try menu.arena.allocator().create(T);
        context.* = value;
        menu.* = .{
            .arena = menu.arena,
            .context = context,
            .context_type = @typeName(T),
            .run = struct {
                fn invoke(ptr: *anyopaque, id: []const u8) !void {
                    try handler(@ptrCast(@alignCast(ptr)), id);
                }
            }.invoke,
        };
        return menu;
    }

    pub fn getActionsContext(self: *Menu, comptime T: type) ?*T {
        return if (std.mem.eql(u8, self.context_type, @typeName(T))) @ptrCast(@alignCast(self.context)) else null;
    }

    pub fn deinit(self: *Menu) void {
        const allocator = self.arena.child_allocator;
        if (self.popup) |popup| popup.deinit();
        for (self.resolved.items) |*actions| actions.deinit();
        self.arena.deinit();
        allocator.destroy(self);
    }

    fn clickable(self: *Menu, action: @FieldType(Entry, "action"), row: ui.ContextMenuItem) !ui.ContextMenuItem {
        const entry = try self.arena.allocator().create(Entry);
        entry.* = .{ .owner = self, .action = action };
        var item = row;
        item.click = .{ .context = entry, .callback = Entry.click };
        return item;
    }

    pub fn add(self: *Menu, id: []const u8, item: ui.ContextMenuItem) !void {
        try self.items.append(self.arena.allocator(), try self.clickable(.{ .command = id }, item));
    }

    /// Local upstream Action subclasses are allocated with this menu. The action
    /// and its arguments remain available through the hide event and dispatch.
    pub fn addAction(self: *Menu, id: []const u8, label: []const u8, checked: ?bool, value: anytype) !void {
        const T = @TypeOf(value);
        const arena = self.arena.allocator();
        const context = try arena.create(T);
        context.* = value;
        const Action = @import("../../../base/common/actions.zig").Action;
        const action = try arena.create(Action);
        action.* = Action.init(arena, id, label, null, true, struct {
            fn run(ptr: *anyopaque, _: ?*const anyopaque) !void {
                const target: *T = @ptrCast(@alignCast(ptr));
                return target.run();
            }
        }.run, context);
        action.checked_state = checked;
        try self.items.append(arena, try self.menuItem(action.interface()));
    }

    pub fn separator(self: *Menu) !void {
        try self.items.append(self.arena.allocator(), .{ .type = .separator });
    }

    pub fn appendMenuActions(self: *Menu, service: *api.MenuService, id: @import("../../actions/common/actions.zig").MenuId, context: @import("../../contextkey/common/contextkey.zig").IContext, exclude_navigation: bool) !void {
        const arena = self.arena.allocator();
        try self.resolved.ensureUnusedCapacity(arena, 1);
        const actions = try service.getMenuActions(arena, id, context);
        self.resolved.appendAssumeCapacity(actions);
        for (actions.groups) |group| {
            if (exclude_navigation and std.mem.eql(u8, group.id, "navigation")) continue;
            if (group.actions.len == 0) continue;
            if (self.items.items.len != 0) try self.separator();
            try self.createMenu(&self.items, group.actions);
        }
    }

    // NativeContextMenuService.createMenu represents group titles as disabled
    // rows. A labeled separator takes precedence over the first action's title.
    fn createMenu(self: *Menu, items: *std.ArrayList(ui.ContextMenuItem), entries: []const IAction) anyerror!void {
        const arena = self.arena.allocator();
        var group_start = true;
        var separator_label: []const u8 = "";
        for (entries) |action| {
            if (@import("../../../base/common/actions.zig").Separator.isSeparator(action)) {
                group_start = true;
                separator_label = action.label();
                if (separator_label.len != 0 and items.items.len == 0) continue;
                try items.append(arena, .{ .type = .separator });
                continue;
            }
            if (group_start) {
                group_start = false;
                const title = if (separator_label.len != 0) separator_label else if (api.MenuItemAction.from(action)) |item| item.group_title else if (api.SubmenuItemAction.from(action)) |submenu| submenu.group_title else null;
                if (title) |label| try items.append(arena, .{ .label = try self.nativeLabel(label), .enabled = false });
            }
            try items.append(arena, try self.menuItem(action));
        }
    }

    fn nativeLabel(self: *Menu, label: []const u8) ![]const u8 {
        // Electron escapes ampersands for native mnemonics. Cells display them literally.
        const plain = try @import("../../../base/common/iconLabels.zig").stripIcons(self.arena.allocator(), label);
        return std.mem.trim(u8, plain, " \t\n\r");
    }

    fn menuItem(self: *Menu, action: IAction) anyerror!ui.ContextMenuItem {
        if (api.SubmenuItemAction.from(action)) |submenu| {
            var children: std.ArrayList(ui.ContextMenuItem) = .empty;
            try self.createMenu(&children, submenu.actions);
            return .{ .type = .submenu, .label = try self.nativeLabel(action.label()), .enabled = action.enabled(), .submenu = children.items };
        }
        const checked = action.checked();
        const registered = api.MenuItemAction.from(action);
        const radio = if (registered) |item| if (item.item.toggled) |expr| expr.* == .Equals else false else false;
        const shortcut = if (registered) |item| item.keybindingLabel() else null;
        return self.clickable(.{ .registered = action }, .{ .label = try self.nativeLabel(action.label()), .enabled = action.enabled(), .type = if (radio) .radio else if (checked != null) .checkbox else .normal, .checked = checked orelse false, .accelerator = shortcut orelse "" });
    }

    pub fn runSelected(self: *Menu) !void {
        const entry = self.selected orelse return;
        switch (entry.action) {
            .command => |id| try self.run(self.context, id),
            .registered => |action| try action.execute(null),
        }
    }

    pub fn show(self: *Menu, anchor: Anchor, theme: ui.ContextMenuTheme) !void {
        self.opening_press = anchor.opening_press;
        self.popup = try ui.contextmenu.popup(self.arena.child_allocator, self.items.items, .{ .x = anchor.x, .y = anchor.y, .theme = theme }, null);
    }
};
