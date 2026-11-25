// Port of `src/vs/workbench/browser/parts/notifications/notificationsCommands.ts`.
// Terminal adaptation: the center and toast lists receive focus and input
// from the terminal host. Notification actions resolve the controller through
// the instantiation service instead of the workbench shell.
const std = @import("std");
const ui = @import("ui");
const model = @import("../../../common/notifications.zig");
const Service = @import("../../../services/notification/common/notificationService.zig").NotificationService;
const Statusbar = @import("../statusbar/statusbarPart.zig").StatusbarService;
const ThemeColors = @import("../../themeColors.zig").ThemeColors;
const Center = @import("./notificationsCenter.zig").NotificationsCenter;
const Toasts = @import("./notificationsToasts.zig").NotificationsToasts;
const Status = @import("./notificationsStatus.zig").NotificationsStatus;
const List = @import("./notificationsList.zig").NotificationsList;
const Queue = @import("../../../../base/common/windowDispatch.zig").Queue;
const contextkey = @import("../../../../platform/contextkey/common/contextkey.zig");
const instantiation = @import("../../../../platform/instantiation/common/instantiation.zig");
const actions = @import("../../../../platform/actions/common/actions.zig");
const registry = @import("../../commands.zig");
const keys = @import("../../../../base/common/keyCodes.zig");
const bindings = @import("../../../../platform/keybinding/common/keybindingsRegistry.zig");

pub const controller_id = instantiation.ServiceIdentifier(NotificationsController, "notificationsController");
const center_context: contextkey.Expr = .{ .Defined = "notificationCenterVisible" };
const toast_context: contextkey.Expr = .{ .Defined = "notificationToastsVisible" };

pub const NotificationsController = struct {
    allocator: std.mem.Allocator,
    service: *Service,
    center: *Center,
    toasts: *Toasts,
    status: *Status,
    list: List,
    host: Host,
    center_key: contextkey.IContextKey,
    toasts_key: contextkey.IContextKey,
    focus_key: contextkey.IContextKey,
    center_focus: bool = false,
    position: model.NotificationsPosition = .bottom_right,
    center_visibility: usize,
    toasts_visibility: usize,
    center_listener: usize,
    toasts_listener: usize,

    pub const Host = struct {
        context: *anyopaque,
        request_frame: *const fn (*anyopaque) void,
        open_link: *const fn (*anyopaque, []const u8) anyerror!void,
        focus_editor: *const fn (*anyopaque) void,
    };
    pub fn create(allocator: std.mem.Allocator, service: *Service, statusbar: *Statusbar, window: *Queue, context_keys: contextkey.IContextKeyService, host: Host) !*NotificationsController {
        const self = try allocator.create(NotificationsController);
        errdefer allocator.destroy(self);
        const center = try Center.create(allocator, &service.model);
        errdefer center.deinit();
        const toasts = try Toasts.create(allocator, &service.model, window);
        errdefer toasts.deinit();
        const status = try Status.create(allocator, service, statusbar, window, host.context, host.request_frame);
        errdefer status.deinit();
        self.* = .{ .allocator = allocator, .service = service, .center = center, .toasts = toasts, .status = status, .list = .init(allocator), .host = host, .center_key = try context_keys.createKey("notificationCenterVisible", .{ .boolean = false }), .toasts_key = undefined, .focus_key = undefined, .center_visibility = undefined, .toasts_visibility = undefined, .center_listener = undefined, .toasts_listener = undefined };
        errdefer self.center_key.dispose();
        self.toasts_key = try context_keys.createKey("notificationToastsVisible", .{ .boolean = false });
        errdefer self.toasts_key.dispose();
        self.focus_key = try context_keys.createKey("notificationFocus", .{ .boolean = false });
        errdefer self.focus_key.dispose();
        self.center_visibility = try center.on_did_change_visibility.listen(self, centerVisibility);
        errdefer center.on_did_change_visibility.unlisten(self.center_visibility);
        self.toasts_visibility = try toasts.on_did_change_visibility.listen(self, toastsVisibility);
        errdefer toasts.on_did_change_visibility.unlisten(self.toasts_visibility);
        self.center_listener = try center.on_did_change.listen(self, changed);
        errdefer center.on_did_change.unlisten(self.center_listener);
        self.toasts_listener = try toasts.on_did_change.listen(self, changed);
        return self;
    }
    pub fn deinit(self: *NotificationsController) void {
        self.center.on_did_change_visibility.unlisten(self.center_visibility);
        self.toasts.on_did_change_visibility.unlisten(self.toasts_visibility);
        self.center.on_did_change.unlisten(self.center_listener);
        self.toasts.on_did_change.unlisten(self.toasts_listener);
        self.center_key.dispose();
        self.toasts_key.dispose();
        self.focus_key.dispose();
        self.status.deinit();
        self.center.deinit();
        self.toasts.deinit();
        self.list.deinit();
        self.allocator.destroy(self);
    }
    fn centerVisibility(_: void, self: *NotificationsController) !void {
        self.status.update(self.center.is_visible, self.toasts.is_visible);
        self.toasts.update(self.center.is_visible);
        self.center_key.set(.{ .boolean = self.center.is_visible });
        if (!self.center.is_visible and self.center_focus) {
            self.center_focus = false;
            self.host.focus_editor(self.host.context);
        }
        try changed({}, self);
    }
    fn toastsVisibility(_: void, self: *NotificationsController) !void {
        self.status.update(self.center.is_visible, self.toasts.is_visible);
        self.toasts_key.set(.{ .boolean = self.toasts.is_visible });
        if (!self.toasts.is_visible) self.toasts.focus_index = null;
        try changed({}, self);
    }
    fn changed(_: void, self: *NotificationsController) !void {
        self.list.invalidate();
        self.requestFrame();
    }
    fn requestFrame(self: *NotificationsController) void {
        self.focus_key.set(.{ .boolean = (self.center.is_visible and self.center_focus) or self.toasts.focusedItem() != null });
        self.host.request_frame(self.host.context);
    }
    pub fn show(self: *NotificationsController) void {
        self.toasts.hide();
        self.center_focus = true;
        self.center.show();
        self.requestFrame();
    }
    pub fn hide(self: *NotificationsController) void {
        self.center.hide();
    }
    pub fn setPosition(self: *NotificationsController, position: model.NotificationsPosition) void {
        self.position = position;
        self.status.setPosition(position);
    }
    pub fn focusedItem(self: *const NotificationsController) ?*model.NotificationViewItem {
        return if (self.center_focus) self.center.focusedItem() else self.toasts.focusedItem();
    }
    fn acceptPrimary(self: *NotificationsController) !void {
        const item = self.focusedItem() orelse if (self.service.model.notifications.items.len > 0) self.service.model.notifications.items[0] else return;
        if (item.actions.primary.len != 0 and item.actions.primary[0].enabled()) try item.actions.primary[0].execute(null);
    }
    fn runHit(self: *NotificationsController, hit: List.Hit) !void {
        if (hit.item) |item| {
            if (std.mem.indexOfScalar(*model.NotificationViewItem, self.service.model.notifications.items, item) == null) return;
            switch (hit.action) {
                .row => {},
                .close => if (!item.hasActiveProgress()) item.close(),
                .toggle => item.toggle(),
                .primary => |index| if (index < item.actions.primary.len and item.actions.primary[index].enabled()) try item.actions.primary[index].execute(null),
                .secondary => |index| if (index < item.actions.secondary.len and item.actions.secondary[index].enabled()) try item.actions.secondary[index].execute(null),
                .link => |index| if (index < item.message.linked_text.nodes.len and item.message.linked_text.nodes[index] == .link) try self.host.open_link(self.host.context, item.message.linked_text.nodes[index].link.href),
                else => {},
            }
        } else switch (hit.action) {
            .clear_all => self.center.clearAll(),
            .hide => self.hide(),
            .filter => try self.toggleDoNotDisturb(),
            else => {},
        }
        self.requestFrame();
    }
    pub fn handleMouse(self: *NotificationsController, event: *const ui.MouseEvent) bool {
        const hit = self.list.hitAt(event.x, event.y);
        if (event.kind == .move) self.toasts.hovered = if (hit) |value| value.item else null;
        if (hit == null) {
            if (event.kind == .down and event.button == .left) {
                self.center_focus = false;
                self.toasts.focus_index = null;
                self.requestFrame();
            }
            return false;
        }
        if (event.kind == .down and event.button == .left) {
            if (hit.?.item) |item| {
                if (self.center.is_visible) {
                    self.center_focus = true;
                    if (std.mem.indexOfScalar(*model.NotificationViewItem, self.service.model.notifications.items, item)) |index| self.center.focus_index = index;
                } else {
                    for (self.toasts.toasts.items, 0..) |toast, index| {
                        if (toast.item == item) {
                            self.toasts.focus_index = index;
                            break;
                        }
                    }
                }
            }
            self.list.keyboard_hit = null;
            self.runHit(hit.?) catch {};
        } else if (event.kind == .wheel and self.center.is_visible) {
            if (event.delta_y > 0) self.center.focusNext() else self.center.focusPrevious();
        }
        return true;
    }
    pub fn handleKey(self: *NotificationsController, event: *const ui.KeyEvent) bool {
        if (self.focusedItem() == null and !(self.center_focus and self.center.is_visible)) return false;
        switch (event.key) {
            .escape => if (self.center.is_visible) self.hide() else self.toasts.hide(),
            .up => if (self.center.is_visible) self.center.focusPrevious() else {
                _ = self.toasts.focusPrevious();
            },
            .down => if (self.center.is_visible) self.center.focusNext() else {
                _ = self.toasts.focusNext();
            },
            .home, .page_up => if (self.center.is_visible) {
                self.center.focus_index = 0;
                self.center.scroll_index = 0;
            } else {
                _ = self.toasts.focusFirst();
            },
            .end, .page_down => if (self.center.is_visible) {
                self.center.focus_index = self.service.model.notifications.items.len -| 1;
            } else {
                _ = self.toasts.focusLast();
            },
            .right => if (self.focusedItem()) |item| item.expand(),
            .left => if (self.focusedItem()) |item| item.collapse(false),
            .delete => if (self.focusedItem()) |item| {
                if (!item.hasActiveProgress()) item.close();
            },
            .tab, .backtab => if (self.focusedItem()) |item| {
                _ = self.list.focusAction(item, event.key == .backtab or event.mods.shift);
            },
            .enter => if (self.focusedItem()) |item| {
                if (self.list.focusedAction(item)) |hit| self.runHit(hit) catch {} else item.toggle();
            },
            .char => |cp| if (cp == ' ') {
                if (self.focusedItem()) |item| item.toggle();
            } else return false,
            else => return false,
        }
        if (event.key != .tab and event.key != .backtab) self.list.keyboard_hit = null;
        self.requestFrame();
        return true;
    }
    pub fn render(self: *NotificationsController, doc: *const ui.Document, grid: *ui.CellGrid, theme: ?*const ThemeColors) !void {
        self.list.clear();
        const width = @min(grid.cols -| 2, 56);
        const max_height = grid.rows -| 2;
        if (width < 6 or max_height < 1) return;
        self.toasts.layout(width, max_height);
        const x: usize = if (self.position == .bottom_left) 1 else grid.cols -| width -| 1;
        if (self.center.is_visible) {
            const items = self.service.model.notifications.items;
            var height: usize = 1;
            for (items) |item| height = @min(max_height, height +| List.rowHeight(item, width, 2));
            height = @max(height, 1);
            self.center.scroll_index = @min(self.center.scroll_index, self.center.focus_index);
            var to_focus: usize = 1;
            for (items[self.center.scroll_index..@min(items.len, self.center.focus_index + 1)]) |item| to_focus += List.rowHeight(item, width, 2);
            while (to_focus > height and self.center.scroll_index < self.center.focus_index) {
                to_focus -= List.rowHeight(items[self.center.scroll_index], width, 2);
                self.center.scroll_index += 1;
            }
            const y = if (self.position == .top_right) 0 else grid.rows -| height -| 1;
            try self.list.renderHeader(&self.service.model, doc, grid, rectangle(x, y, width, 1), theme);
            var row = y + 1;
            for (items[self.center.scroll_index..], self.center.scroll_index..) |item, index| {
                if (row >= y + height) break;
                const row_height = @min(y + height - row, List.rowHeight(item, width, 2));
                try self.list.renderItem(item, doc, grid, rectangle(x, row, width, row_height), theme, self.center_focus and self.center.focus_index == index);
                row += row_height;
            }
        } else {
            var row = if (self.position == .top_right) @as(usize, 0) else grid.rows -| 1;
            for (self.toasts.toasts.items, 0..) |toast, index| {
                if (!toast.visible) continue;
                const height = self.toasts.heightFor(toast.item);
                const y = if (self.position == .top_right) row else row -| height;
                try self.list.renderItem(toast.item, doc, grid, rectangle(x, y, width, height), theme, self.toasts.focus_index == index);
                row = if (self.position == .top_right) row + height else y;
            }
        }
    }
    fn rectangle(x: usize, y: usize, width: usize, height: usize) ui.Rect {
        return .{ .x = @floatFromInt(x), .y = @floatFromInt(y), .w = @floatFromInt(width), .h = @floatFromInt(height) };
    }
    fn toggleDoNotDisturb(self: *NotificationsController) !void {
        try self.service.setFilter(if (self.service.getFilter(null) == .ERROR) .OFF else .ERROR);
    }
};

const Command = enum { show, hide, toggle, hide_toasts, focus, next, previous, first, last, collapse, expand, accept, toggle_item, clear, clear_all, dnd };
fn notificationAction(comptime command: Command, comptime id: []const u8, title: []const u8, f1: bool, condition: ?*const contextkey.Expr, comptime key: ?u32) actions.Action2 {
    return .{ .command = .{ .id = id, .title = title, .category = "Notifications", .precondition = condition }, .f1 = f1, .keybindings = if (key) |primary| &.{.{ .id = id, .weight = @backingInt(bindings.KeybindingWeight.WorkbenchContrib), .bindings = .{ .primary = primary } }} else &.{}, .context = @constCast(&{}), .run_fn = struct {
        fn run(_: *anyopaque, accessor: instantiation.ServicesAccessor) !void {
            const controller = try accessor.get(controller_id);
            switch (command) {
                .show => controller.show(),
                .hide => controller.hide(),
                .toggle => if (controller.center.is_visible) controller.hide() else controller.show(),
                .hide_toasts => controller.toasts.hide(),
                .focus => {
                    _ = controller.toasts.focusFirst();
                },
                .next => {
                    _ = controller.toasts.focusNext();
                },
                .previous => {
                    _ = controller.toasts.focusPrevious();
                },
                .first => {
                    _ = controller.toasts.focusFirst();
                },
                .last => {
                    _ = controller.toasts.focusLast();
                },
                .collapse => if (controller.focusedItem()) |item| item.collapse(false),
                .expand => if (controller.focusedItem()) |item| item.expand(),
                .toggle_item => if (controller.focusedItem()) |item| item.toggle(),
                .accept => try controller.acceptPrimary(),
                .clear => if (controller.focusedItem()) |item| {
                    if (!item.hasActiveProgress()) item.close();
                },
                .clear_all => controller.center.clearAll(),
                .dnd => try controller.toggleDoNotDisturb(),
            }
            controller.requestFrame();
        }
    }.run };
}

pub const notification_actions = [_]actions.Action2{
    notificationAction(.show, "notifications.showList", "Show Notifications", true, null, keys.KeyChord(keys.KeyMod.CtrlCmd | @backingInt(keys.KeyCode.KeyK), keys.KeyMod.CtrlCmd | keys.KeyMod.Shift | @backingInt(keys.KeyCode.KeyN))),
    notificationAction(.hide, "notifications.hideList", "Hide Notifications", true, &center_context, null),
    notificationAction(.toggle, "notifications.toggleList", "Toggle Notifications", false, null, null),
    notificationAction(.hide_toasts, "notifications.hideToasts", "Hide Notification Toasts", false, &toast_context, null),
    notificationAction(.focus, "notifications.focusToasts", "Focus Notification Toast", true, &toast_context, null),
    notificationAction(.next, "notifications.focusNextToast", "Focus Next Notification Toast", false, null, null),
    notificationAction(.previous, "notifications.focusPreviousToast", "Focus Previous Notification Toast", false, null, null),
    notificationAction(.first, "notifications.focusFirstToast", "Focus First Notification Toast", false, null, null),
    notificationAction(.last, "notifications.focusLastToast", "Focus Last Notification Toast", false, null, null),
    notificationAction(.collapse, "notification.collapse", "Collapse Notification", false, null, null),
    notificationAction(.expand, "notification.expand", "Expand Notification", false, null, null),
    notificationAction(.accept, "notification.acceptPrimaryAction", "Accept Notification Primary Action", true, null, null),
    notificationAction(.toggle_item, "notification.toggle", "Toggle Notification", false, null, null),
    notificationAction(.clear, "notification.clear", "Clear Notification", false, null, null),
    notificationAction(.clear_all, "notifications.clearAll", "Clear All Notifications", true, null, null),
    notificationAction(.dnd, "notifications.toggleDoNotDisturbMode", "Toggle Do Not Disturb Mode", true, null, null),
};

pub fn registerNotificationCommands(commands: *registry.CommandRegistry, service: *@import("../../../../platform/instantiation/common/instantiationService.zig").InstantiationService) !void {
    for (notification_actions) |action| try commands.registerAction(service, action);
}
