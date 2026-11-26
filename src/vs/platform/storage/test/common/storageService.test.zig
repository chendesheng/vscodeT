// Port of `src/vs/platform/storage/test/common/storageService.test.ts`.
//
// The upstream suite is generic over async storage backends; this port runs the
// same cases against the synchronous in-memory terminal service.
const std = @import("std");
const storage_mod = @import("../../common/storage.zig");
const InMemoryStorageService = storage_mod.InMemoryStorageService;
const StorageScope = storage_mod.StorageScope;
const StorageTarget = storage_mod.StorageTarget;
const IStorageValueChangeEvent = storage_mod.IStorageValueChangeEvent;
const IStorageTargetChangeEvent = storage_mod.IStorageTargetChangeEvent;

const Events = struct {
    values: std.array_list.Managed(IStorageValueChangeEvent),
    targets: std.array_list.Managed(IStorageTargetChangeEvent),
    value_id: ?usize = null,
    target_id: ?usize = null,

    fn init(allocator: std.mem.Allocator) Events {
        return .{
            .values = std.array_list.Managed(IStorageValueChangeEvent).init(allocator),
            .targets = std.array_list.Managed(IStorageTargetChangeEvent).init(allocator),
        };
    }

    fn deinit(self: *Events) void {
        self.reset();
        self.values.deinit();
        self.targets.deinit();
    }

    fn onValue(event: IStorageValueChangeEvent, context: *Events) anyerror!void {
        var owned = event;
        owned.key = try context.values.allocator.dupe(u8, event.key);
        errdefer context.values.allocator.free(owned.key);
        try context.values.append(owned);
    }

    fn onTarget(event: IStorageTargetChangeEvent, context: *Events) anyerror!void {
        try context.targets.append(event);
    }

    fn listenValues(self: *Events, storage: *InMemoryStorageService, scope: StorageScope, key: ?[]const u8) !void {
        self.value_id = try storage.listenDidChangeValue(scope, key, .{
            .context = self,
            .callback = struct {
                fn wrapped(event: IStorageValueChangeEvent, context: *anyopaque) anyerror!void {
                    const events: *Events = @ptrCast(@alignCast(context));
                    try onValue(event, events);
                }
            }.wrapped,
        });
    }

    fn listenTargets(self: *Events, storage: *InMemoryStorageService) !void {
        _ = try storage.onDidChangeTarget.listen(self, onTarget);
    }

    fn findValue(self: *Events, key: []const u8) ?IStorageValueChangeEvent {
        for (self.values.items) |event| {
            if (std.mem.eql(u8, event.key, key)) return event;
        }
        return null;
    }

    fn reset(self: *Events) void {
        for (self.values.items) |event| self.values.allocator.free(event.key);
        self.values.clearRetainingCapacity();
        self.targets.clearRetainingCapacity();
    }
};

fn objectValue(allocator: std.mem.Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, json, .{});
}

fn storeData(allocator: std.mem.Allocator, scope: StorageScope) !void {
    var storage = InMemoryStorageService.init(allocator);
    defer storage.deinit();
    var events = Events.init(allocator);
    defer events.deinit();
    try events.listenValues(&storage, scope, null);

    try std.testing.expectEqualStrings("foobar", storage.get("test.get", scope, "foobar").?);
    try std.testing.expectEqualStrings("", storage.get("test.get", scope, "").?);
    try std.testing.expectEqual(@as(f64, 5), storage.getNumber("test.getNumber", scope, 5).?);
    try std.testing.expectEqual(@as(f64, 0), storage.getNumber("test.getNumber", scope, 0).?);
    try std.testing.expect(storage.getBoolean("test.getBoolean", scope, true).?);
    try std.testing.expect(!storage.getBoolean("test.getBoolean", scope, false).?);
    try std.testing.expect(try storage.getObject(allocator, "missing", scope) == null);

    try storage.store("test.get", .{ .string = "foobar" }, scope, .machine);
    try std.testing.expectEqualStrings("foobar", storage.get("test.get", scope, null).?);
    var event = events.findValue("test.get").?;
    try std.testing.expectEqual(scope, event.scope);
    events.reset();

    try storage.store("test.get", .{ .string = "" }, scope, .machine);
    try std.testing.expectEqualStrings("", storage.get("test.get", scope, null).?);
    event = events.findValue("test.get").?;
    try std.testing.expectEqual(scope, event.scope);

    try storage.store("test.getNumber", .{ .number = 5 }, scope, .machine);
    try std.testing.expectEqual(@as(f64, 5), storage.getNumber("test.getNumber", scope, null).?);
    try storage.store("test.getNumber", .{ .number = 0 }, scope, .machine);
    try std.testing.expectEqual(@as(f64, 0), storage.getNumber("test.getNumber", scope, null).?);

    try storage.store("test.getBoolean", .{ .boolean = true }, scope, .machine);
    try std.testing.expect(storage.getBoolean("test.getBoolean", scope, null).?);
    try storage.store("test.getBoolean", .{ .boolean = false }, scope, .machine);
    try std.testing.expect(!storage.getBoolean("test.getBoolean", scope, null).?);

    inline for (.{ "{}", "[42]", "{\"foo\":{}}" }) |json| {
        const value = try objectValue(allocator, json);
        defer value.deinit();
        try storage.store("test.getObject", .{ .object = value.value }, scope, .machine);
        const parsed = try storage.getObject(allocator, "test.getObject", scope);
        try std.testing.expect(parsed != null);
        parsed.?.deinit();
    }

    try std.testing.expect(storage.get("test.getDefault", scope, "getDefault") != null);
    try std.testing.expectEqual(@as(f64, 5), storage.getNumber("test.getNumberDefault", scope, 5).?);
    try std.testing.expect(storage.getBoolean("test.getBooleanDefault", scope, true).?);

    try storage.storeAll(&.{
        .{ .key = "test.storeAll1", .value = .{ .string = "foobar" }, .scope = scope, .target = .machine },
        .{ .key = "test.storeAll2", .value = .{ .number = 4 }, .scope = scope, .target = .machine },
        .{ .key = "test.storeAll3", .value = .null_value, .scope = scope, .target = .machine },
    }, false);
    try std.testing.expectEqualStrings("foobar", storage.get("test.storeAll1", scope, null).?);
    try std.testing.expectEqualStrings("4", storage.get("test.storeAll2", scope, null).?);
    try std.testing.expectEqualStrings("null", storage.get("test.storeAll3", scope, "null").?);
    try std.testing.expect(storage.get("test.storeAll3", scope, null) == null);
}

test "Get Data, Integer, Boolean (application)" {
    try storeData(std.testing.allocator, .application);
}

test "Get Data, Integer, Boolean (profile)" {
    try storeData(std.testing.allocator, .profile);
}

test "Get Data, Integer, Boolean, Object (workspace)" {
    try storeData(std.testing.allocator, .workspace);
}

test "Storage change source" {
    const allocator = std.testing.allocator;
    var storage = InMemoryStorageService.init(allocator);
    defer storage.deinit();
    var events = Events.init(allocator);
    defer events.deinit();
    try events.listenValues(&storage, .workspace, null);

    try storage.storeAll(&.{.{ .key = "testExternalChange", .value = .{ .string = "foobar" }, .scope = .workspace, .target = .machine }}, true);
    try std.testing.expect(events.findValue("testExternalChange").?.external);

    try storage.storeAll(&.{.{ .key = "testChange", .value = .{ .string = "barfoo" }, .scope = .workspace, .target = .machine }}, false);
    try std.testing.expect(!events.findValue("testChange").?.external);

    try storage.store("testChange", .{ .string = "foobar" }, .workspace, .machine);
    try std.testing.expect(!events.findValue("testChange").?.external);
}

test "Storage change event scope (all keys)" {
    const allocator = std.testing.allocator;
    var storage = InMemoryStorageService.init(allocator);
    defer storage.deinit();
    var events = Events.init(allocator);
    defer events.deinit();
    try events.listenValues(&storage, .workspace, null);

    try storage.store("testChange", .{ .string = "foobar" }, .workspace, .machine);
    try storage.store("testChange2", .{ .string = "foobar" }, .workspace, .machine);
    try storage.store("testChange", .{ .string = "foobar" }, .application, .machine);
    try storage.store("testChange", .{ .string = "foobar" }, .profile, .machine);
    try storage.store("testChange2", .{ .string = "foobar" }, .profile, .machine);
    try std.testing.expectEqual(@as(usize, 2), events.values.items.len);
}

test "Storage change event scope (specific key)" {
    const allocator = std.testing.allocator;
    var storage = InMemoryStorageService.init(allocator);
    defer storage.deinit();
    var events = Events.init(allocator);
    defer events.deinit();
    try events.listenValues(&storage, .workspace, "testChange");

    try storage.store("testChange", .{ .string = "foobar" }, .workspace, .machine);
    try storage.store("testChange", .{ .string = "foobar" }, .profile, .user);
    try storage.store("testChange", .{ .string = "foobar" }, .application, .machine);
    try storage.store("testChange2", .{ .string = "foobar" }, .workspace, .machine);
    try std.testing.expect(events.findValue("testChange") != null);
    try std.testing.expectEqual(@as(usize, 1), events.values.items.len);
}

fn removeData(allocator: std.mem.Allocator, scope: StorageScope) !void {
    var storage = InMemoryStorageService.init(allocator);
    defer storage.deinit();
    var events = Events.init(allocator);
    defer events.deinit();
    try events.listenValues(&storage, scope, null);

    try storage.store("test.remove", .{ .string = "foobar" }, scope, .machine);
    try std.testing.expectEqualStrings("foobar", storage.get("test.remove", scope, null).?);
    storage.remove("test.remove", scope);
    try std.testing.expect(storage.get("test.remove", scope, null) == null);
    const event = events.findValue("test.remove").?;
    try std.testing.expectEqual(scope, event.scope);
}

test "Remove Data (application)" {
    try removeData(std.testing.allocator, .application);
}

test "Remove Data (profile)" {
    try removeData(std.testing.allocator, .profile);
}

test "Remove Data (workspace)" {
    try removeData(std.testing.allocator, .workspace);
}

test "Keys (in-memory)" {
    const allocator = std.testing.allocator;
    var storage = InMemoryStorageService.init(allocator);
    defer storage.deinit();
    var events = Events.init(allocator);
    defer events.deinit();
    try events.listenTargets(&storage);

    for ([_]StorageScope{ .workspace, .profile, .application }) |scope| {
        for ([_]StorageTarget{ .machine, .user }) |target| {
            const keys = try storage.keys(allocator, scope, target);
            defer allocator.free(keys);
            try std.testing.expectEqual(@as(usize, 0), keys.len);
        }
    }

    for ([_]StorageScope{ .workspace, .profile, .application }) |scope| {
        var value_events = Events.init(allocator);
        defer value_events.deinit();
        try value_events.listenValues(&storage, scope, null);
        defer if (value_events.value_id) |id| storage.unlistenDidChangeValue(id);

        for ([_]StorageTarget{ .machine, .user }) |target| {
            events.reset();
            value_events.reset();

            try storage.store("test.target1", .{ .string = "value1" }, scope, target);
            const first = try storage.keys(allocator, scope, target);
            defer allocator.free(first);
            try std.testing.expectEqual(@as(usize, 1), first.len);
            try std.testing.expectEqual(scope, events.targets.items[0].scope);
            try std.testing.expectEqualStrings("test.target1", value_events.values.items[0].key);
            try std.testing.expectEqual(scope, value_events.values.items[0].scope);
            try std.testing.expectEqual(target, value_events.values.items[0].target.?);

            events.reset();
            value_events.reset();
            try storage.store("test.target1", .{ .string = "otherValue1" }, scope, target);
            try std.testing.expectEqual(@as(usize, 0), events.targets.items.len);
            try std.testing.expectEqualStrings("test.target1", value_events.values.items[0].key);

            try storage.store("test.target2", .{ .string = "value2" }, scope, target);
            try storage.store("test.target3", .{ .string = "value3" }, scope, target);
            const all = try storage.keys(allocator, scope, target);
            defer allocator.free(all);
            try std.testing.expectEqual(@as(usize, 3), all.len);
        }
    }

    for ([_]StorageScope{ .workspace, .profile, .application }) |scope| {
        for ([_]StorageTarget{ .machine, .user }) |target| {
            const before = try storage.keys(allocator, scope, target);
            const before_len = before.len;
            allocator.free(before);

            try storage.store("test.target4", .{ .string = "value1" }, scope, target);
            const added = try storage.keys(allocator, scope, target);
            defer allocator.free(added);
            try std.testing.expectEqual(before_len + 1, added.len);

            storage.remove("test.target4", scope);
            const removed = try storage.keys(allocator, scope, target);
            defer allocator.free(removed);
            try std.testing.expectEqual(before_len, removed.len);
        }
    }

    for ([_]StorageScope{ .workspace, .profile, .application }) |scope| {
        for ([_]StorageTarget{ .machine, .user }) |target| {
            const keys = try storage.keys(allocator, scope, target);
            defer allocator.free(keys);
            for (keys) |key| storage.remove(key, scope);
            const empty = try storage.keys(allocator, scope, target);
            defer allocator.free(empty);
            try std.testing.expectEqual(@as(usize, 0), empty.len);
        }
    }

    for ([_]StorageScope{ .workspace, .profile, .application }) |scope| {
        for ([_]StorageTarget{ .machine, .user }) |target| {
            try storage.store("test.target1", .{ .string = "value1" }, scope, target);
            const one = try storage.keys(allocator, scope, target);
            defer allocator.free(one);
            try std.testing.expectEqual(@as(usize, 1), one.len);

            try storage.store("test.target1", .null_value, scope, target);
            const zero = try storage.keys(allocator, scope, target);
            defer allocator.free(zero);
            try std.testing.expectEqual(@as(usize, 0), zero.len);
        }
    }
}

test "Storage persists profile values and targets across instances" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/profile.json", .{tmp.sub_path});
    defer a.free(path);
    {
        var storage = InMemoryStorageService.init(a);
        defer storage.deinit();
        try storage.attachProfileStorage(io, path);
        const key = try a.dupe(u8, "dynamic");
        try storage.store(key, .{ .string = "value" }, .profile, .machine);
        a.free(key);
        try storage.store("other", .{ .boolean = false }, .profile, .user);
        try storage.store("unpersisted", .{ .string = "workspace only" }, .workspace, .machine);
        try storage.flush(.shutdown);
    }
    {
        var storage = InMemoryStorageService.init(a);
        defer storage.deinit();
        try storage.attachProfileStorage(io, path);
        try std.testing.expectEqualStrings("value", storage.get("dynamic", .profile, null).?);
        try std.testing.expectEqual(false, storage.getBoolean("other", .profile, null).?);
        try std.testing.expect(storage.get("unpersisted", .workspace, null) == null);
        const keys = try storage.keys(a, .profile, .machine);
        defer a.free(keys);
        try std.testing.expectEqual(@as(usize, 1), keys.len);
        try std.testing.expectEqualStrings("dynamic", keys[0]);
        storage.remove("dynamic", .profile);
    }
    {
        var storage = InMemoryStorageService.init(a);
        defer storage.deinit();
        try storage.attachProfileStorage(io, path);
        try std.testing.expect(storage.get("dynamic", .profile, null) == null);
        try std.testing.expectEqual(false, storage.getBoolean("other", .profile, null).?);
    }
}
