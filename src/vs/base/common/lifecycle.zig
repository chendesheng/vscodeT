// Port of the disposable parts of `src/vs/base/common/lifecycle.ts`.
//
// Zig has no deterministic finalizers, so every disposable is an explicit
// struct holding a function pointer plus its context. Ownership of the context
// is not implied: the disposable only runs the callback.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// An object that can be disposed, i.e. release resources it holds.
pub const IDisposable = struct {
    context: ?*anyopaque = null,
    disposeFn: ?*const fn (context: *anyopaque) void = null,

    /// A disposable that does nothing.
    pub const none: IDisposable = .{};

    pub fn dispose(self: IDisposable) void {
        if (self.disposeFn) |function| {
            if (self.context) |context| {
                function(context);
            }
        }
    }

    pub fn isNone(self: IDisposable) bool {
        return self.disposeFn == null;
    }

    /// Builds a disposable that invokes `callback` with `context`.
    pub fn from(comptime T: type, context: *T, comptime callback: fn (context: *T) void) IDisposable {
        return .{
            .context = @ptrCast(context),
            .disposeFn = struct {
                fn dispose(any_context: *anyopaque) void {
                    const typed: *T = @ptrCast(@alignCast(any_context));
                    callback(typed);
                }
            }.dispose,
        };
    }

    /// Builds a disposable that invokes an optional-parameter callback with no
    /// context (i.e. a plain function pointer).
    pub fn fromFunction(comptime callback: fn () void) IDisposable {
        return .{
            .context = @ptrFromInt(@alignOf(usize)),
            .disposeFn = struct {
                fn dispose(_: *anyopaque) void {
                    callback();
                }
            }.dispose,
        };
    }
};

/// A disposable that owns a heap allocation and frees it on dispose.
pub fn toDisposable(allocator: Allocator, comptime T: type, value: *T) IDisposable {
    _ = allocator;
    return .{
        .context = @ptrCast(value),
        .disposeFn = struct {
            fn dispose(context: *anyopaque) void {
                const typed: *T = @ptrCast(@alignCast(context));
                typed.deinit();
            }
        }.dispose,
    };
}

/// A collection of disposables that are disposed together. After `dispose`,
/// any disposable added to the store is disposed immediately.
pub const DisposableStore = struct {
    allocator: Allocator,
    disposables: std.array_list.Managed(IDisposable),
    isDisposed: bool = false,

    pub fn init(allocator: Allocator) DisposableStore {
        return .{
            .allocator = allocator,
            .disposables = std.array_list.Managed(IDisposable).init(allocator),
        };
    }

    /// Disposes all registered disposables and frees the backing storage.
    pub fn deinit(self: *DisposableStore) void {
        self.dispose();
        self.disposables.deinit();
    }

    pub fn add(self: *DisposableStore, disposable: IDisposable) void {
        if (disposable.isNone()) {
            return;
        }
        if (self.isDisposed) {
            disposable.dispose();
            return;
        }
        self.disposables.append(disposable) catch |err| {
            // There is no way to surface the allocation failure; make sure the
            // resource is still released.
            disposable.dispose();
            std.debug.assert(err == error.OutOfMemory);
        };
    }

    pub fn size(self: *const DisposableStore) usize {
        return self.disposables.items.len;
    }

    /// Disposes all registered disposables in the reverse order of addition.
    pub fn dispose(self: *DisposableStore) void {
        if (self.isDisposed) {
            return;
        }
        self.isDisposed = true;
        var index = self.disposables.items.len;
        while (index > 0) {
            index -= 1;
            self.disposables.items[index].dispose();
        }
        self.disposables.clearRetainingCapacity();
    }

    /// Disposes everything without marking the store as disposed.
    pub fn clear(self: *DisposableStore) void {
        var index = self.disposables.items.len;
        while (index > 0) {
            index -= 1;
            self.disposables.items[index].dispose();
        }
        self.disposables.clearRetainingCapacity();
    }
};

/// A disposable that wraps a single callback, allocated on the heap so that it
/// can be handed to consumers that only keep the `IDisposable`.
pub fn disposableCallback(allocator: Allocator, callback: *const fn () void) !IDisposable {
    const holder = try allocator.create(CallbackHolder);
    holder.* = .{ .allocator = allocator, .callback = callback };
    return .{
        .context = @ptrCast(holder),
        .disposeFn = struct {
            fn dispose(context: *anyopaque) void {
                const typed: *CallbackHolder = @ptrCast(@alignCast(context));
                typed.callback();
                typed.allocator.destroy(typed);
            }
        }.dispose,
    };
}

const CallbackHolder = struct {
    allocator: Allocator,
    callback: *const fn () void,
};

test "DisposableStore disposes in reverse order" {
    const Order = struct {
        var calls: [4]u8 = undefined;
        var count: usize = 0;
    };
    Order.count = 0;

    var store = DisposableStore.init(std.testing.allocator);
    defer store.deinit();

    const callbacks = [_]*const fn () void{
        struct {
            fn call() void {
                Order.calls[Order.count] = 'a';
                Order.count += 1;
            }
        }.call,
        struct {
            fn call() void {
                Order.calls[Order.count] = 'b';
                Order.count += 1;
            }
        }.call,
    };

    for (callbacks) |callback| {
        store.add(try disposableCallback(std.testing.allocator, callback));
    }
    store.dispose();
    try std.testing.expectEqual(@as(usize, 2), Order.count);
    try std.testing.expectEqual(@as(u8, 'b'), Order.calls[0]);
    try std.testing.expectEqual(@as(u8, 'a'), Order.calls[1]);
}

test "DisposableStore disposes immediately when already disposed" {
    const State = struct {
        var disposed: bool = false;
    };
    State.disposed = false;

    var store = DisposableStore.init(std.testing.allocator);
    defer store.deinit();
    store.dispose();

    var value: u8 = 0;
    store.add(.{
        .context = &value,
        .disposeFn = struct {
            fn dispose(_: *anyopaque) void {
                State.disposed = true;
            }
        }.dispose,
    });
    try std.testing.expect(State.disposed);
}
