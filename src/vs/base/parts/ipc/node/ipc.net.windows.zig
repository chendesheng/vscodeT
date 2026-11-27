// Native Windows adapter for the named-pipe branch of `ipc.net.ts`.
// Node's net.createConnection uses a duplex, byte-mode Win32 named pipe.
// Overlapped operations have independent events (one reader and one writer),
// and a shared shutdown event releases pending operations before handles close.
const std = @import("std");
const w = std.os.windows;
const HANDLE = w.HANDLE;
const BOOL = w.BOOL;
const DWORD = w.DWORD;
const infinite: DWORD = 0xffffffff;
const wait_timeout: DWORD = 258;
const overlapped_flag: DWORD = 0x40000000;
const pipe_access_duplex: DWORD = 3;
const first_pipe_instance: DWORD = 0x00080000;
const pipe_reject_remote_clients: DWORD = 8;
const generic_read_write: DWORD = 0xc0000000;
const open_existing: DWORD = 3;

const Overlapped = extern struct {
    internal: usize = 0,
    internal_high: usize = 0,
    offset: u32 = 0,
    offset_high: u32 = 0,
    h_event: ?HANDLE = null,
};

extern "kernel32" fn CreateNamedPipeW([*:0]const u16, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, ?*anyopaque) callconv(.winapi) HANDLE;
extern "kernel32" fn ConnectNamedPipe(HANDLE, *Overlapped) callconv(.winapi) BOOL;
extern "kernel32" fn CreateFileW([*:0]const u16, DWORD, DWORD, ?*anyopaque, DWORD, DWORD, ?HANDLE) callconv(.winapi) HANDLE;
extern "kernel32" fn CreateEventW(?*anyopaque, BOOL, BOOL, ?[*:0]const u16) callconv(.winapi) ?HANDLE;
extern "kernel32" fn SetEvent(HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(HANDLE, DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn WaitForMultipleObjects(DWORD, [*]const HANDLE, BOOL, DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn ReadFile(HANDLE, [*]u8, DWORD, ?*DWORD, *Overlapped) callconv(.winapi) BOOL;
extern "kernel32" fn WriteFile(HANDLE, [*]const u8, DWORD, ?*DWORD, *Overlapped) callconv(.winapi) BOOL;
extern "kernel32" fn GetOverlappedResult(HANDLE, *Overlapped, *DWORD, BOOL) callconv(.winapi) BOOL;
extern "kernel32" fn CancelIoEx(HANDLE, ?*Overlapped) callconv(.winapi) BOOL;

fn event() !HANDLE {
    return CreateEventW(null, .TRUE, .FALSE, null) orelse error.EventCreationFailed;
}

fn cancelAndJoin(handle: HANDLE, operation: *Overlapped) void {
    _ = CancelIoEx(handle, operation);
    var transferred: DWORD = 0;
    // Even cancellation is asynchronous: never release the OVERLAPPED or its
    // borrowed buffer until the kernel has acknowledged completion.
    _ = GetOverlappedResult(handle, operation, &transferred, .TRUE);
}

pub const Listener = struct {
    handle: ?HANDLE,

    pub fn listen(path: []const u8, allocator: std.mem.Allocator) !Listener {
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
        defer allocator.free(wide);
        const handle = CreateNamedPipeW(wide, pipe_access_duplex | overlapped_flag | first_pipe_instance, pipe_reject_remote_clients, 1, 64 * 1024, 64 * 1024, 0, null);
        if (handle == w.INVALID_HANDLE_VALUE) return error.PipeCreationFailed;
        return .{ .handle = handle };
    }

    pub fn accept(self: *Listener, timeout_ms: u32) !Pipe {
        const handle = self.handle orelse return error.ListenerClosed;
        const stop = try event();
        errdefer w.CloseHandle(stop);
        const ready = try event();
        defer w.CloseHandle(ready);
        var operation: Overlapped = .{ .h_event = ready };
        if (!ConnectNamedPipe(handle, &operation).toBool()) switch (w.GetLastError()) {
            .PIPE_CONNECTED => {}, // client won the race before ConnectNamedPipe
            .IO_PENDING => {
                const result = WaitForSingleObject(ready, timeout_ms);
                if (result != 0) {
                    cancelAndJoin(handle, &operation);
                    return if (result == wait_timeout) error.Timeout else error.PipeConnectFailed;
                }
                var transferred: DWORD = 0;
                if (!GetOverlappedResult(handle, &operation, &transferred, .FALSE).toBool()) return error.PipeConnectFailed;
            },
            else => return error.PipeConnectFailed,
        };
        self.handle = null;
        return .{ .handle = handle, .stop = stop };
    }

    pub fn close(self: *Listener) void {
        if (self.handle) |handle| w.CloseHandle(handle);
        self.handle = null;
    }
};

pub const Pipe = struct {
    handle: HANDLE,
    stop: HANDLE,

    // Client side used by native interop tests; the production child uses
    // Node.js net.createConnection with the same endpoint.
    pub fn connect(path: []const u8, allocator: std.mem.Allocator) !Pipe {
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
        defer allocator.free(wide);
        const handle = CreateFileW(wide, generic_read_write, 0, null, open_existing, overlapped_flag, null);
        if (handle == w.INVALID_HANDLE_VALUE) return error.PipeConnectFailed;
        errdefer w.CloseHandle(handle);
        return .{ .handle = handle, .stop = try event() };
    }

    fn closed(err: w.Win32Error) bool {
        return switch (err) {
            .BROKEN_PIPE, .NO_DATA, .PIPE_NOT_CONNECTED, .OPERATION_ABORTED => true,
            else => false,
        };
    }

    fn transfer(self: Pipe, buffer: anytype, comptime writing: bool) !usize {
        if (buffer.len == 0) return 0;
        if (WaitForSingleObject(self.stop, 0) == 0) return 0;
        const ready = try event();
        defer w.CloseHandle(ready);
        var operation: Overlapped = .{ .h_event = ready };
        const length: DWORD = @intCast(@min(buffer.len, std.math.maxInt(DWORD)));
        const ok = if (writing)
            WriteFile(self.handle, buffer.ptr, length, null, &operation)
        else
            ReadFile(self.handle, buffer.ptr, length, null, &operation);
        if (!ok.toBool()) {
            const err = w.GetLastError();
            if (err != .IO_PENDING) return if (closed(err)) 0 else error.PipeIoFailed;
            const handles = [_]HANDLE{ ready, self.stop };
            if (WaitForMultipleObjects(handles.len, &handles, .FALSE, infinite) != 0) {
                cancelAndJoin(self.handle, &operation);
                return 0;
            }
        }
        var transferred: DWORD = 0;
        if (!GetOverlappedResult(self.handle, &operation, &transferred, .FALSE).toBool()) {
            return if (closed(w.GetLastError())) 0 else error.PipeIoFailed;
        }
        return transferred;
    }

    pub fn read(self: Pipe, buffer: []u8) !usize {
        return self.transfer(buffer, false);
    }

    pub fn writeAll(self: Pipe, bytes: []const u8) !void {
        var remaining = bytes;
        while (remaining.len != 0) {
            const n = try self.transfer(remaining, true);
            if (n == 0) return error.BrokenPipe;
            remaining = remaining[n..];
        }
    }

    pub fn shutdown(self: Pipe) void {
        _ = SetEvent(self.stop);
    }

    pub fn close(self: Pipe) void {
        w.CloseHandle(self.handle);
        w.CloseHandle(self.stop);
    }
};
