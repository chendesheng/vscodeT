// Terminal-only POSIX PTY host.
//
// This replaces the node-pty / pty-host boundary of VS Code's terminal
// (`src/vs/platform/terminal/node/ptyService.ts` and `terminalProcess.ts`).
// It is deliberately small: one forkpty child per terminal, a non-blocking
// master fd, a bounded input/output queue, resize ioctls and process reaping.
// Windows ConPTY is not implemented; the exported entry points return
// `error.UnsupportedPlatform` there so the rest of the TUI still compiles.
//
// The child executes only async-signal-safe operations after fork (chdir,
// execve, _exit); argv/envp and their strings are fully built before fork.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const is_windows = builtin.os.tag == .windows;

pub const is_supported = !is_windows;

pub const EnvVar = struct {
    key: []const u8,
    /// `null` removes the key from the inherited environment.
    value: ?[]const u8,
};

pub const SpawnOptions = struct {
    /// Absolute executable path.
    executable: []const u8,
    /// Arguments after argv[0]. argv[0] is the executable path.
    args: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    env: []const EnvVar = &.{},
    inherit_env: bool = true,
    cols: u16 = 80,
    rows: u16 = 24,
};

pub const Size = struct {
    cols: u16,
    rows: u16,
};

/// Result of reaping the child.
pub const Exit = struct {
    code: ?i32 = null,
    signal: ?i32 = null,
};

pub const ProcessError = error{
    UnsupportedPlatform,
    PtyOpenFailed,
    WriteFailed,
    ReadFailed,
};

/// The maximum amount of pending input we buffer for a terminal. A paste or a
/// program that stops reading cannot grow this without bound.
pub const max_pending_write: usize = 1024 * 1024;

pub const PtyProcess = struct {
    allocator: Allocator,
    master: posix.fd_t,
    pid: posix.pid_t,
    pending: std.array_list.Managed(u8),
    exit: ?Exit = null,
    master_open: bool = true,
    exit_fd: posix.fd_t,
    exit_waiter: ?std.Thread = null,

    pub fn spawn(allocator: Allocator, options: SpawnOptions) !PtyProcess {
        if (comptime is_windows) return error.UnsupportedPlatform;
        return spawnPosix(allocator, options);
    }

    fn spawnPosix(allocator: Allocator, options: SpawnOptions) !PtyProcess {
        if (!builtin.link_libc) @compileError("the PTY host requires libc");
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const scratch = arena.allocator();

        const executable_z = try dupeZ(scratch, options.executable);
        const argv = try scratch.allocSentinel(?[*:0]const u8, options.args.len + 1, null);
        argv[0] = executable_z.ptr;
        for (options.args, 0..) |arg, index| {
            const arg_z = try dupeZ(scratch, arg);
            argv[index + 1] = arg_z.ptr;
        }

        const envp = try buildEnviron(scratch, options.env, options.inherit_env);
        const cwd_z = if (options.cwd) |cwd| try dupeZ(scratch, cwd) else null;

        var master: c_int = -1;
        var window = posix.winsize{
            .row = options.rows,
            .col = options.cols,
            .xpixel = 0,
            .ypixel = 0,
        };
        const pid = forkpty(&master, null, null, &window);
        if (pid < 0) return error.PtyOpenFailed;

        if (pid == 0) {
            // Child: only async-signal-safe calls from here.
            if (cwd_z) |cwd| {
                if (std.c.chdir(cwd.ptr) != 0) std.c._exit(1);
            }
            _ = std.c.execve(executable_z.ptr, argv.ptr, envp.ptr);
            std.c._exit(127);
        }

        const master_fd: posix.fd_t = @intCast(master);
        errdefer {
            _ = std.c.close(master_fd);
            _ = std.c.kill(pid, .KILL);
            _ = reapChild(pid);
        }
        try setNonBlocking(master_fd);
        const monitor = try monitorExit(pid);
        return .{
            .allocator = allocator,
            .master = master_fd,
            .exit_fd = monitor.fd,
            .exit_waiter = monitor.waiter,
            .pid = @intCast(pid),
            .pending = std.array_list.Managed(u8).init(allocator),
        };
    }

    pub fn deinit(self: *PtyProcess) void {
        self.pending.deinit();
        if (comptime is_windows) return;
        self.closeMaster();
        if (self.exit == null) {
            self.signal(posix.SIG.HUP);
            if (!self.waitForExit(100)) {
                self.signal(posix.SIG.KILL);
                _ = std.c.kill(self.pid, .KILL);
            }
            _ = self.reap();
        }
        _ = std.c.close(self.exit_fd);
    }

    pub fn fd(self: *const PtyProcess) ?posix.fd_t {
        if (comptime is_windows) return null;
        if (!self.master_open) return null;
        return self.master;
    }

    /// Reads available bytes. Returns 0 both for EAGAIN and EOF; EOF is
    /// signalled separately through the process-exit descriptor.
    pub fn read(self: *PtyProcess, buffer: []u8) !usize {
        if (comptime is_windows) return error.UnsupportedPlatform;
        if (!self.master_open or buffer.len == 0) return 0;
        const n = posix.read(self.master, buffer) catch |err| switch (err) {
            error.WouldBlock => return 0,
            error.InputOutput, error.ConnectionResetByPeer => {
                self.closeMaster();
                return 0;
            },
            else => return err,
        };
        if (n == 0) self.closeMaster();
        return n;
    }

    /// Queues bytes for the shell. They are flushed immediately when possible;
    /// call `flush` again when the master is writable.
    pub fn write(self: *PtyProcess, bytes: []const u8) !void {
        if (comptime is_windows) return error.UnsupportedPlatform;
        if (bytes.len == 0) return;
        if (self.exit != null or !self.master_open) return;
        if (self.pending.items.len + bytes.len > max_pending_write) return error.WriteFailed;
        try self.pending.appendSlice(bytes);
        try self.flush();
    }

    pub fn hasPendingWrite(self: *const PtyProcess) bool {
        if (comptime is_windows) return false;
        return self.pending.items.len != 0;
    }

    /// Writes as much of the pending queue as the master accepts.
    pub fn flush(self: *PtyProcess) !void {
        if (comptime is_windows) return error.UnsupportedPlatform;
        if (!self.master_open) {
            self.pending.clearRetainingCapacity();
            return;
        }
        while (self.pending.items.len > 0) {
            const rc = std.c.write(self.master, self.pending.items.ptr, self.pending.items.len);
            if (rc < 0) {
                switch (std.c.errno(rc)) {
                    .INTR => continue,
                    .AGAIN => return,
                    .PIPE, .IO, .CONNRESET => {
                        self.pending.clearRetainingCapacity();
                        return;
                    },
                    else => return error.WriteFailed,
                }
            }
            const written: usize = @intCast(rc);
            if (written == 0) return;
            const remaining = self.pending.items.len - written;
            std.mem.copyForwards(u8, self.pending.items[0..remaining], self.pending.items[written..]);
            self.pending.items.len = remaining;
        }
    }

    pub fn resize(self: *PtyProcess, cols: u16, rows: u16) !void {
        if (comptime is_windows) return error.UnsupportedPlatform;
        if (!self.master_open) return;
        var window = posix.winsize{
            .row = rows,
            .col = cols,
            .xpixel = 0,
            .ypixel = 0,
        };
        const rc = std.c.ioctl(self.master, winsizeRequest(), @intFromPtr(&window));
        if (rc != 0) return error.WriteFailed;
    }

    /// Sends a signal to the child's process group (forkpty made it the
    /// session leader, so the shell and its foreground children are covered).
    pub fn signal(self: *PtyProcess, sig: posix.SIG) void {
        if (comptime is_windows) return;
        _ = std.c.kill(-self.pid, sig);
    }

    pub fn waitForExit(self: *const PtyProcess, timeout_ms: i32) bool {
        if (comptime is_windows) return false;
        var fds = [_]posix.pollfd{.{ .fd = self.exit_fd, .events = posix.POLL.IN, .revents = 0 }};
        return (posix.poll(&fds, timeout_ms) catch return false) != 0;
    }

    /// Called after the exit descriptor becomes ready, or after termination.
    pub fn reap(self: *PtyProcess) Exit {
        if (comptime is_windows) return .{};
        if (self.exit == null) {
            if (self.exit_waiter) |waiter| waiter.join();
            self.exit = reapChild(self.pid);
        }
        return self.exit.?;
    }

    pub fn closeMaster(self: *PtyProcess) void {
        if (comptime is_windows) return;
        if (!self.master_open) return;
        _ = std.c.close(self.master);
        self.master_open = false;
    }
};

fn buildEnviron(
    scratch: Allocator,
    overrides: []const EnvVar,
    inherit: bool,
) ![:null]const ?[*:0]const u8 {
    var values: std.array_list.Managed(?[*:0]const u8) = .init(scratch);
    if (inherit) {
        const environ = std.mem.span(std.c.environ);
        var deleted = std.StringHashMapUnmanaged(void).empty;
        for (overrides) |entry| {
            if (entry.value == null) {
                try deleted.put(scratch, entry.key, {});
            }
        }
        for (environ) |maybe_entry| {
            const entry = maybe_entry orelse continue;
            const bytes = std.mem.span(entry);
            const equals = std.mem.indexOfScalar(u8, bytes, '=') orelse continue;
            const key = bytes[0..equals];
            if (isOverridden(overrides, key) or deleted.contains(key)) continue;
            try values.append(entry);
        }
    }
    for (overrides) |entry| {
        const value = entry.value orelse continue;
        const joined = try std.fmt.allocPrint(scratch, "{s}={s}", .{ entry.key, value });
        const joined_z = try dupeZ(scratch, joined);
        try values.append(joined_z.ptr);
    }
    try values.append(null);
    const slice = try values.toOwnedSlice();
    const sentinel = try scratch.allocSentinel(?[*:0]const u8, slice.len - 1, null);
    @memcpy(sentinel, slice[0 .. slice.len - 1]);
    return sentinel;
}

fn isOverridden(overrides: []const EnvVar, key: []const u8) bool {
    for (overrides) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return true;
    }
    return false;
}

fn parseStatus(status: c_int) Exit {
    const signal_number = status & 0x7f;
    if (signal_number == 0) {
        return .{ .code = (status >> 8) & 0xff };
    }
    return .{ .signal = signal_number };
}

extern "c" fn minecode_process_exit_fd(pid: posix.pid_t) c_int;

fn monitorExit(pid: posix.pid_t) !struct { fd: posix.fd_t, waiter: ?std.Thread = null } {
    switch (builtin.os.tag) {
        .macos, .freebsd, .netbsd, .openbsd, .dragonfly => {
            const fd = minecode_process_exit_fd(pid);
            if (fd < 0) return error.ProcessMonitorFailed;
            return .{ .fd = fd };
        },
        .linux => {
            const fd = std.os.linux.pidfd_open(pid, 0);
            switch (std.os.linux.errno(fd)) {
                .SUCCESS => return .{ .fd = @intCast(fd) },
                .NOSYS, .PERM, .ACCES => {},
                else => return error.ProcessMonitorFailed,
            }
        },
        else => {},
    }
    // Older Linux kernels and other POSIX hosts expose waitid through a
    // descriptor using one sleeping waiter. Only the owner reaps the child.
    var wake: [2]posix.fd_t = undefined;
    if (std.c.pipe(&wake) != 0) return error.PtyOpenFailed;
    errdefer for (wake) |descriptor| {
        _ = std.c.close(descriptor);
    };
    for (wake) |descriptor| {
        if (std.c.fcntl(descriptor, posix.F.SETFD, @as(c_int, posix.FD_CLOEXEC)) < 0) return error.PtyOpenFailed;
    }
    const waiter = try std.Thread.spawn(.{}, waitForProcessExit, .{ pid, wake[1] });
    return .{ .fd = wake[0], .waiter = waiter };
}

extern "c" fn minecode_wait_for_process_exit(pid: posix.pid_t, wake_fd: c_int) void;

fn waitForProcessExit(pid: posix.pid_t, wake_fd: c_int) void {
    minecode_wait_for_process_exit(pid, wake_fd);
}

fn reapChild(pid: posix.pid_t) Exit {
    var status: c_int = 0;
    while (true) {
        const result = std.c.waitpid(pid, &status, 0);
        if (result >= 0) return parseStatus(status);
        if (std.c.errno(result) != .INTR) return .{};
    }
}

fn setNonBlocking(fd: posix.fd_t) !void {
    const current = std.c.fcntl(fd, posix.F.GETFL);
    if (current < 0) return error.PtyOpenFailed;
    const bits: u32 = @intCast(current);
    var flags: posix.O = @bitCast(bits);
    flags.NONBLOCK = true;
    const updated: u32 = @bitCast(flags);
    const rc = std.c.fcntl(fd, posix.F.SETFL, @as(c_int, @bitCast(updated)));
    if (rc < 0) return error.PtyOpenFailed;
}

fn winsizeRequest() c_int {
    return switch (builtin.os.tag) {
        .macos => @bitCast(@as(u32, 0x80087467)),
        else => @intCast(posix.T.IOCSWINSZ),
    };
}

fn dupeZ(allocator: Allocator, bytes: []const u8) ![:0]u8 {
    const result = try allocator.allocSentinel(u8, bytes.len, 0);
    @memcpy(result, bytes);
    return result;
}

extern "c" fn forkpty(
    amaster: *c_int,
    name: ?[*]u8,
    termp: ?*const anyopaque,
    winp: ?*const posix.winsize,
) c_int;

test "pty: build an explicit environment" {
    if (comptime is_windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const envp = try buildEnviron(arena.allocator(), &.{
        .{ .key = "TERM", .value = "xterm-256color" },
        .{ .key = "REMOVED", .value = null },
    }, false);
    try std.testing.expectEqualStrings("TERM=xterm-256color", std.mem.span(envp[0].?));
    try std.testing.expect(envp[1] == null);
}

test "pty: parse wait status" {
    try std.testing.expectEqual(@as(?i32, 7), parseStatus(7 << 8).code);
    try std.testing.expectEqual(@as(?i32, 15), parseStatus(15).signal);
}

test "pty: spawn a shell, read output, resize and reap" {
    if (comptime is_windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var process = PtyProcess.spawn(allocator, .{
        .executable = "/bin/sh",
        .args = &.{ "-c", "printf 'pty-hello\\r\\n'; stty size" },
        .cols = 40,
        .rows = 12,
        .env = &.{
            .{ .key = "TERM", .value = "xterm-256color" },
        },
    }) catch |err| switch (err) {
        // Some CI sandboxes do not expose /dev/ptmx to unprivileged tests.
        error.PtyOpenFailed => return error.SkipZigTest,
        else => return err,
    };
    defer process.deinit();

    var output: std.array_list.Managed(u8) = .init(allocator);
    defer output.deinit();
    var buffer: [4096]u8 = undefined;
    var fds = [_]posix.pollfd{
        .{ .fd = process.master, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = process.exit_fd, .events = posix.POLL.IN, .revents = 0 },
    };
    while (process.exit == null) {
        try std.testing.expect(try posix.poll(&fds, 5000) != 0);
        if (fds[0].revents != 0 or fds[1].revents != 0) {
            while (true) {
                const n = try process.read(&buffer);
                if (n == 0) break;
                try output.appendSlice(buffer[0..n]);
            }
            fds[0].fd = process.fd() orelse -1;
        }
        if (fds[1].revents != 0) _ = process.reap();
    }
    try std.testing.expect(process.exit != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "pty-hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "12 40") != null);
}
