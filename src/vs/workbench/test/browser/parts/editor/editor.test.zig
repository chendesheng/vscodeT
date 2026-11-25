// Terminal editor-factory registry coverage for the port of common/editor.ts.
// The native window uses the same deferred registration/start contract as the
// upstream editor group and editor-part tests, without decorator reflection.
const std = @import("std");
const factory = @import("../../../../common/editor/editorFactory.zig");
const EditorFactoryRegistry = factory.EditorFactoryRegistry;
const IEditorSerializer = factory.IEditorSerializer;
const Allocator = std.mem.Allocator;
const EditorInput = @import("../../../../common/editor/editorInput.zig").EditorInput;
const instantiation = @import("../../../../../platform/instantiation/common/instantiationService.zig");
const ServicesAccessor = @import("../../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const ServiceCollection = @import("../../../../../platform/instantiation/common/serviceCollection.zig").ServiceCollection;

test "EditorFactoryRegistry rejects duplicate serializers" {
    const allocator = std.testing.allocator;
    var registry = EditorFactoryRegistry.init(allocator);
    defer registry.deinit();

    const Serializer = struct {
        fn canSerialize(_: *anyopaque, _: *EditorInput) bool {
            return true;
        }
        fn serialize(_: *anyopaque, _: *EditorInput, _: Allocator) anyerror!?[]const u8 {
            return null;
        }
        fn deserialize(_: *anyopaque, _: []const u8) anyerror!?*EditorInput {
            return null;
        }
    };

    var context: u8 = 0;
    const serializer = IEditorSerializer{
        .context = &context,
        .canSerialize = Serializer.canSerialize,
        .serialize = Serializer.serialize,
        .deserialize = Serializer.deserialize,
    };

    try registry.registerEditorSerializer("test.input", serializer);
    try std.testing.expectError(error.AlreadyRegistered, registry.registerEditorSerializer("test.input", serializer));
    try std.testing.expect(registry.getEditorSerializerByType("test.input") != null);
}

test "EditorFactoryRegistry creates registered factories during start and registrations after start immediately" {
    const allocator = std.testing.allocator;
    var registry = EditorFactoryRegistry.init(allocator);
    defer registry.deinit();
    const Probe = struct {
        calls: usize = 0,
        fn create(context: *anyopaque, accessor: ServicesAccessor) !IEditorSerializer {
            const self: *@This() = @ptrCast(@alignCast(context));
            _ = try accessor.get(instantiation.instantiation_service_id);
            self.calls += 1;
            return .{ .context = self, .canSerialize = canSerialize, .serialize = serialize, .deserialize = deserialize };
        }
        fn canSerialize(_: *anyopaque, _: *EditorInput) bool {
            return true;
        }
        fn serialize(_: *anyopaque, _: *EditorInput, _: Allocator) !?[]const u8 {
            return null;
        }
        fn deserialize(_: *anyopaque, _: []const u8) !?*EditorInput {
            return null;
        }
        fn start(accessor: ServicesAccessor, target: *EditorFactoryRegistry) !void {
            try target.start(accessor);
        }
    };
    var probe = Probe{};
    const constructor = factory.SerializerFactory{ .context = &probe, .create = Probe.create };
    try registry.registerEditorSerializerFactory("before", constructor);
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    try std.testing.expect(registry.getEditorSerializerByType("before") == null);
    try std.testing.expectError(error.AlreadyRegistered, registry.registerEditorSerializerFactory("before", constructor));
    var services = ServiceCollection.init(allocator);
    defer services.deinit();
    var service: instantiation.InstantiationService = undefined;
    try service.init(allocator, &services);
    defer service.deinit();
    try service.invokeFunction(Probe.start, .{&registry});
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(registry.getEditorSerializerByType("before") != null);
    try registry.registerEditorSerializerFactory("after", constructor);
    try std.testing.expectEqual(@as(usize, 2), probe.calls);
    try std.testing.expect(registry.getEditorSerializerByType("after") != null);
    registry.stop(&service);
    try registry.registerEditorSerializerFactory("later", constructor);
    try std.testing.expectEqual(@as(usize, 2), probe.calls);
}
