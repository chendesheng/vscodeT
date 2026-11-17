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
const factory_mod = @import("../../../../common/editor/editorFactory.zig");
const IEditorSerializer = factory_mod.IEditorSerializer;

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
        base.description = std.fs.path.dirname(path_copy);
        base.capabilities = editor_input.EditorInputCapabilities.None;
        base.matches_fn = matches;
        base.save_fn = saveHook;
        base.revert_fn = revertHook;
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

    fn saveHook(base: *EditorInput, _: editor_input.GroupIdentifier) anyerror!editor_input.SaveResult {
        const self: *FileEditorInput = @ptrCast(@alignCast(base.impl.?));
        try self.save();
        return base;
    }

    fn revertHook(base: *EditorInput, _: editor_input.GroupIdentifier) anyerror!void {
        const self: *FileEditorInput = @ptrCast(@alignCast(base.impl.?));
        try self.revert();
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

    pub fn getPreferredName(self: *const FileEditorInput) []const u8 {
        return std.fs.path.basename(self.path);
    }

    pub fn getPreferredResource(self: *const FileEditorInput) []const u8 {
        return self.path;
    }

    pub fn getPreferredLanguage(_: *const FileEditorInput) ?[]const u8 {
        return null;
    }

    pub fn getPreferredContents(self: *const FileEditorInput) []const u8 {
        return self.getText();
    }

    pub fn load(self: *FileEditorInput) !void {
        if (self.content) |content| self.allocator.free(content);
        self.content = try self.text_files.read(self.path, self.allocator);
    }

    pub fn getText(self: *const FileEditorInput) []const u8 {
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

pub const FileEditorSerializer = struct {
    allocator: Allocator,
    text_files: *TextFileService,

    pub fn init(allocator: Allocator, text_files: *TextFileService) FileEditorSerializer {
        return .{ .allocator = allocator, .text_files = text_files };
    }

    pub fn interface(self: *FileEditorSerializer) IEditorSerializer {
        return .{
            .context = self,
            .canSerialize = canSerialize,
            .serialize = serialize,
            .deserialize = deserialize,
        };
    }

    fn canSerialize(context: *anyopaque, input: *EditorInput) bool {
        const self: *FileEditorSerializer = @ptrCast(@alignCast(context));
        _ = self;
        return std.mem.eql(u8, input.type_id, TYPE_ID) and input.impl != null;
    }

    fn serialize(context: *anyopaque, input: *EditorInput, allocator: Allocator) anyerror!?[]const u8 {
        const self: *FileEditorSerializer = @ptrCast(@alignCast(context));
        _ = self;
        const file_input: *FileEditorInput = @ptrCast(@alignCast(input.impl orelse return null));
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        var root = std.json.ObjectMap{};
        try root.put(scratch.allocator(), "resource", .{ .string = file_input.path });
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try std.json.Stringify.value(std.json.Value{ .object = root }, .{}, &out.writer);
        const bytes = try out.toOwnedSlice();
        return bytes;
    }

    fn deserialize(context: *anyopaque, data: []const u8) anyerror!?*EditorInput {
        const self: *FileEditorSerializer = @ptrCast(@alignCast(context));
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch return null;
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |object| object,
            else => return null,
        };
        const resource = switch (object.get("resource") orelse return null) {
            .string => |value| value,
            else => return null,
        };
        const input = try self.allocator.create(FileEditorInput);
        errdefer self.allocator.destroy(input);
        input.* = try FileEditorInput.init(self.allocator, self.text_files, resource);
        return input.interface();
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
    _ = input.interface();
    try input.load();
    try std.testing.expectEqualStrings("hello", input.getText());
    try std.testing.expectEqualStrings("file.txt", input.getPreferredName());
    try std.testing.expectEqualStrings(path, input.getPreferredResource());
    try std.testing.expectEqualStrings("hello", input.getPreferredContents());
    try std.testing.expect(input.getPreferredLanguage() == null);
    try std.testing.expectEqualStrings("file.txt", input.base.getName());
    try std.testing.expectEqualStrings(root, input.base.getDescription(.LONG).?);
    try std.testing.expectEqual(editor_input.EditorInputCapabilities.None, input.base.capabilities);
    try std.testing.expect(!input.base.isDirty());

    try input.setText("changed");
    try std.testing.expect(input.base.isDirty());
    try std.testing.expectEqualStrings("changed", input.getText());
    _ = try input.base.save(1);
    try std.testing.expect(!input.base.isDirty());
    const saved = try text_files.read(path, allocator);
    defer allocator.free(saved);
    try std.testing.expectEqualStrings("changed", saved);

    try input.setText("revert me");
    try input.base.revert(1);
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

test "FileEditorSerializer round-trips the resource" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &buffer);
    const root = buffer[0..root_len];
    const path = try std.fs.path.join(allocator, &.{ root, "serialized.txt" });
    defer allocator.free(path);

    var files = @import("../../../../../platform/files/common/fileService.zig").DiskFileService.init(allocator, io);
    defer files.deinit();
    var text_files = TextFileService.init(allocator, &files);
    var input = try FileEditorInput.init(allocator, &text_files, path);
    defer input.deinit();
    _ = input.interface();
    var serializer = FileEditorSerializer.init(allocator, &text_files);
    const interface = serializer.interface();
    var registry = factory_mod.EditorFactoryRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerEditorSerializer(TYPE_ID, interface);
    const registered = registry.getEditorSerializer(&input.base).?;
    try std.testing.expect(registered.canSerialize(registered.context, &input.base));
    var other = EditorInput.init(allocator, "other");
    defer other.deinit();
    try std.testing.expect(!registered.canSerialize(registered.context, &other));
    const data = (try registered.serialize(registered.context, &input.base, allocator)).?;
    defer allocator.free(data);
    const restored = (try registered.deserialize(registered.context, data)).?;
    const restored_input: *FileEditorInput = @ptrCast(@alignCast(restored.impl.?));
    defer {
        restored_input.deinit();
        allocator.destroy(restored_input);
    }
    try std.testing.expectEqualStrings(path, restored_input.path);
}
