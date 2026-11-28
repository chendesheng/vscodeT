// Port of the buffered ProtocolWriter in `src/vs/base/parts/ipc/common/ipc.net.ts`.
// Native socket/pipe writes may block. The producer owns framing; this writer
// copies the frame into an ordered queue and an owned worker Io task drains it.
// Closing the underlying transport interrupts the detached writer before join.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const ProtocolWriter = struct {
    allocator: Allocator,
    io: Io,
    sink: Sink,
    mutex: Io.Mutex = .init,
    available: Io.Condition = .init,
    drained: Io.Event = .is_set,
    queue: std.ArrayList([]u8) = .empty,
    worker: ?Io.Future(void) = null,
    stopped: bool = false,

    pub const Sink = struct {
        context: *anyopaque,
        write: *const fn (*anyopaque, []const u8) anyerror!void,
        failed: *const fn (*anyopaque) void,
    };

    pub fn start(self: *ProtocolWriter) !void {
        self.worker = try self.io.concurrent(run, .{self});
    }

    /// Copies the producer's borrowed frame before returning. No transport
    /// I/O is performed on the caller's thread.
    pub fn write(self: *ProtocolWriter, header: []const u8, body: []const u8) !void {
        const bytes = try self.allocator.alloc(u8, try std.math.add(usize, header.len, body.len));
        errdefer self.allocator.free(bytes);
        @memcpy(bytes[0..header.len], header);
        @memcpy(bytes[header.len..], body);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stopped) return error.BrokenPipe;
        try self.queue.append(self.allocator, bytes);
        self.drained.reset();
        self.available.signal(self.io);
    }

    /// Used only during transport disposal. A failed or stalled peer cannot
    /// indefinitely hold the window on exit.
    pub fn flush(self: *ProtocolWriter, timeout: Io.Timeout) void {
        self.drained.waitTimeout(self.io, timeout) catch {};
    }

    /// No new frames may be submitted. A native transport shutdown then
    /// releases any in-flight write before deinit joins the thread.
    pub fn stop(self: *ProtocolWriter) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.stopped = true;
        self.drained.set(self.io);
        self.available.broadcast(self.io);
    }

    pub fn deinit(self: *ProtocolWriter) void {
        self.stop();
        if (self.worker) |*worker| worker.await(self.io);
        self.worker = null;
        for (self.queue.items) |bytes| self.allocator.free(bytes);
        self.queue.deinit(self.allocator);
    }

    fn take(self: *ProtocolWriter) ?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.queue.items.len == 0 and !self.stopped)
            self.available.waitUncancelable(self.io, &self.mutex);
        if (self.stopped) return null;
        return self.queue.orderedRemove(0);
    }

    fn run(self: *ProtocolWriter) void {
        while (self.take()) |bytes| {
            defer self.allocator.free(bytes);
            self.sink.write(self.sink.context, bytes) catch {
                self.stop();
                self.sink.failed(self.sink.context);
                return;
            };
            self.mutex.lockUncancelable(self.io);
            if (self.queue.items.len == 0) self.drained.set(self.io);
            self.mutex.unlock(self.io);
        }
    }
};
