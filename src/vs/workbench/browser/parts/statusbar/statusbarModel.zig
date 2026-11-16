// Port of `src/vs/workbench/browser/parts/statusbar/statusbarModel.ts`.
//
// The portable model keeps the ordered entry list, alignment buckets,
// priority sorting (including relative priorities), hidden entries and the
// first/last-visible flags. The browser version stores DOM containers and
// persists hidden ids in storage; the terminal version stores a display string
// per entry and keeps hidden ids in memory until a storage service is ported.
//
// Terminal adaptation: `findEntry` takes an id instead of a DOM container,
// `focusNextEntry`/`focusPreviousEntry` are omitted because focus lives in the
// terminal UI layer, and entries carry a `text` field that the status row
// paints.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../../../base/common/event.zig").Emitter;

pub const StatusbarAlignment = enum { left, right };

/// Upstream `IStatusbarEntryPriority` primary value: a number, or a location
/// relative to another entry.
pub const PrimaryPriority = union(enum) {
    number: f64,
    location: struct {
        id: []const u8,
        priority: f64,
        alignment: StatusbarAlignment,
    },
};

pub const Priority = struct {
    primary: PrimaryPriority,
    secondary: f64,
};

pub const Entry = struct {
    id: []const u8,
    name: []const u8,
    /// Text painted by the terminal status row. Browser entries use DOM nodes.
    text: []const u8 = "",
    alignment: StatusbarAlignment,
    priority: Priority,
    has_command: bool = false,
    extension_id: ?[]const u8 = null,
    /// Updated by `markFirstLastVisibleEntry`.
    first_visible: bool = false,
    last_visible: bool = false,
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

    pub fn add(self: *StatusbarModel, entry: Entry) !void {
        try self.entries_list.append(entry);
        self.updateVisibility(entry.id, false);
        try self.sort();
        self.markFirstLastVisibleEntry();
    }

    pub fn remove(self: *StatusbarModel, id: []const u8) void {
        for (self.entries_list.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.id, id)) {
                _ = self.entries_list.orderedRemove(index);
                // Re-sort when another entry referenced this one.
                var referenced = false;
                for (self.entries_list.items) |other| {
                    if (other.priority.primary == .location and
                        std.mem.eql(u8, other.priority.primary.location.id, id))
                    {
                        referenced = true;
                        break;
                    }
                }
                if (referenced) self.sort() catch {};
                self.markFirstLastVisibleEntry();
                return;
            }
        }
    }

    pub fn isHidden(self: *const StatusbarModel, id: []const u8) bool {
        return self.hidden.contains(id);
    }

    pub fn hide(self: *StatusbarModel, id: []const u8) void {
        if (self.hidden.contains(id)) return;
        self.hidden.put(id, {}) catch return;
        self.updateVisibility(id, true);
        self.markFirstLastVisibleEntry();
    }

    pub fn show(self: *StatusbarModel, id: []const u8) void {
        if (self.hidden.fetchRemove(id) == null) return;
        self.updateVisibility(id, true);
        self.markFirstLastVisibleEntry();
    }

    /// Updates an entry's display text. The slice is borrowed; the caller
    /// keeps it alive for as long as the entry is painted, matching the
    /// browser model's DOM-node ownership.
    pub fn setText(self: *StatusbarModel, id: []const u8, text: []const u8) void {
        for (self.entries_list.items) |*entry| {
            if (std.mem.eql(u8, entry.id, id)) {
                entry.text = text;
                return;
            }
        }
    }

    pub fn findEntry(self: *const StatusbarModel, id: []const u8) ?*const Entry {
        for (self.entries_list.items) |*entry| {
            if (std.mem.eql(u8, entry.id, id)) return entry;
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
            .location => |location| location.priority,
        };
    }

    fn sort(self: *StatusbarModel) !void {
        const count = self.entries_list.items.len;
        if (count < 2) return;

        // Index of each entry's original insertion order, for stable sorting.
        var order = std.array_list.Managed(usize).init(self.allocator);
        defer order.deinit();
        try order.ensureTotalCapacity(count);
        for (0..count) |index| order.appendAssumeCapacity(index);

        // Split into entries with a numeric priority (or a missing relative
        // reference) and entries that reference an existing entry.
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
            if (primary == .number or self.entryIndex(primary.location.id) == null) {
                try numbered.append(index);
                continue;
            }
            const root = self.resolveReferenceRoot(primary.location.id);
            const key = if (root) |id| id else primary.location.id;
            const result = try relative.getOrPut(key);
            if (!result.found_existing) result.value_ptr.* = std.array_list.Managed(usize).init(self.allocator);
            try result.value_ptr.append(index);
        }

        // Sort the numbered entries: alignment, primary descending, secondary
        // descending, then original insertion order.
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

        // Entries that reference an entry that does not exist are appended,
        // sorted by secondary priority, matching upstream's fallback.
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
            const next = primary.location.id;
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
