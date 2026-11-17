// Terminal disk-backed subset of `src/vs/platform/files/common/fileService.ts`.
// The full provider/event/etag machinery is not ported; this service exposes
// synchronous path operations used by the terminal editor/file plumbing.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const files = @import("./files.zig");
const buffer_mod = @import("../../../base/common/buffer.zig");
const VSBuffer = buffer_mod.VSBuffer;

pub const DiskFileService = struct {
    allocator: Allocator,
    io: Io,

    pub fn init(allocator: Allocator, io: Io) DiskFileService {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn exists(self: *DiskFileService, path: []const u8) bool {
        _ = Io.Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = false }) catch return false;
        return true;
    }

    pub fn stat(self: *DiskFileService, path: []const u8) !files.FileStat {
        const info = try Io.Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = false });
        const type_flags: u8 = switch (info.kind) {
            .file => files.FileType.File,
            .directory => files.FileType.Directory,
            .sym_link => files.FileType.SymbolicLink,
            else => files.FileType.Unknown,
        };
        return .{
            .resource = path,
            .name = std.fs.path.basename(path),
            .type = type_flags,
            .size = info.size,
        };
    }

    pub fn readFile(self: *DiskFileService, path: []const u8) !VSBuffer {
        const bytes = try Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .unlimited);
        return .{ .bytes = bytes };
    }

    pub fn writeFile(self: *DiskFileService, path: []const u8, data: VSBuffer) !void {
        try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = data.bytes });
    }

    pub fn deleteFile(self: *DiskFileService, path: []const u8) !void {
        try Io.Dir.cwd().deleteFile(self.io, path);
    }

    pub fn rename(self: *DiskFileService, from: []const u8, to: []const u8) !void {
        try Io.Dir.renameAbsolute(from, to, self.io);
    }

    pub fn copy(self: *DiskFileService, from: []const u8, to: []const u8) !void {
        var data = try self.readFile(from);
        defer data.deinit(self.allocator);
        try self.writeFile(to, data);
    }
};

test "DiskFileService reads, writes, stats and removes files" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buffer);
    const root = path_buffer[0..root_len];
    const path = try std.fs.path.join(allocator, &.{ root, "hello.txt" });
    defer allocator.free(path);
    const copy_path = try std.fs.path.join(allocator, &.{ root, "copy.txt" });
    defer allocator.free(copy_path);

    var service = DiskFileService.init(allocator, io);
    try std.testing.expect(!service.exists(path));
    var data = try VSBuffer.fromString(allocator, "hello");
    defer data.deinit(allocator);
    try service.writeFile(path, data);
    try std.testing.expect(service.exists(path));
    const stat = try service.stat(path);
    try std.testing.expect(stat.isFile());
    try std.testing.expectEqual(@as(u64, 5), stat.size);

    var read = try service.readFile(path);
    defer read.deinit(allocator);
    const text = try read.toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("hello", text);

    try service.copy(path, copy_path);
    try std.testing.expect(service.exists(copy_path));
    try service.rename(copy_path, path);
    try service.deleteFile(path);
    try std.testing.expect(!service.exists(path));
}

test "DiskFileService reports missing files" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var service = DiskFileService.init(allocator, io);
    try std.testing.expectError(error.FileNotFound, service.stat("/definitely/not/here"));
}
