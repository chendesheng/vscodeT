// Workbench-side owner of the Node extension host process.
//
// Transport adaptation of VS Code's IPCExtHostConnection: a local Unix socket
// or Windows named pipe carries the existing framed RPC stream. The pinned
// desktop Electron MessagePort is not available in a standalone Zig process.
// The transport and RPC bytes are independent (docs/extensions.md §5).
//
// The reader thread only copies complete frames into a queue. `pump()` runs on
// the TUI thread and is the only place that dispatches RPC messages.
const std = @import("std");
const builtin = @import("builtin");
const ipc = @import("../../../../base/parts/ipc/node/ipc.net.zig");
const std_uri = @import("../../../../base/common/stdUri.zig");
const time_compat = @import("../../../../base/common/timeCompat.zig");
const Allocator = std.mem.Allocator;
const rpcProtocol = @import("rpcProtocol.zig");
const proxyIdentifier = @import("proxyIdentifier.zig");
const protocol = @import("../../../api/common/extHost.protocol.zig");

pub const max_frame_size: usize = 64 * 1024 * 1024;
// LocalProcessExtensionHost._establishProtocol/_performHandshake allow 60s
// for connection and each handshake phase; the 10s upstream notification is
// a warning, not a deadline that terminates a slow-starting host.
pub const startup_timeout_ms: u32 = 60_000;

/// The manager creates its own `Io` for the host transport, and that `Io` must
/// carry the process environment: `std.process.spawn` resolves `node` against
/// the `Io`'s environment, not the calling process's, so an empty one makes
/// every bare executable name fail with `FileNotFound`.
fn processEnviron() std.process.Environ {
    return switch (builtin.os.tag) {
        .windows => .{ .block = .global },
        else => if (builtin.link_libc)
            .{ .block = .{ .slice = @ptrCast(@as([:null]?[*:0]u8, std.mem.span(std.c.environ))) } }
        else
            .empty,
    };
}

/// `std.os.linux.getpid` type-checks on every target but issues a Linux
/// syscall, which traps with SIGSYS on other kernels.
pub fn currentProcessId() u32 {
    return switch (builtin.os.tag) {
        .linux => @intCast(std.os.linux.getpid()),
        .plan9 => std.os.plan9.getpid(),
        .windows => std.os.windows.GetCurrentProcessId(),
        else => @intCast(std.c.getpid()),
    };
}

pub const ExtensionHostError = error{
    HostExited,
    HostTimeout,
    InvalidFrame,
    FrameTooLarge,
    SocketSetupFailed,
    HandshakeFailed,
};

pub const ExtensionDescription = struct {
    /// Absolute extension directory.
    path: []const u8,
    parsed: std.json.Parsed(std.json.Value),
    manifest: std.json.Value,
    identifier: []const u8,
    activation_events: []const []const u8,
    /// A system/builtin extension (`isBuiltin` in `IExtensionDescription`).
    is_builtin: bool = false,
    /// An extension loaded from a development/unpacked location.
    is_under_development: bool = false,

    pub fn deinit(self: *ExtensionDescription, allocator: Allocator) void {
        for (self.activation_events) |event| allocator.free(event);
        if (self.activation_events.len > 0) allocator.free(self.activation_events);
        self.parsed.deinit();
        allocator.free(self.identifier);
        allocator.free(self.path);
    }
};

pub const Options = struct {
    node_path: []const u8 = "node",
    /// host/dist/extensionHost.mjs
    host_script: []const u8,
    extensions: []const *const ExtensionDescription,
    workspace_path: ?[]const u8 = null,
    workspace_data: ?std.json.Value = null,
    workspace_name: []const u8 = "workspace",
    /// The TUI user data directory; storage and logs follow upstream's
    /// `<userData>/User/...` and `<userData>/logs` layout.
    user_data_dir: []const u8,
    app_root: []const u8,
    parent_pid: u32,
};

const ProtocolWriter = @import("../../../../base/parts/ipc/common/ipc.net.zig").ProtocolWriter;

const SendContext = struct {
    stream: ipc.Connection,
    io: std.Io,
    owner: *HostManager,
    writer: ProtocolWriter,

    fn send(context: *anyopaque, payload: []const u8) void {
        const self: *SendContext = @ptrCast(@alignCast(context));
        self.write(payload) catch {};
    }

    fn write(self: *SendContext, payload: []const u8) !void {
        if (payload.len > max_frame_size) return ExtensionHostError.FrameTooLarge;
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(payload.len), .big);
        try self.writer.write(&length, payload);
    }

    fn writeDetached(context: *anyopaque, bytes: []const u8) !void {
        const self: *SendContext = @ptrCast(@alignCast(context));
        try self.stream.writeAll(self.io, bytes);
    }

    fn failed(context: *anyopaque) void {
        const self: *SendContext = @ptrCast(@alignCast(context));
        self.owner.setEof();
    }

    fn transport(self: *SendContext) rpcProtocol.Transport {
        return .{ .context = self, .send_fn = send };
    }
};

/// Port of IPCExtHostConnection's environment contract and the standalone
/// process-launch boundary. Electron's utility process is not required.
fn spawnHost(allocator: Allocator, io: std.Io, options: Options, endpoint: []const u8) !std.process.Child {
    var env = try processEnviron().createMap(allocator);
    defer env.deinit();
    _ = env.swapRemove("VSCODE_EXTHOST_WILL_SEND_SOCKET");
    _ = env.swapRemove("VSCODE_WILL_SEND_MESSAGE_PORT");
    try env.put("VSCODE_EXTHOST_IPC_HOOK", endpoint);
    const stderr_path = try std.fs.path.join(allocator, &.{ options.user_data_dir, "logs", "extension-host.log" });
    defer allocator.free(stderr_path);
    if (std.fs.path.dirname(stderr_path)) |directory| try std.Io.Dir.cwd().createDirPath(io, directory);

    if (builtin.os.tag == .windows) {
        // Keep both output streams off the terminal and separate from IPC.
        // Separate files avoid two independently opened file offsets writing
        // over each other on Windows. No command interpreter is involved.
        const stdout_path = try std.fs.path.join(allocator, &.{ options.user_data_dir, "logs", "extension-host.stdout.log" });
        defer allocator.free(stdout_path);
        const stderr = try std.Io.Dir.cwd().createFile(io, stderr_path, .{});
        defer stderr.close(io);
        const stdout = try std.Io.Dir.cwd().createFile(io, stdout_path, .{});
        defer stdout.close(io);
        return std.process.spawn(io, .{
            // Keep the launcher's legacy argument while installed bundles can
            // predate the upstream IPC environment contract. Both designate
            // the same random endpoint, not a second transport.
            .argv = &.{ options.node_path, options.host_script, "--socket", endpoint },
            .environ_map = &env,
            .stdin = .ignore,
            .stdout = .{ .file = stdout },
            .stderr = .{ .file = stderr },
            .create_no_window = true,
        });
    }

    // Retain the existing POSIX launcher workaround: posix_spawn with
    // .file/.pipe returned EBADF in the live TUI's shared fd table. Only the
    // shell handles stdout/stderr redirection; IPC is independent of it.
    return std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "exec \"$0\" \"$1\" --socket \"$3\" </dev/null >>\"$2\" 2>&1", options.node_path, options.host_script, stderr_path, endpoint },
        .environ_map = &env,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
}

pub const HostManager = struct {
    allocator: Allocator,
    child: std.process.Child,
    server: ipc.Server,
    stream: ipc.Connection,
    io_state: std.Io.Threaded,
    io: std.Io,
    sender: *SendContext,
    rpc: rpcProtocol.RpcProtocol,
    queue: std.array_list.Managed([]u8),
    queue_mutex: std.Io.Mutex = .init,
    reader: ?std.Thread = null,
    ready_task: ?*@import("../../../../base/common/windowDispatch.zig").Task = null,
    awaiting: ?*AwaitSlot = null,
    eof: bool = false,
    started: bool = false,
    stopped: bool = false,
    requested_activation_events: std.StringHashMapUnmanaged(void) = .empty,

    pub fn start(allocator: Allocator, options: Options) !*HostManager {
        const self = try allocator.create(HostManager);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .child = undefined,
            .server = undefined,
            .stream = undefined,
            .sender = undefined,
            .rpc = undefined,
            .queue = .init(allocator),
            .io_state = undefined,
            .io = undefined,
        };
        self.io_state = std.Io.Threaded.init(std.heap.page_allocator, .{ .environ = processEnviron() });
        self.io = self.io_state.io();

        errdefer self.io_state.deinit();
        errdefer self.queue.deinit();

        for (options.extensions) |extension| {
            const extension_storage = try std.fs.path.join(allocator, &.{ options.user_data_dir, "User", "globalStorage", extension.identifier });
            defer allocator.free(extension_storage);
            std.Io.Dir.cwd().createDirPath(self.io, extension_storage) catch {};
        }

        self.server = ipc.Server.listen(allocator, self.io, processEnviron()) catch return ExtensionHostError.SocketSetupFailed;
        errdefer self.server.deinit(self.io);

        self.child = spawnHost(allocator, self.io, options, self.server.path) catch return ExtensionHostError.HostExited;
        errdefer if (self.child.id != null) self.child.kill(self.io);

        // A dead or stalled child cannot hold the workbench at startup.
        self.stream = self.server.accept(self.io, startup_timeout_ms) catch |err| switch (err) {
            error.Timeout => return ExtensionHostError.HostTimeout,
            else => return ExtensionHostError.HostExited,
        };
        errdefer self.stream.close(self.io);

        self.sender = try allocator.create(SendContext);
        errdefer allocator.destroy(self.sender);
        self.sender.* = .{
            .stream = self.stream,
            .io = self.io,
            .owner = self,
            .writer = .{ .allocator = allocator, .io = self.io, .sink = .{ .context = self.sender, .write = SendContext.writeDetached, .failed = SendContext.failed } },
        };
        try self.sender.writer.start();
        errdefer {
            self.sender.writer.stop();
            self.stream.shutdown(self.io);
            self.sender.writer.deinit();
        }
        self.rpc = rpcProtocol.RpcProtocol.init(allocator, self.io, self.sender.transport());
        errdefer self.rpc.deinit();
        self.reader = try std.Thread.spawn(.{}, readerLoop, .{self});
        self.started = true;
        return self;
    }

    pub fn deinit(self: *HostManager) void {
        self.stop();
        self.failAwaiters();
        self.rpc.deinit();
        self.server.deinit(self.io);
        self.allocator.destroy(self.sender);
        for (self.queue.items) |frame| self.allocator.free(frame);
        self.queue.deinit();
        var events = self.requested_activation_events.keyIterator();
        while (events.next()) |event| self.allocator.free(event.*);
        self.requested_activation_events.deinit(self.allocator);
        self.io_state.deinit();
        self.allocator.destroy(self);
    }

    pub fn stop(self: *HostManager) void {
        if (self.stopped) return;
        self.stopped = true;
        if (self.started) {
            self.started = false;
            const terminate = [_]u8{3};
            self.sendRawFrame(&terminate) catch {};
            self.sender.writer.flush(.{ .duration = .{ .raw = .fromMilliseconds(250), .clock = .awake } });
        }
        self.sender.writer.stop();
        // Interrupt any in-flight read or write before joining either
        // transport thread; termination is best effort on a closing socket.
        self.stream.shutdown(self.io);
        self.sender.writer.deinit();
        if (self.reader) |thread| {
            thread.join();
            self.stream.close(self.io);
            self.reader = null;
        }
        if (self.child.id != null) {
            self.child.kill(self.io);
        }
    }

    fn readerLoop(self: *HostManager) void {
        var buffer: std.array_list.Managed(u8) = .init(self.allocator);
        defer buffer.deinit();
        var chunk: [16 * 1024]u8 = undefined;
        while (true) {
            const count = self.stream.read(self.io, &chunk) catch break;
            if (count == 0) break;
            buffer.appendSlice(chunk[0..count]) catch break;
            while (buffer.items.len >= 4) {
                const length = std.mem.readInt(u32, buffer.items[0..4], .big);
                if (length > max_frame_size) {
                    self.setEof();
                    return;
                }
                if (buffer.items.len < 4 + length) break;
                const payload = self.allocator.dupe(u8, buffer.items[4 .. 4 + length]) catch break;
                self.queue_mutex.lockUncancelable(self.io);
                self.queue.append(payload) catch self.allocator.free(payload);
                if (self.ready_task) |task| task.post();
                self.queue_mutex.unlock(self.io);
                const consumed = 4 + length;
                std.mem.copyForwards(u8, buffer.items[0 .. buffer.items.len - consumed], buffer.items[consumed..]);
                buffer.shrinkRetainingCapacity(buffer.items.len - consumed);
            }
        }
        self.setEof();
    }

    fn setEof(self: *HostManager) void {
        self.queue_mutex.lockUncancelable(self.io);
        self.eof = true;
        if (self.ready_task) |task| task.post();
        self.queue_mutex.unlock(self.io);
    }

    /// The reader owns only transport bytes; the window owns RPC dispatch.
    /// Detach under the same lock before freeing the window task.
    pub fn attachReadyTask(self: *HostManager, task: ?*@import("../../../../base/common/windowDispatch.zig").Task) void {
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);
        self.ready_task = task;
        if (task) |ready| {
            if (self.queue.items.len != 0 or self.eof) ready.post();
        }
    }

    pub fn hasEof(self: *HostManager) bool {
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);
        return self.eof;
    }

    fn popFrame(self: *HostManager) ?[]u8 {
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);
        if (self.queue.items.len == 0) return null;
        const frame = self.queue.orderedRemove(0);
        return frame;
    }

    pub fn pump(self: *HostManager) bool {
        var worked = false;
        while (self.popFrame()) |frame| {
            defer self.allocator.free(frame);
            self.rpc.receive(frame);
            worked = true;
        }
        if (self.hasEof()) self.failAwaiters();
        return worked;
    }

    /// Pumps until `done` is set or the deadline expires. Used during boot;
    /// the TUI loop uses `pump()` instead.
    pub fn waitUntil(self: *HostManager, context: *anyopaque, done: *const fn (*anyopaque) bool, timeout_ms: u32) !void {
        const deadline = time_compat.milliTimestamp(self.io) + timeout_ms;
        while (!done(context)) {
            _ = self.pump();
            if (self.hasEof()) return ExtensionHostError.HostExited;
            if (time_compat.milliTimestamp(self.io) > deadline) return ExtensionHostError.HostTimeout;
            self.io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
    }

    pub fn waitForRawFrame(self: *HostManager, timeout_ms: u32) ![]u8 {
        const deadline = time_compat.milliTimestamp(self.io) + timeout_ms;
        while (true) {
            if (self.popFrame()) |frame| return frame;
            if (self.hasEof()) return ExtensionHostError.HostExited;
            if (time_compat.milliTimestamp(self.io) > deadline) return ExtensionHostError.HostTimeout;
            self.io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
    }

    pub fn sendRawFrame(self: *HostManager, payload: []const u8) !void {
        try self.sender.write(payload);
    }

    pub fn expectControl(self: *HostManager, value: u8, timeout_ms: u32) !void {
        const deadline = time_compat.milliTimestamp(self.io) + timeout_ms;
        while (true) {
            const frame = try self.waitForRawFrame(timeout_ms);
            if (frame.len == 1) {
                defer self.allocator.free(frame);
                if (frame[0] != value) return ExtensionHostError.HandshakeFailed;
                return;
            }
            // Requests can arrive before Initialized; dispatch them while
            // waiting for the control byte.
            self.rpc.receive(frame);
            self.allocator.free(frame);
            if (time_compat.milliTimestamp(self.io) > deadline) return ExtensionHostError.HostTimeout;
        }
    }

    /// Sends init data as the first unframed-type payload after `Ready`.
    pub fn sendInitData(self: *HostManager, init_data: std.json.Value) !void {
        var out: std.array_list.Managed(u8) = .init(self.allocator);
        defer out.deinit();
        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer writer.deinit();
        try std.json.Stringify.value(init_data, .{}, &writer.writer);
        try self.sendRawFrame(writer.written());
    }

    pub fn call(
        self: *HostManager,
        identifier: proxyIdentifier.ProxyIdentifier,
        method: []const u8,
        args: []const rpcProtocol.Arg,
        token: ?@import("../../../../base/common/cancellation.zig").CancellationToken,
        callback: rpcProtocol.ReplyCallback,
    ) !u32 {
        return self.rpc.call(identifier, method, args, token, callback);
    }

    pub fn setActor(self: *HostManager, identifier: proxyIdentifier.ProxyIdentifier, handler: rpcProtocol.ActorHandler) void {
        self.rpc.set(identifier, handler);
    }

    /// Runs from a WindowIo fiber. Incoming frames are dispatched by the
    /// normal window queue, including requests nested inside this RPC.
    /// No recursive pump and no blocking wait on the window thread.
    pub fn requestAwait(
        self: *HostManager,
        window: *@import("../../../../base/common/windowDispatch.zig").Queue,
        allocator: Allocator,
        identifier: proxyIdentifier.ProxyIdentifier,
        method: []const u8,
        args: []const rpcProtocol.Arg,
        token: ?@import("../../../../base/common/cancellation.zig").CancellationToken,
        timeout_ms: u32,
    ) !std.json.Value {
        const cancellation = @import("../../../../base/common/cancellation.zig");
        if (!@import("ui").WindowIo.inFiber(window.io)) return error.NotInWindowFiber;
        if (self.hasEof()) return ExtensionHostError.HostExited;
        const effective_token = token orelse cancellation.CancellationToken.None;
        try effective_token.throwIfCancellationRequested();
        var slot: AwaitSlot = .{
            .owner = self,
            .io = window.io,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
        defer slot.arena.deinit();
        const listener = try effective_token.onCancellationRequested(cancellation.CancellationListener.from(AwaitSlot, &slot, AwaitSlot.canceled));
        defer listener.dispose();
        slot.id = try self.rpc.call(identifier, method, args, token, .{ .context = &slot, .callback = AwaitSlot.callback });
        slot.next = self.awaiting;
        self.awaiting = &slot;
        defer slot.detach();

        const deadline = std.Io.Clock.Timestamp.fromNow(window.io, .{ .clock = .awake, .raw = .fromMilliseconds(timeout_ms) });
        while (!slot.event.isSet()) {
            slot.event.waitTimeout(window.io, .{ .deadline = deadline }) catch |err| switch (err) {
                error.Timeout => {
                    if (std.Io.Timestamp.now(window.io, .awake).nanoseconds >= deadline.raw.nanoseconds) return ExtensionHostError.HostTimeout;
                },
                error.Canceled => return err,
            };
        }
        try effective_token.throwIfCancellationRequested();
        if (slot.exited) return ExtensionHostError.HostExited;
        if (slot.failed) return error.RequestFailed;
        return rpcProtocol.cloneJsonValue(allocator, slot.value);
    }

    fn failAwaiters(self: *HostManager) void {
        while (self.awaiting) |slot| {
            slot.detach();
            if (!slot.done) slot.exited = true;
            slot.event.set(slot.io);
        }
    }

    /// Legacy direct-call harness for protocol and provider tests. The
    /// production window must never recursively pump the extension transport;
    /// use requestAwait from an owned window fiber or a deferred callback.
    pub fn requestSync(
        self: *HostManager,
        allocator: Allocator,
        identifier: proxyIdentifier.ProxyIdentifier,
        method: []const u8,
        args: []const rpcProtocol.Arg,
        token: ?@import("../../../../base/common/cancellation.zig").CancellationToken,
        timeout_ms: u32,
    ) !std.json.Value {
        if (!builtin.is_test) return error.NotInWindowFiber;
        const slot = try allocator.create(SyncSlot);
        slot.* = .{ .allocator = allocator, .arena = std.heap.ArenaAllocator.init(allocator) };
        errdefer {
            slot.arena.deinit();
            allocator.destroy(slot);
        }
        const id = try self.rpc.call(identifier, method, args, token, .{ .context = slot, .callback = SyncSlot.callback });
        const deadline = time_compat.milliTimestamp(self.io) + timeout_ms;
        while (!slot.done) {
            _ = self.pump();
            if (self.hasEof()) {
                self.rpc.cancel(id);
                return ExtensionHostError.HostExited;
            }
            if (time_compat.milliTimestamp(self.io) > deadline) {
                self.rpc.cancel(id);
                return ExtensionHostError.HostTimeout;
            }
            self.io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
        if (slot.failed) return error.RequestFailed;
        const value = slot.value orelse std.json.Value.null;
        const result = try rpcProtocol.cloneJsonValue(allocator, value);
        slot.arena.deinit();
        allocator.destroy(slot);
        return result;
    }

    pub fn notify(
        self: *HostManager,
        identifier: proxyIdentifier.ProxyIdentifier,
        method: []const u8,
        args: []const rpcProtocol.Arg,
    ) !void {
        try self.rpc.notify(identifier, method, args);
    }

    /// Activates extensions registered for `activation_event` in the host.
    /// Upstream awaits the returned promise; the terminal workbench fires it
    /// and lets the host queue the activation, exactly like a workbench that
    /// does not block the UI on extension activation.
    pub fn executeContributedCommand(self: *HostManager, id: []const u8, values: []const std.json.Value) !void {
        const args = try self.allocator.alloc(rpcProtocol.Arg, values.len + 1);
        defer self.allocator.free(args);
        args[0] = .{ .json = .{ .string = id } };
        for (values, args[1..]) |value, *arg| arg.* = .{ .json = value };
        try self.notify(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostCommands), "$executeContributedCommand", args);
    }

    pub fn activateByEvent(self: *HostManager, activation_event: []const u8, activation_kind: u32) !void {
        if (!self.requested_activation_events.contains(activation_event)) {
            const owned = try self.allocator.dupe(u8, activation_event);
            errdefer self.allocator.free(owned);
            try self.requested_activation_events.put(self.allocator, owned, {});
        }
        var args = [_]rpcProtocol.Arg{
            .{ .json = .{ .string = activation_event } },
            .{ .json = .{ .integer = @intCast(activation_kind) } },
        };
        _ = try self.rpc.call(
            proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostExtensionService),
            "$activateByEvent",
            &args,
            null,
            noop_callback,
        );
    }
};

const AwaitSlot = struct {
    owner: ?*HostManager,
    next: ?*AwaitSlot = null,
    io: std.Io,
    id: u32 = undefined,
    arena: std.heap.ArenaAllocator,
    event: std.Io.Event = .unset,
    value: std.json.Value = .null,
    done: bool = false,
    failed: bool = false,
    exited: bool = false,

    fn callback(context: *anyopaque, reply: rpcProtocol.Reply) void {
        const self: *AwaitSlot = @ptrCast(@alignCast(context));
        self.done = true;
        defer self.event.set(self.io);
        switch (reply) {
            .json => |value| self.value = rpcProtocol.cloneJsonValue(self.arena.allocator(), value) catch {
                self.failed = true;
                return;
            },
            .empty => {},
            else => self.failed = true,
        }
    }

    fn canceled(self: *AwaitSlot) void {
        self.event.set(self.io);
    }

    fn detach(self: *AwaitSlot) void {
        const owner = self.owner orelse return;
        var link = &owner.awaiting;
        while (link.*) |slot| {
            if (slot == self) {
                link.* = self.next;
                break;
            }
            link = &slot.next;
        }
        if (!self.done) owner.rpc.cancel(self.id);
        self.owner = null;
    }
};

const SyncSlot = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    done: bool = false,
    failed: bool = false,
    value: ?std.json.Value = null,

    fn callback(context: *anyopaque, reply: rpcProtocol.Reply) void {
        const self: *SyncSlot = @ptrCast(@alignCast(context));
        self.done = true;
        switch (reply) {
            .json => |value| self.value = rpcProtocol.cloneJsonValue(self.arena.allocator(), value) catch {
                self.failed = true;
                return;
            },
            .empty => self.value = .null,
            .buffer => self.failed = true,
            .err => self.failed = true,
        }
    }
};

pub const noop_callback = rpcProtocol.ReplyCallback{
    .context = undefined,
    .callback = struct {
        fn cb(_: *anyopaque, _: rpcProtocol.Reply) void {}
    }.cb,
};

pub fn fileUri(arena: Allocator, path: []const u8) !std.json.Value {
    return std_uri.jsonComponents(arena, .{ .scheme = "file", .path = .{ .raw = path } });
}

pub fn extensionIdentifierJson(arena: Allocator, identifier: []const u8) !std.json.Value {
    var result: std.json.ObjectMap = .empty;
    try result.put(arena, "value", .{ .string = try arena.dupe(u8, identifier) });
    try result.put(arena, "_lower", .{ .string = try std.ascii.allocLowerString(arena, identifier) });
    return .{ .object = result };
}

/// Common IExtensionDescription shape used by both initial data and deltas.
pub fn extensionDescriptionJson(arena: Allocator, extension: *const ExtensionDescription) !std.json.Value {
    var description = switch (extension.manifest) {
        .object => |object| try object.clone(arena),
        else => return error.InvalidManifest,
    };
    try description.put(arena, "id", .{ .string = try arena.dupe(u8, extension.identifier) });
    try description.put(arena, "identifier", try extensionIdentifierJson(arena, extension.identifier));
    try description.put(arena, "extensionLocation", try fileUri(arena, extension.path));
    try description.put(arena, "isBuiltin", .{ .bool = extension.is_builtin });
    try description.put(arena, "isUserBuiltin", .{ .bool = false });
    try description.put(arena, "isUnderDevelopment", .{ .bool = extension.is_under_development });
    try description.put(arena, "targetPlatform", .{ .string = "undefined" });
    try description.put(arena, "preRelease", .{ .bool = false });
    var events = std.json.Array.init(arena);
    for (extension.activation_events) |event| try events.append(.{ .string = try arena.dupe(u8, event) });
    try description.put(arena, "activationEvents", .{ .array = events });
    return .{ .object = description };
}

/// ExtensionHostManager.deltaExtensions: all extensions and the local host's
/// assigned extensions change together in the single-host terminal topology.
pub fn buildExtensionsDelta(arena: Allocator, version: u32, remove: []const []const u8, add: []const *const ExtensionDescription) !std.json.Value {
    var to_remove = std.json.Array.init(arena);
    for (remove) |identifier| try to_remove.append(try extensionIdentifierJson(arena, identifier));
    var to_add = std.json.Array.init(arena);
    var my_to_add = std.json.Array.init(arena);
    var activation_events: std.json.ObjectMap = .empty;
    for (add) |extension| {
        const value = try extensionDescriptionJson(arena, extension);
        try to_add.append(value);
        try my_to_add.append(value.object.get("identifier").?);
        try activation_events.put(arena, extension.identifier, value.object.get("activationEvents").?);
    }
    var delta: std.json.ObjectMap = .empty;
    try delta.put(arena, "versionId", .{ .integer = version });
    try delta.put(arena, "toRemove", .{ .array = to_remove });
    try delta.put(arena, "toAdd", .{ .array = to_add });
    try delta.put(arena, "addActivationEvents", .{ .object = activation_events });
    try delta.put(arena, "myToRemove", .{ .array = to_remove });
    try delta.put(arena, "myToAdd", .{ .array = my_to_add });
    return .{ .object = delta };
}

pub fn buildInitData(
    arena: Allocator,
    options: Options,
) !std.json.Value {
    var root: std.json.ObjectMap = .empty;
    try root.put(arena, "version", .{ .string = "1.147.0" });
    try root.put(arena, "quality", .{ .string = "stable" });
    try root.put(arena, "parentPid", .{ .integer = options.parent_pid });

    var environment: std.json.ObjectMap = .empty;
    try environment.put(arena, "isExtensionDevelopmentDebug", .{ .bool = false });
    try environment.put(arena, "appName", .{ .string = "zig-editor" });
    try environment.put(arena, "appHost", .{ .string = "node" });
    // Init-data URIs must be absolute: the host resolves storage/log paths to
    // file URIs and a relative directory becomes a path below `/`.
    try environment.put(arena, "appRoot", try fileUri(arena, try std.fs.path.resolve(arena, &.{options.app_root})));
    try environment.put(arena, "appLanguage", .{ .string = "en" });
    try environment.put(arena, "isExtensionTelemetryLoggingOnly", .{ .bool = false });
    try environment.put(arena, "appUriScheme", .{ .string = "zig-editor" });
    try environment.put(arena, "globalStorageHome", try fileUri(arena, try std.fs.path.resolve(arena, &.{ options.user_data_dir, "User", "globalStorage" })));
    try environment.put(arena, "workspaceStorageHome", try fileUri(arena, try std.fs.path.resolve(arena, &.{ options.user_data_dir, "User", "workspaceStorage" })));
    try environment.put(arena, "useHostProxy", .{ .bool = false });
    try environment.put(arena, "skipWorkspaceStorageLock", .{ .bool = true });
    try root.put(arena, "environment", .{ .object = environment });

    if (options.workspace_data) |data| {
        try root.put(arena, "workspace", data);
    } else if (options.workspace_path) |workspace| {
        var workspace_data: std.json.ObjectMap = .empty;
        try workspace_data.put(arena, "id", .{ .string = "workspace" });
        try workspace_data.put(arena, "name", .{ .string = try arena.dupe(u8, options.workspace_name) });
        try workspace_data.put(arena, "transient", .{ .bool = false });
        try workspace_data.put(arena, "configuration", .null);
        try workspace_data.put(arena, "isUntitled", .null);
        var folders = std.json.Array.init(arena);
        var folder: std.json.ObjectMap = .empty;
        try folder.put(arena, "uri", try fileUri(arena, workspace));
        try folder.put(arena, "name", .{ .string = try arena.dupe(u8, options.workspace_name) });
        try folder.put(arena, "index", .{ .integer = 0 });
        try folders.append(.{ .object = folder });
        try workspace_data.put(arena, "folders", .{ .array = folders });
        try root.put(arena, "workspace", .{ .object = workspace_data });
    } else {
        try root.put(arena, "workspace", .null);
    }

    var extensions: std.json.ObjectMap = .empty;
    try extensions.put(arena, "versionId", .{ .integer = 1 });
    var all_extensions: std.json.Array = .init(arena);
    var activation_map: std.json.ObjectMap = .empty;
    var my_extensions = std.json.Array.init(arena);

    for (options.extensions) |extension| {
        const description = try extensionDescriptionJson(arena, extension);
        try all_extensions.append(description);
        try activation_map.put(arena, try arena.dupe(u8, extension.identifier), description.object.get("activationEvents").?);
        try my_extensions.append(description.object.get("identifier").?);
    }

    try extensions.put(arena, "allExtensions", .{ .array = all_extensions });
    try extensions.put(arena, "activationEvents", .{ .object = activation_map });
    try extensions.put(arena, "myExtensions", .{ .array = my_extensions });
    try root.put(arena, "extensions", .{ .object = extensions });

    var telemetry: std.json.ObjectMap = .empty;
    for ([_][]const u8{ "sessionId", "machineId", "sqmId", "devDeviceId", "firstSessionDate" }) |key| {
        try telemetry.put(arena, key, .{ .string = "" });
    }
    try root.put(arena, "telemetryInfo", .{ .object = telemetry });
    try root.put(arena, "logLevel", .{ .integer = 1 });
    try root.put(arena, "loggers", .{ .array = std.json.Array.init(arena) });
    try root.put(arena, "logsLocation", try fileUri(arena, try std.fs.path.resolve(arena, &.{ options.user_data_dir, "logs" })));
    try root.put(arena, "autoStart", .{ .bool = false });

    var remote: std.json.ObjectMap = .empty;
    try remote.put(arena, "isRemote", .{ .bool = false });
    try remote.put(arena, "connectionData", .null);
    try root.put(arena, "remote", .{ .object = remote });

    var console_forward: std.json.ObjectMap = .empty;
    try console_forward.put(arena, "includeStack", .{ .bool = false });
    try console_forward.put(arena, "logNative", .{ .bool = false });
    try root.put(arena, "consoleForward", .{ .object = console_forward });
    try root.put(arena, "uiKind", .{ .integer = 1 });
    return .{ .object = root };
}

fn appendActivation(events: *std.array_list.Managed([]const u8), prefix: []const u8, value: []const u8) !void {
    if (value.len == 0) return;
    for (events.items) |event| {
        if (std.mem.startsWith(u8, event, prefix) and std.mem.eql(u8, event[prefix.len..], value)) return;
    }
    try events.ensureUnusedCapacity(1);
    events.appendAssumeCapacity(try std.mem.concat(events.allocator, u8, &.{ prefix, value }));
}

pub fn readExtensionDescription(allocator: Allocator, io: std.Io, extension_path: []const u8) !ExtensionDescription {
    const manifest_path = try std.fs.path.join(allocator, &.{ extension_path, "package.json" });
    defer allocator.free(manifest_path);
    const text = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .unlimited);
    defer allocator.free(text);
    const sanitized = try @import("../../../../platform/configuration/common/configurationModels.zig").stripJsonc(allocator, text);
    defer allocator.free(sanitized);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, sanitized, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    const value = parsed.value;

    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidManifest,
    };
    const publisher = if (object.get("publisher")) |v| if (v == .string) v.string else "" else "";
    const name = if (object.get("name")) |v| if (v == .string) v.string else "" else "";
    const identifier = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ publisher, name });

    errdefer allocator.free(identifier);
    var events: std.array_list.Managed([]const u8) = .init(allocator);
    defer events.deinit();
    errdefer for (events.items) |event| allocator.free(event);
    if (object.get("activationEvents")) |explicit| {
        if (explicit == .array) for (explicit.array.items) |event| {
            if (event == .string) try appendActivation(&events, "", event.string);
        };
    }
    if (object.get("contributes")) |points| {
        if (points == .object) {
            if (points.object.get("languages")) |languages| {
                if (languages == .array) for (languages.array.items) |language| {
                    if (language != .object or !language.object.contains("configuration")) continue;
                    const id = language.object.get("id") orelse continue;
                    if (id == .string) try appendActivation(&events, "onLanguage:", id.string);
                };
            }
            if (points.object.get("authentication")) |providers| {
                if (providers == .array) for (providers.array.items) |provider| {
                    if (provider != .object) continue;
                    const id = provider.object.get("id") orelse continue;
                    if (id == .string) try appendActivation(&events, "onAuthenticationRequest:", id.string);
                };
            }
            if (points.object.get("commands")) |commands| {
                if (commands == .array) for (commands.array.items) |command| {
                    if (command != .object) continue;
                    const id = command.object.get("command") orelse continue;
                    if (id == .string) try appendActivation(&events, "onCommand:", id.string);
                };
            }
        }
    }
    const path_copy = try allocator.dupe(u8, extension_path);
    errdefer allocator.free(path_copy);
    return .{
        .path = path_copy,
        .parsed = parsed,
        .manifest = value,
        .identifier = identifier,
        .activation_events = try events.toOwnedSlice(),
    };
}

test "activation events include implicit commands without eager activation" {
    const allocator = std.testing.allocator;
    var description = try readExtensionDescription(allocator, std.testing.io, "vscode/extensions/emmet");
    defer description.deinit(allocator);
    var language = false;
    var command = false;
    for (description.activation_events) |event| {
        try std.testing.expect(!std.mem.eql(u8, event, "*"));
        if (std.mem.eql(u8, event, "onLanguage")) language = true;
        if (std.mem.eql(u8, event, "onCommand:editor.emmet.action.wrapWithAbbreviation")) command = true;
    }
    try std.testing.expect(language and command);
}
