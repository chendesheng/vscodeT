// Port of `src/vs/platform/storage/common/storage.ts` (in-memory subset).
//
// Terminal adaptation: there is no SQLite/IndexedDB-backed `Storage`, async
// initialization, flush scheduling, profile/workspace switching or cross-window
// propagation. `InMemoryStorageService` keeps the same scopes, targets, value
// stringification, key/target bookkeeping and change-event semantics in memory
// for the session. Values are stored as strings exactly like the upstream
// `Storage` cache; numbers/booleans/objects are stringified on write.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../../base/common/event.zig").Emitter;

pub const StorageScope = enum(i8) {
    application_shared = -2,
    application = -1,
    profile = 0,
    workspace = 1,
};

pub const StorageTarget = enum { user, machine };

pub const WillSaveStateReason = enum { none, shutdown };

pub const StorageValue = union(enum) {
    string: []const u8,
    number: f64,
    boolean: bool,
    /// Storing `null`/`undefined` removes the key (upstream
    /// `isUndefinedOrNull`).
    null_value,
    undefined_value,
    object: std.json.Value,
};

pub const IStorageEntry = struct {
    key: []const u8,
    value: StorageValue,
    scope: StorageScope,
    target: StorageTarget,
};

pub const IStorageValueChangeEvent = struct {
    scope: StorageScope,
    key: []const u8,
    target: ?StorageTarget,
    external: bool,
};

pub const IStorageTargetChangeEvent = struct {
    scope: StorageScope,
};

pub const IWillSaveStateEvent = struct {
    reason: WillSaveStateReason,
};

pub const ParsedObject = std.json.Parsed(std.json.Value);

const ScopeData = struct {
    values: std.StringHashMap([]u8),
    targets: std.StringHashMap(StorageTarget),

    fn init(allocator: Allocator) ScopeData {
        return .{
            .values = std.StringHashMap([]u8).init(allocator),
            .targets = std.StringHashMap(StorageTarget).init(allocator),
        };
    }

    fn deinit(self: *ScopeData, allocator: Allocator) void {
        var iterator = self.values.iterator();
        while (iterator.next()) |entry| allocator.free(entry.value_ptr.*);
        self.values.deinit();
        self.targets.deinit();
    }
};

pub const InMemoryStorageService = struct {
    allocator: Allocator,
    application_shared: ScopeData,
    application: ScopeData,
    profile: ScopeData,
    workspace: ScopeData,
    onDidChangeValue: Emitter(IStorageValueChangeEvent),
    onDidChangeTarget: Emitter(IStorageTargetChangeEvent),
    onWillSaveState: Emitter(IWillSaveStateEvent),
    filters: std.array_list.Managed(*ValueFilter),
    filter_ids: std.AutoHashMap(usize, FilterHandle),

    pub fn init(allocator: Allocator) InMemoryStorageService {
        return .{
            .allocator = allocator,
            .application_shared = ScopeData.init(allocator),
            .application = ScopeData.init(allocator),
            .profile = ScopeData.init(allocator),
            .workspace = ScopeData.init(allocator),
            .onDidChangeValue = Emitter(IStorageValueChangeEvent).init(allocator),
            .onDidChangeTarget = Emitter(IStorageTargetChangeEvent).init(allocator),
            .onWillSaveState = Emitter(IWillSaveStateEvent).init(allocator),
            .filters = std.array_list.Managed(*ValueFilter).init(allocator),
            .filter_ids = std.AutoHashMap(usize, FilterHandle).init(allocator),
        };
    }

    pub fn deinit(self: *InMemoryStorageService) void {
        self.application_shared.deinit(self.allocator);
        self.application.deinit(self.allocator);
        self.profile.deinit(self.allocator);
        self.workspace.deinit(self.allocator);
        var filters = self.filters.items;
        while (filters.len > 0) {
            const filter = filters[0];
            if (filter.key) |key| self.allocator.free(key);
            self.allocator.destroy(filter);
            _ = self.filters.orderedRemove(0);
            filters = self.filters.items;
        }
        self.filters.deinit();
        self.filter_ids.deinit();
        self.onDidChangeValue.deinit();
        self.onDidChangeTarget.deinit();
        self.onWillSaveState.deinit();
    }

    pub fn initialize(_: *InMemoryStorageService) void {}

    fn data(self: *InMemoryStorageService, scope: StorageScope) *ScopeData {
        return switch (scope) {
            .application_shared => &self.application_shared,
            .application => &self.application,
            .profile => &self.profile,
            .workspace => &self.workspace,
        };
    }

    pub fn get(self: *InMemoryStorageService, key: []const u8, scope: StorageScope, fallback: ?[]const u8) ?[]const u8 {
        return self.data(scope).values.get(key) orelse fallback;
    }

    pub fn getBoolean(self: *InMemoryStorageService, key: []const u8, scope: StorageScope, fallback: ?bool) ?bool {
        const value = self.get(key, scope, null) orelse return fallback;
        if (std.mem.eql(u8, value, "true")) return true;
        if (std.mem.eql(u8, value, "false")) return false;
        return fallback;
    }

    pub fn getNumber(self: *InMemoryStorageService, key: []const u8, scope: StorageScope, fallback: ?f64) ?f64 {
        const value = self.get(key, scope, null) orelse return fallback;
        return std.fmt.parseFloat(f64, value) catch fallback;
    }

    /// Parsed JSON object; the caller owns the result and must call `deinit`.
    pub fn getObject(self: *InMemoryStorageService, allocator: Allocator, key: []const u8, scope: StorageScope) !?ParsedObject {
        const value = self.get(key, scope, null) orelse return null;
        return try std.json.parseFromSlice(std.json.Value, allocator, value, .{});
    }

    pub fn store(self: *InMemoryStorageService, key: []const u8, value: StorageValue, scope: StorageScope, target: StorageTarget) !void {
        return self.storeInternal(key, value, scope, target, false);
    }

    pub fn storeAll(self: *InMemoryStorageService, entries: []const IStorageEntry, external: bool) !void {
        for (entries) |entry| {
            try self.storeInternal(entry.key, entry.value, entry.scope, entry.target, external);
        }
    }

    fn storeInternal(self: *InMemoryStorageService, key: []const u8, value: StorageValue, scope: StorageScope, target: StorageTarget, external: bool) !void {
        switch (value) {
            .null_value, .undefined_value => {
                self.removeInternal(key, scope, external);
                return;
            },
            else => {},
        }
        const scope_data = self.data(scope);
        const serialized = try serializeValue(self.allocator, value);
        errdefer self.allocator.free(serialized);

        const existing_target = scope_data.targets.get(key);
        if (existing_target == null or existing_target.? != target) {
            try scope_data.targets.put(key, target);
            try self.onDidChangeTarget.fire(.{ .scope = scope });
        }

        const result = try scope_data.values.getOrPut(key);
        if (result.found_existing) {
            self.allocator.free(result.value_ptr.*);
        }
        result.value_ptr.* = serialized;

        try self.onDidChangeValue.fire(.{
            .scope = scope,
            .key = key,
            .target = target,
            .external = external,
        });
    }

    pub fn remove(self: *InMemoryStorageService, key: []const u8, scope: StorageScope) void {
        self.removeInternal(key, scope, false);
    }

    fn removeInternal(self: *InMemoryStorageService, key: []const u8, scope: StorageScope, external: bool) void {
        const scope_data = self.data(scope);
        const removed = scope_data.values.fetchRemove(key);
        if (removed) |entry| self.allocator.free(entry.value);
        const had_target = scope_data.targets.remove(key);
        if (had_target) {
            self.onDidChangeTarget.fire(.{ .scope = scope }) catch {};
        }
        self.onDidChangeValue.fire(.{
            .scope = scope,
            .key = key,
            .target = null,
            .external = external,
        }) catch {};
    }

    /// Returns keys with the given target; the caller frees the returned slice.
    pub fn keys(self: *InMemoryStorageService, allocator: Allocator, scope: StorageScope, target: StorageTarget) ![]const []const u8 {
        var result = std.array_list.Managed([]const u8).init(allocator);
        errdefer result.deinit();
        var iterator = self.data(scope).targets.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.* == target) try result.append(entry.key_ptr.*);
        }
        return result.toOwnedSlice();
    }

    pub const ValueListener = struct {
        context: *anyopaque,
        callback: *const fn (event: IStorageValueChangeEvent, context: *anyopaque) anyerror!void,
    };

    const FilterHandle = struct {
        filter: *ValueFilter,
    };

    const ValueFilter = struct {
        scope: StorageScope,
        key: ?[]u8,
        listener: ValueListener,
    };

    /// Registers a scoped/key-filtered listener (upstream
    /// `onDidChangeValue(scope, key)`); returns an id for
    /// `unlistenDidChangeValue`.
    pub fn listenDidChangeValue(
        self: *InMemoryStorageService,
        scope: StorageScope,
        key: ?[]const u8,
        listener: ValueListener,
    ) !usize {
        const filter = try self.allocator.create(ValueFilter);
        errdefer self.allocator.destroy(filter);
        filter.* = .{
            .scope = scope,
            .key = if (key) |value| try self.allocator.dupe(u8, value) else null,
            .listener = listener,
        };
        errdefer if (filter.key) |value| self.allocator.free(value);
        try self.filters.append(filter);
        const id = try self.onDidChangeValue.listen(filter, filterEvent);
        try self.filter_ids.put(id, .{ .filter = filter });
        return id;
    }

    pub fn unlistenDidChangeValue(self: *InMemoryStorageService, id: usize) void {
        const filter_id = self.filter_ids.get(id) orelse return;
        const filter = filter_id.filter;
        _ = self.filter_ids.remove(id);
        self.onDidChangeValue.unlisten(id);
        for (self.filters.items, 0..) |entry, index| {
            if (entry == filter) {
                _ = self.filters.orderedRemove(index);
                break;
            }
        }
        if (filter.key) |key| self.allocator.free(key);
        self.allocator.destroy(filter);
    }

    fn filterEvent(event: IStorageValueChangeEvent, filter: *ValueFilter) anyerror!void {
        if (event.scope != filter.scope) return;
        if (filter.key) |key| {
            if (!std.mem.eql(u8, event.key, key)) return;
        }
        try filter.listener.callback(event, filter.listener.context);
    }

    pub fn isNew(self: *InMemoryStorageService, scope: StorageScope) bool {
        return self.getBoolean("__$__isNewStorageMarker", scope, false) orelse false;
    }

    pub fn flush(self: *InMemoryStorageService, reason: WillSaveStateReason) !void {
        try self.onWillSaveState.fire(.{ .reason = reason });
    }
};

fn serializeValue(allocator: Allocator, value: StorageValue) ![]u8 {
    return switch (value) {
        .string => |text| allocator.dupe(u8, text),
        .number => |number| std.fmt.allocPrint(allocator, "{d}", .{number}),
        .boolean => |boolean| allocator.dupe(u8, if (boolean) "true" else "false"),
        .null_value, .undefined_value => unreachable,
        .object => |object| blk: {
            var out: std.Io.Writer.Allocating = .init(allocator);
            errdefer out.deinit();
            try std.json.Stringify.value(object, .{}, &out.writer);
            break :blk try out.toOwnedSlice();
        },
    };
}

const TestListener = struct {
    events: std.array_list.Managed(IStorageValueChangeEvent),
    target_events: std.array_list.Managed(IStorageTargetChangeEvent),

    fn valueEvent(event: IStorageValueChangeEvent, context: *TestListener) anyerror!void {
        try context.events.append(event);
    }
    fn targetEvent(event: IStorageTargetChangeEvent, context: *TestListener) anyerror!void {
        try context.target_events.append(event);
    }
};

test "storage get/store/remove across scopes and targets" {
    const allocator = std.testing.allocator;
    var storage = InMemoryStorageService.init(allocator);
    defer storage.deinit();

    try std.testing.expectEqualStrings("fallback", storage.get("missing", .workspace, "fallback").?);
    try std.testing.expect(storage.getNumber("missing", .workspace, 5).? == 5);
    try std.testing.expect(storage.getBoolean("missing", .workspace, true).?);

    try storage.store("key", .{ .string = "value" }, .workspace, .machine);
    try std.testing.expectEqualStrings("value", storage.get("key", .workspace, null).?);

    try storage.store("bool", .{ .boolean = false }, .profile, .user);
    try std.testing.expect(!storage.getBoolean("bool", .profile, null).?);

    try storage.storeAll(&.{
        .{ .key = "number", .value = .{ .number = 4 }, .scope = .application, .target = .machine },
        .{ .key = "null", .value = .null_value, .scope = .application, .target = .machine },
    }, false);
    try std.testing.expectEqualStrings("4", storage.get("number", .application, null).?);
    // Storing null removes the key; the fallback is returned instead.
    try std.testing.expect(storage.get("null", .application, null) == null);
    try std.testing.expectEqualStrings("null", storage.get("null", .application, "null").?);

    const object = try storage.getObject(allocator, "number", .application);
    try std.testing.expectEqual(@as(i64, 4), object.?.value.integer);
    object.?.deinit();

    storage.remove("key", .workspace);
    try std.testing.expect(storage.get("key", .workspace, null) == null);
}

test "storage emits scoped value and target events" {
    const allocator = std.testing.allocator;
    var storage = InMemoryStorageService.init(allocator);
    defer storage.deinit();

    var listener = TestListener{
        .events = std.array_list.Managed(IStorageValueChangeEvent).init(allocator),
        .target_events = std.array_list.Managed(IStorageTargetChangeEvent).init(allocator),
    };
    defer listener.events.deinit();
    defer listener.target_events.deinit();
    _ = try storage.onDidChangeValue.listen(&listener, TestListener.valueEvent);
    _ = try storage.onDidChangeTarget.listen(&listener, TestListener.targetEvent);

    try storage.store("one", .{ .string = "1" }, .workspace, .machine);
    try std.testing.expectEqual(@as(usize, 1), listener.events.items.len);
    try std.testing.expectEqual(StorageScope.workspace, listener.events.items[0].scope);
    try std.testing.expectEqual(StorageTarget.machine, listener.events.items[0].target.?);
    try std.testing.expectEqual(@as(usize, 1), listener.target_events.items.len);

    // Same key/target keeps the target and only emits a value change.
    try storage.store("one", .{ .string = "2" }, .workspace, .machine);
    try std.testing.expectEqual(@as(usize, 2), listener.events.items.len);
    try std.testing.expectEqual(@as(usize, 1), listener.target_events.items.len);

    try storage.store("one", .{ .string = "3" }, .profile, .machine);
    try std.testing.expectEqual(StorageScope.profile, listener.events.items[2].scope);

    storage.remove("one", .workspace);
    try std.testing.expectEqual(@as(usize, 4), listener.events.items.len);
    try std.testing.expect(listener.events.items[3].target == null);
}

test "storage keys group by target" {
    const allocator = std.testing.allocator;
    var storage = InMemoryStorageService.init(allocator);
    defer storage.deinit();

    try storage.store("a", .{ .string = "1" }, .workspace, .user);
    try storage.store("b", .{ .string = "2" }, .workspace, .machine);
    try storage.store("c", .{ .string = "3" }, .workspace, .user);

    const user_keys = try storage.keys(allocator, .workspace, .user);
    defer allocator.free(user_keys);
    try std.testing.expectEqual(@as(usize, 2), user_keys.len);

    const machine_keys = try storage.keys(allocator, .workspace, .machine);
    defer allocator.free(machine_keys);
    try std.testing.expectEqual(@as(usize, 1), machine_keys.len);
    try std.testing.expectEqualStrings("b", machine_keys[0]);
}
