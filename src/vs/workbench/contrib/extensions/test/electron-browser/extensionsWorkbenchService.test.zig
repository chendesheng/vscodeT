// Port of the local-extension subset of
// `src/vs/workbench/contrib/extensions/test/electron-browser/extensionsWorkbenchService.test.ts`.
//
// Terminal adaptation: the service scans local directories instead of a
// gallery/extension-management server. Installed inventory, enablement state,
// change events, persistence through an injected Store and refresh are
// covered; gallery install/update, extension packs, recommendations and
// running-extension state are not ported.
const std = @import("std");
const service_mod = @import("../../browser/extensionsWorkbenchService.zig");
const enablement_mod = @import("../../../../services/extensionManagement/browser/extensionEnablementService.zig");
const ExtensionsWorkbenchService = service_mod.ExtensionsWorkbenchService;
const ExtensionEnablementService = enablement_mod.ExtensionEnablementService;
const Store = enablement_mod.Store;

const io = std.Io.Threaded.global_single_threaded.io();
const testing = std.testing;

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

const Fixture = struct {
    tmp: std.testing.TmpDir,
    system: []u8,
    user: []u8,
    root: []u8,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io, "system");
        try tmp.dir.createDirPath(io, "user");
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const length = try tmp.dir.realPath(io, &path_buffer);
        const root = try allocator.dupe(u8, path_buffer[0..length]);
        errdefer allocator.free(root);
        return .{
            .tmp = tmp,
            .system = try std.fs.path.join(allocator, &.{ root, "system" }),
            .user = try std.fs.path.join(allocator, &.{ root, "user" }),
            .root = root,
            .allocator = allocator,
        };
    }

    fn deinit(self: *Fixture) void {
        self.allocator.free(self.system);
        self.allocator.free(self.user);
        self.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn write(self: *Fixture, builtin: bool, folder: []const u8, manifest: []const u8) !void {
        var dir_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const dir = try std.fmt.bufPrint(&dir_buffer, "{s}/{s}", .{ if (builtin) "system" else "user", folder });
        try self.tmp.dir.createDirPath(io, dir);
        var file_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const file = try std.fmt.bufPrint(&file_buffer, "{s}/package.json", .{dir});
        try self.tmp.dir.writeFile(io, .{ .sub_path = file, .data = manifest });
    }
};

test "test for empty installed extensions" {
    const allocator = testing.allocator;
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();
    var enablement = try ExtensionEnablementService.init(allocator, null);
    defer enablement.deinit();
    var service = try ExtensionsWorkbenchService.init(allocator, io, .{
        .system_location = fixture.system,
        .user_location = fixture.user,
        .enablement = enablement,
    });
    defer service.deinit();

    try testing.expectEqual(@as(usize, 0), service.queryLocal().len);
    try testing.expectEqual(@as(usize, 0), service.enabledDescriptions().len);
}

test "test for installed extensions" {
    const allocator = testing.allocator;
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();
    try fixture.write(true, "pub.system-extension-1.0.0",
        \\{"name":"system-extension","publisher":"pub","version":"1.0.0","engines":{"vscode":"*"},"displayName":"System Extension"}
    );
    try fixture.write(false, "pub.user-extension-1.0.0",
        \\{"name":"user-extension","publisher":"pub","version":"1.0.0","engines":{"vscode":"*"},"displayName":"User Extension"}
    );

    var enablement = try ExtensionEnablementService.init(allocator, null);
    defer enablement.deinit();
    var service = try ExtensionsWorkbenchService.init(allocator, io, .{
        .system_location = fixture.system,
        .user_location = fixture.user,
        .enablement = enablement,
    });
    defer service.deinit();

    try testing.expectEqual(@as(usize, 2), service.queryLocal().len);
    try testing.expectEqual(@as(usize, 2), service.enabledDescriptions().len);
    try testing.expectEqual(@as(usize, 1), service.systemExtensions().len);
    try testing.expectEqual(@as(usize, 1), service.userExtensions().len);

    const builtin = service.find("pub.system-extension").?;
    try testing.expect(builtin.is_builtin);
    try testing.expectEqualStrings("System Extension", builtin.display_name);
    try testing.expect(builtin.isEnabled());

    const user = service.find("pub.user-extension").?;
    try testing.expect(!user.is_builtin);
    try testing.expectEqualStrings("User Extension", user.display_name);
}

test "test system extensions can be disabled" {
    const allocator = testing.allocator;
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();
    try fixture.write(true, "pub.system-extension-1.0.0",
        \\{"name":"system-extension","publisher":"pub","version":"1.0.0","engines":{"vscode":"*"}}
    );
    try fixture.write(false, "pub.user-extension-1.0.0",
        \\{"name":"user-extension","publisher":"pub","version":"1.0.0","engines":{"vscode":"*"}}
    );

    const Observer = struct {
        count: usize = 0,
        fn run(self: *@This()) !void {
            self.count += 1;
        }
    };
    var observer = Observer{};
    var enablement = try ExtensionEnablementService.init(allocator, null);
    defer enablement.deinit();
    var service = try ExtensionsWorkbenchService.init(allocator, io, .{
        .system_location = fixture.system,
        .user_location = fixture.user,
        .enablement = enablement,
    });
    defer service.deinit();
    _ = try service.on_change.listenSignal(&observer, Observer.run);

    try testing.expect(try service.setEnablement("pub.system-extension", .DisabledGlobally));
    try testing.expectEqual(@as(usize, 1), observer.count);
    try testing.expect(!service.find("pub.system-extension").?.isEnabled());
    try testing.expectEqual(@as(usize, 1), service.enabledDescriptions().len);
    try testing.expectEqualStrings("pub.user-extension", service.enabledDescriptions()[0].identifier);
    // The system scan still owns executable built-in bundle resolution.
    try testing.expectEqual(@as(usize, 1), service.systemExtensions().len);

    try testing.expect(try service.setEnablement("pub.system-extension", .EnabledGlobally));
    try testing.expect(service.find("pub.system-extension").?.isEnabled());
    try testing.expectEqual(@as(usize, 2), service.enabledDescriptions().len);
}

test "test enablement state is persisted and restored from the store" {
    const allocator = testing.allocator;
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();
    try fixture.write(true, "pub.system-extension-1.0.0",
        \\{"name":"system-extension","publisher":"pub","version":"1.0.0","engines":{"vscode":"*"}}
    );

    var store = TestStore.init(allocator);
    defer store.deinit();
    var enablement = try ExtensionEnablementService.init(allocator, store.store());
    defer enablement.deinit();
    var service = try ExtensionsWorkbenchService.init(allocator, io, .{
        .system_location = fixture.system,
        .user_location = fixture.user,
        .enablement = enablement,
    });
    defer service.deinit();
    try testing.expect(try service.setEnablement("pub.system-extension", .DisabledGlobally));
    try testing.expectEqualStrings("[{\"id\":\"pub.system-extension\"}]", store.value.?);

    // A second service created from the same profile state sees the disabled
    // extension and excludes it from the declarative scan input.
    var restored_enablement = try ExtensionEnablementService.init(allocator, store.store());
    defer restored_enablement.deinit();
    var restored = try ExtensionsWorkbenchService.init(allocator, io, .{
        .system_location = fixture.system,
        .user_location = fixture.user,
        .enablement = restored_enablement,
    });
    defer restored.deinit();
    try testing.expect(!restored.find("pub.system-extension").?.isEnabled());
    try testing.expectEqual(@as(usize, 0), restored.enabledDescriptions().len);
}

test "test refresh picks up a newly installed user extension" {
    const allocator = testing.allocator;
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();
    try fixture.write(true, "pub.system-extension-1.0.0",
        \\{"name":"system-extension","publisher":"pub","version":"1.0.0","engines":{"vscode":"*"}}
    );
    var enablement = try ExtensionEnablementService.init(allocator, null);
    defer enablement.deinit();
    var service = try ExtensionsWorkbenchService.init(allocator, io, .{
        .system_location = fixture.system,
        .user_location = fixture.user,
        .enablement = enablement,
    });
    defer service.deinit();
    try testing.expectEqual(@as(usize, 1), service.queryLocal().len);

    try fixture.write(false, "pub.user-extension-1.0.0",
        \\{"name":"user-extension","publisher":"pub","version":"1.0.0","engines":{"vscode":"*"}}
    );
    try service.refresh();
    try testing.expectEqual(@as(usize, 2), service.queryLocal().len);
    try testing.expect(service.find("pub.user-extension") != null);
}
