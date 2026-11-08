// Port of `src/vs/base/common/cancellation.ts`.
//
// Differences from the TypeScript implementation:
//  * `AbortSignal` integration (`fromAbortSignal`, `toAbortSignal`) is omitted.
//  * Listeners registered on an already cancelled token are invoked
//    synchronously instead of on the next tick of the event loop.
const std = @import("std");
const Allocator = std.mem.Allocator;
const errors = @import("errors.zig");
const lifecycle = @import("lifecycle.zig");

pub const CancellationError = errors.CancellationError;
pub const IDisposable = lifecycle.IDisposable;
pub const DisposableStore = lifecycle.DisposableStore;

/// A listener that is invoked when cancellation is requested.
pub const CancellationListener = struct {
    context: *anyopaque,
    callbackFn: *const fn (context: *anyopaque) void,

    pub fn call(self: CancellationListener) void {
        self.callbackFn(self.context);
    }

    pub fn from(comptime T: type, context: *T, comptime callback: fn (context: *T) void) CancellationListener {
        return .{
            .context = @ptrCast(context),
            .callbackFn = struct {
                fn invoke(any_context: *anyopaque) void {
                    const typed: *T = @ptrCast(@alignCast(any_context));
                    callback(typed);
                }
            }.invoke,
        };
    }
};

const Registration = struct {
    token: *MutableToken,
    /// Index into `MutableToken.registrations`, kept up to date when entries
    /// are removed.
    id: usize,
    /// Index into `MutableToken.listeners`, or `null` once the listener has
    /// fired or was removed.
    slotIndex: ?usize,
};

/// The mutable part of a `CancellationToken`; owned by a
/// `CancellationTokenSource`.
pub const MutableToken = struct {
    allocator: Allocator,
    isCancelled: bool = false,
    listeners: std.array_list.Managed(?CancellationListener),
    /// Registrations that have not been disposed yet. They are freed either
    /// when the caller disposes the listener handle or when the token dies.
    registrations: std.array_list.Managed(*Registration),

    pub fn init(allocator: Allocator) MutableToken {
        return .{
            .allocator = allocator,
            .listeners = std.array_list.Managed(?CancellationListener).init(allocator),
            .registrations = std.array_list.Managed(*Registration).init(allocator),
        };
    }

    pub fn deinit(self: *MutableToken) void {
        for (self.registrations.items) |registration| {
            self.allocator.destroy(registration);
        }
        self.registrations.deinit();
        self.listeners.deinit();
    }

    pub fn cancel(self: *MutableToken) void {
        if (self.isCancelled) {
            return;
        }
        self.isCancelled = true;

        var index: usize = 0;
        while (index < self.listeners.items.len) : (index += 1) {
            const maybe_listener = self.listeners.items[index];
            if (maybe_listener) |listener| {
                // Clear the slot before invoking so that the listener may
                // unregister itself without firing twice.
                self.listeners.items[index] = null;
                listener.call();
            }
        }
        self.listeners.clearRetainingCapacity();

        // Listener handles are dead now, but the caller may still dispose them.
        for (self.registrations.items) |registration| {
            registration.slotIndex = null;
        }
    }

    /// Forgets all listeners without cancelling the token.
    pub fn clearListeners(self: *MutableToken) void {
        for (self.listeners.items) |*maybe_listener| {
            maybe_listener.* = null;
        }
        self.listeners.clearRetainingCapacity();
        for (self.registrations.items) |registration| {
            registration.slotIndex = null;
        }
    }

    pub fn token(self: *MutableToken) CancellationToken {
        return .{ .state = self };
    }

    /// Registers a listener. The returned disposable removes the listener; it
    /// must be either disposed or kept alive until the token is deinitialized.
    pub fn onCancellationRequested(self: *MutableToken, listener: CancellationListener) !IDisposable {
        if (self.isCancelled) {
            listener.call();
            return IDisposable.none;
        }

        const registration = try self.allocator.create(Registration);
        errdefer self.allocator.destroy(registration);
        try self.registrations.append(registration);
        errdefer _ = self.registrations.pop();

        try self.listeners.append(listener);
        registration.* = .{
            .token = self,
            .id = self.registrations.items.len - 1,
            .slotIndex = self.listeners.items.len - 1,
        };

        return .{
            .context = @ptrCast(registration),
            .disposeFn = struct {
                fn dispose(context: *anyopaque) void {
                    const reg: *Registration = @ptrCast(@alignCast(context));
                    reg.token.removeRegistration(reg);
                }
            }.dispose,
        };
    }

    fn removeRegistration(self: *MutableToken, registration: *Registration) void {
        if (registration.slotIndex) |slot_index| {
            self.listeners.items[slot_index] = null;
        }

        const removed_index = registration.id;
        _ = self.registrations.swapRemove(removed_index);
        if (removed_index < self.registrations.items.len) {
            // Fix up the index of the registration that was swapped in.
            self.registrations.items[removed_index].id = removed_index;
        }
        self.allocator.destroy(registration);
    }
};

/// A token that can be used to check whether an operation has been cancelled.
pub const CancellationToken = struct {
    /// Non-null once the token is backed by a `CancellationTokenSource`.
    state: ?*MutableToken = null,
    /// Set for the `Cancelled` constant, which is cancelled from the start.
    alreadyCancelled: bool = false,

    /// A token that is never cancelled.
    pub const None: CancellationToken = .{};

    /// A token that is already cancelled.
    pub const Cancelled: CancellationToken = .{ .alreadyCancelled = true };

    pub fn isCancellationRequested(self: CancellationToken) bool {
        if (self.alreadyCancelled) {
            return true;
        }
        if (self.state) |mutable| {
            return mutable.isCancelled;
        }
        return false;
    }

    /// An event that fires when cancellation is requested. Fires immediately
    /// (and exactly once) when the token is already cancelled.
    pub fn onCancellationRequested(self: CancellationToken, listener: CancellationListener) !IDisposable {
        if (self.alreadyCancelled) {
            listener.call();
            return IDisposable.none;
        }
        const mutable = self.state orelse return IDisposable.none;
        return mutable.onCancellationRequested(listener);
    }

    pub fn throwIfCancellationRequested(self: CancellationToken) CancellationError!void {
        if (self.isCancellationRequested()) {
            return error.CancellationError;
        }
    }
};

const TokenState = union(enum) {
    /// No token has been requested yet.
    none: void,
    /// A lazily created mutable token.
    mutable: *MutableToken,
    /// Cancelled before anyone asked for the token.
    cancelled: void,
    /// Disposed without cancelling.
    disposed: void,
};

const SourceImpl = struct {
    allocator: Allocator,
    state: TokenState = .none,
    parentListener: IDisposable = .{},
    /// Token that was still referenced by a caller when the source got
    /// disposed. It is freed together with the source so that the token stays
    /// valid (reporting "not cancelled") until then.
    retainedToken: ?*MutableToken = null,
};

/// A source for a `CancellationToken` that controls the cancellation state.
pub const CancellationTokenSource = struct {
    impl: *SourceImpl,

    /// Creates a source that can be cancelled explicitly.
    pub fn init(allocator: Allocator) !CancellationTokenSource {
        const impl = try allocator.create(SourceImpl);
        impl.* = .{ .allocator = allocator };
        return .{ .impl = impl };
    }

    /// Creates a source whose token is cancelled when `parent` is cancelled.
    pub fn initChild(allocator: Allocator, parent: CancellationToken) !CancellationTokenSource {
        const impl = try allocator.create(SourceImpl);
        impl.* = .{ .allocator = allocator };
        errdefer allocator.destroy(impl);

        if (parent.isCancellationRequested()) {
            impl.state = .cancelled;
        } else {
            impl.parentListener = try parent.onCancellationRequested(.{
                .context = @ptrCast(impl),
                .callbackFn = struct {
                    fn cancel(any_context: *anyopaque) void {
                        const source: *SourceImpl = @ptrCast(@alignCast(any_context));
                        cancelImpl(source);
                    }
                }.cancel,
            });
        }
        return .{ .impl = impl };
    }

    pub fn getAllocator(self: CancellationTokenSource) Allocator {
        return self.impl.allocator;
    }

    /// Disposes the source and frees its memory. The token returned by `token`
    /// must not be used afterwards.
    pub fn deinit(self: *CancellationTokenSource) void {
        const allocator = self.impl.allocator;
        self.dispose(false);
        if (self.impl.retainedToken) |mutable| {
            mutable.deinit();
            allocator.destroy(mutable);
            self.impl.retainedToken = null;
        }
        allocator.destroy(self.impl);
    }

    pub fn token(self: *CancellationTokenSource) !CancellationToken {
        const impl = self.impl;
        switch (impl.state) {
            .none => {
                const mutable = try impl.allocator.create(MutableToken);
                mutable.* = MutableToken.init(impl.allocator);
                impl.state = .{ .mutable = mutable };
                return mutable.token();
            },
            .mutable => |mutable| return mutable.token(),
            .cancelled => return CancellationToken.Cancelled,
            .disposed => return CancellationToken.None,
        }
    }

    pub fn cancel(self: *CancellationTokenSource) void {
        cancelImpl(self.impl);
    }

    /// Disposes the source, optionally cancelling it first.
    pub fn dispose(self: *CancellationTokenSource, cancel_first: bool) void {
        const impl = self.impl;
        if (cancel_first) {
            cancelImpl(impl);
        }

        impl.parentListener.dispose();
        impl.parentListener = .{};

        const previous_state = impl.state;
        impl.state = .disposed;
        switch (previous_state) {
            .mutable => |mutable| {
                // Drop all listeners, but keep the token object alive so that
                // outstanding tokens do not observe freed memory.
                mutable.clearListeners();
                impl.retainedToken = mutable;
            },
            else => {},
        }
    }
};

fn cancelImpl(impl: *SourceImpl) void {
    switch (impl.state) {
        .none => impl.state = .cancelled,
        .mutable => |mutable| mutable.cancel(),
        .cancelled, .disposed => {},
    }
}

/// Creates a token that is cancelled when the given store is disposed. The
/// token must not be used after the store has been disposed.
pub fn cancelOnDispose(allocator: Allocator, store: *DisposableStore) !CancellationToken {
    const source = try allocator.create(CancellationTokenSource);
    source.* = try CancellationTokenSource.init(allocator);
    errdefer allocator.destroy(source);
    const token = try source.token();

    store.add(.{
        .context = @ptrCast(source),
        .disposeFn = struct {
            fn dispose(context: *anyopaque) void {
                const typed: *CancellationTokenSource = @ptrCast(@alignCast(context));
                const source_allocator = typed.getAllocator();
                typed.cancel();
                typed.deinit();
                source_allocator.destroy(typed);
            }
        }.dispose,
    });

    return token;
}

/// A pool that aggregates multiple cancellation tokens. The pool's own token is
/// cancelled only after every token added to the pool has been cancelled.
/// Adding tokens after the pool token has been cancelled has no effect.
///
/// The pool registers listeners that point at the pool itself, so it must not
/// be moved once tokens have been added.
pub const CancellationTokenPool = struct {
    allocator: Allocator,
    source: CancellationTokenSource,
    listeners: DisposableStore,
    total: usize = 0,
    cancelled: usize = 0,
    isDone: bool = false,

    pub fn init(allocator: Allocator) !CancellationTokenPool {
        return .{
            .allocator = allocator,
            .source = try CancellationTokenSource.init(allocator),
            .listeners = DisposableStore.init(allocator),
        };
    }

    pub fn deinit(self: *CancellationTokenPool) void {
        self.listeners.deinit();
        self.source.deinit();
    }

    pub fn token(self: *CancellationTokenPool) !CancellationToken {
        return self.source.token();
    }

    /// Adds a token to the pool. If the token is already cancelled it is
    /// counted immediately.
    pub fn add(self: *CancellationTokenPool, cancellation_token: CancellationToken) !void {
        if (self.isDone) {
            return;
        }

        self.total += 1;

        if (cancellation_token.isCancellationRequested()) {
            self.cancelled += 1;
            self.check();
            return;
        }

        const disposable = try cancellation_token.onCancellationRequested(.{
            .context = @ptrCast(self),
            .callbackFn = struct {
                fn onCancelled(any_context: *anyopaque) void {
                    const pool: *CancellationTokenPool = @ptrCast(@alignCast(any_context));
                    pool.cancelled += 1;
                    pool.check();
                }
            }.onCancelled,
        });
        self.listeners.add(disposable);
    }

    fn check(self: *CancellationTokenPool) void {
        if (!self.isDone and self.total > 0 and self.total == self.cancelled) {
            self.isDone = true;
            self.listeners.dispose();
            self.source.cancel();
        }
    }

    pub fn dispose(self: *CancellationTokenPool) void {
        self.listeners.dispose();
        self.source.dispose(false);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "CancellationToken.None is never cancelled" {
    try std.testing.expect(!CancellationToken.None.isCancellationRequested());
    try std.testing.expect(!CancellationToken.Cancelled.isCancellationRequested() == false);

    var called = false;
    const disposable = try CancellationToken.None.onCancellationRequested(.{
        .context = @ptrCast(&called),
        .callbackFn = struct {
            fn call(_: *anyopaque) void {}
        }.call,
    });
    disposable.dispose();
    try std.testing.expect(!called);
}

test "CancellationTokenSource cancels" {
    var source = try CancellationTokenSource.init(std.testing.allocator);
    defer source.deinit();

    const token = try source.token();
    try std.testing.expect(!token.isCancellationRequested());

    source.cancel();
    try std.testing.expect(token.isCancellationRequested());
    // Cancelling twice is a no-op.
    source.cancel();
    try std.testing.expect(token.isCancellationRequested());
}

test "cancel before the token is requested" {
    var source = try CancellationTokenSource.init(std.testing.allocator);
    defer source.deinit();

    source.cancel();
    const token = try source.token();
    try std.testing.expect(token.isCancellationRequested());
}

test "dispose without cancel leaves the token uncancelled" {
    var source = try CancellationTokenSource.init(std.testing.allocator);
    defer source.deinit();

    const token = try source.token();
    source.dispose(false);
    try std.testing.expect(!token.isCancellationRequested());
}

test "listeners fire once" {
    var source = try CancellationTokenSource.init(std.testing.allocator);
    defer source.deinit();
    const token = try source.token();

    const Recorder = struct {
        var count: usize = 0;
        fn onCancel(_: *anyopaque) void {
            count += 1;
        }
    };
    Recorder.count = 0;

    var context: u8 = 0;
    const disposable = try token.onCancellationRequested(.{
        .context = @ptrCast(&context),
        .callbackFn = Recorder.onCancel,
    });
    defer disposable.dispose();

    source.cancel();
    source.cancel();
    try std.testing.expectEqual(@as(usize, 1), Recorder.count);
}

test "listener registered after cancellation fires immediately" {
    var source = try CancellationTokenSource.init(std.testing.allocator);
    defer source.deinit();
    const token = try source.token();
    source.cancel();

    const Recorder = struct {
        var count: usize = 0;
        fn onCancel(_: *anyopaque) void {
            count += 1;
        }
    };
    Recorder.count = 0;

    var context: u8 = 0;
    const disposable = try token.onCancellationRequested(.{
        .context = @ptrCast(&context),
        .callbackFn = Recorder.onCancel,
    });
    defer disposable.dispose();
    try std.testing.expectEqual(@as(usize, 1), Recorder.count);
}

test "disposing a registration removes the listener" {
    var source = try CancellationTokenSource.init(std.testing.allocator);
    defer source.deinit();
    const token = try source.token();

    const Recorder = struct {
        var count: usize = 0;
        fn onCancel(_: *anyopaque) void {
            count += 1;
        }
    };
    Recorder.count = 0;

    var context: u8 = 0;
    const disposable = try token.onCancellationRequested(.{
        .context = @ptrCast(&context),
        .callbackFn = Recorder.onCancel,
    });
    disposable.dispose();

    source.cancel();
    try std.testing.expectEqual(@as(usize, 0), Recorder.count);
}

test "child source is cancelled by its parent" {
    var parent = try CancellationTokenSource.init(std.testing.allocator);
    defer parent.deinit();
    const parent_token = try parent.token();

    var child = try CancellationTokenSource.initChild(std.testing.allocator, parent_token);
    defer child.deinit();
    const child_token = try child.token();

    try std.testing.expect(!child_token.isCancellationRequested());
    parent.cancel();
    try std.testing.expect(child_token.isCancellationRequested());
}

test "child source created from a cancelled parent" {
    var parent = try CancellationTokenSource.init(std.testing.allocator);
    defer parent.deinit();
    const parent_token = try parent.token();
    parent.cancel();

    var child = try CancellationTokenSource.initChild(std.testing.allocator, parent_token);
    defer child.deinit();
    try std.testing.expect((try child.token()).isCancellationRequested());
}

test "CancellationTokenPool cancels once all tokens are cancelled" {
    const allocator = std.testing.allocator;
    var pool = try CancellationTokenPool.init(allocator);
    defer pool.deinit();

    var first = try CancellationTokenSource.init(allocator);
    defer first.deinit();
    var second = try CancellationTokenSource.init(allocator);
    defer second.deinit();

    try pool.add(try first.token());
    try pool.add(try second.token());

    const pool_token = try pool.token();
    try std.testing.expect(!pool_token.isCancellationRequested());

    first.cancel();
    try std.testing.expect(!pool_token.isCancellationRequested());

    second.cancel();
    try std.testing.expect(pool_token.isCancellationRequested());
}

test "CancellationTokenPool with an empty token set never cancels" {
    const allocator = std.testing.allocator;
    var pool = try CancellationTokenPool.init(allocator);
    defer pool.deinit();
    const pool_token = try pool.token();
    try std.testing.expect(!pool_token.isCancellationRequested());
}

test "throwIfCancellationRequested" {
    try CancellationToken.None.throwIfCancellationRequested();
    try std.testing.expectError(error.CancellationError, CancellationToken.Cancelled.throwIfCancellationRequested());
}
