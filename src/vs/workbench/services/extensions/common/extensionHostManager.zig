// Workbench-side owner of the Node extension host process.
//
// Transport adaptation: the pinned launcher uses dedicated fd 3/4 by default;
// the editor creates a Unix socket pair instead and passes the path through
// VSCODE_EXTENSION_HOST_SOCKET. This keeps stdout/stderr free for the host and
// extension code without needing raw fork/exec fd plumbing in Zig. The frame
// and RPC bytes are unchanged (docs/extensions.md §5).
//
// The reader thread only copies complete frames into a queue. `pump()` runs on
// the TUI thread and is the only place that dispatches RPC messages.
const std = @import("std");
const time_compat = @import("../../../../base/common/timeCompat.zig");
const Allocator = std.mem.Allocator;
const rpcProtocol = @import("rpcProtocol.zig");
const proxyIdentifier = @import("proxyIdentifier.zig");

pub const max_frame_size: usize = 64 * 1024 * 1024;

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
    extension: *const ExtensionDescription,
    workspace_path: ?[]const u8 = null,
    workspace_name: []const u8 = "workspace",
    data_path: []const u8,
    app_root: []const u8,
    parent_pid: u32,
};

const SendContext = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    mutex: std.Io.Mutex = .init,

    fn send(context: *anyopaque, payload: []const u8) void {
        const self: *SendContext = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(payload.len), .big);
        var buffer: [4096]u8 = undefined;
        var writer = self.stream.writer(self.io, &buffer);
        writer.interface.writeAll(&length) catch return;
        writer.interface.writeAll(payload) catch return;
        writer.interface.flush() catch return;
    }

    fn transport(self: *SendContext) rpcProtocol.Transport {
        return .{ .context = self, .send_fn = send };
    }
};

pub const HostManager = struct {
    allocator: Allocator,
    child: std.process.Child,
    server: std.Io.net.Server,
    stream: std.Io.net.Stream,
    io_state: std.Io.Threaded,
    io: std.Io,
    socket_path: []u8,
    sender: *SendContext,
    rpc: rpcProtocol.RpcProtocol,
    queue: std.array_list.Managed([]u8),
    queue_mutex: std.Io.Mutex = .init,
    reader: ?std.Thread = null,
    stderr_reader: ?std.Thread = null,
    stderr_log: ?std.Io.File = null,
    eof: bool = false,
    started: bool = false,
    stopped: bool = false,

    pub fn start(allocator: Allocator, options: Options) !*HostManager {
        const self = try allocator.create(HostManager);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .child = undefined,
            .server = undefined,
            .stream = undefined,
            .socket_path = undefined,
            .sender = undefined,
            .rpc = undefined,
            .queue = .init(allocator),
            .io_state = undefined,
            .io = undefined,
        };
        self.io_state = std.Io.Threaded.init(std.heap.page_allocator, .{});
        self.io = self.io_state.io();

        self.socket_path = try std.fmt.allocPrint(allocator, "/tmp/zig-vscode-ext-{d}-{d}.sock", .{
            std.os.linux.getpid(),
            time_compat.milliTimestamp(),
        });
        errdefer allocator.free(self.socket_path);

        const extension_storage = try std.fs.path.join(allocator, &.{ options.data_path, "globalStorage", options.extension.identifier });
        defer allocator.free(extension_storage);
        std.Io.Dir.cwd().createDirPath(self.io, extension_storage) catch {};

        const address = std.Io.net.UnixAddress.init(self.socket_path) catch return ExtensionHostError.SocketSetupFailed;
        self.server = address.listen(self.io, .{}) catch return ExtensionHostError.SocketSetupFailed;

        self.child = std.process.spawn(self.io, .{
            .argv = &.{ options.node_path, options.host_script, "--socket", self.socket_path },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .pipe,
        }) catch return ExtensionHostError.HostExited;

        const stderr_path = try std.fs.path.join(allocator, &.{ options.data_path, "extension-host.log" });
        defer allocator.free(stderr_path);
        self.stderr_log = std.Io.Dir.cwd().createFile(self.io, stderr_path, .{ .read = true }) catch null;

        // Bound the accept so a host that dies before connecting does not
        // hang the editor forever.
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = self.server.socket.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&poll_fds, 10_000) catch 0;
        if (ready == 0) return ExtensionHostError.HostTimeout;
        const connection = self.server.accept(self.io) catch return ExtensionHostError.HostExited;
        self.stream = connection;

        self.sender = try allocator.create(SendContext);
        self.sender.* = .{ .stream = self.stream, .io = self.io };
        self.rpc = rpcProtocol.RpcProtocol.init(allocator, self.sender.transport());
        self.reader = try std.Thread.spawn(.{}, readerLoop, .{self});
        self.stderr_reader = try std.Thread.spawn(.{}, stderrLoop, .{self});
        return self;
    }

    pub fn deinit(self: *HostManager) void {
        self.stop();
        self.rpc.deinit();
        self.server.deinit(self.io);
        std.Io.Dir.deleteFileAbsolute(self.io, self.socket_path) catch {};
        self.allocator.free(self.socket_path);
        self.allocator.destroy(self.sender);
        for (self.queue.items) |frame| self.allocator.free(frame);
        self.queue.deinit();
        if (self.stderr_log) |file| file.close(self.io);
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
        }
        if (self.reader) |thread| {
            self.stream.shutdown(self.io, .both) catch {};
            self.stream.close(self.io);
            thread.join();
            self.reader = null;
        }
        if (self.stderr_reader) |thread| {
            thread.join();
            self.stderr_reader = null;
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
            var iovec = [_][]u8{&chunk};
            const count = self.stream.read(self.io, &iovec) catch break;
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
                self.queue_mutex.unlock(self.io);
                const consumed = 4 + length;
                std.mem.copyForwards(u8, buffer.items[0 .. buffer.items.len - consumed], buffer.items[consumed..]);
                buffer.shrinkRetainingCapacity(buffer.items.len - consumed);
            }
        }
        self.setEof();
    }

    fn stderrLoop(self: *HostManager) void {
        const log_file = self.stderr_log orelse return;
        const stderr = self.child.stderr orelse return;
        var buffer: [4096]u8 = undefined;
        while (true) {
            const count = stderr.readStreaming(self.io, &.{&buffer}) catch break;
            if (count == 0) break;
            log_file.writeStreamingAll(self.io, buffer[0..count]) catch break;
        }
    }

    fn setEof(self: *HostManager) void {
        self.queue_mutex.lockUncancelable(self.io);
        self.eof = true;
        self.queue_mutex.unlock(self.io);
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
        return worked;
    }

    /// Pumps until `done` is set or the deadline expires. Used during boot;
    /// the TUI loop uses `pump()` instead.
    pub fn waitUntil(self: *HostManager, context: *anyopaque, done: *const fn (*anyopaque) bool, timeout_ms: u32) !void {
        const deadline = time_compat.milliTimestamp() + timeout_ms;
        while (!done(context)) {
            _ = self.pump();
            if (self.hasEof()) return ExtensionHostError.HostExited;
            if (time_compat.milliTimestamp() > deadline) return ExtensionHostError.HostTimeout;
            self.io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
    }

    pub fn waitForRawFrame(self: *HostManager, timeout_ms: u32) ![]u8 {
        const deadline = time_compat.milliTimestamp() + timeout_ms;
        while (true) {
            if (self.popFrame()) |frame| return frame;
            if (self.hasEof()) return ExtensionHostError.HostExited;
            if (time_compat.milliTimestamp() > deadline) return ExtensionHostError.HostTimeout;
            self.io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
    }

    pub fn sendRawFrame(self: *HostManager, payload: []const u8) !void {
        SendContext.send(self.sender, payload);
    }

    pub fn expectControl(self: *HostManager, value: u8, timeout_ms: u32) !void {
        const deadline = time_compat.milliTimestamp() + timeout_ms;
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
            if (time_compat.milliTimestamp() > deadline) return ExtensionHostError.HostTimeout;
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
};

pub const noop_callback = rpcProtocol.ReplyCallback{
    .context = undefined,
    .callback = struct {
        fn cb(_: *anyopaque, _: rpcProtocol.Reply) void {}
    }.cb,
};

pub fn fileUri(arena: Allocator, path: []const u8) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(arena, "$mid", .{ .integer = 1 });
    try object.put(arena, "scheme", .{ .string = "file" });
    try object.put(arena, "authority", .{ .string = "" });
    try object.put(arena, "path", .{ .string = try arena.dupe(u8, path) });
    try object.put(arena, "query", .{ .string = "" });
    try object.put(arena, "fragment", .{ .string = "" });
    return .{ .object = object };
}

pub fn buildInitData(
    arena: Allocator,
    options: Options,
) !std.json.Value {
    const extension = options.extension;
    var root: std.json.ObjectMap = .empty;
    try root.put(arena, "version", .{ .string = "1.147.0" });
    try root.put(arena, "quality", .{ .string = "stable" });
    try root.put(arena, "parentPid", .{ .integer = options.parent_pid });

    var environment: std.json.ObjectMap = .empty;
    try environment.put(arena, "isExtensionDevelopmentDebug", .{ .bool = false });
    try environment.put(arena, "appName", .{ .string = "zig-editor" });
    try environment.put(arena, "appHost", .{ .string = "node" });
    try environment.put(arena, "appRoot", try fileUri(arena, options.app_root));
    try environment.put(arena, "appLanguage", .{ .string = "en" });
    try environment.put(arena, "isExtensionTelemetryLoggingOnly", .{ .bool = false });
    try environment.put(arena, "appUriScheme", .{ .string = "zig-editor" });
    try environment.put(arena, "globalStorageHome", try fileUri(arena, try std.fs.path.join(arena, &.{ options.data_path, "globalStorage" })));
    try environment.put(arena, "workspaceStorageHome", try fileUri(arena, try std.fs.path.join(arena, &.{ options.data_path, "workspaceStorage" })));
    try environment.put(arena, "useHostProxy", .{ .bool = false });
    try environment.put(arena, "skipWorkspaceStorageLock", .{ .bool = true });
    try root.put(arena, "environment", .{ .object = environment });

    if (options.workspace_path) |workspace| {
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

    var description = switch (extension.manifest) {
        .object => |object| object,
        else => return error.InvalidManifest,
    };
    try description.put(arena, "id", .{ .string = try arena.dupe(u8, extension.identifier) });
    var identifier: std.json.ObjectMap = .empty;
    try identifier.put(arena, "value", .{ .string = try arena.dupe(u8, extension.identifier) });
    try identifier.put(arena, "_lower", .{ .string = try std.ascii.allocLowerString(arena, extension.identifier) });
    try description.put(arena, "identifier", .{ .object = identifier });
    try description.put(arena, "extensionLocation", try fileUri(arena, extension.path));
    try description.put(arena, "isBuiltin", .{ .bool = false });
    try description.put(arena, "isUserBuiltin", .{ .bool = false });
    try description.put(arena, "isUnderDevelopment", .{ .bool = true });
    try description.put(arena, "targetPlatform", .{ .string = "undefined" });
    try description.put(arena, "preRelease", .{ .bool = false });

    var activation_events = std.json.Array.init(arena);
    for (extension.activation_events) |event| {
        try activation_events.append(.{ .string = try arena.dupe(u8, event) });
    }
    try description.put(arena, "activationEvents", .{ .array = activation_events });

    var extensions: std.json.ObjectMap = .empty;
    try extensions.put(arena, "versionId", .{ .integer = 1 });
    var all_extensions: std.json.Array = .init(arena);
    try all_extensions.append(.{ .object = description });
    try extensions.put(arena, "allExtensions", .{ .array = all_extensions });
    var activation_map: std.json.ObjectMap = .empty;
    try activation_map.put(arena, try arena.dupe(u8, extension.identifier), .{ .array = activation_events });
    try extensions.put(arena, "activationEvents", .{ .object = activation_map });
    var my_extensions = std.json.Array.init(arena);
    try my_extensions.append(.{ .object = identifier });
    try extensions.put(arena, "myExtensions", .{ .array = my_extensions });
    try root.put(arena, "extensions", .{ .object = extensions });

    var telemetry: std.json.ObjectMap = .empty;
    for ([_][]const u8{ "sessionId", "machineId", "sqmId", "devDeviceId", "firstSessionDate" }) |key| {
        try telemetry.put(arena, key, .{ .string = "" });
    }
    try root.put(arena, "telemetryInfo", .{ .object = telemetry });
    try root.put(arena, "logLevel", .{ .integer = 1 });
    try root.put(arena, "loggers", .{ .array = std.json.Array.init(arena) });
    try root.put(arena, "logsLocation", try fileUri(arena, try std.fs.path.join(arena, &.{ options.data_path, "logs" })));
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

pub fn readExtensionDescription(allocator: Allocator, extension_path: []const u8) !ExtensionDescription {
    const manifest_path = try std.fs.path.join(allocator, &.{ extension_path, "package.json" });
    defer allocator.free(manifest_path);
    const text = try std.Io.Dir.cwd().readFileAlloc(time_compat.io, manifest_path, allocator, .unlimited);
    defer allocator.free(text);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    errdefer parsed.deinit();
    const value = parsed.value;

    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidManifest,
    };
    const publisher = if (object.get("publisher")) |v| if (v == .string) v.string else "" else "";
    const name = if (object.get("name")) |v| if (v == .string) v.string else "" else "";
    const identifier = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ publisher, name });

    var events: std.array_list.Managed([]const u8) = .init(allocator);
    defer events.deinit();
    if (object.get("activationEvents")) |activation_value| {
        if (activation_value == .array) {
            for (activation_value.array.items) |item| {
                if (item == .string) try events.append(try allocator.dupe(u8, item.string));
            }
        }
    }
    if (events.items.len == 0) {
        // VS Code synthesizes `*` for extensions without explicit events.
        try events.append(try allocator.dupe(u8, "*"));
    }
    return .{
        .path = try allocator.dupe(u8, extension_path),
        .parsed = parsed,
        .manifest = value,
        .identifier = identifier,
        .activation_events = try events.toOwnedSlice(),
    };
}
