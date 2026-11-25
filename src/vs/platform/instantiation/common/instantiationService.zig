// Port of strict service lookup, singleton construction and invokeFunction
// from `src/vs/platform/instantiation/common/instantiationService.ts`.
// Factories request dependencies explicitly through a scoped ServicesAccessor.
const std = @import("std");
const api = @import("instantiation.zig");
const collection = @import("serviceCollection.zig");
const ServicesAccessor = api.ServicesAccessor;
pub const instantiation_service_id = api.ServiceIdentifier(InstantiationService, "instantiationService");

pub const InstantiationService = struct {
    allocator: std.mem.Allocator,
    services: *collection.ServiceCollection,
    parent: ?*InstantiationService = null,
    children: std.ArrayList(*InstantiationService) = .empty,
    owned: std.ArrayList(Owned) = .empty,
    creating: std.StringHashMapUnmanaged(void) = .empty,
    current: ?*const Scope = null,
    serial: usize = 0,
    disposed: bool = false,

    const Owned = struct { instance: *anyopaque, dispose: *const fn (std.mem.Allocator, *anyopaque) void };
    const Scope = struct { serial: usize, previous: ?*const Scope };

    pub fn init(self: *InstantiationService, allocator: std.mem.Allocator, services: *collection.ServiceCollection) !void {
        self.* = .{ .allocator = allocator, .services = services };
        _ = try services.set(instantiation_service_id, self);
    }

    // As in upstream, a child overrides services locally and resolves other
    // services in the collection where their descriptor was registered.
    pub fn createChild(self: *InstantiationService, services: *collection.ServiceCollection) !*InstantiationService {
        if (self.disposed) return error.ServiceDisposed;
        try self.children.ensureUnusedCapacity(self.allocator, 1);
        const child = try self.allocator.create(InstantiationService);
        errdefer self.allocator.destroy(child);
        try child.init(self.allocator, services);
        child.parent = self;
        self.children.appendAssumeCapacity(child);
        return child;
    }

    pub fn deinit(self: *InstantiationService) void {
        if (self.disposed) return;
        self.disposed = true;
        while (self.children.pop()) |child| {
            child.deinit();
            self.allocator.destroy(child);
        }
        self.children.deinit(self.allocator);
        while (self.owned.pop()) |entry| entry.dispose(self.allocator, entry.instance);
        self.owned.deinit(self.allocator);
        self.creating.deinit(self.allocator);
    }

    fn InvokeResult(comptime func: anytype) type {
        const result = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
        return switch (@typeInfo(result)) {
            .error_union => |info| (info.error_set || error{ServiceDisposed})!info.payload,
            else => error{ServiceDisposed}!result,
        };
    }

    pub fn invokeFunction(self: *InstantiationService, comptime func: anytype, args: anytype) InvokeResult(func) {
        if (self.disposed) return error.ServiceDisposed;
        self.serial += 1;
        const scope = Scope{ .serial = self.serial, .previous = self.current };
        self.current = &scope;
        defer self.current = scope.previous;
        return @call(.auto, func, .{ServicesAccessor{ .context = self, .scope = scope.serial, .resolve = resolve }} ++ args);
    }

    fn resolve(context: *anyopaque, serial: usize, id: []const u8, value_type: []const u8) !*anyopaque {
        const self: *InstantiationService = @ptrCast(@alignCast(context));
        var scope = self.current;
        while (scope) |frame| : (scope = frame.previous) {
            if (frame.serial == serial) return self.getOrCreate(id, value_type);
        }
        return error.AccessorOutsideInvocation;
    }

    fn getOrCreate(self: *InstantiationService, id: []const u8, value_type: []const u8) anyerror!*anyopaque {
        const entry = self.services.entries.get(id) orelse {
            if (self.parent) |parent| return parent.getOrCreate(id, value_type);
            return error.UnknownService;
        };
        if (!std.mem.eql(u8, entry.value_type, value_type)) return error.ServiceTypeMismatch;
        switch (entry.value) {
            .instance => |instance| return instance,
            .descriptor => |factory| {
                const active = try self.creating.getOrPut(self.allocator, id);
                if (active.found_existing) return error.CyclicServiceDependency;
                defer _ = self.creating.remove(id);
                const instance = try self.invokeFunction(makeInstance, .{ self.allocator, factory });
                errdefer factory.dispose(self.allocator, instance);
                try self.owned.append(self.allocator, .{ .instance = instance, .dispose = factory.dispose });
                self.services.entries.getPtr(id).?.value = .{ .instance = instance };
                return instance;
            },
        }
    }

    fn makeInstance(accessor: ServicesAccessor, allocator: std.mem.Allocator, factory: collection.Factory) !*anyopaque {
        return factory.create(allocator, accessor);
    }
};
