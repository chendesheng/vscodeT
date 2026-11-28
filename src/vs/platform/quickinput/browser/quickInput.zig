// Port of the portable `QuickPick` state from
// `src/vs/platform/quickinput/browser/quickInput.ts`.
//
// The browser class also owns the DOM list and input box. This model keeps the
// value, the items, the active/selected item and the activation/navigation
// rules; `quickInputList.zig` renders it and forwards keys. Filtering is
// intentionally absent: quick access providers hand over already filtered
// picks, exactly as `PickerQuickAccessProvider` does upstream by disabling
// `matchOnLabel`, `matchOnDescription`, `matchOnDetail` and `sortByLabel`.
//
// Items are copied into the model, but their label/description slices are
// borrowed. The provider owns those slices until its next refresh.

const std = @import("std");
const Allocator = std.mem.Allocator;
const quick_input = @import("../common/quickInput.zig");
const QuickPickItem = quick_input.QuickPickItem;
const Item = quick_input.Item;
const ItemActivation = quick_input.ItemActivation;

pub const QuickPick = struct {
    io: std.Io,
    allocator: Allocator,
    value: std.array_list.Managed(u8),
    placeholder: []const u8 = "",
    items: std.array_list.Managed(QuickPickItem),
    /// Visible rows exclude inline group separators. Values index the provider items.
    rows: std.array_list.Managed(usize),
    active_index: ?usize = null,
    selected_index: ?usize = null,
    scroll_top: usize = 0,
    /// Number of list rows the widget can show; page navigation uses it.
    page_size: usize = 10,
    busy: bool = false,
    busy_since_ms: i64 = 0,
    visible: bool = false,
    item_activation: ItemActivation = .first,

    on_change_context: ?*anyopaque = null,
    on_change: ?*const fn (context: *anyopaque) void = null,
    on_accept_context: ?*anyopaque = null,
    on_accept: ?*const fn (context: *anyopaque) void = null,
    on_hide_context: ?*anyopaque = null,
    on_hide: ?*const fn (context: *anyopaque) void = null,

    pub fn init(allocator: Allocator, io: std.Io) QuickPick {
        return .{
            .allocator = allocator,
            .io = io,
            .value = std.array_list.Managed(u8).init(allocator),
            .items = std.array_list.Managed(QuickPickItem).init(allocator),
            .rows = std.array_list.Managed(usize).init(allocator),
        };
    }

    pub fn deinit(self: *QuickPick) void {
        self.rows.deinit();
        self.items.deinit();
        self.value.deinit();
    }

    pub fn reset(self: *QuickPick) void {
        self.value.clearRetainingCapacity();
        self.rows.clearRetainingCapacity();
        self.items.clearRetainingCapacity();
        self.active_index = null;
        self.selected_index = null;
        self.scroll_top = 0;
        self.busy = false;
        self.item_activation = .first;
        self.placeholder = "";
    }

    pub fn setValue(self: *QuickPick, value: []const u8) !void {
        if (std.mem.eql(u8, self.value.items, value)) return;
        self.value.clearRetainingCapacity();
        try self.value.appendSlice(value);
        if (self.on_change) |callback| callback(self.on_change_context.?);
    }

    pub fn setPlaceholder(self: *QuickPick, placeholder: []const u8) void {
        self.placeholder = placeholder;
    }

    pub fn setBusy(self: *QuickPick, busy: bool) void {
        if (busy and !self.busy) self.busy_since_ms = @import("../../../base/common/timeCompat.zig").milliTimestamp(self.io);
        self.busy = busy;
    }

    /// Replaces the items and applies the one-shot activation mode. Providers
    /// may restore the previous active item afterwards (see
    /// `pickerQuickAccess.zig`).
    pub fn setItems(self: *QuickPick, items: []const QuickPickItem) !void {
        self.rows.clearRetainingCapacity();
        self.items.clearRetainingCapacity();
        try self.rows.ensureTotalCapacity(items.len);
        try self.items.appendSlice(items);
        for (items, 0..) |item, index| {
            if (item == .item) self.rows.appendAssumeCapacity(index);
        }
        self.scroll_top = 0;

        const mode = self.item_activation;
        self.item_activation = .first;
        self.active_index = switch (mode) {
            .none => null,
            .first => self.firstItemIndex(),
            .second => self.secondItemIndex(),
            .last => self.lastItemIndex(),
        };
    }

    pub fn removeItem(self: *QuickPick, index: usize) void {
        const row = std.mem.indexOfScalar(usize, self.rows.items, index) orelse return;
        const active = self.activeRow() orelse row;
        _ = self.items.orderedRemove(index);
        if (index > 0 and self.items.items[index - 1] == .separator and
            (index == self.items.items.len or self.items.items[index] == .separator))
            _ = self.items.orderedRemove(index - 1);
        self.rows.clearRetainingCapacity();
        for (self.items.items, 0..) |item, i| {
            if (item == .item) self.rows.appendAssumeCapacity(i);
        }
        self.selected_index = null;
        if (self.rows.items.len == 0) {
            self.active_index = null;
            self.scroll_top = 0;
            return;
        }
        const next_row = if (active > row) active - 1 else @min(active, self.rows.items.len - 1);
        self.setActiveIndex(self.rows.items[next_row]);
    }

    pub fn clearItems(self: *QuickPick) void {
        self.rows.clearRetainingCapacity();
        self.items.clearRetainingCapacity();
        self.active_index = null;
        self.selected_index = null;
        self.scroll_top = 0;
        self.busy = false;
    }

    pub fn activeItem(self: *const QuickPick) ?*const Item {
        const index = self.active_index orelse return null;
        if (index >= self.items.items.len) return null;
        const slot = &self.items.items[index];
        return switch (slot.*) {
            .item => &slot.item,
            .separator => null,
        };
    }

    pub fn selectedItem(self: *const QuickPick) ?*const Item {
        const index = self.selected_index orelse return null;
        if (index >= self.items.items.len) return null;
        const slot = &self.items.items[index];
        return switch (slot.*) {
            .item => &slot.item,
            .separator => null,
        };
    }

    pub fn setActiveIndex(self: *QuickPick, index: ?usize) void {
        self.active_index = index;
        if (index) |value| {
            if (value >= self.items.items.len) self.active_index = null;
            self.revealActive();
        }
    }

    pub fn focusNext(self: *QuickPick) void {
        self.move(1);
    }

    pub fn focusPrevious(self: *QuickPick) void {
        self.move(-1);
    }

    pub fn focusFirst(self: *QuickPick) void {
        self.active_index = self.firstItemIndex();
        self.scroll_top = 0;
    }

    pub fn focusLast(self: *QuickPick) void {
        self.active_index = self.lastItemIndex();
        self.revealActive();
    }

    pub fn focusNextPage(self: *QuickPick) void {
        self.movePage(@intCast(@max(self.page_size, 1)));
    }

    pub fn focusPreviousPage(self: *QuickPick) void {
        self.movePage(-@as(isize, @intCast(@max(self.page_size, 1))));
    }

    pub fn accept(self: *QuickPick) void {
        self.selected_index = self.active_index;
        if (self.on_accept) |callback| callback(self.on_accept_context.?);
    }

    pub fn show(self: *QuickPick) void {
        self.visible = true;
    }

    pub fn hide(self: *QuickPick) void {
        if (!self.visible) return;
        self.visible = false;
        self.busy = false;
        if (self.on_hide) |callback| callback(self.on_hide_context.?);
    }

    fn move(self: *QuickPick, delta: isize) void {
        if (self.rows.items.len == 0) return;
        const row = self.activeRow() orelse {
            if (delta > 0) self.focusFirst() else self.focusLast();
            return;
        };
        const next = @mod(@as(isize, @intCast(row)) + delta, @as(isize, @intCast(self.rows.items.len)));
        self.setActiveIndex(self.rows.items[@intCast(next)]);
    }

    fn movePage(self: *QuickPick, delta: isize) void {
        const row = self.activeRow() orelse return self.focusFirst();
        const next = std.math.clamp(@as(isize, @intCast(row)) + delta, 0, @as(isize, @intCast(self.rows.items.len - 1)));
        self.setActiveIndex(self.rows.items[@intCast(next)]);
    }

    fn activeRow(self: *const QuickPick) ?usize {
        return std.mem.indexOfScalar(usize, self.rows.items, self.active_index orelse return null);
    }

    fn revealActive(self: *QuickPick) void {
        const row = self.activeRow() orelse return;
        if (row < self.scroll_top) self.scroll_top = row;
        if (row >= self.scroll_top + self.page_size) self.scroll_top = row + 1 - self.page_size;
    }

    fn firstItemIndex(self: *const QuickPick) ?usize {
        return if (self.rows.items.len == 0) null else self.rows.items[0];
    }

    fn secondItemIndex(self: *const QuickPick) ?usize {
        return if (self.rows.items.len >= 2) self.rows.items[1] else self.firstItemIndex();
    }

    fn lastItemIndex(self: *const QuickPick) ?usize {
        return self.rows.getLastOrNull();
    }
};

test "QuickPick: items, separator skipping and wrapping" {
    var picker = QuickPick.init(std.testing.allocator, std.testing.io);
    defer picker.deinit();

    try picker.setItems(&.{
        .{ .separator = .{ .label = "group" } },
        .{ .item = .{ .id = "a", .label = "Alpha" } },
        .{ .item = .{ .id = "b", .label = "Beta" } },
    });
    try std.testing.expectEqualStrings("a", picker.activeItem().?.id);

    picker.focusNext();
    try std.testing.expectEqualStrings("b", picker.activeItem().?.id);
    picker.focusNext();
    try std.testing.expectEqualStrings("a", picker.activeItem().?.id);
    picker.focusPrevious();
    try std.testing.expectEqualStrings("b", picker.activeItem().?.id);
    picker.focusFirst();
    try std.testing.expectEqualStrings("a", picker.activeItem().?.id);
    picker.focusLast();
    try std.testing.expectEqualStrings("b", picker.activeItem().?.id);
}

test "QuickPick: activation modes and accept" {
    const State = struct {
        accepts: usize = 0,
        hides: usize = 0,
        changes: usize = 0,
        fn onChange(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.changes += 1;
        }
        fn onAccept(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.accepts += 1;
        }
        fn onHide(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.hides += 1;
        }
    };

    var state = State{};
    var picker = QuickPick.init(std.testing.allocator, std.testing.io);
    defer picker.deinit();
    picker.on_change_context = &state;
    picker.on_change = State.onChange;
    picker.on_accept_context = &state;
    picker.on_accept = State.onAccept;
    picker.on_hide_context = &state;
    picker.on_hide = State.onHide;

    picker.item_activation = .second;
    try picker.setItems(&.{
        .{ .item = .{ .id = "a", .label = "Alpha" } },
        .{ .item = .{ .id = "b", .label = "Beta" } },
    });
    try std.testing.expectEqualStrings("b", picker.activeItem().?.id);
    // The activation mode is one-shot.
    picker.item_activation = .first;
    try picker.setItems(&.{
        .{ .item = .{ .id = "a", .label = "Alpha" } },
        .{ .item = .{ .id = "b", .label = "Beta" } },
    });
    try std.testing.expectEqualStrings("a", picker.activeItem().?.id);

    try picker.setValue("a");
    try std.testing.expectEqual(@as(usize, 1), state.changes);
    picker.show();
    picker.accept();
    try std.testing.expectEqual(@as(usize, 1), state.accepts);
    try std.testing.expectEqualStrings("a", picker.selectedItem().?.id);
    picker.hide();
    try std.testing.expectEqual(@as(usize, 1), state.hides);
}
