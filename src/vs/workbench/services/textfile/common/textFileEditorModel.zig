// Terminal subset of
// `src/vs/workbench/services/textfile/common/textFileEditorModel.ts`:
// text content/version/dirty state backed by `TextFileService`. BOM-based
// encoding detection (UTF-8/UTF-16 LE/BE) is ported; heuristic charset
// guessing, auto-save and external file events are not.
const std = @import("std");
const Allocator = std.mem.Allocator;
const text_file = @import("./textFileService.zig");
const encoding_mod = @import("./encoding.zig");
const TextFileService = text_file.TextFileService;
const Emitter = @import("../../../../base/common/event.zig").Emitter;

pub const TextFileEditorModel = struct {
    allocator: Allocator,
    path: []u8,
    text_files: *TextFileService,
    content: ?[]u8 = null,
    saved_content: ?[]u8 = null,
    encoding: encoding_mod.Encoding = .utf8,
    version: u32 = 0,
    disposed: bool = false,
    onDidChangeContent: Emitter(void),
    onDidChangeDirty: Emitter(void),

    pub fn create(allocator: Allocator, text_files: *TextFileService, path: []const u8) !*TextFileEditorModel {
        const self = try allocator.create(TextFileEditorModel);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .path = try allocator.dupe(u8, path),
            .text_files = text_files,
            .onDidChangeContent = Emitter(void).init(allocator),
            .onDidChangeDirty = Emitter(void).init(allocator),
        };
        return self;
    }

    pub fn destroy(self: *TextFileEditorModel) void {
        self.onDidChangeContent.deinit();
        self.onDidChangeDirty.deinit();
        if (self.content) |content| self.allocator.free(content);
        if (self.saved_content) |content| self.allocator.free(content);
        self.allocator.free(self.path);
        self.disposed = true;
        self.allocator.destroy(self);
    }

    pub fn load(self: *TextFileEditorModel) !void {
        const result = try self.text_files.readWithEncoding(self.path, self.allocator);
        errdefer self.allocator.free(result.text);
        const text = result.text;
        if (self.content) |content| self.allocator.free(content);
        if (self.saved_content) |content| self.allocator.free(content);
        self.content = text;
        self.encoding = result.encoding;
        self.saved_content = try self.allocator.dupe(u8, text);
        self.version +%= 1;
        try self.onDidChangeContent.fire({});
        try self.onDidChangeDirty.fire({});
    }

    pub fn getText(self: *const TextFileEditorModel) []const u8 {
        return self.content orelse "";
    }

    pub fn isDirty(self: *const TextFileEditorModel) bool {
        const saved = self.saved_content orelse return false;
        return !std.mem.eql(u8, self.getText(), saved);
    }

    pub fn versionId(self: *const TextFileEditorModel) u32 {
        return self.version;
    }

    pub fn updateContent(self: *TextFileEditorModel, text: []const u8) !void {
        const copy = try self.allocator.dupe(u8, text);
        if (self.content) |content| self.allocator.free(content);
        self.content = copy;
        self.version +%= 1;
        try self.onDidChangeContent.fire({});
        try self.onDidChangeDirty.fire({});
    }

    pub fn setEncoding(self: *TextFileEditorModel, encoding: encoding_mod.Encoding) void {
        self.encoding = encoding;
    }

    pub fn getEncoding(self: *const TextFileEditorModel) encoding_mod.Encoding {
        return self.encoding;
    }

    pub const SaveOptions = struct {
        skip_save_participants: bool = false,
    };

    pub fn save(self: *TextFileEditorModel) !void {
        return self.saveWithOptions(.{});
    }

    pub fn saveWithOptions(self: *TextFileEditorModel, options: SaveOptions) !void {
        const was_dirty = self.isDirty();
        if (!options.skip_save_participants) {
            for (self.text_files.save_participants.items) |participant| {
                try participant.participate(participant.context, self);
            }
        }
        const dirty_after_participants = self.isDirty();
        try self.text_files.writeWithEncoding(self.path, self.getText(), self.encoding);
        if (self.saved_content) |content| self.allocator.free(content);
        self.saved_content = try self.allocator.dupe(u8, self.getText());
        if (was_dirty or dirty_after_participants) try self.onDidChangeDirty.fire({});
    }

    pub fn revert(self: *TextFileEditorModel) !void {
        const saved = self.saved_content orelse return self.load();
        const copy = try self.allocator.dupe(u8, saved);
        if (self.content) |content| self.allocator.free(content);
        self.content = copy;
        self.version +%= 1;
        try self.onDidChangeContent.fire({});
        try self.onDidChangeDirty.fire({});
    }
};

test "TextFileEditorModel tracks content, version and dirty state" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &buffer);
    const root = buffer[0..root_len];
    const path = try std.fs.path.join(allocator, &.{ root, "model.txt" });
    defer allocator.free(path);

    var files = @import("../../../../platform/files/common/fileService.zig").DiskFileService.init(allocator, io);
    defer files.deinit();
    var text_files = TextFileService.init(allocator, &files);
    try text_files.write(path, "one");
    var model = try TextFileEditorModel.create(allocator, &text_files, path);
    defer model.destroy();
    const Listener = struct {
        fn onDirty(_: void, count: *usize) anyerror!void {
            count.* += 1;
        }
    };
    var dirty_events: usize = 0;
    _ = try model.onDidChangeDirty.listen(&dirty_events, Listener.onDirty);
    try model.load();
    try std.testing.expectEqualStrings("one", model.getText());
    try std.testing.expect(!model.isDirty());
    const version = model.versionId();

    try model.updateContent("two");
    try std.testing.expect(model.isDirty());
    try std.testing.expect(dirty_events > 0);
    try std.testing.expect(model.versionId() != version);
    try model.save();
    try std.testing.expect(!model.isDirty());
    const dirty_after_save = dirty_events;
    try model.save();
    try std.testing.expectEqual(dirty_after_save, dirty_events);
    const saved = try text_files.read(path, allocator);
    defer allocator.free(saved);
    try std.testing.expectEqualStrings("two", saved);

    try model.updateContent("three");
    try std.testing.expect(model.isDirty());
    try model.revert();
    try std.testing.expectEqualStrings("two", model.getText());
    try std.testing.expect(!model.isDirty());
}

test "TextFileEditorModel reports missing files" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var files = @import("../../../../platform/files/common/fileService.zig").DiskFileService.init(allocator, io);
    defer files.deinit();
    var text_files = TextFileService.init(allocator, &files);
    var model = try TextFileEditorModel.create(allocator, &text_files, "/definitely/not/here.txt");
    defer model.destroy();
    try std.testing.expectError(error.FileNotFound, model.load());
    try std.testing.expectEqualStrings("", model.getText());
}

test "TextFileEditorModel creates missing parents when saving" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &buffer);
    const root = buffer[0..root_len];
    const path = try std.fs.path.join(allocator, &.{ root, "a", "b", "model.txt" });
    defer allocator.free(path);

    var files = @import("../../../../platform/files/common/fileService.zig").DiskFileService.init(allocator, io);
    defer files.deinit();
    var text_files = TextFileService.init(allocator, &files);
    var model = try TextFileEditorModel.create(allocator, &text_files, path);
    defer model.destroy();
    try model.updateContent("created");
    try model.save();
    try std.testing.expect(files.existsFile(path));
    try std.testing.expect(!model.isDirty());
}

test "TextFileEditorModel preserves BOM encodings across load and save" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &buffer);
    const path = try std.fs.path.join(allocator, &.{ buffer[0..root_len], "encoded.txt" });
    defer allocator.free(path);

    var files = @import("../../../../platform/files/common/fileService.zig").DiskFileService.init(allocator, io);
    defer files.deinit();
    var text_files = TextFileService.init(allocator, &files);

    try text_files.writeWithEncoding(path, "hello", .utf8_with_bom);
    var model = try TextFileEditorModel.create(allocator, &text_files, path);
    defer model.destroy();
    try model.load();
    try std.testing.expectEqualStrings("hello", model.getText());
    try std.testing.expectEqual(encoding_mod.Encoding.utf8_with_bom, model.getEncoding());

    try model.updateContent("changed");
    try model.save();
    const read_back = try text_files.readWithEncoding(path, allocator);
    defer allocator.free(read_back.text);
    try std.testing.expectEqualStrings("changed", read_back.text);
    try std.testing.expectEqual(encoding_mod.Encoding.utf8_with_bom, read_back.encoding);

    try text_files.writeWithEncoding(path, "utf16 text", .utf16le_with_bom);
    try model.load();
    try std.testing.expectEqualStrings("utf16 text", model.getText());
    try std.testing.expectEqual(encoding_mod.Encoding.utf16le_with_bom, model.getEncoding());
    try model.updateContent("utf16 changed");
    try model.save();
    const utf16_read = try text_files.readWithEncoding(path, allocator);
    defer allocator.free(utf16_read.text);
    try std.testing.expectEqualStrings("utf16 changed", utf16_read.text);
    try std.testing.expectEqual(encoding_mod.Encoding.utf16le_with_bom, utf16_read.encoding);
}

test "TextFileEditorModel runs save participants and honors skip/error" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &buffer);
    const path = try std.fs.path.join(allocator, &.{ buffer[0..root_len], "participants.txt" });
    defer allocator.free(path);

    var files = @import("../../../../platform/files/common/fileService.zig").DiskFileService.init(allocator, io);
    defer files.deinit();
    var text_files = TextFileService.init(allocator, &files);
    defer text_files.deinit();
    try text_files.write(path, "initial");

    var model = try TextFileEditorModel.create(allocator, &text_files, path);
    defer model.destroy();
    try model.load();
    try model.updateContent("foo");

    const Participant = struct {
        count: usize = 0,
        fail: bool = false,

        fn participate(context: *anyopaque, raw_model: *anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
            if (self.fail) return error.ParticipantFailed;
            const editor_model: *TextFileEditorModel = @ptrCast(@alignCast(raw_model));
            try editor_model.updateContent("bar");
        }
    };
    var participant = Participant{};
    try text_files.addSaveParticipant(&participant, Participant.participate);

    try model.save();
    try std.testing.expectEqual(@as(usize, 1), participant.count);
    try std.testing.expectEqualStrings("bar", model.getText());
    try std.testing.expect(!model.isDirty());

    try model.updateContent("skipped");
    try model.saveWithOptions(.{ .skip_save_participants = true });
    try std.testing.expectEqual(@as(usize, 1), participant.count);
    const skipped = try text_files.read(path, allocator);
    defer allocator.free(skipped);
    try std.testing.expectEqualStrings("skipped", skipped);

    try model.updateContent("failing");
    participant.fail = true;
    try std.testing.expectError(error.ParticipantFailed, model.save());
    try std.testing.expect(model.isDirty());
    const unchanged = try text_files.read(path, allocator);
    defer allocator.free(unchanged);
    try std.testing.expectEqualStrings("skipped", unchanged);
}
