// Port of `src/vs/workbench/test/common/memento.test.ts`.
//
// The JS suite mutates plain objects and compares them deeply; here a memento
// value is a `std.json.ObjectMap` accessed through `put/get/remove/count`, and
// the four upstream cases assert the same states.
const std = @import("std");
const storage_mod = @import("../../../platform/storage/common/storage.zig");
const InMemoryStorageService = storage_mod.InMemoryStorageService;
const StorageScope = storage_mod.StorageScope;
const StorageTarget = storage_mod.StorageTarget;
const memento_mod = @import("../../common/memento.zig");
const Memento = memento_mod.Memento;
const MementoStore = memento_mod.MementoStore;

fn expectStored(storage: *InMemoryStorageService, scope: StorageScope, expected: []const u8) !void {
    const raw = storage.get("memento/memento.test", scope, null) orelse return error.MissingMemento;
    try std.testing.expectEqualStrings(expected, raw);
}

fn expectInteger(memento: *memento_mod.ScopedMemento, key: []const u8, expected: i64) !void {
    try std.testing.expectEqual(expected, memento.get(key).?.integer);
}

test "Loading and Saving Memento with Scopes" {
    const allocator = std.testing.allocator;
    var storage = InMemoryStorageService.init(allocator);
    defer storage.deinit();
    var store = MementoStore.init(allocator);
    defer store.deinit();

    var memento = try Memento.init(allocator, "memento.test", &storage, &store);
    defer memento.deinit();

    // Application
    var scoped = try memento.getMemento(.application, .machine);
    try scoped.put("foo", .{ .integer = 1 });
    try std.testing.expectEqual(@as(usize, 1), scoped.count());

    // Profile
    scoped = try memento.getMemento(.profile, .machine);
    try scoped.put("foo", .{ .integer = 4 });

    // Workspace
    scoped = try memento.getMemento(.workspace, .machine);
    try scoped.put("foo", .{ .string = "Hello World" });

    try memento.saveMemento();
    try expectStored(&storage, .application, "{\"foo\":1}");
    try expectStored(&storage, .profile, "{\"foo\":4}");
    try expectStored(&storage, .workspace, "{\"foo\":\"Hello World\"}");

    // Delete all values and save: the keys are removed from storage.
    scoped = try memento.getMemento(.application, .machine);
    scoped.remove("foo");
    scoped = try memento.getMemento(.profile, .machine);
    scoped.remove("foo");
    scoped = try memento.getMemento(.workspace, .machine);
    scoped.remove("foo");

    try memento.saveMemento();
    try std.testing.expectEqual(@as(usize, 0), (try memento.getMemento(.application, .machine)).count());
    try std.testing.expectEqual(@as(usize, 0), (try memento.getMemento(.profile, .machine)).count());
    try std.testing.expectEqual(@as(usize, 0), (try memento.getMemento(.workspace, .machine)).count());
    try std.testing.expect(storage.get("memento/memento.test", .application, null) == null);
    try std.testing.expect(storage.get("memento/memento.test", .profile, null) == null);
    try std.testing.expect(storage.get("memento/memento.test", .workspace, null) == null);
}

test "Save and Load" {
    const allocator = std.testing.allocator;
    var storage = InMemoryStorageService.init(allocator);
    defer storage.deinit();
    var store = MementoStore.init(allocator);
    defer store.deinit();

    var memento = try Memento.init(allocator, "memento.test", &storage, &store);
    defer memento.deinit();

    var profile = try memento.getMemento(.profile, .machine);
    try profile.put("foo", .{ .integer = 1 });

    var workspace = try memento.getMemento(.workspace, .machine);
    try workspace.put("foo", .{ .string = "Hello World" });

    try memento.saveMemento();
    try expectInteger(profile, "foo", 1);
    try std.testing.expectEqualStrings("Hello World", (try memento.getMemento(.workspace, .machine)).get("foo").?.string);

    profile = try memento.getMemento(.profile, .machine);
    try profile.put("foo", .{ .integer = 4 });
    workspace = try memento.getMemento(.workspace, .machine);
    try workspace.put("foo", .{ .string = "World Hello" });

    try memento.saveMemento();
    try expectStored(&storage, .profile, "{\"foo\":4}");
    try expectStored(&storage, .workspace, "{\"foo\":\"World Hello\"}");

    profile.remove("foo");
    workspace.remove("foo");
    try memento.saveMemento();
    try std.testing.expectEqual(@as(usize, 0), (try memento.getMemento(.profile, .machine)).count());
    try std.testing.expectEqual(@as(usize, 0), (try memento.getMemento(.workspace, .machine)).count());
}

test "Save and Load - 2 Components with same id" {
    const allocator = std.testing.allocator;
    var storage = InMemoryStorageService.init(allocator);
    defer storage.deinit();
    var store = MementoStore.init(allocator);
    defer store.deinit();

    var first = try Memento.init(allocator, "memento.test", &storage, &store);
    defer first.deinit();
    var second = try Memento.init(allocator, "memento.test", &storage, &store);
    defer second.deinit();

    var profile = try first.getMemento(.profile, .machine);
    try profile.put("foo", .{ .integer = 1 });
    profile = try second.getMemento(.profile, .machine);
    try profile.put("bar", .{ .integer = 2 });

    var workspace = try first.getMemento(.workspace, .machine);
    try workspace.put("foo", .{ .string = "Hello World" });
    workspace = try second.getMemento(.workspace, .machine);
    try workspace.put("bar", .{ .string = "Hello World" });

    try first.saveMemento();
    try second.saveMemento();

    profile = try first.getMemento(.profile, .machine);
    try std.testing.expectEqual(@as(usize, 2), profile.count());
    try std.testing.expect(profile.get("bar") != null);
    profile = try second.getMemento(.profile, .machine);
    try std.testing.expectEqual(@as(usize, 2), profile.count());

    workspace = try first.getMemento(.workspace, .machine);
    try std.testing.expectEqual(@as(usize, 2), workspace.count());
    try std.testing.expect(workspace.get("bar") != null);
}

test "Clear Memento" {
    const allocator = std.testing.allocator;
    var storage = InMemoryStorageService.init(allocator);
    defer storage.deinit();
    var store = MementoStore.init(allocator);
    defer store.deinit();

    var memento = try Memento.init(allocator, "memento.test", &storage, &store);
    defer memento.deinit();

    var profile = try memento.getMemento(.profile, .machine);
    try profile.put("foo", .{ .string = "Hello World" });
    var workspace = try memento.getMemento(.workspace, .machine);
    try workspace.put("bar", .{ .string = "Hello World" });
    try memento.saveMemento();

    // New storage and cleared mementos.
    var new_storage = InMemoryStorageService.init(allocator);
    defer new_storage.deinit();
    store.clear(.profile);
    store.clear(.workspace);

    var reloaded = try Memento.init(allocator, "memento.test", &new_storage, &store);
    defer reloaded.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try reloaded.getMemento(.profile, .machine)).count());
    try std.testing.expectEqual(@as(usize, 0), (try reloaded.getMemento(.workspace, .machine)).count());
}
