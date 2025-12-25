const std = @import("std");
const io = std.io;
const fs = std.fs;

var loggerFile: ?fs.File = null;

pub fn format(comptime fmt: []const u8, args: anytype) void {
    if (loggerFile) |file| {
        var buf: [1024]u8 = undefined;
        var w = file.writer(&buf);
        w.interface.print(fmt, args) catch {};
        w.interface.flush() catch {};
    }
}

pub fn openLoggerFile(filepath: []const u8) !fs.File {
    const file = std.fs.cwd().openFile(filepath, .{
        .mode = .write_only,
    }) catch blk: {
        // If file doesn't exist, create it
        break :blk try std.fs.cwd().createFile(filepath, .{});
    };
    try file.seekFromEnd(0);
    return file;
}

pub fn init(filepath: []const u8) !void {
    loggerFile = try openLoggerFile(filepath);
}

pub fn deinit() void {
    if (loggerFile) |file| {
        file.close();
    }
}
