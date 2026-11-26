// Port of the global-enablement portion of
// `src/vs/workbench/services/extensionManagement/browser/extensionEnablementService.ts`
// and the profile-storage `StorageManager` from
// `src/vs/platform/extensionManagement/common/extensionEnablementService.ts`.
//
// Terminal adaptation: the workbench has no profile storage database, so the
// service receives a narrow `Store` that the native window binds to
// `<user-data-dir>/User/globalStorage/extensions.state.json`. The stored value
// is upstream's profile value for `extensionsIdentifiers/disabled`:
// `[{"id":"publisher.name"}]`. Workspace enablement, workspace trust,
// extension kind, dependency, bisect and malicious-extension layers are not
// ported, so only `EnabledGlobally`/`DisabledGlobally` can be set.
//
// The change event carries the changed identifier instead of upstream's
// `IExtensionIdentifier[]`; every consumer in the TUI updates its own model
// from the call site, and the event exists for observers/tests.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const util = @import("../../../../platform/extensionManagement/common/extensionManagementUtil.zig");
const management = @import("../common/extensionManagement.zig");
const EnablementState = management.EnablementState;

/// Native persistence boundary. `load` returns the raw stored JSON value or
/// null when no value has been stored; `save` stores the raw JSON value.
pub const Store = struct {
    context: *anyopaque,
    load: *const fn (context: *anyopaque, allocator: Allocator) anyerror!?[]const u8,
    save: *const fn (context: *anyopaque, value: []const u8) anyerror!void,
};

const StoredIdentifier = struct { id: []const u8 };

pub const ExtensionEnablementService = struct {
    allocator: Allocator,
    store: ?Store = null,
    /// Owned, lowercased ids of globally disabled extensions.
    disabled: std.array_list.Managed([]u8),
    on_did_change: Emitter([]const u8),

    pub fn init(allocator: Allocator, store: ?Store) !*ExtensionEnablementService {
        const self = try allocator.create(ExtensionEnablementService);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .store = store,
            .disabled = std.array_list.Managed([]u8).init(allocator),
            .on_did_change = Emitter([]const u8).init(allocator),
        };
        errdefer self.deinitContents();
        try self.load();
        return self;
    }

    pub fn deinit(self: *ExtensionEnablementService) void {
        self.deinitContents();
        self.allocator.destroy(self);
    }

    fn deinitContents(self: *ExtensionEnablementService) void {
        for (self.disabled.items) |identifier| self.allocator.free(identifier);
        self.disabled.deinit();
        self.on_did_change.deinit();
    }

    fn load(self: *ExtensionEnablementService) !void {
        const store = self.store orelse return;
        const raw = (try store.load(store.context, self.allocator)) orelse return;
        defer self.allocator.free(raw);
        var parsed = std.json.parseFromSlice([]StoredIdentifier, self.allocator, raw, .{
            .ignore_unknown_fields = true,
        }) catch return; // A corrupt value loads as "nothing disabled".
        defer parsed.deinit();
        for (parsed.value) |entry| {
            if (entry.id.len == 0) continue;
            if (self.find(entry.id) != null) continue;
            const owned = try self.allocator.dupe(u8, entry.id);
            errdefer self.allocator.free(owned);
            try self.disabled.append(owned);
        }
    }

    pub fn getDisabledExtensions(self: *const ExtensionEnablementService, allocator: Allocator) ![][]const u8 {
        const result = try allocator.alloc([]const u8, self.disabled.items.len);
        for (self.disabled.items, 0..) |identifier, index| result[index] = identifier;
        return result;
    }

    pub fn isEnabled(self: *const ExtensionEnablementService, identifier: []const u8) bool {
        return self.find(identifier) == null;
    }

    pub fn getEnablementState(self: *const ExtensionEnablementService, identifier: []const u8) EnablementState {
        return if (self.find(identifier) != null) .DisabledGlobally else .EnabledGlobally;
    }

    /// Returns whether the state changed. The new value is persisted before it
    /// is committed, so a storage failure leaves the in-memory state intact.
    pub fn setEnablement(self: *ExtensionEnablementService, identifier: []const u8, state: EnablementState) !bool {
        const disable = switch (state) {
            .DisabledGlobally => true,
            .EnabledGlobally => false,
            else => return error.UnsupportedEnablementState,
        };
        const existing = self.find(identifier);
        if (disable == (existing != null)) return false;

        var next: std.array_list.Managed([]u8) = .init(self.allocator);
        errdefer {
            for (next.items) |entry| self.allocator.free(entry);
            next.deinit();
        }
        try next.ensureTotalCapacity(self.disabled.items.len + 1);
        for (self.disabled.items) |entry| {
            if (util.areSameExtensions(entry, identifier)) continue;
            next.appendAssumeCapacity(try self.allocator.dupe(u8, entry));
        }
        if (disable) next.appendAssumeCapacity(try self.allocator.dupe(u8, identifier));
        try self.persist(next.items);

        const previous = self.disabled;
        self.disabled = next;
        for (previous.items) |entry| self.allocator.free(entry);
        previous.deinit();

        try self.on_did_change.fire(identifier);
        return true;
    }

    /// Serializes the upstream profile value shape: `[{"id":"…"}]`.
    fn persist(self: *ExtensionEnablementService, identifiers: []const []u8) !void {
        const store = self.store orelse return;
        var items: std.array_list.Managed(StoredIdentifier) = .init(self.allocator);
        defer items.deinit();
        try items.ensureTotalCapacity(identifiers.len);
        for (identifiers) |identifier| items.appendAssumeCapacity(.{ .id = identifier });
        const wrapped = try std.json.Stringify.valueAlloc(self.allocator, items.items, .{});
        defer self.allocator.free(wrapped);
        try store.save(store.context, wrapped);
    }

    fn find(self: *const ExtensionEnablementService, identifier: []const u8) ?[]const u8 {
        for (self.disabled.items) |entry| {
            if (util.areSameExtensions(entry, identifier)) return entry;
        }
        return null;
    }
};
