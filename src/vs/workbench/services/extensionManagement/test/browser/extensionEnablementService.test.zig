// Port of the global-enablement cases from
// `src/vs/workbench/services/extensionManagement/test/browser/extensionEnablementService.test.ts`.
//
// Terminal adaptation: the TUI has no workspace enablement profiles, so the
// workspace/trust/dependency cases are not portable. The persistence adapter is
// an in-memory Store that records the raw profile value.
const std = @import("std");
const service_mod = @import("../../browser/extensionEnablementService.zig");
const management = @import("../../common/extensionManagement.zig");
const service_type = service_mod.ExtensionEnablementService;
const Store = service_mod.Store;
const EnablementState = management.EnablementState;

const TestStore = struct {
    value: ?[]u8 = null,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) TestStore {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *TestStore) void {
        if (self.value) |value| self.allocator.free(value);
    }

    fn store(self: *TestStore) Store {
        return .{ .context = self, .load = load, .save = save };
    }

    fn load(context: *anyopaque, allocator: std.mem.Allocator) anyerror!?[]const u8 {
        const self: *TestStore = @ptrCast(@alignCast(context));
        const value = self.value orelse return null;
        const copy = try allocator.dupe(u8, value);
        return @as(?[]const u8, copy);
    }

    fn save(context: *anyopaque, value: []const u8) anyerror!void {
        const self: *TestStore = @ptrCast(@alignCast(context));
        if (self.value) |old| self.allocator.free(old);
        self.value = try self.allocator.dupe(u8, value);
    }
};

test "enablement state helper matches upstream" {
    try std.testing.expect(EnablementState.EnabledGlobally.isEnabled());
    try std.testing.expect(EnablementState.EnabledWorkspace.isEnabled());
    try std.testing.expect(EnablementState.EnabledByEnvironment.isEnabled());
    try std.testing.expect(!EnablementState.DisabledGlobally.isEnabled());
    try std.testing.expect(!EnablementState.DisabledWorkspace.isEnabled());
    try std.testing.expect(!EnablementState.DisabledByExtensionDependency.isEnabled());
}

test "test disable an extension globally" {
    const allocator = std.testing.allocator;
    var store = TestStore.init(allocator);
    defer store.deinit();
    var service = try service_type.init(allocator, store.store());
    defer service.deinit();

    try std.testing.expect(try service.setEnablement("example.extension", .DisabledGlobally));
    try std.testing.expect(!service.isEnabled("example.extension"));
    try std.testing.expectEqual(EnablementState.DisabledGlobally, service.getEnablementState("EXAMPLE.extension"));
}

test "test disable an extension globally again returns false and keeps the value" {
    const allocator = std.testing.allocator;
    var store = TestStore.init(allocator);
    defer store.deinit();
    var service = try service_type.init(allocator, store.store());
    defer service.deinit();

    try std.testing.expect(try service.setEnablement("example.extension", .DisabledGlobally));
    try std.testing.expect(!try service.setEnablement("example.extension", .DisabledGlobally));
    try std.testing.expectEqualStrings("[{\"id\":\"example.extension\"}]", store.value.?);
}

test "test the profile value shape matches upstream" {
    const allocator = std.testing.allocator;
    var store = TestStore.init(allocator);
    defer store.deinit();
    var service = try service_type.init(allocator, store.store());
    defer service.deinit();

    try std.testing.expect(try service.setEnablement("Example.Extension", .DisabledGlobally));
    try std.testing.expectEqualStrings("[{\"id\":\"Example.Extension\"}]", store.value.?);
    try std.testing.expect(try service.setEnablement("example.extension", .EnabledGlobally));
    try std.testing.expectEqualStrings("[]", store.value.?);
}

test "test enable an extension globally" {
    const allocator = std.testing.allocator;
    var store = TestStore.init(allocator);
    defer store.deinit();
    var service = try service_type.init(allocator, store.store());
    defer service.deinit();

    try std.testing.expect(!try service.setEnablement("example.extension", .EnabledGlobally));
    try std.testing.expect(try service.setEnablement("example.extension", .DisabledGlobally));
    try std.testing.expect(try service.setEnablement("example.extension", .EnabledGlobally));
    try std.testing.expect(service.isEnabled("example.extension"));
    try std.testing.expect(!try service.setEnablement("example.extension", .EnabledGlobally));
}

test "test state of disabled extensions is restored from the store" {
    const allocator = std.testing.allocator;
    var store = TestStore.init(allocator);
    defer store.deinit();
    store.value = try allocator.dupe(u8, "[{\"id\":\"example.extension\",\"uuid\":\"ignored\"}]");

    var service = try service_type.init(allocator, store.store());
    defer service.deinit();
    try std.testing.expect(!service.isEnabled("Example.Extension"));
    try std.testing.expectEqual(EnablementState.DisabledGlobally, service.getEnablementState("example.extension"));

    const disabled = try service.getDisabledExtensions(allocator);
    defer allocator.free(disabled);
    try std.testing.expectEqual(@as(usize, 1), disabled.len);
    try std.testing.expectEqualStrings("example.extension", disabled[0]);
}

test "test a corrupt stored value loads as nothing disabled" {
    const allocator = std.testing.allocator;
    var store = TestStore.init(allocator);
    defer store.deinit();
    store.value = try allocator.dupe(u8, "not json");

    var service = try service_type.init(allocator, store.store());
    defer service.deinit();
    try std.testing.expect(service.isEnabled("example.extension"));
}

test "test disable an extension globally triggers the change event" {
    const allocator = std.testing.allocator;
    var store = TestStore.init(allocator);
    defer store.deinit();
    var service = try service_type.init(allocator, store.store());
    defer service.deinit();

    const Observer = struct {
        count: usize = 0,
        fn run(identifier: []const u8, self: *@This()) !void {
            self.count += 1;
            try std.testing.expectEqualStrings("example.extension", identifier);
        }
    };
    var observer = Observer{};
    _ = try service.on_did_change.listen(&observer, Observer.run);
    try std.testing.expect(try service.setEnablement("example.extension", .DisabledGlobally));
    try std.testing.expectEqual(@as(usize, 1), observer.count);
    try std.testing.expect(!try service.setEnablement("example.extension", .DisabledGlobally));
    try std.testing.expectEqual(@as(usize, 1), observer.count);
}

test "test unsupported workspace enablement is rejected" {
    const allocator = std.testing.allocator;
    var service = try service_type.init(allocator, null);
    defer service.deinit();
    try std.testing.expectError(error.UnsupportedEnablementState, service.setEnablement("example.extension", .DisabledWorkspace));
    try std.testing.expectError(error.UnsupportedEnablementState, service.setEnablement("example.extension", .EnabledWorkspace));
}
