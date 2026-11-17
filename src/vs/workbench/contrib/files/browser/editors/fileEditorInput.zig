// Terminal subset of
// `src/vs/workbench/contrib/files/browser/editors/fileEditorInput.ts`.
// The input owns a simple text buffer loaded/saved through `TextFileService`;
// encoding detection, working copies and the full editor-input lifecycle are
// not ported yet.
const std = @import("std");
const Allocator = std.mem.Allocator;
const editor_input = @import("../../../../common/editor/editorInput.zig");
const text_file = @import("../../../../services/textfile/common/textFileService.zig");
const EditorInput = editor_input.EditorInput;
const TextFileService = text_file.TextFileService;

pub const TYPE_ID = "workbench.editors.files.textFileEditor";

pub const FileEditorInput = struct {
    allocator: Allocator,
    base: EditorInput,
    path: []u8,
    text_files: *TextFileService,
    content: ?[]u8 = null,
    modified: ?[]u8 = null,

    pub fn init(allocator: Allocator, text_files: *TextFileService, path: []const u8) !FileEditorInput {
        const path_copy = try allocator.dupe(u8, path);
        errdefer allocator.free(path_copy);
        var base = EditorInput.init(allocator, TYPE_ID);
        base.resource = path_copy;
        base.name = std.fs.path.basename(path_copy);
        base.matches_fn = matches;
        return .{
            .allocator = allocator,
            .base = base,
            .path = path_copy,
            .text_files = text_files,
        };
    }

    pub fn deinit(self: *FileEditorInput) void {
        if (self.content) |content| self.allocator.free(content);
        if (self.modified) |modified| self.allocator.free(modified);
        self.base.deinit();
        self.allocator.free(self.path);
    }

    fn matches(base: *EditorInput, other: *EditorInput) bool {
        const self: *FileEditorInput = @ptrCast(@alignCast(base.impl.?));
        const other_input: *FileEditorInput = @ptrCast(@alignCast(other.impl.?));
        return std.mem.eql(u8, self.path, other_input.path);
    }

    pub fn interface(self: *FileEditorInput) *EditorInput {
        self.base.impl = self;
        return &self.base;
    }

    pub fn load(self: *FileEditorInput) !void {
        if (self.content) |content| self.allocator.free(content);
        self.content = try self.text_files.read(self.path, self.allocator);
    }

    pub fn getText(self: *FileEditorInput) []const u8 {
        if (self.modified) |modified| return modified;
        return self.content orelse "";
    }

    pub fn setText(self: *FileEditorInput, text: []const u8) !void {
        const copy = try self.allocator.dupe(u8, text);
        if (self.modified) |modified| self.allocator.free(modified);
        self.modified = copy;
        try self.base.setDirty(true);
    }

    pub fn save(self: *FileEditorInput) !void {
        try self.text_files.write(self.path, self.getText());
        if (self.modified) |modified| self.allocator.free(modified);
        self.modified = null;
        try self.base.setDirty(false);
        try self.load();
    }

    pub fn revert(self: *FileEditorInput) !void {
        if (self.modified) |modified| self.allocator.free(modified);
        self.modified = null;
        try self.base.setDirty(false);
        try self.load();
    }
};

test "FileEditorInput loads, edits, saves and reverts" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &buffer);
    const root = buffer[0..root_len];
    const path = try std.fs.path.join(allocator, &.{ root, "file.txt" });
    defer allocator.free(path);

    var files = @import("../../../../../platform/files/common/fileService.zig").DiskFileService.init(allocator, io);
    defer files.deinit();
    var text_files = TextFileService.init(allocator, &files);
    try text_files.write(path, "hello");

    var input = try FileEditorInput.init(allocator, &text_files, path);
    defer input.deinit();
    try input.load();
    try std.testing.expectEqualStrings("hello", input.getText());
    try std.testing.expectEqualStrings("file.txt", input.base.getName());
    try std.testing.expect(!input.base.isDirty());

    try input.setText("changed");
    try std.testing.expect(input.base.isDirty());
    try std.testing.expectEqualStrings("changed", input.getText());
    try input.save();
    try std.testing.expect(!input.base.isDirty());
    const saved = try text_files.read(path, allocator);
    defer allocator.free(saved);
    try std.testing.expectEqualStrings("changed", saved);

    try input.setText("revert me");
    try input.revert();
    try std.testing.expectEqualStrings("changed", input.getText());
    try std.testing.expect(!input.base.isDirty());

    var same = try FileEditorInput.init(allocator, &text_files, path);
    defer same.deinit();
    _ = same.interface();
    _ = input.interface();
    const candidate = editor_input.Candidate{ .input = &same.base };
    try std.testing.expect(input.base.matches(candidate));

    const other_path = try std.fs.path.join(allocator, &.{ root, "other.txt" });
    defer allocator.free(other_path);
    var other = try FileEditorInput.init(allocator, &text_files, other_path);
    defer other.deinit();
    _ = other.interface();
    const other_candidate = editor_input.Candidate{ .input = &other.base };
    try std.testing.expect(!input.base.matches(other_candidate));
}
