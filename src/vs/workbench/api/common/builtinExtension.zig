// Registry and lifecycle for compiled-in extensions.
//
// A built-in extension is an `IBuiltinExtension` value registered at the
// product composition root. The registry owns activation and the per-extension
// disposable store; the workbench core only sees this generic contract.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const lifecycle = @import("../../../base/common/lifecycle.zig");
const extension_api = @import("./extensionApi.zig");

pub const IBuiltinExtension = extension_api.IBuiltinExtension;
pub const IExtensionContext = extension_api.IExtensionContext;

pub const ActivationErrorCallback = struct {
    context: *anyopaque,
    report: *const fn (context: *anyopaque, id: []const u8, err: anyerror) void,
};

const Entry = struct {
    extension: IBuiltinExtension,
    store: lifecycle.DisposableStore,
    activated: bool = false,
};

pub const BuiltinExtensionRegistry = struct {
    allocator: Allocator,
    entries: ArrayList(Entry),
    error_callback: ?ActivationErrorCallback = null,

    pub fn init(allocator: Allocator) BuiltinExtensionRegistry {
        return .{
            .allocator = allocator,
            .entries = ArrayList(Entry).init(allocator),
        };
    }

    pub fn deinit(self: *BuiltinExtensionRegistry) void {
        self.deactivateAll();
        for (self.entries.items) |*entry| entry.store.deinit();
        self.entries.deinit();
    }

    pub fn setErrorCallback(self: *BuiltinExtensionRegistry, callback: ?ActivationErrorCallback) void {
        self.error_callback = callback;
    }

    pub fn register(self: *BuiltinExtensionRegistry, extension: IBuiltinExtension) !void {
        for (self.entries.items) |existing| {
            if (std.mem.eql(u8, existing.extension.id, extension.id)) return error.DuplicateBuiltinExtension;
        }
        try self.entries.append(.{
            .extension = extension,
            .store = lifecycle.DisposableStore.init(self.allocator),
        });
    }

    /// Activates every registered extension. `base` supplies the shared
    /// service interfaces; each extension gets its own disposable store, so
    /// deactivating one cannot remove another's registrations.
    pub fn activateAll(self: *BuiltinExtensionRegistry, base: IExtensionContext) void {
        for (self.entries.items) |*entry| {
            if (entry.activated) continue;
            var context = base;
            context.disposables = &entry.store;
            entry.extension.activate(&context) catch |err| {
                // Activation may have allocated extension-owned state before
                // failing; deactivate runs before the store is disposed so the
                // extension can release it.
                entry.extension.deactivate();
                entry.store.dispose();
                if (self.error_callback) |callback| callback.report(callback.context, entry.extension.id, err);
                continue;
            };
            entry.activated = true;
        }
    }

    pub fn deactivateAll(self: *BuiltinExtensionRegistry) void {
        var index = self.entries.items.len;
        while (index > 0) {
            index -= 1;
            const entry = &self.entries.items[index];
            if (!entry.activated) continue;
            entry.extension.deactivate();
            entry.store.dispose();
            entry.activated = false;
        }
    }

    pub fn get(self: *const BuiltinExtensionRegistry, id: []const u8) ?IBuiltinExtension {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.extension.id, id)) return entry.extension;
        }
        return null;
    }
};

test "BuiltinExtensionRegistry: activation is isolated and disposable" {
    const allocator = std.testing.allocator;
    var registry = BuiltinExtensionRegistry.init(allocator);
    defer registry.deinit();

    const State = struct {
        active: bool = false,
        registered: *std.array_list.Managed(u32),

        fn activate(context: *anyopaque, api: *const IExtensionContext) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.active = true;
            const command = struct {
                fn run(_: *anyopaque) anyerror!void {}
            };
            api.disposables.add(try api.commands.register("test.builtin", "Test", .{
                .context = self,
                .run = command.run,
            }));
            api.disposables.add(try api.key_input.register(.{
                .context = self,
                .handle = keyHandler,
            }));
            try self.registered.append(1);
        }

        fn keyHandler(_: *anyopaque, _: *const extension_api.KeyInputEvent) anyerror!bool {
            return false;
        }

        fn deactivate(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.active = false;
        }
    };

    var calls = ArrayList(u32).init(allocator);
    defer calls.deinit();
    var state = State{ .registered = &calls };
    try registry.register(.{
        .context = &state,
        .id = "test.builtin",
        .display_name = "Test",
        .version = "1.0.0",
        .activate_fn = State.activate,
        .deactivate_fn = State.deactivate,
    });

    // A context without real services is enough for this lifecycle test; the
    // fake command/key-input services just need stable function pointers.
    var key_registry = @import("./keyInput.zig").KeyInputRegistry.init(allocator);
    defer key_registry.deinit();
    var commands = @import("../../../platform/commands/common/commands.zig").CommandRegistry.init(allocator);
    defer commands.deinit();

    const key_service = struct {
        fn register(context: *anyopaque, handler: extension_api.KeyInputHandler) anyerror!extension_api.IDisposable {
            const registry_ptr: *@import("./keyInput.zig").KeyInputRegistry = @ptrCast(@alignCast(context));
            return registry_ptr.register(handler);
        }
    };
    const command_service = struct {
        fn register(_: *anyopaque, _: []const u8, _: []const u8, _: extension_api.CommandHandler) anyerror!extension_api.IDisposable {
            return extension_api.IDisposable.none;
        }
        fn execute(_: *anyopaque, _: []const u8) anyerror!bool {
            return false;
        }
    };
    const no_editor = struct {
        fn active(_: *anyopaque) ?extension_api.ITextEditor {
            return null;
        }
        fn listen(_: *anyopaque, _: extension_api.EditorChangeListener) anyerror!extension_api.IDisposable {
            return extension_api.IDisposable.none;
        }
    };
    const no_window = struct {
        fn create(_: *anyopaque, _: []const u8, _: []const u8) anyerror!extension_api.IStatusEntry {
            return error.Unsupported;
        }
        fn message(_: *anyopaque, _: []const u8) void {}
        fn forceClose(_: *anyopaque) anyerror!void {}
        fn openPath(_: *anyopaque, _: []const u8) anyerror!void {}
        fn switchTab(_: *anyopaque, _: isize) anyerror!void {}
    };
    const no_workspace = struct {
        fn getBool(_: *anyopaque, _: []const u8, default: bool) bool {
            return default;
        }
        fn getString(_: *anyopaque, _: []const u8) ?[]const u8 {
            return null;
        }
    };

    const base = IExtensionContext{
        .allocator = allocator,
        .disposables = undefined,
        .commands = .{ .context = &commands, .register_fn = command_service.register, .execute_fn = command_service.execute },
        .key_input = .{ .context = &key_registry, .register_fn = key_service.register },
        .editors = .{ .context = undefined, .active_text_editor_fn = no_editor.active, .on_did_change_active_editor_fn = no_editor.listen },
        .window = .{
            .context = undefined,
            .create_status_entry_fn = no_window.create,
            .set_message_fn = no_window.message,
            .force_close_active_fn = no_window.forceClose,
            .open_path_fn = no_window.openPath,
            .switch_tab_fn = no_window.switchTab,
        },
        .workspace = .{ .context = undefined, .get_bool_fn = no_workspace.getBool, .get_string_fn = no_workspace.getString },
    };

    registry.activateAll(base);
    try std.testing.expect(state.active);
    try std.testing.expectEqual(@as(usize, 1), calls.items.len);

    registry.deactivateAll();
    try std.testing.expect(!state.active);
}
