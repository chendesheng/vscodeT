// Port of the local endpoint and byte-stream boundary in
// `src/vs/base/parts/ipc/node/ipc.net.ts`. Node's libuv implementation is
// replaced by Zig Unix sockets or native Windows named pipes. The caller owns
// framing and the protocol; the transport has no workbench dependencies.
const std = @import("std");
const builtin = @import("builtin");
const windows = builtin.os.tag == .windows;
const win = @import("ipc.net.windows.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn createRandomIPCHandle(allocator: Allocator, io: Io, env: std.process.Environ) ![]u8 {
    var random: [16]u8 = undefined;
    try io.randomSecure(&random);
    random[6] = (random[6] & 0x0f) | 0x40;
    random[8] = (random[8] & 0x3f) | 0x80;
    const hex = std.fmt.bytesToHex(random, .lower);
    var uuid: [36]u8 = undefined;
    _ = try std.fmt.bufPrint(&uuid, "{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] });
    if (windows) return std.fmt.allocPrint(allocator, "\\\\.\\pipe\\vscode-ipc-{s}-sock", .{&uuid});

    // Follow createRandomIPCHandle's choice of XDG_RUNTIME_DIR on Unix and
    // the platform's temporary directory on macOS. Trim the random suffix
    // for the native sockaddr_un limit, rather than truncating the path.
    const temporary = env.getPosix("TMPDIR") orelse env.getPosix("TMP") orelse env.getPosix("TEMP") orelse "/tmp";
    const runtime = if (builtin.os.tag == .macos) temporary else env.getPosix("XDG_RUNTIME_DIR") orelse temporary;
    const base = if (runtime.len == 0) "/tmp" else runtime;
    const prefix = try std.fs.path.join(allocator, &.{ base, "vscode-ipc-" });
    defer allocator.free(prefix);
    const limit: usize = if (builtin.os.tag == .macos) 103 else 107;
    const available = (limit - 1) -| (prefix.len + ".sock".len);
    if (available == 0) return error.EndpointPathTooLong;
    return std.fmt.allocPrint(allocator, "{s}{s}.sock", .{ prefix, uuid[0..@min(uuid.len, available)] });
}

pub const Server = struct {
    allocator: Allocator,
    path: []u8,
    listener: if (windows) win.Listener else Io.net.Server,

    pub fn listen(allocator: Allocator, io: Io, env: std.process.Environ) !Server {
        const path = try createRandomIPCHandle(allocator, io, env);
        errdefer allocator.free(path);
        const listener = if (windows)
            try win.Listener.listen(path, allocator)
        else blk: {
            const address = try Io.net.UnixAddress.init(path);
            break :blk try address.listen(io, .{});
        };
        return .{ .allocator = allocator, .path = path, .listener = listener };
    }

    pub fn accept(self: *Server, io: Io, timeout_ms: u32) !Connection {
        if (windows) return .{ .stream = try self.listener.accept(timeout_ms) };
        var poll_fds = [_]std.posix.pollfd{.{ .fd = self.listener.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&poll_fds, @intCast(timeout_ms)) == 0) return error.Timeout;
        return .{ .stream = try self.listener.accept(io) };
    }

    pub fn deinit(self: *Server, io: Io) void {
        if (windows) self.listener.close() else {
            self.listener.deinit(io);
            Io.Dir.cwd().deleteFile(io, self.path) catch {};
        }
        self.allocator.free(self.path);
    }
};

pub const Connection = struct {
    stream: if (windows) win.Pipe else Io.net.Stream,

    pub fn connect(allocator: Allocator, io: Io, path: []const u8) !Connection {
        if (windows) return .{ .stream = try win.Pipe.connect(path, allocator) };
        const address = try Io.net.UnixAddress.init(path);
        return .{ .stream = try address.connect(io) };
    }

    pub fn read(self: Connection, io: Io, buffer: []u8) !usize {
        if (windows) return self.stream.read(buffer);
        var iovec = [_][]u8{buffer};
        // The control-data variant also works with Zig 0.17's ReadResult.
        var control: [0]u8 = undefined;
        return (try self.stream.readWithControl(io, &iovec, &control)).data_len;
    }

    pub fn writeAll(self: Connection, io: Io, bytes: []const u8) !void {
        if (windows) return self.stream.writeAll(bytes);
        var buffer: [4096]u8 = undefined;
        var writer = self.stream.writer(io, &buffer);
        try writer.interface.writeAll(bytes);
        try writer.interface.flush();
    }

    /// Wake a blocked read before the owner joins its reader thread.
    pub fn shutdown(self: Connection, io: Io) void {
        if (windows) self.stream.shutdown() else self.stream.shutdown(io, .both) catch {};
    }

    pub fn close(self: Connection, io: Io) void {
        if (windows) self.stream.close() else self.stream.close(io);
    }
};
