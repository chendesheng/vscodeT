// Terminal subset of `src/vs/workbench/services/textfile/common/textFileService.ts`:
// text loads/saves through the disk file service. Working copies, encoding
// detection, auto-save and file-operation events are not ported.
const std = @import("std");
const Allocator = std.mem.Allocator;
const file_service = @import("../../../../platform/files/common/fileService.zig");
const buffer_mod = @import("../../../../base/common/buffer.zig");
const encoding_mod = @import("./encoding.zig");
const DiskFileService = file_service.DiskFileService;
const VSBuffer = buffer_mod.VSBuffer;

pub const ReadWithEncodingResult = struct {
    text: []u8,
    encoding: encoding_mod.Encoding,
};

pub const TextFileService = struct {
    allocator: Allocator,
    files: *DiskFileService,

    pub fn init(allocator: Allocator, files: *DiskFileService) TextFileService {
        return .{ .allocator = allocator, .files = files };
    }

    pub fn exists(self: *TextFileService, path: []const u8) bool {
        return self.files.exists(path);
    }

    /// Reads the file as UTF-8 text; the caller owns the returned bytes.
    pub fn read(self: *TextFileService, path: []const u8, allocator: Allocator) ![]u8 {
        var data = try self.files.readFile(path);
        defer data.deinit(self.allocator);
        return data.toString(allocator);
    }

    /// Reads text and detects its BOM encoding (UTF-8/UTF-16 LE/BE); content
    /// without a BOM is treated as UTF-8. The caller owns the returned text.
    pub fn readWithEncoding(self: *TextFileService, path: []const u8, allocator: Allocator) !ReadWithEncodingResult {
        var data = try self.files.readFile(path);
        defer data.deinit(self.allocator);
        const encoding = if (encoding_mod.detectBOM(data.bytes)) |bom| bom.encoding else .utf8;
        return .{
            .text = try encoding_mod.decode(allocator, data.bytes, encoding),
            .encoding = encoding,
        };
    }

    /// Encodes `text` with `encoding` (including a BOM for the BOM variants)
    /// and writes it, creating parent directories.
    pub fn writeWithEncoding(self: *TextFileService, path: []const u8, text: []const u8, encoding: encoding_mod.Encoding) !void {
        const bytes = try encoding_mod.encode(self.allocator, text, encoding);
        defer self.allocator.free(bytes);
        const data = VSBuffer{ .bytes = bytes };
        try self.files.writeFileEnsuringParents(path, data);
    }

    pub fn write(self: *TextFileService, path: []const u8, text: []const u8) !void {
        var data = try VSBuffer.fromString(self.allocator, text);
        defer data.deinit(self.allocator);
        try self.files.writeFileEnsuringParents(path, data);
    }
};

test "TextFileService reads and writes text files" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &buffer);
    const root = buffer[0..root_len];
    const path = try std.fs.path.join(allocator, &.{ root, "nested", "file.txt" });
    defer allocator.free(path);

    var files = DiskFileService.init(allocator, io);
    defer files.deinit();
    var text_file_service = TextFileService.init(allocator, &files);
    try std.testing.expect(!text_file_service.exists(path));
    try text_file_service.write(path, "hello\nworld");
    try std.testing.expect(text_file_service.exists(path));
    const text = try text_file_service.read(path, allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("hello\nworld", text);
}
