// Port of `src/vs/platform/actionWidget/browser/actionWidget.ts`.
// The terminal context-menu handler is the existing native context-view
// surface: it supplies row focus, scrolling, hit testing and the shared
// window overlay. The portable action widget owns its active delegate.
const std = @import("std");
const ui = @import("ui");
const list = @import("actionList.zig");
const menu = @import("../../contextview/browser/contextMenuService.zig");
const contextkey = @import("../../contextkey/common/contextkey.zig");
const actions = @import("../../actions/common/actions.zig");
const keycodes = @import("../../../base/common/keyCodes.zig");
const keybindings = @import("../../keybinding/common/keybindingsRegistry.zig");
const instantiation = @import("../../instantiation/common/instantiation.zig");

pub const Action = enum { hide, previous, next, accept, preview };

pub const IActionWidgetService = struct {
    context: *anyopaque,
    show_fn: *const fn (*anyopaque, []const list.IActionListItem, list.IActionListDelegate, menu.Anchor) anyerror!void,
    hide_fn: *const fn (*anyopaque, ?*anyopaque) void,
    visible_fn: *const fn (*anyopaque) bool,
    action_fn: *const fn (*anyopaque, Action) void,

    pub fn show(self: IActionWidgetService, entries: []const list.IActionListItem, delegate: list.IActionListDelegate, anchor: menu.Anchor) !void {
        try self.show_fn(self.context, entries, delegate, anchor);
    }
    pub fn hide(self: IActionWidgetService, owner: ?*anyopaque) void {
        self.hide_fn(self.context, owner);
    }
    pub fn runAction(self: IActionWidgetService, action: Action) void {
        self.action_fn(self.context, action);
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
    visible_key: ?contextkey.IContextKey = null,

    const MenuContext = struct {
        owner: *ActionWidgetService,
        delegate: list.IActionListDelegate,
        menu: ?*menu.Menu = null,

        fn run(self: *MenuContext, id: []const u8) !void {
            try self.delegate.on_select(self.delegate.context, try std.fmt.parseInt(usize, id, 10), self.menu.?.preview_activation);
        }
        fn focused(context: *anyopaque, id: ?[]const u8) void {
            const self: *MenuContext = @ptrCast(@alignCast(context));
            if (self.delegate.on_focus) |notify| notify(self.delegate.context, if (id) |value| std.fmt.parseInt(usize, value, 10) catch null else null);
        }
        fn mapKey(_: *anyopaque, event: ui.KeyEvent) ui.KeyEvent {
            if (!event.mods.ctrl) return event;
            return switch (event.key) {
                .char => |ch| switch (ch) {
                    '.' => .{ .key = .enter },
                    'p' => .{ .key = .up },
                    'n' => .{ .key = .down },
                    else => event,
                },
                else => event,
            };
        }
        fn hidden(context: *anyopaque) void {
            const self: *MenuContext = @ptrCast(@alignCast(context));
            if (self.owner.active == self) {
                self.owner.active = null;
                self.owner.setVisible(false);
            }
            self.delegate.on_hide(self.delegate.context, self.menu.?.selected == null);
        }
    };

    pub fn interface(self: *ActionWidgetService) IActionWidgetService {
        return .{ .context = self, .show_fn = show, .hide_fn = hide, .visible_fn = visible, .action_fn = runAction };
    }

    pub fn deinit(self: *ActionWidgetService) void {
        hide(self, null);
        if (self.visible_key) |key| key.dispose();
        self.visible_key = null;
    }

    pub fn bindContextKeys(self: *ActionWidgetService, service: contextkey.IContextKeyService) !void {
        if (self.visible_key) |key| key.dispose();
        self.visible_key = try service.createKey("codeActionMenuVisible", .{ .boolean = self.active != null });
    }

    fn setVisible(self: *ActionWidgetService, value: bool) void {
        if (self.visible_key) |key| key.set(.{ .boolean = value });
    }

    fn runAction(context: *anyopaque, action: Action) void {
        const self: *ActionWidgetService = @ptrCast(@alignCast(context));
        if (self.active == null) return;
        if (action == .hide) return hide(self, null);
        const event: ui.KeyEvent = switch (action) {
            .hide => unreachable,
            .previous => .{ .key = .up },
            .next => .{ .key = .down },
            .accept => .{ .key = .enter },
            .preview => .{ .key = .enter, .mods = .{ .ctrl = true } },
        };
        _ = self.context_menu.handleKey(&event);
    }

    fn show(context: *anyopaque, entries: []const list.IActionListItem, delegate: list.IActionListDelegate, anchor: menu.Anchor) !void {
        const self: *ActionWidgetService = @ptrCast(@alignCast(context));
        hide(self, null);
        const popup = try menu.Menu.init(self.allocator, MenuContext{ .owner = self, .delegate = delegate }, MenuContext.run);
        errdefer popup.deinit();
        const value = popup.getActionsContext(MenuContext).?;
        value.menu = popup;
        popup.on_hide = MenuContext.hidden;
        popup.on_focus = MenuContext.focused;
        popup.map_key = MenuContext.mapKey;
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
        errdefer {
            self.active = null;
            self.setVisible(false);
        }
        try self.context_menu.showContextMenu(popup, anchor);
        self.setVisible(self.active != null);
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

const visible_context = contextkey.Expr{ .Defined = "codeActionMenuVisible" };
const weight = @backingInt(keybindings.KeybindingWeight.EditorContrib) + 1000;
const ctrl = keycodes.KeyMod.CtrlCmd;
const KeyCode = keycodes.KeyCode;

pub const widget_actions = [_]actions.Action2{
    widgetAction(.hide, "hideCodeActionWidget", "Hide action widget", @backingInt(KeyCode.Escape), &.{keycodes.KeyMod.Shift | @backingInt(KeyCode.Escape)}, null),
    widgetAction(.previous, "selectPrevCodeAction", "Select previous action", @backingInt(KeyCode.UpArrow), &.{ctrl | @backingInt(KeyCode.UpArrow)}, &.{ ctrl | @backingInt(KeyCode.UpArrow), keycodes.KeyMod.WinCtrl | @backingInt(KeyCode.KeyP) }),
    widgetAction(.next, "selectNextCodeAction", "Select next action", @backingInt(KeyCode.DownArrow), &.{ctrl | @backingInt(KeyCode.DownArrow)}, &.{ ctrl | @backingInt(KeyCode.DownArrow), keycodes.KeyMod.WinCtrl | @backingInt(KeyCode.KeyN) }),
    widgetAction(.accept, "acceptSelectedCodeAction", "Accept selected action", @backingInt(KeyCode.Enter), &.{ctrl | @backingInt(KeyCode.Period)}, null),
    widgetAction(.preview, "previewSelectedCodeAction", "Preview selected action", ctrl | @backingInt(KeyCode.Enter), &.{}, null),
};

fn widgetAction(comptime action: Action, comptime id: []const u8, comptime title: []const u8, comptime primary: u32, comptime secondary: []const u32, comptime mac_secondary: ?[]const u32) actions.Action2 {
    return .{
        .command = .{ .id = id, .title = title, .precondition = &visible_context },
        .context = @ptrFromInt(1),
        .run_fn = struct {
            fn run(_: *anyopaque, accessor: instantiation.ServicesAccessor) !void {
                (try accessor.get(action_widget_service_id)).runAction(action);
            }
        }.run,
        .keybindings = &.{.{ .id = id, .weight = weight, .when = &visible_context, .bindings = .{ .primary = primary, .secondary = secondary, .mac = if (mac_secondary) |keys| .{ .primary = primary, .secondary = keys } else null } }},
    };
}

test "ActionWidget: focused items, preview activation and hide are delivered through the shared context view" {
    const a = std.testing.allocator;
    const Probe = struct {
        focus: ?usize = null,
        selected: ?usize = null,
        previewed: bool = false,
        hidden: usize = 0,
        canceled: bool = false,
        failure: ?anyerror = null,
        fn onFocus(context: *anyopaque, index: ?usize) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.focus = index;
        }
        fn onSelect(context: *anyopaque, index: usize, preview: bool) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.selected = index;
            self.previewed = preview;
        }
        fn onHide(context: *anyopaque, canceled: bool) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.hidden += 1;
            self.canceled = canceled;
        }
        fn report(context: *anyopaque, failure: anyerror) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.failure = failure;
        }
    };
    var probe: Probe = .{};
    var context_menu = menu.ContextMenuService.init(a, &probe, Probe.report);
    defer context_menu.deinit();
    var service: ActionWidgetService = .{ .allocator = a, .context_menu = context_menu.interface() };
    defer service.deinit();
    var contexts = contextkey.ContextKeyService.init(a);
    defer contexts.deinit();
    try service.bindContextKeys(contexts.interface());
    defer {
        if (service.visible_key) |key| key.dispose();
        service.visible_key = null;
    }
    const items = [_]list.IActionListItem{
        .{ .kind = .Header, .label = "Quick Fix" },
        .{ .kind = .Action, .label = "Disabled", .item = 0, .disabled = true },
        .{ .kind = .Action, .label = "Fix", .item = 1, .can_preview = true },
        .{ .kind = .Action, .label = "Second", .item = 2, .can_preview = true },
    };
    const delegate: list.IActionListDelegate = .{ .context = &probe, .on_select = Probe.onSelect, .on_hide = Probe.onHide, .on_focus = Probe.onFocus };
    const api = service.interface();
    try api.show(&items, delegate, .{ .x = 0, .y = 0 });
    try std.testing.expect(api.isVisible());
    try std.testing.expect(contexts.interface().getContextKeyValue("codeActionMenuVisible").boolean);
    try std.testing.expectEqual(@as(?usize, 1), probe.focus);
    api.runAction(.next);
    try std.testing.expectEqual(@as(?usize, 2), probe.focus);
    api.runAction(.preview);
    try std.testing.expectEqual(@as(?usize, 2), probe.selected);
    try std.testing.expect(probe.previewed);
    try std.testing.expect(!probe.canceled);
    try std.testing.expect(!api.isVisible());
    try std.testing.expect(!contexts.interface().getContextKeyValue("codeActionMenuVisible").boolean);
    try api.show(&items, delegate, .{ .x = 0, .y = 0 });
    api.runAction(.hide);
    try std.testing.expect(probe.canceled);
    try std.testing.expectEqual(@as(usize, 2), probe.hidden);
    try std.testing.expect(probe.failure == null);
}
