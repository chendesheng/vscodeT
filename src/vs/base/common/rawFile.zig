//! Raw blocking file reads for the 32-bit CheerpX/WebVM build.
//!
//! CheerpX's Linux syscall emulation does not service the gathered reads used
//! by `std.Io.Threaded`; opening a file through `Io.Dir.readFileAlloc` fails
//! with `error.Unexpected`. On i386 Linux this helper opens the path with
//! `openat(2)` and reads it with plain `read(2)`, which CheerpX implements.
//! Every other target keeps the normal Io implementation.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub fn readFileAlloc(
    allocator: Allocator,
    io: Io,
    path: []const u8,
    limit: Io.Limit,
) ![]u8 {
    if (comptime builtin.os.tag == .linux and builtin.cpu.arch == .x86) {
        return readRaw(allocator, path);
    }
    return Io.Dir.cwd().readFileAlloc(io, path, allocator, limit);
}

fn readRaw(allocator: Allocator, path: []const u8) ![]u8 {
    const fd = try std.posix.openat(
        std.posix.AT.FDCWD,
        path,
        .{ .ACCMODE = .RDONLY, .CLOEXEC = true },
        0,
    );
    defer _ = std.posix.system.close(fd);

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);

    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try std.posix.read(fd, &buffer);
        if (n == 0) break;
        try list.appendSlice(allocator, buffer[0..n]);
    }
    return list.toOwnedSlice(allocator);
}
