// Port of ListService from src/vs/platform/list/browser/listService.ts.
// Native list/tree adapters emit focus and disposal at their actual lifetime
// boundaries instead of the browser's DOM focus and dispose events.
const std = @import("std");
const ui = @import("ui");
const Emitter = @import("../../../base/common/event.zig").Emitter;
const instantiation = @import("../../instantiation/common/instantiation.zig");

pub const Navigation = enum {
    focus_previous,
    focus_next,
    focus_first,
    focus_last,
    focus_previous_page,
    focus_next_page,
    collapse,
    expand,
    toggle_expand,
    select,

    /// The native List/Tree controllers already implement these keyboard
    /// operations. Translate the portable command into that input contract.
    pub fn key(self: Navigation) ui.Key {
        return switch (self) {
            .focus_previous => .up,
            .focus_next => .down,
            .focus_first => .home,
            .focus_last => .end,
            .focus_previous_page => .page_up,
            .focus_next_page => .page_down,
            .collapse => .left,
            .expand => .right,
            .toggle_expand => .{ .char = ' ' },
            .select => .enter,
        };
    }
};

pub const ListFocus = struct {
    focused: bool = false,
    on_did_focus: Emitter(void),
    on_did_dispose: Emitter(void),

    pub fn init(allocator: std.mem.Allocator) ListFocus {
        return .{ .on_did_focus = .init(allocator), .on_did_dispose = .init(allocator) };
    }

    pub fn setFocused(self: *ListFocus, focused: bool) void {
        if (self.focused == focused) return;
        self.focused = focused;
        if (focused) self.on_did_focus.fire({}) catch {};
    }

    pub fn deinit(self: *ListFocus) void {
        self.on_did_dispose.fire({}) catch {};
        self.on_did_focus.deinit();
        self.on_did_dispose.deinit();
    }
};

pub const WorkbenchListWidget = struct {
    context: *anyopaque,
    focus: *ListFocus,
    run: *const fn (*anyopaque, Navigation) anyerror!void,
};

pub const IListService = struct {
    context: *anyopaque,
    last_focused_list: *const fn (*anyopaque) ?WorkbenchListWidget,

    pub fn lastFocusedList(self: IListService) ?WorkbenchListWidget {
        return self.last_focused_list(self.context);
    }
};

pub const list_service_id = instantiation.ServiceIdentifier(IListService, "listService");

pub const ListService = struct {
    allocator: std.mem.Allocator,
    lists: std.ArrayList(*Registration) = .empty,
    last_focused_widget: ?*Registration = null,

    const Registration = struct {
        service: *ListService,
        widget: WorkbenchListWidget,
        focus_listener: usize,
        dispose_listener: usize,

        fn onFocus(_: void, self: *Registration) !void {
            self.service.last_focused_widget = self;
        }

        fn onDispose(_: void, self: *Registration) !void {
            self.service.unregister(self);
        }
    };

    pub fn init(allocator: std.mem.Allocator) ListService {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ListService) void {
        while (self.lists.items.len != 0) self.unregister(self.lists.items[self.lists.items.len - 1]);
        self.lists.deinit(self.allocator);
    }

    pub fn interface(self: *ListService) IListService {
        return .{ .context = self, .last_focused_list = lastFocusedListContext };
    }

    fn lastFocusedListContext(context: *anyopaque) ?WorkbenchListWidget {
        const self: *ListService = @ptrCast(@alignCast(context));
        return self.lastFocusedList();
    }

    pub fn lastFocusedList(self: *ListService) ?WorkbenchListWidget {
        return if (self.last_focused_widget) |registration| registration.widget else null;
    }

    /// The native widget lifetime owns the registration; its dispose event
    /// releases it automatically.
    pub fn register(self: *ListService, widget: WorkbenchListWidget) !void {
        for (self.lists.items) |entry| {
            if (entry.widget.focus == widget.focus) return error.ListAlreadyRegistered;
        }
        const entry = try self.allocator.create(Registration);
        errdefer self.allocator.destroy(entry);
        entry.* = .{
            .service = self,
            .widget = widget,
            .focus_listener = try widget.focus.on_did_focus.listen(entry, Registration.onFocus),
            .dispose_listener = undefined,
        };
        errdefer widget.focus.on_did_focus.unlisten(entry.focus_listener);
        entry.dispose_listener = try widget.focus.on_did_dispose.listen(entry, Registration.onDispose);
        errdefer widget.focus.on_did_dispose.unlisten(entry.dispose_listener);
        try self.lists.append(self.allocator, entry);
        if (widget.focus.focused) self.last_focused_widget = entry;
    }

    fn unregister(self: *ListService, entry: *Registration) void {
        const index = std.mem.indexOfScalar(*Registration, self.lists.items, entry) orelse return;
        _ = self.lists.orderedRemove(index);
        if (self.last_focused_widget == entry) self.last_focused_widget = null;
        entry.widget.focus.on_did_focus.unlisten(entry.focus_listener);
        entry.widget.focus.on_did_dispose.unlisten(entry.dispose_listener);
        self.allocator.destroy(entry);
    }
};
