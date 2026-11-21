// Terminal key-input contribution point for built-in extensions.
//
// Upstream VS Code has no raw key hook for extensions: keybindings dispatch
// command ids and printable text arrives through the `type` command. The
// terminal already owns a single decoded key stream, so a built-in extension
// can register one handler and receive that stream in order. This is a
// deliberate addition, not an upstream port.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const ui = @import("ui");
const lifecycle = @import("../../../base/common/lifecycle.zig");

pub const IDisposable = lifecycle.IDisposable;

/// The decoded terminal key. `text` runs and paste boundaries stay in the
/// event so an extension can preserve IME/paste behavior.
pub const KeyInputEvent = ui.KeyEvent;

/// Larger priorities run first. A built-in extension is above editor commands
/// but below an explicitly exclusive handler.
pub const KeyInputPriority = enum(i64) {
    editor = 0,
    builtin_extension = 300,
    exclusive = 1000,
};

pub const Handler = struct {
    context: *anyopaque,
    priority: KeyInputPriority = .builtin_extension,
    /// Optional cheap gate; when false the handler is skipped. This keeps
    /// modal editors from inspecting every key while another surface has
    /// focus.
    is_enabled: ?*const fn (context: *anyopaque) bool = null,
    /// Returns true when the event was consumed. Returning false passes the
    /// key to the next handler and then to the workbench.
    handle: *const fn (context: *anyopaque, event: *const KeyInputEvent) anyerror!bool,
    /// Called when an external action (pointer selection, tab switch) makes
    /// pending modal state stale. Optional.
    reset: ?*const fn (context: *anyopaque) void = null,
};

const Entry = struct {
    id: u64,
    handler: Handler,
    active: bool = true,
};

pub const DispatchErrorCallback = struct {
    context: *anyopaque,
    report: *const fn (context: *anyopaque, err: anyerror) void,
};

pub const KeyInputRegistry = struct {
    allocator: Allocator,
    entries: ArrayList(Entry),
    next_id: u64 = 1,
    error_callback: ?DispatchErrorCallback = null,

    pub fn init(allocator: Allocator) KeyInputRegistry {
        return .{
            .allocator = allocator,
            .entries = ArrayList(Entry).init(allocator),
        };
    }

    pub fn deinit(self: *KeyInputRegistry) void {
        self.entries.deinit();
    }

    pub fn setErrorCallback(self: *KeyInputRegistry, callback: ?DispatchErrorCallback) void {
        self.error_callback = callback;
    }

    pub fn register(self: *KeyInputRegistry, handler: Handler) !IDisposable {
        const id = self.next_id;
        self.next_id += 1;
        try self.entries.append(.{ .id = id, .handler = handler });
        std.mem.sort(Entry, self.entries.items, {}, entryLessThan);
        const holder = try self.allocator.create(Registration);
        holder.* = .{ .registry = self, .id = id };
        return .{ .context = holder, .disposeFn = Registration.disposeFn };
    }

    /// Dispatches to the highest-priority active handler. Handler failures are
    /// reported and treated as not consumed; one broken extension must not
    /// take down the input loop.
    pub fn dispatch(self: *KeyInputRegistry, event: *const KeyInputEvent) bool {
        for (self.entries.items) |*entry| {
            if (!entry.active) continue;
            if (entry.handler.is_enabled) |enabled| {
                if (!enabled(entry.handler.context)) continue;
            }
            const consumed = entry.handler.handle(entry.handler.context, event) catch |err| {
                if (self.error_callback) |callback| callback.report(callback.context, err);
                continue;
            };
            if (consumed) return true;
        }
        return false;
    }

    /// Clears transient state in every active handler. Used for pointer
    /// selections and tab switches that bypass the key stream.
    pub fn reset(self: *KeyInputRegistry) void {
        for (self.entries.items) |*entry| {
            if (!entry.active) continue;
            if (entry.handler.reset) |reset_fn| reset_fn(entry.handler.context);
        }
    }

    fn unregister(self: *KeyInputRegistry, id: u64) void {
        for (self.entries.items) |*entry| {
            if (entry.id == id) {
                entry.active = false;
                return;
            }
        }
    }
};

const Registration = struct {
    registry: *KeyInputRegistry,
    id: u64,

    fn disposeFn(context: *anyopaque) void {
        const self: *Registration = @ptrCast(@alignCast(context));
        self.registry.unregister(self.id);
        self.registry.allocator.destroy(self);
    }
};

fn entryLessThan(_: void, a: Entry, b: Entry) bool {
    return @backingInt(a.handler.priority) > @backingInt(b.handler.priority);
}

test "KeyInputRegistry: priority, pass-through and disposal" {
    const allocator = std.testing.allocator;
    var registry = KeyInputRegistry.init(allocator);
    defer registry.deinit();

    const State = struct {
        log: [8]u8 = undefined,
        len: usize = 0,
        consume: bool = false,

        fn enabled(_: *anyopaque) bool {
            return true;
        }

        fn handle(context: *anyopaque, _: *const KeyInputEvent) anyerror!bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.log[self.len] = 'a';
            self.len += 1;
            return self.consume;
        }
    };
    var low = State{};
    var high = State{ .consume = true };
    const low_registration = try registry.register(.{
        .context = &low,
        .priority = .editor,
        .is_enabled = State.enabled,
        .handle = State.handle,
    });
    const high_registration = try registry.register(.{
        .context = &high,
        .priority = .builtin_extension,
        .is_enabled = State.enabled,
        .handle = State.handle,
    });

    const event = KeyInputEvent{ .key = .{ .char = 'x' } };
    try std.testing.expect(registry.dispatch(&event));
    try std.testing.expectEqual(@as(usize, 0), low.len);
    try std.testing.expectEqual(@as(usize, 1), high.len);

    high_registration.dispose();
    try std.testing.expect(!registry.dispatch(&event));
    try std.testing.expectEqual(@as(usize, 1), low.len);

    low_registration.dispose();
    try std.testing.expect(!registry.dispatch(&event));
}

test "KeyInputRegistry: disabled handler passes through" {
    const allocator = std.testing.allocator;
    var registry = KeyInputRegistry.init(allocator);
    defer registry.deinit();

    const State = struct {
        enabled_value: bool = false,
        calls: usize = 0,

        fn enabled(context: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.enabled_value;
        }

        fn handle(context: *anyopaque, _: *const KeyInputEvent) anyerror!bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            return true;
        }
    };
    var state = State{};
    const registration = try registry.register(.{
        .context = &state,
        .is_enabled = State.enabled,
        .handle = State.handle,
    });
    defer registration.dispose();

    const event = KeyInputEvent{ .key = .escape };
    try std.testing.expect(!registry.dispatch(&event));
    try std.testing.expectEqual(@as(usize, 0), state.calls);
    state.enabled_value = true;
    try std.testing.expect(registry.dispatch(&event));
    try std.testing.expectEqual(@as(usize, 1), state.calls);
}
