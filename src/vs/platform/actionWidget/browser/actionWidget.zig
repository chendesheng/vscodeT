// Port of `src/vs/platform/actionWidget/browser/actionWidget.ts`.
// The terminal context-menu handler is the existing native context-view
// surface: it supplies row focus, scrolling, hit testing and the shared
// window overlay. The portable action widget owns its active delegate.
const std = @import("std");
const list = @import("actionList.zig");
const menu = @import("../../contextview/browser/contextMenuService.zig");
const instantiation = @import("../../instantiation/common/instantiation.zig");

pub const IActionWidgetService = struct {
    context: *anyopaque,
    show_fn: *const fn (*anyopaque, []const list.IActionListItem, list.IActionListDelegate, menu.Anchor) anyerror!void,
    hide_fn: *const fn (*anyopaque, ?*anyopaque) void,
    visible_fn: *const fn (*anyopaque) bool,

    pub fn show(self: IActionWidgetService, entries: []const list.IActionListItem, delegate: list.IActionListDelegate, anchor: menu.Anchor) !void {
        try self.show_fn(self.context, entries, delegate, anchor);
    }
    pub fn hide(self: IActionWidgetService, owner: ?*anyopaque) void {
        self.hide_fn(self.context, owner);
    }
    pub fn isVisible(self: IActionWidgetService) bool {
        return self.visible_fn(self.context);
    }
};

pub const action_widget_service_id = instantiation.ServiceIdentifier(IActionWidgetService, "actionWidgetService");

pub const ActionWidgetService = struct {
    allocator: std.mem.Allocator,
    context_menu: menu.IContextMenuService,
    active: ?*MenuContext = null,

    const MenuContext = struct {
        owner: *ActionWidgetService,
        delegate: list.IActionListDelegate,
        menu: ?*menu.Menu = null,

        fn run(self: *MenuContext, id: []const u8) !void {
            try self.delegate.on_select(self.delegate.context, try std.fmt.parseInt(usize, id, 10), false);
        }
        fn hidden(context: *anyopaque) void {
            const self: *MenuContext = @ptrCast(@alignCast(context));
            if (self.owner.active == self) self.owner.active = null;
            self.delegate.on_hide(self.delegate.context, self.menu.?.selected == null);
        }
    };

    pub fn interface(self: *ActionWidgetService) IActionWidgetService {
        return .{ .context = self, .show_fn = show, .hide_fn = hide, .visible_fn = visible };
    }

    pub fn deinit(self: *ActionWidgetService) void {
        hide(self, null);
    }

    fn show(context: *anyopaque, entries: []const list.IActionListItem, delegate: list.IActionListDelegate, anchor: menu.Anchor) !void {
        const self: *ActionWidgetService = @ptrCast(@alignCast(context));
        hide(self, null);
        const popup = try menu.Menu.init(self.allocator, MenuContext{ .owner = self, .delegate = delegate }, MenuContext.run);
        errdefer popup.deinit();
        const value = popup.getActionsContext(MenuContext).?;
        value.menu = popup;
        popup.on_hide = MenuContext.hidden;
        const a = popup.arena.allocator();
        for (entries) |item| {
            const label = try a.dupe(u8, item.label);
            if (item.kind == .Header) {
                if (popup.items.items.len != 0) try popup.separator();
                try popup.items.append(a, .{ .label = label, .enabled = false });
            } else {
                const id = try std.fmt.allocPrint(a, "{d}", .{item.item orelse continue});
                try popup.add(id, .{ .label = label, .enabled = !item.disabled, .accelerator = try a.dupe(u8, item.keybinding) });
            }
        }
        if (popup.items.items.len == 0) {
            popup.deinit();
            delegate.on_hide(delegate.context, true);
            return;
        }
        self.active = value;
        errdefer self.active = null;
        try self.context_menu.showContextMenu(popup, anchor);
    }

    fn hide(context: *anyopaque, owner: ?*anyopaque) void {
        const self: *ActionWidgetService = @ptrCast(@alignCast(context));
        const value = self.active orelse return;
        if (owner != null and owner != value.delegate.context) return;
        self.context_menu.hideContextMenu();
    }

    fn visible(context: *anyopaque) bool {
        const self: *ActionWidgetService = @ptrCast(@alignCast(context));
        return self.active != null;
    }
};
