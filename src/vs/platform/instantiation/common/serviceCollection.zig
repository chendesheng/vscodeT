// Port of `src/vs/platform/instantiation/common/serviceCollection.ts`.
// The collection borrows registered instances. InstantiationService owns only
// the instances it creates from explicit factories.
const std = @import("std");
const ServicesAccessor = @import("instantiation.zig").ServicesAccessor;

pub const Factory = struct {
    create: *const fn (std.mem.Allocator, ServicesAccessor) anyerror!*anyopaque,
    dispose: *const fn (std.mem.Allocator, *anyopaque) void,
};

pub const Entry = struct {
    value_type: []const u8,
    value: union(enum) { instance: *anyopaque, descriptor: Factory },
};

pub const ServiceCollection = struct {
    entries: std.StringHashMap(Entry),

    pub fn init(allocator: std.mem.Allocator) ServiceCollection {
        return .{ .entries = .init(allocator) };
    }

    pub fn deinit(self: *ServiceCollection) void {
        self.entries.deinit();
    }

    pub fn set(self: *ServiceCollection, comptime Id: type, instance: *Id.Value) !?Entry {
        return self.put(Id, .{ .instance = instance });
    }

    pub fn setFactory(
        self: *ServiceCollection,
        comptime Id: type,
        comptime create: fn (std.mem.Allocator, ServicesAccessor) anyerror!*Id.Value,
        comptime dispose: fn (std.mem.Allocator, *Id.Value) void,
    ) !?Entry {
        const Adapter = struct {
            fn make(allocator: std.mem.Allocator, services: ServicesAccessor) anyerror!*anyopaque {
                return try create(allocator, services);
            }
            fn destroy(allocator: std.mem.Allocator, instance: *anyopaque) void {
                dispose(allocator, @ptrCast(@alignCast(instance)));
            }
        };
        return self.put(Id, .{ .descriptor = .{ .create = Adapter.make, .dispose = Adapter.destroy } });
    }

    fn put(self: *ServiceCollection, comptime Id: type, value: @FieldType(Entry, "value")) !?Entry {
        const entry = try self.entries.getOrPut(Id.id);
        const previous = if (entry.found_existing) entry.value_ptr.* else null;
        if (previous) |old| {
            if (!std.mem.eql(u8, old.value_type, @typeName(Id.Value))) return error.ServiceTypeMismatch;
        }
        entry.value_ptr.* = .{ .value_type = @typeName(Id.Value), .value = value };
        return previous;
    }

    pub fn has(self: *const ServiceCollection, comptime Id: type) bool {
        return self.entries.contains(Id.id);
    }

    pub fn get(self: *const ServiceCollection, comptime Id: type) ?Entry {
        return self.entries.get(Id.id);
    }

    pub fn clone(self: *const ServiceCollection) !ServiceCollection {
        return .{ .entries = try self.entries.clone() };
    }
};
