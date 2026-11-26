// Port of `src/vs/editor/contrib/codelens/browser/codeLensCache.ts`.
// Copies only inert labels/ranges, never provider cache IDs or executable
// commands. Session storage retains only line numbers and line counts.
const std = @import("std");
const Allocator = std.mem.Allocator;
const model_mod = @import("./codelens.zig");
const languages = @import("../../../common/languages.zig");
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const Range = @import("../../../common/core/range.zig").Range;
const CancellationToken = @import("../../../../base/common/cancellation.zig").CancellationToken;
const instantiation = @import("../../../../platform/instantiation/common/instantiation.zig");
const storage_mod = @import("../../../../platform/storage/common/storage.zig");
const resource_key = @import("../../../../base/common/stdUri.zig").resourceKey;

pub const code_lens_cache_id = instantiation.ServiceIdentifier(CodeLensCache, "codeLensCache");
pub fn getCodeLensCache(accessor: instantiation.ServicesAccessor) !*CodeLensCache {
    return accessor.get(code_lens_cache_id);
}
pub fn registerSingleton(collection: *@import("../../../../platform/instantiation/common/serviceCollection.zig").ServiceCollection) !void {
    _ = try collection.setFactory(code_lens_cache_id, createService, disposeService);
}
fn createService(allocator: Allocator, accessor: instantiation.ServicesAccessor) !*CodeLensCache {
    const self = try allocator.create(CodeLensCache);
    errdefer allocator.destroy(self);
    self.* = .{ .allocator = allocator };
    errdefer self.deinit();
    if (accessor.get(storage_mod.storage_service_id)) |storage| try self.attachStorage(storage.*) else |_| {}
    return self;
}
fn disposeService(allocator: Allocator, self: *CodeLensCache) void {
    self.deinit();
    allocator.destroy(self);
}

pub const CodeLensCache = struct {
    allocator: Allocator,
    entries: std.ArrayList(Entry) = .empty,
    storage: ?storage_mod.IStorageService = null,
    storage_listener: ?usize = null,
    const key_name = "codelens/cache2";
    const Entry = struct {
        key: []const u8,
        line_count: usize,
        model: *model_mod.CodeLensModel,
        identity: *Identity,
    };

    /// Upstream compares the cached model object by identity after an expiry
    /// timeout. The native cache clones inert lenses, so retain a separate
    /// object identity until the observing controller releases it. Eviction
    /// cannot recycle an address still held by an expiry callback.
    pub const Identity = struct {
        allocator: Allocator,
        refs: usize = 1,

        fn retain(self: *Identity) *Identity {
            self.refs += 1;
            return self;
        }

        pub fn release(self: *Identity) void {
            self.refs -= 1;
            if (self.refs == 0) self.allocator.destroy(self);
        }
    };

    pub const Cached = struct {
        model: *model_mod.CodeLensModel,
        identity: *Identity,
    };

    pub fn deinit(self: *CodeLensCache) void {
        if (self.storage_listener) |id| self.storage.?.on_will_save_state.unlisten(id);
        while (self.entries.items.len > 0) self.removeAt(0);
        self.entries.deinit(self.allocator);
    }

    fn removeAt(self: *CodeLensCache, index: usize) void {
        const item = self.entries.orderedRemove(index);
        item.model.dispose();
        self.allocator.free(item.key);
        item.identity.release();
    }

    fn indexOf(self: *CodeLensCache, key: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, index| if (std.mem.eql(u8, entry.key, key)) return index;
        return null;
    }

    fn putEntry(self: *CodeLensCache, key: []const u8, line_count: usize, model: *model_mod.CodeLensModel) !void {
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        const identity = try self.allocator.create(Identity);
        identity.* = .{ .allocator = self.allocator };
        if (self.indexOf(key)) |index| self.removeAt(index);
        self.entries.appendAssumeCapacity(.{ .key = key, .line_count = line_count, .model = model, .identity = identity });
        if (self.entries.items.len > 20) while (self.entries.items.len > 15) self.removeAt(0);
    }

    fn inertProvider(self: *CodeLensCache) languages.CodeLensProvider {
        return .{ .context = self, .provide_code_lenses = noProvide };
    }
    fn noProvide(_: *anyopaque, _: Allocator, _: *TextModel, _: CancellationToken) !?languages.CodeLensList {
        return null;
    }

    fn clone(self: *CodeLensCache, data: *const model_mod.CodeLensModel) !*model_mod.CodeLensModel {
        const result = try model_mod.CodeLensModel.create(self.allocator);
        errdefer result.dispose();
        const a = result.arena.allocator();
        const items = try a.alloc(languages.CodeLens, data.lenses.items.len);
        for (data.lenses.items, items) |item, *copy| copy.* = .{
            .range = item.symbol.range,
            .command = if (item.symbol.command) |command| .{ .id = "", .title = try a.dupe(u8, command.title) } else null,
        };
        try result.add(.{ .lenses = items }, self.inertProvider(), 0);
        return result;
    }

    pub fn put(self: *CodeLensCache, model: *TextModel, data: *const model_mod.CodeLensModel) !void {
        const key = try resource_key(self.allocator, model.uri());
        errdefer self.allocator.free(key);
        const copy = try self.clone(data);
        errdefer copy.dispose();
        try self.putEntry(key, model.getLineCount(), copy);
    }

    /// The caller owns the inert copy, independent of future cache eviction.
    pub fn get(self: *CodeLensCache, model: *TextModel) !?*model_mod.CodeLensModel {
        const cached = (try self.getWithIdentity(model)) orelse return null;
        cached.identity.release();
        return cached.model;
    }

    /// Caller owns the inert model and one reference to its cache identity.
    pub fn getWithIdentity(self: *CodeLensCache, model: *TextModel) !?Cached {
        const key = try resource_key(self.allocator, model.uri());
        defer self.allocator.free(key);
        const index = self.indexOf(key) orelse return null;
        const item = self.entries.orderedRemove(index);
        self.entries.appendAssumeCapacity(item);
        if (item.line_count != model.getLineCount()) return null;
        const copy = try self.clone(item.model);
        return .{ .model = copy, .identity = item.identity.retain() };
    }

    pub fn deleteIfSame(self: *CodeLensCache, model: *TextModel, identity: *Identity) bool {
        const key = resource_key(self.allocator, model.uri()) catch return false;
        defer self.allocator.free(key);
        const index = self.indexOf(key) orelse return false;
        const item = self.entries.orderedRemove(index);
        self.entries.appendAssumeCapacity(item);
        if (item.identity != identity or item.line_count != model.getLineCount()) return false;
        self.removeAt(self.entries.items.len - 1);
        return true;
    }

    pub fn delete(self: *CodeLensCache, model: *TextModel) void {
        const key = resource_key(self.allocator, model.uri()) catch return;
        defer self.allocator.free(key);
        if (self.indexOf(key)) |index| self.removeAt(index);
    }

    pub fn attachStorage(self: *CodeLensCache, storage: storage_mod.IStorageService) !void {
        self.storage = storage;
        storage.remove("codelens/cache", .workspace);
        if (storage.get(key_name, .workspace, null)) |raw| self.deserialize(raw) catch {};
        self.storage_listener = try storage.on_will_save_state.listen(self, onWillSaveState);
    }

    fn onWillSaveState(event: storage_mod.IWillSaveStateEvent, self: *CodeLensCache) !void {
        if (event.reason != .shutdown) return;
        const serialized = try self.serialize();
        defer self.allocator.free(serialized);
        try self.storage.?.store(key_name, .{ .string = serialized }, .workspace, .machine);
    }

    pub fn serialize(self: *CodeLensCache) ![]u8 {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        var object = std.json.ObjectMap{};
        for (self.entries.items) |entry| {
            var lines = std.array_list.Managed(std.json.Value).init(a);
            var seen = std.AutoHashMap(usize, void).init(a);
            for (entry.model.lenses.items) |item| {
                const line = item.symbol.range.startLineNumber;
                const previous = try seen.getOrPut(line);
                if (!previous.found_existing) try lines.append(.{ .integer = @intCast(line) });
            }
            var value = std.json.ObjectMap{};
            try value.put(a, "lineCount", .{ .integer = @intCast(entry.line_count) });
            try value.put(a, "lines", .{ .array = lines });
            try object.put(a, entry.key, .{ .object = value });
        }
        return std.json.Stringify.valueAlloc(self.allocator, std.json.Value{ .object = object }, .{});
    }

    pub fn deserialize(self: *CodeLensCache, raw: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, raw, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return;
        var iterator = parsed.value.object.iterator();
        while (iterator.next()) |value| {
            if (value.value_ptr.* != .object) continue;
            const line_count = value.value_ptr.object.get("lineCount") orelse continue;
            const lines = value.value_ptr.object.get("lines") orelse continue;
            if (line_count != .integer or line_count.integer < 1 or lines != .array) continue;
            const count: usize = @intCast(line_count.integer);
            const key = try self.allocator.dupe(u8, value.key_ptr.*);
            errdefer self.allocator.free(key);
            const result = try model_mod.CodeLensModel.create(self.allocator);
            errdefer result.dispose();
            for (lines.array.items) |line| {
                if (line != .integer or line.integer < 1 or line.integer > line_count.integer) continue;
                const number: usize = @intCast(line.integer);
                try result.add(.{ .lenses = &.{.{ .range = Range.init(number, 1, number, 11) }} }, self.inertProvider(), 0);
            }
            try self.putEntry(key, count, result);
        }
    }
};
