// Port of `src/Event.hh` from `@parcel/watcher` v2.5.6 (external package).
//
// The event list keeps the upstream coalescing rules: a delete after a create
// cancels both, a create after a delete becomes an update, a create hides a
// following update, and a created+deleted pair is filtered out.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const EventType = enum { create, update, delete };

pub const Event = struct {
    path: []const u8,
    type: EventType,
};

const State = struct {
    path: []const u8,
    created: bool = false,
    deleted: bool = false,
    updated: bool = false,
};

pub const EventList = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    states: std.array_list.Managed(State),
    index: std.StringHashMap(usize),
    error_message: ?[]const u8 = null,

    pub fn init(allocator: Allocator) EventList {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .states = std.array_list.Managed(State).init(allocator),
            .index = std.StringHashMap(usize).init(allocator),
        };
    }

    pub fn deinit(self: *EventList) void {
        self.states.deinit();
        self.index.deinit();
        self.arena.deinit();
    }

    pub fn clear(self: *EventList) void {
        self.states.clearRetainingCapacity();
        self.index.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
        self.error_message = null;
    }

    fn find(self: *EventList, path: []const u8) ?usize {
        return self.index.get(path);
    }

    fn ensure(self: *EventList, path: []const u8) !usize {
        if (self.find(path)) |found| return found;
        const owned = try self.arena.allocator().dupe(u8, path);
        try self.states.append(.{ .path = owned });
        const index = self.states.items.len - 1;
        try self.index.put(owned, index);
        return index;
    }

    pub fn create(self: *EventList, path: []const u8) !void {
        const index = try self.ensure(path);
        const state = &self.states.items[index];
        if (state.deleted) {
            state.deleted = false;
        } else {
            state.created = true;
        }
    }

    pub fn update(self: *EventList, path: []const u8) !void {
        const index = try self.ensure(path);
        self.states.items[index].updated = true;
    }

    pub fn remove(self: *EventList, path: []const u8) !void {
        const index = try self.ensure(path);
        self.states.items[index].deleted = true;
    }

    pub fn recordError(self: *EventList, message: []const u8) !void {
        if (self.error_message == null) {
            self.error_message = try self.arena.allocator().dupe(u8, message);
        }
    }

    pub fn hasError(self: *const EventList) bool {
        return self.error_message != null;
    }

    pub fn hasEvents(self: *const EventList) bool {
        if (self.error_message != null) return true;
        for (self.states.items) |state| {
            if (!(state.created and state.deleted)) return true;
        }
        return false;
    }

    /// Returns events whose path slices are owned by the list and valid until
    /// the next `clear`.
    pub fn getEvents(self: *EventList, allocator: Allocator) ![]Event {
        var events = std.array_list.Managed(Event).init(allocator);
        errdefer events.deinit();
        for (self.states.items) |state| {
            if (state.created and state.deleted) continue;
            const event_type: EventType = if (state.created)
                .create
            else if (state.deleted)
                .delete
            else
                .update;
            try events.append(.{ .path = state.path, .type = event_type });
        }
        return try events.toOwnedSlice();
    }
};

test "EventList: upstream coalescing" {
    var list = EventList.init(std.testing.allocator);
    defer list.deinit();

    try list.create("/a");
    try list.remove("/a");
    try list.update("/b");
    try list.remove("/c");
    try list.create("/c");
    try list.create("/d");
    try list.update("/d");

    try std.testing.expect(list.hasEvents());
    const events = try list.getEvents(std.testing.allocator);
    defer std.testing.allocator.free(events);
    try std.testing.expectEqual(@as(usize, 3), events.len);
}
