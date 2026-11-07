const std = @import("std");
const Io = std.Io;

var io_instance: ?Io = null;
var loggerFile: ?Io.File = null;
var loggerWriter: ?Io.File.Writer = null;
var writer_buffer: [4096]u8 = undefined;

pub fn format(comptime fmt: []const u8, args: anytype) void {
    if (loggerWriter) |*w| {
        w.interface.print(fmt, args) catch {};
    }
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    format(fmt, args);
}

pub fn writer() ?*Io.Writer {
    if (loggerWriter) |*w| {
        return &w.interface;
    }
    return null;
}

pub fn write(text: []const u8) void {
    if (loggerWriter) |*w| {
        w.interface.writeAll(text) catch {};
    }
}

pub fn openLoggerFile(io: Io, filepath: []const u8) !Io.File {
    const dir = Io.Dir.cwd();
    return dir.openFile(io, filepath, .{
        .mode = .write_only,
    }) catch dir.createFile(io, filepath, .{});
}

pub fn init(io: Io, filepath: []const u8) !void {
    const file = try openLoggerFile(io, filepath);

    io_instance = io;
    loggerFile = file;
    loggerWriter = .init(file, io, &writer_buffer);
    try loggerWriter.?.end();
}

pub fn deinit() void {
    if (loggerWriter) |*w| {
        w.interface.flush() catch {};
    }
    loggerWriter = null;

    if (io_instance) |io| {
        if (loggerFile) |file| file.close(io);
    }
    loggerFile = null;
    io_instance = null;
}
