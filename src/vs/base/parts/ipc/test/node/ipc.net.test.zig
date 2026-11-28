// Port of the local stream and random endpoint cases from
// `src/vs/base/parts/ipc/test/node/ipc.net.test.ts`. Electron persistent
// protocol/WebSocket cases belong to their separate, unported owners.
const std = @import("std");
const builtin = @import("builtin");
const ipc = @import("../../node/ipc.net.zig");
const testing = std.testing;
const Io = std.Io;
const ProtocolWriter = @import("../../common/ipc.net.zig").ProtocolWriter;

test "IPC: randomized local endpoint accepts a duplex stream" {
    const io = testing.io;
    const allocator = testing.allocator;
    var server = try ipc.Server.listen(allocator, io, .empty);
    defer server.deinit(io);
    const other = try ipc.createRandomIPCHandle(allocator, io, .empty);
    defer allocator.free(other);
    try testing.expect(!std.mem.eql(u8, server.path, other));
    if (builtin.os.tag == .windows) {
        try testing.expect(std.mem.startsWith(u8, server.path, "\\\\.\\pipe\\vscode-ipc-"));
    } else {
        try testing.expect(std.mem.startsWith(u8, server.path, "/tmp/vscode-ipc-"));
    }
    // The peer connects before accept: Windows reports ERROR_PIPE_CONNECTED
    // in this race, which still establishes the very same duplex connection.
    const peer = try ipc.Connection.connect(allocator, io, server.path);
    defer peer.close(io);
    const connection = try server.accept(io, 2000);
    defer connection.close(io);
    try connection.writeAll(io, "request");
    var request: [7]u8 = undefined;
    try readAll(peer, io, &request);
    try testing.expectEqualStrings("request", &request);
    try peer.writeAll(io, "reply");
    var reply: [5]u8 = undefined;
    try readAll(connection, io, &reply);
    try testing.expectEqualStrings("reply", &reply);
}

test "IPC: listener times out without a peer" {
    var server = try ipc.Server.listen(testing.allocator, testing.io, .empty);
    defer server.deinit(testing.io);
    try testing.expectError(error.Timeout, server.accept(testing.io, 5));
}

test "IPC: pending read joins after shutdown" {
    const io = testing.io;
    var server = try ipc.Server.listen(testing.allocator, io, .empty);
    defer server.deinit(io);
    const peer = try ipc.Connection.connect(testing.allocator, io, server.path);
    defer peer.close(io);
    const connection = try server.accept(io, 2000);
    defer connection.close(io);
    const Reader = struct {
        connection: ipc.Connection,
        io: std.Io,
        entered: std.Io.Event = .unset,
        result: anyerror!usize = error.NotRun,
        fn run(self: *@This()) void {
            var byte: [1]u8 = undefined;
            self.entered.set(self.io);
            self.result = self.connection.read(self.io, &byte);
        }
    };
    var reader: Reader = .{ .connection = connection, .io = io };
    const thread = try std.Thread.spawn(.{}, Reader.run, .{&reader});
    reader.entered.wait(io) catch |err| {
        connection.shutdown(io);
        thread.join();
        return err;
    };
    connection.shutdown(io);
    thread.join();
    try testing.expectEqual(@as(usize, 0), try reader.result);
}

fn readAll(connection: ipc.Connection, io: std.Io, bytes: []u8) !void {
    var remaining = bytes;
    while (remaining.len != 0) {
        const n = try connection.read(io, remaining);
        if (n == 0) return error.EndOfStream;
        remaining = remaining[n..];
    }
}

test "ProtocolWriter: a stalled transport does not block the producer and frames remain ordered" {
    const Probe = struct {
        io: Io,
        entered: Io.Event = .unset,
        release: Io.Event = .unset,
        finished: Io.Event = .unset,
        bytes: [6]u8 = undefined,
        len: usize = 0,
        failed: bool = false,

        fn write(context: *anyopaque, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.entered.set(self.io);
            self.release.waitUncancelable(self.io);
            @memcpy(self.bytes[self.len..][0..bytes.len], bytes);
            self.len += bytes.len;
            if (self.len == self.bytes.len) self.finished.set(self.io);
        }

        fn failure(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.failed = true;
        }
    };
    const io = std.testing.io;
    var probe: Probe = .{ .io = io };
    var writer: ProtocolWriter = .{ .allocator = std.testing.allocator, .io = io, .sink = .{ .context = &probe, .write = Probe.write, .failed = Probe.failure } };
    try writer.start();
    defer writer.deinit();
    defer probe.release.set(io);
    var first = [_]u8{ 'a', 'b' };
    try writer.write("1", &first);
    probe.entered.waitUncancelable(io);
    first[0] = 'x';
    try writer.write("2", "cd");
    probe.release.set(io);
    probe.finished.waitUncancelable(io);
    writer.flush(.{ .duration = .{ .raw = .fromMilliseconds(1000), .clock = .awake } });
    try std.testing.expect(writer.drained.isSet());
    try std.testing.expectEqualStrings("1ab2cd", &probe.bytes);
    try std.testing.expect(!probe.failed);
}
