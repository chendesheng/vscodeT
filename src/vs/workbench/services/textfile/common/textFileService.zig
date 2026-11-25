// Terminal subset of `src/vs/workbench/services/textfile/common/textFileService.ts`:
// The terminal disk provider decodes BOM-tagged files and resolves editor inputs
// to filesystem paths. Browser streams and charset guessing are omitted.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const file_service = @import("../../../../platform/files/common/fileService.zig");
const buffer_mod = @import("../../../../base/common/buffer.zig");
const encoding_mod = @import("./encoding.zig");
const DiskFileService = file_service.DiskFileService;
const VSBuffer = buffer_mod.VSBuffer;

pub const ReadWithEncodingResult = struct {
    text: []u8,
    encoding: encoding_mod.Encoding,

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        allocator.free(self.text);
    }
};

/// Resolved editor input. The terminal document uses a canonical filesystem
/// path for its model URI. The caller owns the decoded text and the path.
pub const ResolvedTextFile = struct {
    text: []u8,
    encoding: encoding_mod.Encoding,
    absolute_path: []u8,

    pub fn deinit(self: *ResolvedTextFile, allocator: Allocator) void {
        allocator.free(self.text);
        allocator.free(self.absolute_path);
    }
};

/// Returns the filesystem path used as the editor model URI.
pub fn absolutePath(allocator: Allocator, io: Io, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return std.fs.path.resolve(allocator, &.{path});
    var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    if (Io.Dir.cwd().realPathFile(io, path, &buffer)) |length| {
        return try allocator.dupe(u8, buffer[0..length]);
    } else |_| {}
    var cwd_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_length = try Io.Dir.cwd().realPathFile(io, ".", &cwd_buffer);
    return std.fs.path.resolve(allocator, &.{ cwd_buffer[0..cwd_length], path });
}

/// URI identity at the terminal filesystem boundary. Existing paths use
/// realpath (including symlinks); missing files are normalized lexically.
pub fn canonicalPath(allocator: Allocator, io: Io, path: []const u8) ![]const u8 {
    var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    if (Io.Dir.cwd().realPathFile(io, path, &buffer)) |length| {
        return allocator.dupe(u8, buffer[0..length]);
    } else |_| {}
    var cwd_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_length = try Io.Dir.cwd().realPathFile(io, ".", &cwd_buffer);
    return std.fs.path.resolve(allocator, &.{ cwd_buffer[0..cwd_length], path });
}

pub fn samePath(allocator: Allocator, io: Io, left: []const u8, right: []const u8) bool {
    if (std.mem.eql(u8, left, right)) return true;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const resolved_left = canonicalPath(arena.allocator(), io, left) catch return false;
    const resolved_right = canonicalPath(arena.allocator(), io, right) catch return false;
    return std.mem.eql(u8, resolved_left, resolved_right);
}

pub const SaveParticipant = struct {
    context: *anyopaque,
    participate: *const fn (context: *anyopaque, model: *anyopaque) anyerror!void,
};

pub const TextFileService = struct {
    allocator: Allocator,
    files: *DiskFileService,
    save_participants: std.array_list.Managed(SaveParticipant),

    pub fn init(allocator: Allocator, files: *DiskFileService) TextFileService {
        return .{
            .allocator = allocator,
            .files = files,
            .save_participants = std.array_list.Managed(SaveParticipant).init(allocator),
        };
    }

    pub fn deinit(self: *TextFileService) void {
        self.save_participants.deinit();
    }

    pub fn addSaveParticipant(self: *TextFileService, context: *anyopaque, callback: *const fn (context: *anyopaque, model: *anyopaque) anyerror!void) !void {
        try self.save_participants.append(.{ .context = context, .participate = callback });
    }

    pub fn removeSaveParticipant(self: *TextFileService, context: *anyopaque) void {
        var index: usize = 0;
        while (index < self.save_participants.items.len) : (index += 1) {
            if (self.save_participants.items[index].context == context) {
                _ = self.save_participants.orderedRemove(index);
                return;
            }
        }
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

    pub fn resolve(self: *TextFileService, path: []const u8, allow_missing: bool) !ResolvedTextFile {
        const loaded = self.readWithEncoding(path, self.allocator) catch |err| switch (err) {
            error.FileNotFound => if (allow_missing)
                ReadWithEncodingResult{ .text = try self.allocator.alloc(u8, 0), .encoding = .utf8 }
            else
                return err,
            else => return err,
        };
        errdefer self.allocator.free(loaded.text);
        return .{
            .text = loaded.text,
            .encoding = loaded.encoding,
            .absolute_path = try absolutePath(self.allocator, self.files.io, path),
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

/// Worker-side file read for a terminal with blocking filesystem calls. The
/// caller consumes the result or cancels the read before releasing the path.
pub const TextFileRead = struct {
    allocator: Allocator,
    service: *TextFileService,
    path: []u8,
    allow_missing: bool,
    future: Io.Future(anyerror!ResolvedTextFile),
    completion: @import("../../../../base/common/windowDispatch.zig").Task,
    listener: ?Listener,

    pub const Listener = struct {
        context: *anyopaque,
        queue: *@import("../../../../base/common/windowDispatch.zig").Queue,
        run: *const fn (*anyopaque, *TextFileRead) bool,
    };

    pub fn start(service: *TextFileService, path: []const u8, allow_missing: bool) !*TextFileRead {
        return startWithListener(service, path, allow_missing, null);
    }

    pub fn startWithListener(service: *TextFileService, path: []const u8, allow_missing: bool, listener: ?Listener) !*TextFileRead {
        const allocator = service.allocator;
        const self = try allocator.create(TextFileRead);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .service = service, .path = try allocator.dupe(u8, path), .allow_missing = allow_missing, .future = undefined, .listener = listener, .completion = .{ .queue = if (listener) |l| l.queue else null, .context = self, .run = complete, .progress = true } };
        self.future = service.files.io.async(run, .{self});
        return self;
    }

    fn run(self: *TextFileRead) anyerror!ResolvedTextFile {
        defer self.completion.post();
        return self.service.resolve(self.path, self.allow_missing);
    }

    fn complete(context: *anyopaque, _: i64, _: bool) bool {
        const self: *TextFileRead = @ptrCast(@alignCast(context));
        const listener = self.listener.?;
        return listener.run(listener.context, self);
    }

    pub fn awaitResult(self: *TextFileRead) !ResolvedTextFile {
        return self.future.await(self.service.files.io);
    }

    pub fn destroy(self: *TextFileRead) void {
        self.completion.schedule(null);
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    pub fn cancel(self: *TextFileRead) void {
        if (self.future.cancel(self.service.files.io)) |value| {
            var loaded = value;
            loaded.deinit(self.allocator);
        } else |_| {}
        self.destroy();
    }
};

test "an interactive read may create a missing buffer while a reload preserves the missing-file error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dir);
    const path = try std.fs.path.join(allocator, &.{ dir, "missing.txt" });
    defer allocator.free(path);
    var files = DiskFileService.init(allocator, io);
    defer files.deinit();
    var service = TextFileService.init(allocator, &files);
    defer service.deinit();

    const open = try TextFileRead.start(&service, path, true);
    defer open.destroy();
    var empty = try open.awaitResult();
    defer empty.deinit(allocator);
    try std.testing.expectEqualStrings("", empty.text);
    try std.testing.expectEqualStrings(path, empty.absolute_path);
    try std.testing.expectEqual(encoding_mod.Encoding.utf8, empty.encoding);

    const reload = try TextFileRead.start(&service, path, false);
    defer reload.destroy();
    try std.testing.expectError(error.FileNotFound, reload.awaitResult());

    try tmp.dir.writeFile(io, .{ .sub_path = "missing.txt", .data = &.{ 0xff, 0xfe, 'A', 0 } });
    const existing = try TextFileRead.start(&service, path, false);
    defer existing.destroy();
    var loaded = try existing.awaitResult();
    defer loaded.deinit(allocator);
    try std.testing.expectEqualStrings("A", loaded.text);
    try std.testing.expectEqual(encoding_mod.Encoding.utf16le_with_bom, loaded.encoding);
}

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
