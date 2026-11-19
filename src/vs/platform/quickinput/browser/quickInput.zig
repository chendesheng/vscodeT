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
    allocator: Allocator,
    value: std.array_list.Managed(u8),
    placeholder: []const u8 = "",
    items: std.array_list.Managed(QuickPickItem),
    active_index: ?usize = null,
    selected_index: ?usize = null,
    scroll_top: usize = 0,
    /// Number of list rows the widget can show; page navigation uses it.
    page_size: usize = 10,
    busy: bool = false,
    visible: bool = false,
    item_activation: ItemActivation = .first,

    on_change_context: ?*anyopaque = null,
    on_change: ?*const fn (context: *anyopaque) void = null,
    on_accept_context: ?*anyopaque = null,
    on_accept: ?*const fn (context: *anyopaque) void = null,
    on_hide_context: ?*anyopaque = null,
    on_hide: ?*const fn (context: *anyopaque) void = null,

    pub fn init(allocator: Allocator) QuickPick {
        return .{
            .allocator = allocator,
            .value = std.array_list.Managed(u8).init(allocator),
            .items = std.array_list.Managed(QuickPickItem).init(allocator),
        };
    }

    pub fn deinit(self: *QuickPick) void {
        self.items.deinit();
        self.value.deinit();
    }

    pub fn reset(self: *QuickPick) void {
        self.value.clearRetainingCapacity();
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
        self.busy = busy;
    }

    /// Replaces the items and applies the one-shot activation mode. Providers
    /// may restore the previous active item afterwards (see
    /// `pickerQuickAccess.zig`).
    pub fn setItems(self: *QuickPick, items: []const QuickPickItem) !void {
        self.items.clearRetainingCapacity();
        try self.items.appendSlice(items);
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

    pub fn clearItems(self: *QuickPick) void {
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
        const indices = self.itemCount();
        if (indices == 0) {
            self.active_index = null;
            return;
        }

        const current = self.active_index orelse {
            self.active_index = if (delta > 0) self.firstItemIndex() else self.lastItemIndex();
            return;
        };

        var index: isize = @intCast(current);
        var remaining = @abs(delta);
        while (remaining > 0) : (remaining -= 1) {
            index = self.step(index, delta);
        }
        if (index < 0) index = @intCast(self.items.items.len - 1);
        if (index >= @as(isize, @intCast(self.items.items.len))) index = 0;
        self.active_index = @intCast(index);
        self.revealActive();
    }

    fn movePage(self: *QuickPick, delta: isize) void {
        const indices = self.itemCount();
        if (indices == 0) {
            self.active_index = null;
            return;
        }
        if (self.active_index == null) {
            self.focusFirst();
            return;
        }

        const current: isize = @intCast(self.active_index.?);
        var index = current + delta;
        if (index < 0) {
            self.active_index = self.firstItemIndex();
        } else if (index >= @as(isize, @intCast(self.items.items.len))) {
            self.active_index = self.lastItemIndex();
        } else {
            while (index >= 0 and index < @as(isize, @intCast(self.items.items.len))) : (index += if (delta > 0) 1 else -1) {
                const candidate = switch (self.items.items[@intCast(index)]) {
                    .item => true,
                    .separator => false,
                };
                if (candidate) {
                    self.active_index = @intCast(index);
                    break;
                }
            }
        }
        self.revealActive();
    }

    /// Finds the next selectable index in `delta` direction, wrapping once.
    fn step(self: *const QuickPick, from: isize, delta: isize) isize {
        const count: isize = @intCast(self.items.items.len);
        if (count == 0) return 0;
        var index = from;
        var attempts: isize = 0;
        while (attempts < count) : (attempts += 1) {
            index += delta;
            if (index < 0) index = count - 1;
            if (index >= count) index = 0;
            switch (self.items.items[@intCast(index)]) {
                .item => return index,
                .separator => {},
            }
        }
        return from;
    }

    fn revealActive(self: *QuickPick) void {
        const index = self.active_index orelse return;
        if (index < self.scroll_top) {
            self.scroll_top = index;
        } else if (self.page_size > 0 and index >= self.scroll_top + self.page_size) {
            self.scroll_top = index - self.page_size + 1;
        }
    }

    fn itemCount(self: *const QuickPick) usize {
        var count: usize = 0;
        for (self.items.items) |item| {
            switch (item) {
                .item => count += 1,
                .separator => {},
            }
        }
        return count;
    }

    fn firstItemIndex(self: *const QuickPick) ?usize {
        for (self.items.items, 0..) |item, index| {
            switch (item) {
                .item => return index,
                .separator => {},
            }
        }
        return null;
    }

    fn secondItemIndex(self: *const QuickPick) ?usize {
        var seen: usize = 0;
        for (self.items.items, 0..) |item, index| {
            switch (item) {
                .item => {},
                .separator => continue,
            }
            seen += 1;
            if (seen == 2) return index;
        }
        return self.firstItemIndex();
    }

    fn lastItemIndex(self: *const QuickPick) ?usize {
        var index = self.items.items.len;
        while (index > 0) {
            index -= 1;
            switch (self.items.items[index]) {
                .item => return index,
                .separator => {},
            }
        }
        return null;
    }
};

test "QuickPick: items, separator skipping and wrapping" {
    var picker = QuickPick.init(std.testing.allocator);
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
    var picker = QuickPick.init(std.testing.allocator);
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
