// Native wakeup for callbacks queued from worker threads while the terminal
// is waiting for input. Multiple notifications may share one wakeup.
const std = @import("std");
const windows = std.os.windows;
const posix = std.posix;
const is_windows = @import("builtin").os.tag == .windows;

extern "kernel32" fn CreateEventW(attributes: ?*anyopaque, manual_reset: windows.BOOL, initial: windows.BOOL, name: ?[*:0]const u16) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn SetEvent(handle: windows.HANDLE) callconv(.winapi) windows.BOOL;

pub const Signal = struct {
    handles: if (is_windows) windows.HANDLE else [2]posix.fd_t,

    pub fn init() !Signal {
        if (is_windows) return .{ .handles = CreateEventW(null, .FALSE, .FALSE, null) orelse return error.WakeSignalFailed };
        var fds: [2]posix.fd_t = undefined;
        if (std.c.pipe(&fds) != 0) return error.WakeSignalFailed;
        errdefer for (fds) |fd| {
            _ = std.c.close(fd);
        };
        for (fds) |fd| {
            if (std.c.fcntl(fd, posix.F.SETFD, @as(c_int, posix.FD_CLOEXEC)) < 0) return error.WakeSignalFailed;
            const flags = std.c.fcntl(fd, posix.F.GETFL);
            if (flags < 0) return error.WakeSignalFailed;
            var options: posix.O = @bitCast(@as(u32, @intCast(flags)));
            options.NONBLOCK = true;
            if (std.c.fcntl(fd, posix.F.SETFL, @as(c_int, @bitCast(options))) < 0) return error.WakeSignalFailed;
        }
        return .{ .handles = fds };
    }

    pub fn deinit(self: Signal) void {
        if (is_windows) {
            _ = windows.CloseHandle(self.handles);
        } else for (self.handles) |fd| {
            _ = std.c.close(fd);
        }
    }

    pub fn notify(context: *anyopaque) void {
        const self: *Signal = @ptrCast(@alignCast(context));
        if (is_windows) {
            _ = SetEvent(self.handles);
        } else {
            while (std.c.errno(std.c.write(self.handles[1], "!", 1)) == .INTR) {}
        }
    }

    pub fn drain(self: Signal) void {
        if (is_windows) return; // WaitForMultipleObjects consumes the auto-reset event.
        var bytes: [256]u8 = undefined;
        while (true) {
            const n = std.c.read(self.handles[0], &bytes, bytes.len);
            if (n > 0) continue;
            if (std.c.errno(n) != .INTR) return;
        }
    }
};
