// Port of the `IPolicyService`/`AbstractPolicyService` subset of
// `src/vs/platform/policy/common/policy.ts` needed by `PolicyConfiguration`.
// The terminal port provides an explicit in-memory service; file/managed
// policy sources are not ported.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../../base/common/event.zig").Emitter;

pub const PolicyValue = union(enum) {
    string: []const u8,
    number: f64,
    boolean: bool,
};

pub const PolicyType = enum { string, number, boolean };

pub const PolicyDefinition = struct {
    name: []const u8,
    value_type: PolicyType,
    value: ?PolicyValue = null,
    managed_settings: ?bool = null,
    restricted_value: ?PolicyValue = null,
};

pub const InMemoryPolicyService = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    definitions: std.StringHashMap(PolicyDefinition),
    values: std.StringHashMap(PolicyValue),
    onDidChange: Emitter([]const []const u8),

    pub fn init(allocator: Allocator) InMemoryPolicyService {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .definitions = std.StringHashMap(PolicyDefinition).init(allocator),
            .values = std.StringHashMap(PolicyValue).init(allocator),
            .onDidChange = Emitter([]const []const u8).init(allocator),
        };
    }

    pub fn deinit(self: *InMemoryPolicyService) void {
        self.definitions.deinit();
        self.values.deinit();
        self.onDidChange.deinit();
        self.arena.deinit();
    }

    pub fn setDefinition(self: *InMemoryPolicyService, definition: PolicyDefinition) !void {
        try self.definitions.put(try self.arena.allocator().dupe(u8, definition.name), definition);
    }

    pub fn updatePolicyDefinitions(self: *InMemoryPolicyService, definitions: []const PolicyDefinition) !void {
        const arena = self.arena.allocator();
        var changed = std.array_list.Managed([]const u8).init(self.allocator);
        defer changed.deinit();
        for (definitions) |definition| {
            const name = try arena.dupe(u8, definition.name);
            if (!self.definitions.contains(name)) try changed.append(name);
            try self.definitions.put(name, definition);
        }
        if (changed.items.len > 0) try self.onDidChange.fire(changed.items);
    }

    pub fn setPolicyValue(self: *InMemoryPolicyService, name: []const u8, value: ?PolicyValue) !void {
        const changed = if (value) |new_value| blk: {
            if (self.values.get(name)) |existing| {
                if (policyValuesEqual(existing, new_value)) break :blk false;
            }
            const arena = self.arena.allocator();
            try self.values.put(try arena.dupe(u8, name), try cloneValue(arena, new_value));
            break :blk true;
        } else blk: {
            break :blk self.values.remove(name);
        };
        if (changed) {
            const names = try self.arena.allocator().alloc([]const u8, 1);
            names[0] = name;
            try self.onDidChange.fire(names);
        }
    }

    pub fn getPolicyValue(self: *InMemoryPolicyService, name: []const u8) ?PolicyValue {
        return self.values.get(name);
    }

    pub fn listen(self: *InMemoryPolicyService, context: anytype, callback: fn ([]const []const u8, @TypeOf(context)) anyerror!void) !usize {
        return self.onDidChange.listen(context, callback);
    }

    pub fn unlisten(self: *InMemoryPolicyService, id: usize) void {
        self.onDidChange.unlisten(id);
    }
};

fn cloneValue(allocator: Allocator, value: PolicyValue) !PolicyValue {
    return switch (value) {
        .string => |text| .{ .string = try allocator.dupe(u8, text) },
        else => value,
    };
}

pub fn policyValuesEqual(a: PolicyValue, b: PolicyValue) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .string => |text| std.mem.eql(u8, text, b.string),
        .number => |number| number == b.number,
        .boolean => |boolean| boolean == b.boolean,
    };
}

test "in-memory policy service tracks values and change names" {
    const allocator = std.testing.allocator;
    var service = InMemoryPolicyService.init(allocator);
    defer service.deinit();
    const Listener = struct {
        fn onChange(_: []const []const u8, count: *usize) anyerror!void {
            count.* += 1;
        }
    };
    var changes: usize = 0;
    _ = try service.listen(&changes, Listener.onChange);

    try service.setPolicyValue("A", .{ .string = "on" });
    try std.testing.expectEqualStrings("on", service.getPolicyValue("A").?.string);
    try service.setPolicyValue("A", .{ .string = "off" });
    try std.testing.expectEqualStrings("off", service.getPolicyValue("A").?.string);
    try service.setPolicyValue("A", null);
    try std.testing.expect(service.getPolicyValue("A") == null);
    try std.testing.expectEqual(@as(usize, 3), changes);
}
