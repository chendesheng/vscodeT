// Terminal subset of
// `src/vs/workbench/services/textfile/common/textFileEditorModel.ts`:
// text content/version/dirty state backed by `TextFileService`. Working
// copies, encoding detection, auto-save and file events are not ported.
const std = @import("std");
const Allocator = std.mem.Allocator;
const text_file = @import("./textFileService.zig");
const TextFileService = text_file.TextFileService;
const Emitter = @import("../../../../base/common/event.zig").Emitter;

pub const TextFileEditorModel = struct {
    allocator: Allocator,
    path: []u8,
    text_files: *TextFileService,
    content: ?[]u8 = null,
    saved_content: ?[]u8 = null,
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
        const text = try self.text_files.read(self.path, self.allocator);
        if (self.content) |content| self.allocator.free(content);
        if (self.saved_content) |content| self.allocator.free(content);
        self.content = text;
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

    pub fn save(self: *TextFileEditorModel) !void {
        const was_dirty = self.isDirty();
        try self.text_files.write(self.path, self.getText());
        if (self.saved_content) |content| self.allocator.free(content);
        self.saved_content = try self.allocator.dupe(u8, self.getText());
        if (was_dirty) try self.onDidChangeDirty.fire({});
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
