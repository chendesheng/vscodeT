const std = @import("std");
const io = std.io;
const fs = std.fs;

var loggerFile: ?fs.File = null;

pub fn format(comptime fmt: []const u8, args: anytype) void {
    if (loggerFile) |file| {
        std.fmt.format(file.writer(), fmt, args) catch {};
    }
}

pub fn writer() ?fs.File.Writer {
    if (loggerFile) |file| {
        return file.writer();
    }
    return null;
}

pub fn write(text: []const u8) void {
    if (loggerFile) |file| {
        _ = file.write(text) catch {};
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
