// Port of `src/vs/workbench/browser/parts/statusbar/statusbarModel.ts`.
//
// The browser model stores DOM containers and persists hidden ids through the
// storage service. The terminal model stores a `StatusbarItem` per entry and
// keeps hidden ids in memory until a storage service is ported. Entry handles
// give accessors stable identity across the priority sort, matching the browser
// model's object identity (multiple entries may share an id).
//
// Terminal adaptation: `findEntry` takes an id instead of a DOM container, and
// focus is model state set by the terminal part rather than DOM activeElement.
// Focus navigation skips hidden and empty-text entries, which is the effective
// browser behaviour when the label container is display:none.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../../../base/common/event.zig").Emitter;

const statusbar = @import("../../../services/statusbar/browser/statusbar.zig");
const StatusbarAlignment = statusbar.StatusbarAlignment;
const StatusbarEntry = statusbar.StatusbarEntry;
const StatusbarEntryPriority = statusbar.StatusbarEntryPriority;
const PrimaryPriority = statusbar.PrimaryPriority;
const StatusbarItem = @import("statusbarItem.zig").StatusbarItem;
const StatusbarItemTheme = @import("statusbarItem.zig").Theme;

pub const EntryHandle = u64;

pub const Entry = struct {
    handle: EntryHandle,
    id: []const u8,
    alignment: StatusbarAlignment,
    priority: StatusbarEntryPriority,
    item: StatusbarItem,
    /// Updated by `markFirstLastVisibleEntry`.
    first_visible: bool = false,
    last_visible: bool = false,

    pub fn name(self: *const Entry) []const u8 {
        return self.item.name();
    }

    pub fn hasCommand(self: *const Entry) bool {
        return self.item.hasCommand();
    }

    pub fn extensionId(self: *const Entry) ?[]const u8 {
        return self.item.entry.extension_id;
    }
};

pub const VisibilityChange = struct {
    id: []const u8,
    visible: bool,
};

pub const StatusbarModel = struct {
    allocator: Allocator,
    entries_list: std.array_list.Managed(Entry),
    hidden: std.StringHashMap(void),
    on_did_change_entry_visibility: Emitter(VisibilityChange),
    next_handle: EntryHandle = 1,
    focused_handle: ?EntryHandle = null,
    last_focused_handle: ?EntryHandle = null,
    /// Bumped whenever the visible entry set, text or focus changes. View
    /// hosts use it to skip rebuilding an unchanged status bar.
    revision: u64 = 0,

    pub fn init(allocator: Allocator) StatusbarModel {
        return .{
            .allocator = allocator,
            .entries_list = std.array_list.Managed(Entry).init(allocator),
            .hidden = std.StringHashMap(void).init(allocator),
            .on_did_change_entry_visibility = Emitter(VisibilityChange).init(allocator),
        };
    }

    pub fn deinit(self: *StatusbarModel) void {
        self.hidden.deinit();
        self.on_did_change_entry_visibility.deinit();
        self.entries_list.deinit();
    }

    /// Entries in display order.
    pub fn entries(self: *const StatusbarModel) []const Entry {
        return self.entries_list.items;
    }

    /// Adds an entry and returns its stable handle. The browser model accepts a
    /// fully built entry with DOM containers; the terminal model builds the
    /// `StatusbarItem` here.
    /// Applies the resolved item-kind theme to every entry.
    pub fn setTheme(self: *StatusbarModel, theme: StatusbarItemTheme) void {
        for (self.entries_list.items) |*entry| entry.item.setTheme(theme);
    }

    pub fn add(
        self: *StatusbarModel,
        entry: StatusbarEntry,
        id: []const u8,
        alignment: StatusbarAlignment,
        priority: StatusbarEntryPriority,
    ) !EntryHandle {
        self.revision +%= 1;
        const handle = self.next_handle;
        self.next_handle += 1;
        try self.entries_list.append(.{
            .handle = handle,
            .id = id,
            .alignment = alignment,
            .priority = priority,
            .item = StatusbarItem.init(entry),
        });
        errdefer _ = self.entries_list.pop();

        self.updateVisibility(id, false);
        try self.sort();
        self.markFirstLastVisibleEntry();
        return handle;
    }

    pub fn update(self: *StatusbarModel, handle: EntryHandle, entry: StatusbarEntry) bool {
        self.revision +%= 1;
        const index = self.indexForHandle(handle) orelse return false;
        self.entries_list.items[index].item.update(entry);
        if (entry.text.len == 0 and self.focused_handle == handle) {
            self.focused_handle = null;
        }
        return true;
    }

    pub fn remove(self: *StatusbarModel, handle: EntryHandle) bool {
        self.revision +%= 1;
        const index = self.indexForHandle(handle) orelse return false;
        const removed_id = self.entries_list.items[index].id;
        _ = self.entries_list.orderedRemove(index);

        if (self.focused_handle == handle) self.focused_handle = null;
        if (self.last_focused_handle == handle) self.last_focused_handle = null;

        // Re-sort when another entry referenced this one.
        var referenced = false;
        for (self.entries_list.items) |other| {
            if (other.priority.primary == .location and
                std.mem.eql(u8, other.priority.primary.location.location.id, removed_id))
            {
                referenced = true;
                break;
            }
        }
        if (referenced) self.sort() catch {};
        self.markFirstLastVisibleEntry();
        return true;
    }

    pub fn isHidden(self: *const StatusbarModel, id: []const u8) bool {
        return self.hidden.contains(id);
    }

    pub fn hide(self: *StatusbarModel, id: []const u8) void {
        if (self.hidden.contains(id)) return;
        self.revision +%= 1;
        self.hidden.put(id, {}) catch return;
        self.updateVisibility(id, true);
        if (self.focused_handle) |handle| {
            if (self.findByHandle(handle)) |entry| {
                if (std.mem.eql(u8, entry.id, id)) self.focused_handle = null;
            }
        }
        self.markFirstLastVisibleEntry();
    }

    pub fn show(self: *StatusbarModel, id: []const u8) void {
        if (self.hidden.fetchRemove(id) == null) return;
        self.revision +%= 1;
        self.updateVisibility(id, true);
        self.markFirstLastVisibleEntry();
    }

    pub fn findEntry(self: *const StatusbarModel, id: []const u8) ?*const Entry {
        for (self.entries_list.items) |*entry| {
            if (std.mem.eql(u8, entry.id, id)) return entry;
        }
        return null;
    }

    pub fn findByHandle(self: *StatusbarModel, handle: EntryHandle) ?*Entry {
        const index = self.indexForHandle(handle) orelse return null;
        return &self.entries_list.items[index];
    }

    pub fn findHandle(self: *const StatusbarModel, id: []const u8) ?EntryHandle {
        for (self.entries_list.items) |entry| {
            if (std.mem.eql(u8, entry.id, id)) return entry.handle;
        }
        return null;
    }

    /// Entries with the given alignment, in display order. The returned slice
    /// is allocated and owned by the caller.
    pub fn getEntries(self: *const StatusbarModel, allocator: Allocator, alignment: StatusbarAlignment) ![]Entry {
        var result = std.array_list.Managed(Entry).init(allocator);
        errdefer result.deinit();
        for (self.entries_list.items) |entry| {
            if (entry.alignment == alignment) try result.append(entry);
        }
        return result.toOwnedSlice();
    }

    //#region Focus

    pub fn setFocused(self: *StatusbarModel, handle: ?EntryHandle) void {
        self.revision +%= 1;
        if (handle) |value| {
            const entry = self.findByHandle(value) orelse return;
            if (!self.isAvailable(entry)) return;
            self.focused_handle = value;
            self.last_focused_handle = value;
        } else {
            self.focused_handle = null;
        }
    }

    pub fn clearFocus(self: *StatusbarModel) void {
        self.revision +%= 1;
        self.focused_handle = null;
    }

    pub fn focusedEntry(self: *StatusbarModel) ?*Entry {
        const handle = self.focused_handle orelse return null;
        const entry = self.findByHandle(handle) orelse return null;
        if (!self.isAvailable(entry)) return null;
        return entry;
    }

    pub fn lastFocusedEntry(self: *StatusbarModel) ?*Entry {
        const handle = self.last_focused_handle orelse return null;
        const entry = self.findByHandle(handle) orelse return null;
        if (!self.isAvailable(entry)) return null;
        return entry;
    }

    pub fn isEntryFocused(self: *const StatusbarModel) bool {
        return self.focused_handle != null;
    }

    /// Upstream `focusNextEntry`: from the focused entry, or the first visible
    /// entry when nothing is focused.
    pub fn focusNextEntry(self: *StatusbarModel) ?*Entry {
        return self.focusRelative(1, 0);
    }

    /// Upstream `focusPreviousEntry`: from the focused entry, or the last
    /// visible entry when nothing is focused.
    pub fn focusPreviousEntry(self: *StatusbarModel) ?*Entry {
        return self.focusRelative(-1, self.entries_list.items.len -| 1);
    }

    pub fn focusFirstEntry(self: *StatusbarModel) ?*Entry {
        self.focused_handle = null;
        return self.focusRelative(1, 0);
    }

    pub fn focusLastEntry(self: *StatusbarModel) ?*Entry {
        self.focused_handle = null;
        return self.focusRelative(-1, self.entries_list.items.len -| 1);
    }

    fn focusRelative(self: *StatusbarModel, delta: isize, restart: usize) ?*Entry {
        if (self.entries_list.items.len == 0) return null;

        if (self.focusedEntry()) |focused| {
            if (self.indexForHandle(focused.handle)) |index| {
                const start: isize = @as(isize, @intCast(index)) + delta;
                if (self.visibleFrom(start, delta)) |entry| {
                    self.focused_handle = entry.handle;
                    self.last_focused_handle = entry.handle;
                    return entry;
                }
                // Upstream keeps the current focus when there is no next item.
                return null;
            }
        }

        if (self.visibleFrom(@intCast(restart), delta)) |entry| {
            self.focused_handle = entry.handle;
            self.last_focused_handle = entry.handle;
            return entry;
        }
        return null;
    }

    fn visibleFrom(self: *StatusbarModel, start: isize, delta: isize) ?*Entry {
        var index = start;
        while (index >= 0 and index < @as(isize, @intCast(self.entries_list.items.len))) : (index += delta) {
            const entry = &self.entries_list.items[@intCast(index)];
            if (self.isAvailable(entry)) return entry;
        }
        return null;
    }

    fn isAvailable(self: *const StatusbarModel, entry: *const Entry) bool {
        return !self.isHidden(entry.id) and entry.item.text().len > 0;
    }

    //#endregion

    fn indexForHandle(self: *const StatusbarModel, handle: EntryHandle) ?usize {
        for (self.entries_list.items, 0..) |entry, index| {
            if (entry.handle == handle) return index;
        }
        return null;
    }

    fn updateVisibility(self: *StatusbarModel, id: []const u8, trigger: bool) void {
        const visible = !self.isHidden(id);
        for (self.entries_list.items) |*entry| {
            if (!std.mem.eql(u8, entry.id, id)) continue;
            entry.first_visible = false;
            entry.last_visible = false;
        }
        if (trigger) {
            self.on_did_change_entry_visibility.fire(.{ .id = id, .visible = visible }) catch {};
        }
    }

    fn entryIndex(self: *const StatusbarModel, id: []const u8) ?usize {
        for (self.entries_list.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.id, id)) return index;
        }
        return null;
    }

    fn alignmentOf(entry: Entry) StatusbarAlignment {
        return entry.alignment;
    }

    fn primaryNumber(entry: Entry) f64 {
        return switch (entry.priority.primary) {
            .number => |value| value,
            .location => |location| location.location.priority,
        };
    }

    fn sort(self: *StatusbarModel) !void {
        const count = self.entries_list.items.len;
        if (count < 2) return;

        // Stable insertion order for equal priorities.
        var order = std.array_list.Managed(usize).init(self.allocator);
        defer order.deinit();
        try order.ensureTotalCapacity(count);
        for (0..count) |index| order.appendAssumeCapacity(index);

        var numbered = std.array_list.Managed(usize).init(self.allocator);
        defer numbered.deinit();
        var relative = std.StringHashMap(std.array_list.Managed(usize)).init(self.allocator);
        defer {
            var iterator = relative.valueIterator();
            while (iterator.next()) |list| list.deinit();
            relative.deinit();
        }

        for (self.entries_list.items, 0..) |entry, index| {
            const primary = entry.priority.primary;
            if (primary == .number or self.entryIndex(primary.location.location.id) == null) {
                try numbered.append(index);
                continue;
            }
            const root = self.resolveReferenceRoot(primary.location.location.id);
            const key = if (root) |id| id else primary.location.location.id;
            const result = try relative.getOrPut(key);
            if (!result.found_existing) result.value_ptr.* = std.array_list.Managed(usize).init(self.allocator);
            try result.value_ptr.append(index);
        }

        const sort_context = SortContext{
            .entries = self.entries_list.items,
            .order = order.items,
        };
        std.mem.sort(usize, numbered.items, sort_context, numberedLessThan);

        var sorted = std.array_list.Managed(Entry).init(self.allocator);
        errdefer sorted.deinit();

        var handled = std.StringHashMap(void).init(self.allocator);
        defer handled.deinit();

        for (numbered.items) |index| {
            const entry = self.entries_list.items[index];
            if (relative.get(entry.id)) |relative_indices| {
                try self.appendRelative(&sorted, relative_indices.items, .left);
                try sorted.append(entry);
                try self.appendRelative(&sorted, relative_indices.items, .right);
                handled.put(entry.id, {}) catch {};
            } else {
                try sorted.append(entry);
            }
        }

        // Entries referencing a missing entry are appended, sorted by secondary
        // priority, matching upstream's fallback.
        var iterator = relative.iterator();
        while (iterator.next()) |pair| {
            if (handled.contains(pair.key_ptr.*)) continue;
            var remaining = std.array_list.Managed(usize).init(self.allocator);
            defer remaining.deinit();
            for (pair.value_ptr.items) |index| {
                if (!handled.contains(self.entries_list.items[index].id)) {
                    try remaining.append(index);
                }
            }
            std.mem.sort(usize, remaining.items, self.entries_list.items, relativeLessThan);
            for (remaining.items) |index| try sorted.append(self.entries_list.items[index]);
        }

        self.entries_list.deinit();
        self.entries_list = sorted;
    }

    fn resolveReferenceRoot(self: *const StatusbarModel, id: []const u8) ?[]const u8 {
        var current = id;
        var steps: usize = 0;
        while (steps < self.entries_list.items.len) : (steps += 1) {
            const index = self.entryIndex(current) orelse return null;
            const primary = self.entries_list.items[index].priority.primary;
            if (primary == .number) return current;
            const next = primary.location.location.id;
            if (self.entryIndex(next) == null) return current;
            if (std.mem.eql(u8, next, current)) return current;
            current = next;
        }
        return current;
    }

    fn appendRelative(
        self: *const StatusbarModel,
        sorted: *std.array_list.Managed(Entry),
        indices: []const usize,
        alignment: StatusbarAlignment,
    ) !void {
        var selected = std.array_list.Managed(usize).init(self.allocator);
        defer selected.deinit();
        for (indices) |index| {
            const entry = self.entries_list.items[index];
            if (entry.priority.primary != .location) continue;
            if (entry.priority.primary.location.alignment != alignment) continue;
            try selected.append(index);
        }
        std.mem.sort(usize, selected.items, self.entries_list.items, relativeLessThan);
        for (selected.items) |index| try sorted.append(self.entries_list.items[index]);
    }

    fn relativeLessThan(all_entries: []const Entry, a: usize, b: usize) bool {
        return all_entries[a].priority.secondary > all_entries[b].priority.secondary;
    }

    const SortContext = struct {
        entries: []const Entry,
        order: []const usize,
    };

    fn numberedLessThan(context: SortContext, a: usize, b: usize) bool {
        const entry_a = context.entries[a];
        const entry_b = context.entries[b];

        if (entry_a.alignment != entry_b.alignment) {
            return alignmentOf(entry_a) == .left;
        }

        const primary_a = primaryNumber(entry_a);
        const primary_b = primaryNumber(entry_b);
        if (primary_a != primary_b) return primary_a > primary_b;
        if (entry_a.priority.secondary != entry_b.priority.secondary) {
            return entry_a.priority.secondary > entry_b.priority.secondary;
        }
        return context.order[a] < context.order[b];
    }

    fn markFirstLastVisibleEntry(self: *StatusbarModel) void {
        for (self.entries_list.items) |*entry| {
            entry.first_visible = false;
            entry.last_visible = false;
        }
        self.markFirstLastVisible(StatusbarAlignment.left);
        self.markFirstLastVisible(StatusbarAlignment.right);
    }

    fn markFirstLastVisible(self: *StatusbarModel, alignment: StatusbarAlignment) void {
        var first: ?usize = null;
        var last: ?usize = null;
        for (self.entries_list.items, 0..) |entry, index| {
            if (entry.alignment != alignment or self.isHidden(entry.id)) continue;
            if (first == null) first = index;
            last = index;
        }
        if (first) |index| self.entries_list.items[index].first_visible = true;
        if (last) |index| self.entries_list.items[index].last_visible = true;
    }
};

test "StatusbarModel: handles, focus and visibility" {
    var model = StatusbarModel.init(std.testing.allocator);
    defer model.deinit();

    const a = try model.add(.{ .name = "a", .text = "A" }, "a", .left, .{
        .primary = .{ .number = 3 },
        .secondary = 1,
    });
    const b = try model.add(.{ .name = "b", .text = "B" }, "b", .left, .{
        .primary = .{ .number = 2 },
        .secondary = 1,
    });
    const c = try model.add(.{ .name = "c", .text = "C" }, "c", .right, .{
        .primary = .{ .number = 1 },
        .secondary = 1,
    });
    try std.testing.expectEqual(@as(usize, 3), model.entries().len);
    try std.testing.expectEqualStrings("a", model.entries()[0].id);

    const first = model.focusNextEntry().?;
    try std.testing.expectEqual(a, first.handle);
    const second = model.focusNextEntry().?;
    try std.testing.expectEqual(b, second.handle);
    const third = model.focusNextEntry().?;
    try std.testing.expectEqual(c, third.handle);

    model.setFocused(c);
    const previous = model.focusPreviousEntry().?;
    try std.testing.expectEqual(b, previous.handle);

    model.hide("b");
    const next = model.focusNextEntry().?;
    try std.testing.expectEqual(a, next.handle);

    try std.testing.expect(model.remove(a));
    try std.testing.expectEqual(@as(usize, 2), model.entries().len);
}

test "StatusbarModel: empty text is not focusable" {
    var model = StatusbarModel.init(std.testing.allocator);
    defer model.deinit();
    _ = try model.add(.{ .name = "empty", .text = "" }, "empty", .left, .{
        .primary = .{ .number = 2 },
        .secondary = 0,
    });
    const visible = try model.add(.{ .name = "visible", .text = "v" }, "visible", .left, .{
        .primary = .{ .number = 1 },
        .secondary = 0,
    });
    const focused = model.focusNextEntry().?;
    try std.testing.expectEqual(visible, focused.handle);
}
