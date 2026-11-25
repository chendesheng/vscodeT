// Port of the service lifetime, descriptor and scoped-accessor cases from
// `src/vs/platform/instantiation/test/common/instantiationService.test.ts`.
const std = @import("std");
const instantiation = @import("../../common/instantiation.zig");
const ServiceCollection = @import("../../common/serviceCollection.zig").ServiceCollection;
const InstantiationService = @import("../../common/instantiationService.zig").InstantiationService;
const ServicesAccessor = instantiation.ServicesAccessor;
const Counter = struct { created: usize = 0, disposed: usize = 0 };
const counter_id = instantiation.ServiceIdentifier(Counter, "counter");
const Example = struct {
    counter: *Counter,
    fn create(allocator: std.mem.Allocator, accessor: ServicesAccessor) !*Example {
        const counter = try accessor.get(counter_id);
        const example = try allocator.create(Example);
        example.* = .{ .counter = counter };
        counter.created += 1;
        return example;
    }
    fn dispose(allocator: std.mem.Allocator, self: *Example) void {
        self.counter.disposed += 1;
        allocator.destroy(self);
    }
    fn get(accessor: ServicesAccessor) !*Example {
        return accessor.get(example_id);
    }
};
const example_id = instantiation.ServiceIdentifier(Example, "example");

test "service collection is live and children share the parent's singleton" {
    const allocator = std.testing.allocator;
    var parent_collection = ServiceCollection.init(allocator);
    defer parent_collection.deinit();
    var child_collection = ServiceCollection.init(allocator);
    defer child_collection.deinit();
    var counter: Counter = .{};
    var shadow: Counter = .{};
    var parent: InstantiationService = undefined;
    try parent.init(allocator, &parent_collection);
    defer parent.deinit();
    const child = try parent.createChild(&child_collection);
    _ = try parent_collection.setFactory(example_id, Example.create, Example.dispose);
    try std.testing.expectError(error.UnknownService, child.invokeFunction(Example.get, .{}));
    _ = try parent_collection.set(counter_id, &counter);
    _ = try child_collection.set(counter_id, &shadow);
    const service = try child.invokeFunction(Example.get, .{});
    try std.testing.expectEqual(service, try parent.invokeFunction(Example.get, .{}));
    try std.testing.expectEqual(@as(usize, 1), counter.created);
    try std.testing.expectEqual(@as(usize, 0), shadow.created);
    child.deinit();
    try std.testing.expectError(error.ServiceDisposed, child.invokeFunction(Example.get, .{}));
    try std.testing.expectEqual(@as(usize, 0), counter.disposed);
    parent.deinit();
    try std.testing.expectEqual(@as(usize, 1), counter.disposed);
}

test "keeping an accessor outside invokeFunction is rejected" {
    var collection = ServiceCollection.init(std.testing.allocator);
    defer collection.deinit();
    var service: InstantiationService = undefined;
    try service.init(std.testing.allocator, &collection);
    defer service.deinit();
    var accessor: ServicesAccessor = undefined;
    try service.invokeFunction(struct {
        fn capture(scoped: ServicesAccessor, result: *ServicesAccessor) !void {
            result.* = scoped;
        }
    }.capture, .{&accessor});
    try std.testing.expectError(error.AccessorOutsideInvocation, accessor.get(counter_id));
}

test "cyclic service dependency leaves the descriptor available for retry" {
    const Factory = struct {
        fn cycle(_: std.mem.Allocator, accessor: ServicesAccessor) anyerror!*Example {
            return accessor.get(example_id);
        }
    };
    var collection = ServiceCollection.init(std.testing.allocator);
    defer collection.deinit();
    var service: InstantiationService = undefined;
    try service.init(std.testing.allocator, &collection);
    defer service.deinit();
    _ = try collection.setFactory(example_id, Factory.cycle, Example.dispose);
    try std.testing.expectError(error.CyclicServiceDependency, service.invokeFunction(Example.get, .{}));
    try std.testing.expectError(error.CyclicServiceDependency, service.invokeFunction(Example.get, .{}));
}
