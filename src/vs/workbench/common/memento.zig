// Port of `src/vs/workbench/common/memento.ts`.
//
// Terminal adaptations:
// - Upstream keeps four static maps keyed by memento id, so two `Memento`
//   instances with the same id share their scoped object. Hidden global state is
//   not allowed here, so the sharing owner is an explicit `MementoStore` passed
//   to every `Memento`; `Memento.clear(scope)` becomes `MementoStore.clear`.
// - A memento value is a `std.json.ObjectMap` allocated from a per-scope arena;
//   callers mutate the map directly instead of a JS object. `reload` replaces
//   the arena, so previously returned key/value slices are invalidated.
const std = @import("std");
const Allocator = std.mem.Allocator;
const storage_mod = @import("../../platform/storage/common/storage.zig");
const InMemoryStorageService = storage_mod.InMemoryStorageService;
const StorageScope = storage_mod.StorageScope;
const StorageTarget = storage_mod.StorageTarget;
const IStorageValueChangeEvent = storage_mod.IStorageValueChangeEvent;

pub const COMMON_PREFIX = "memento/";

pub const ScopedMemento = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    id: []const u8,
    scope: StorageScope,
    target: StorageTarget,
    object: std.json.ObjectMap,
    storage: *InMemoryStorageService,

    pub fn put(self: *ScopedMemento, key: []const u8, value: std.json.Value) !void {
        try self.object.put(self.arena.allocator(), key, value);
    }

    pub fn get(self: *ScopedMemento, key: []const u8) ?std.json.Value {
        return self.object.get(key);
    }

    pub fn remove(self: *ScopedMemento, key: []const u8) void {
        _ = self.object.swapRemove(key);
    }

    pub fn clear(self: *ScopedMemento) void {
        self.object.clearRetainingCapacity();
    }

    pub fn count(self: *const ScopedMemento) usize {
        return self.object.count();
    }

    pub fn isEmpty(self: *const ScopedMemento) bool {
        return self.object.count() == 0;
    }

    pub fn reload(self: *ScopedMemento) !void {
        self.arena.deinit();
        self.arena = std.heap.ArenaAllocator.init(self.allocator);
        self.object = try loadObject(self.arena.allocator(), self.storage, self.id, self.scope);
    }

    pub fn save(self: *ScopedMemento) !void {
        if (self.isEmpty()) {
            self.storage.remove(self.id, self.scope);
            return;
        }
        try self.storage.store(self.id, .{ .object = .{ .object = self.object } }, self.scope, self.target);
    }

    fn deinit(self: *ScopedMemento) void {
        self.arena.deinit();
        self.allocator.free(self.id);
    }
};

fn loadObject(allocator: Allocator, storage: *InMemoryStorageService, id: []const u8, scope: StorageScope) !std.json.ObjectMap {
    const raw = storage.get(id, scope, null) orelse return .{};
    const value = std.json.parseFromSliceLeaky(std.json.Value, allocator, raw, .{}) catch
        return .{};
    return switch (value) {
        .object => |object| object,
        else => .{},
    };
}

pub const MementoStore = struct {
    allocator: Allocator,
    application_shared: std.StringHashMap(*ScopedMemento),
    application: std.StringHashMap(*ScopedMemento),
    profile: std.StringHashMap(*ScopedMemento),
    workspace: std.StringHashMap(*ScopedMemento),

    pub fn init(allocator: Allocator) MementoStore {
        return .{
            .allocator = allocator,
            .application_shared = std.StringHashMap(*ScopedMemento).init(allocator),
            .application = std.StringHashMap(*ScopedMemento).init(allocator),
            .profile = std.StringHashMap(*ScopedMemento).init(allocator),
            .workspace = std.StringHashMap(*ScopedMemento).init(allocator),
        };
    }

    pub fn deinit(self: *MementoStore) void {
        self.deinitMap(&self.application_shared);
        self.deinitMap(&self.application);
        self.deinitMap(&self.profile);
        self.deinitMap(&self.workspace);
    }

    fn deinitMap(self: *MementoStore, map: *std.StringHashMap(*ScopedMemento)) void {
        var iterator = map.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        map.deinit();
    }

    fn mapFor(self: *MementoStore, scope: StorageScope) *std.StringHashMap(*ScopedMemento) {
        return switch (scope) {
            .application_shared => &self.application_shared,
            .application => &self.application,
            .profile => &self.profile,
            .workspace => &self.workspace,
        };
    }

    pub fn clear(self: *MementoStore, scope: StorageScope) void {
        const map = self.mapFor(scope);
        var iterator = map.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        map.clearRetainingCapacity();
    }
};

pub const Memento = struct {
    allocator: Allocator,
    store: *MementoStore,
    storage: *InMemoryStorageService,
    id: []u8,

    pub fn init(allocator: Allocator, id: []const u8, storage: *InMemoryStorageService, store: *MementoStore) !Memento {
        return .{
            .allocator = allocator,
            .store = store,
            .storage = storage,
            .id = try std.fmt.allocPrint(allocator, "{s}{s}", .{ COMMON_PREFIX, id }),
        };
    }

    pub fn deinit(self: *Memento) void {
        self.allocator.free(self.id);
    }

    /// Returns the shared scoped object, loading it from storage on first use.
    pub fn getMemento(self: *Memento, scope: StorageScope, target: StorageTarget) !*ScopedMemento {
        const map = self.store.mapFor(scope);
        if (map.get(self.id)) |existing| return existing;

        const scoped = try self.allocator.create(ScopedMemento);
        errdefer self.allocator.destroy(scoped);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        scoped.* = .{
            .allocator = self.allocator,
            .arena = arena,
            .id = try self.allocator.dupe(u8, self.id),
            .scope = scope,
            .target = target,
            .object = try loadObject(arena.allocator(), self.storage, self.id, scope),
            .storage = self.storage,
        };
        errdefer self.allocator.free(scoped.id);
        try map.put(try self.allocator.dupe(u8, self.id), scoped);
        return scoped;
    }

    pub fn saveMemento(self: *Memento) !void {
        for ([_]StorageScope{ .workspace, .profile, .application, .application_shared }) |scope| {
            if (self.store.mapFor(scope).get(self.id)) |scoped| try scoped.save();
        }
    }

    pub fn reloadMemento(self: *Memento, scope: StorageScope) !void {
        if (self.store.mapFor(scope).get(self.id)) |scoped| try scoped.reload();
    }
};
