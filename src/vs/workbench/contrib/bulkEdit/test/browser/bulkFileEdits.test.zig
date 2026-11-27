// Port of `src/vs/workbench/contrib/bulkEdit/test/browser/bulkFileEdits.test.ts`.
const std = @import("std");
const files = @import("../../../../../platform/files/common/files.zig");
const FileService = @import("../../../../../platform/files/common/fileService.zig").ProviderFileService;
const Memory = @import("../../../../../platform/files/common/inMemoryFilesystemProvider.zig").InMemoryFileSystemProvider;
const working = @import("../../../../services/workingCopy/common/workingCopyFileService.zig");
const undo = @import("../../../../../platform/undoRedo/common/undoRedo.zig");
const UndoRedoService = @import("../../../../../platform/undoRedo/common/undoRedoService.zig").UndoRedoService;
const BulkFileEdits = @import("../../browser/bulkFileEdits.zig").BulkFileEdits;
const bulk = @import("../../../../../editor/browser/services/bulkEditService.zig");
const Options = @import("../../../../../editor/common/languages.zig").WorkspaceFileEditOptions;
const a = std.testing.allocator;
const Uri = std.Uri;

fn uri(value: []const u8) Uri {
    return Uri.parse(value) catch unreachable;
}
const resources = [_]Uri{ uri("file:///workspace/entry-0"), uri("file:///workspace/entry-1"), uri("file:///workspace/entry-2") };
const Entry = struct { kind: enum { read, delete, create, create_folder }, index: usize, contents: ?[3]u8 = null };
const Fixture = struct {
    types: []const u8,
    present: [3]bool = .{ true, true, true },
    entries: std.ArrayList(Entry) = .empty,

    fn index(resource: Uri) usize {
        const raw = switch (resource.path) {
            inline else => |value| value,
        };
        return raw[raw.len - 1] - '0';
    }
    fn stat(context: *anyopaque, resource: Uri) !files.IStat {
        const self: *Fixture = @ptrCast(@alignCast(context));
        const i = index(resource);
        if (!self.present[i]) return error.FileNotFound;
        return .{ .type = self.types[i], .mtime = 0, .ctime = 0, .size = 3 };
    }
    fn read(context: *anyopaque, allocator: std.mem.Allocator, resource: Uri) ![]u8 {
        const self: *Fixture = @ptrCast(@alignCast(context));
        const i = index(resource);
        try self.entries.append(a, .{ .kind = .read, .index = i });
        return allocator.dupe(u8, &.{ @intCast(i), 128, 255 });
    }
    fn del(context: *anyopaque, resource: Uri, _: files.IFileDeleteOptions) !void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        const i = index(resource);
        try self.entries.append(a, .{ .kind = .delete, .index = i });
        self.present[i] = false;
    }
    fn create(context: *anyopaque, resource: Uri, bytes: []const u8, _: files.IFileWriteOptions) !void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        const i = index(resource);
        try std.testing.expectEqual(@as(usize, 3), bytes.len);
        try self.entries.append(a, .{ .kind = .create, .index = i, .contents = bytes[0..3].* });
        self.present[i] = true;
    }
    fn folder(context: *anyopaque, resource: Uri) !void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        const i = index(resource);
        try self.entries.append(a, .{ .kind = .create_folder, .index = i });
        self.present[i] = true;
    }
};

fn applyDelete(types: []const u8, extra: Options, expected: []const Entry) !void {
    var registry = FileService.init(a);
    defer registry.deinit();
    var fixture: Fixture = .{ .types = types };
    defer fixture.entries.deinit(a);
    var file = registry.interface();
    file.context = &fixture;
    file.stat_uri = Fixture.stat;
    file.read_uri = Fixture.read;
    file.delete_uri = Fixture.del;
    file.write_uri = Fixture.create;
    file.create_folder_uri = Fixture.folder;
    file.capabilities = null;
    var working_service = working.WorkingCopyFileService.init(a, file, null);
    defer working_service.deinit();
    var undo_service = UndoRedoService.init(a);
    defer undo_service.deinit();
    var edits: [3]bulk.ResourceEdit = undefined;
    for (types, 0..) |kind, i| {
        var options = extra;
        options.recursive = true;
        options.folder = options.folder or files.FileType.isDirectory(kind);
        edits[i] = .{ .file = .{ .old_resource = resources[i], .options = options } };
    }
    var group = undo.UndoRedoGroup.init();
    _ = try BulkFileEdits.apply(a, .{ .files = file, .working_copies = working_service.interface(), .undo_redo = &undo_service }, edits[0..types.len], .{}, &group);
    for (resources[0..types.len]) |resource| {
        if (try undo_service.canUndo(.{ .uri = resource })) {
            try undo_service.undo(.{ .uri = resource });
            break;
        }
    }
    try std.testing.expectEqualSlices(Entry, expected, fixture.entries.items);
}

test "BulkFileEdits: delete skips undo contents for non-regular files" {
    try applyDelete(&.{files.FileType.Unknown}, .{}, &.{.{ .kind = .delete, .index = 0 }});
}

test "BulkFileEdits: delete preserves undo contents for regular files" {
    try applyDelete(&.{files.FileType.File}, .{}, &.{ .{ .kind = .read, .index = 0 }, .{ .kind = .delete, .index = 0 }, .{ .kind = .create, .index = 0, .contents = .{ 0, 128, 255 } } });
}

test "BulkFileEdits: undo restores only regular files in a mixed deletion" {
    try applyDelete(&.{ files.FileType.File, files.FileType.Unknown, files.FileType.File }, .{}, &.{ .{ .kind = .read, .index = 0 }, .{ .kind = .read, .index = 2 }, .{ .kind = .delete, .index = 0 }, .{ .kind = .delete, .index = 1 }, .{ .kind = .delete, .index = 2 }, .{ .kind = .create, .index = 0, .contents = .{ 0, 128, 255 } }, .{ .kind = .create, .index = 2, .contents = .{ 2, 128, 255 } } });
}

test "BulkFileEdits: delete does not restore non-regular files when the folder option is set" {
    try applyDelete(&.{files.FileType.Unknown}, .{ .folder = true }, &.{.{ .kind = .delete, .index = 0 }});
}

test "BulkFileEdits: delete preserves undo for empty folders" {
    try applyDelete(&.{files.FileType.Directory}, .{}, &.{ .{ .kind = .delete, .index = 0 }, .{ .kind = .create_folder, .index = 0 } });
}

test "BulkFileEdits: delete skips undo contents exceeding the size limit" {
    try applyDelete(&.{files.FileType.File}, .{ .max_size = 2 }, &.{.{ .kind = .delete, .index = 0 }});
}

test "BulkFileEdits: create, copy and rename mutate real provider resources and reverse through the undo service" {
    var registry = FileService.init(a);
    defer registry.deinit();
    var memory = try Memory.init(a);
    defer memory.deinit();
    var registration = try registry.interface().registerProvider("inmemory", memory.interface());
    defer registration.dispose();
    const file = registry.interface();
    var working_service = working.WorkingCopyFileService.init(a, file, null);
    defer working_service.deinit();
    var undo_service = UndoRedoService.init(a);
    defer undo_service.deinit();
    const services: @import("../../browser/bulkFileEdits.zig").Services = .{ .files = file, .working_copies = working_service.interface(), .undo_redo = &undo_service };
    const source = uri("inmemory:/first.txt");
    const copied = uri("inmemory:/copied.txt");
    const moved = uri("inmemory:/moved.txt");
    var group = undo.UndoRedoGroup.init();
    _ = try BulkFileEdits.apply(a, services, &.{.{ .file = .{ .new_resource = source, .options = .{ .contents = "hello" } } }}, .{}, &group);
    _ = try BulkFileEdits.apply(a, services, &.{.{ .file = .{ .old_resource = source, .new_resource = copied, .options = .{ .copy = true } } }}, .{}, &group);
    _ = try BulkFileEdits.apply(a, services, &.{.{ .file = .{ .old_resource = copied, .new_resource = moved } }}, .{}, &group);
    const bytes = try file.readFile(a, moved);
    defer a.free(bytes);
    try std.testing.expectEqualStrings("hello", bytes);
    try std.testing.expectError(error.FileNotFound, file.stat(copied));
    try undo_service.undo(.{ .uri = moved });
    try std.testing.expectError(error.FileNotFound, file.stat(source));
    try std.testing.expectError(error.FileNotFound, file.stat(copied));
    try std.testing.expectError(error.FileNotFound, file.stat(moved));
    try undo_service.redo(.{ .uri = moved });
    const redone = try file.readFile(a, moved);
    defer a.free(redone);
    try std.testing.expectEqualStrings("hello", redone);
}
