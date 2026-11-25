// Port of ConfigAwareContextValuesContainer and OverlayContext in src/vs/platform/contextkey/browser/contextKeyService.ts.
const std = @import("std");
const keys = @import("../common/contextkey.zig");

pub const OverlayContext = struct {
    parent: keys.IContext,
    overlay: []const keys.KeyValue,

    pub fn interface(self: *OverlayContext) keys.IContext {
        return .{ .context = self, .get_value = getValue };
    }

    fn getValue(context: *anyopaque, key: []const u8) keys.ContextKeyValue {
        const self: *OverlayContext = @ptrCast(@alignCast(context));
        for (self.overlay) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        return self.parent.getValue(key);
    }
};

const configuration = @import("../../configuration/common/configuration.zig");
const SignalSubscription = @import("../../../base/common/event.zig").SignalSubscription;

/// ConfigAwareContextValuesContainer reads and caches config.* context keys
/// only when requested. Configuration change events invalidate cached keys
/// before notifying expression listeners. The map replaces the JS ternary
/// search tree; owned per-key arenas keep values valid across model reloads.
pub const ConfigAwareContextValuesContainer = struct {
    const prefix = "config.";
    const Entry = struct { arena: std.heap.ArenaAllocator, value: keys.ContextKeyValue };

    allocator: std.mem.Allocator,
    service: *keys.ContextKeyService,
    configuration_service: configuration.IConfigurationService,
    cached: std.StringHashMapUnmanaged(Entry) = .empty,
    listener: ?SignalSubscription = null,

    pub fn init(allocator: std.mem.Allocator, service: *keys.ContextKeyService, configuration_service: configuration.IConfigurationService) ConfigAwareContextValuesContainer {
        return .{ .allocator = allocator, .service = service, .configuration_service = configuration_service };
    }

    pub fn registerListeners(self: *ConfigAwareContextValuesContainer) !void {
        if (self.configuration_service.on_did_change_configuration) |emitter|
            self.listener = try emitter.listenDisposable(self, onDidChangeConfiguration);
        self.service.configuration_context = self.interface();
    }

    pub fn deinit(self: *ConfigAwareContextValuesContainer) void {
        self.service.configuration_context = null;
        if (self.listener) |listener| listener.dispose();
        var iterator = self.cached.valueIterator();
        while (iterator.next()) |entry| entry.arena.deinit();
        self.cached.deinit(self.allocator);
    }

    pub fn interface(self: *ConfigAwareContextValuesContainer) keys.IContext {
        return .{ .context = self, .get_value = getValue };
    }

    fn getValue(context: *anyopaque, key: []const u8) keys.ContextKeyValue {
        const self: *ConfigAwareContextValuesContainer = @ptrCast(@alignCast(context));
        if (!std.mem.startsWith(u8, key, prefix)) return .undefined_value;
        if (self.cached.get(key)) |entry| return entry.value;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        const a = arena.allocator();
        const owned_key = a.dupe(u8, key) catch {
            arena.deinit();
            return .undefined_value;
        };
        const value: keys.ContextKeyValue = if (self.configuration_service.getValue(key[prefix.len..])) |raw|
            fromValue(a, raw.*, true) catch .undefined_value
        else
            .undefined_value;
        self.cached.put(self.allocator, owned_key, .{ .arena = arena, .value = value }) catch {
            arena.deinit();
            return .undefined_value;
        };
        return value;
    }

    fn onDidChangeConfiguration(change: configuration.Change, self: *ConfigAwareContextValuesContainer) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var affected: std.ArrayList([]const u8) = .empty;
        var iterator = self.cached.keyIterator();
        while (iterator.next()) |key| {
            if (change.source != .DEFAULT and !configuration.affectsConfiguration(change, key.*[prefix.len..])) continue;
            try affected.append(arena.allocator(), try arena.allocator().dupe(u8, key.*));
        }
        for (affected.items) |key| {
            if (self.cached.fetchRemove(key)) |removed| {
                var entry = removed.value;
                entry.arena.deinit();
            }
        }
        if (affected.items.len != 0) try self.service.onDidChangeContext.fire(.{ .changed_keys = affected.items });
    }

    fn fromValue(allocator: std.mem.Allocator, value: configuration.Value, top_level: bool) !keys.ContextKeyValue {
        return switch (value) {
            .null => .null_value,
            .bool => |item| .{ .boolean = item },
            .integer => |item| .{ .number = @floatFromInt(item) },
            .float => |item| .{ .number = item },
            .number_string => |item| .{ .number = std.fmt.parseFloat(f64, item) catch return .undefined_value },
            .string => |item| .{ .string = try allocator.dupe(u8, item) },
            .array => |items| blk: {
                // Upstream serializes top-level array settings to a string.
                if (top_level) break :blk .{ .string = try std.json.Stringify.valueAlloc(allocator, value, .{}) };
                const result = try allocator.alloc(keys.ContextKeyValue, items.items.len);
                for (items.items, result) |item, *dest| dest.* = try fromValue(allocator, item, false);
                break :blk .{ .array = result };
            },
            .object => |object| blk: {
                const result = try allocator.create(std.StringHashMap(keys.ContextKeyValue));
                result.* = .init(allocator);
                var iterator = object.iterator();
                while (iterator.next()) |entry|
                    try result.put(try allocator.dupe(u8, entry.key_ptr.*), try fromValue(allocator, entry.value_ptr.*, false));
                break :blk .{ .object = result };
            },
        };
    }
};
