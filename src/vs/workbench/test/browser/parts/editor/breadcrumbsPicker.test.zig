// Port of the file-picker decisions used by
// `src/vs/workbench/browser/parts/editor/breadcrumbsPicker.ts`.

const std = @import("std");
const picker = @import("../../../../browser/parts/editor/breadcrumbsPicker.zig");
const FileElement = @import("../../../../browser/parts/editor/breadcrumbsModel.zig").FileElement;
const inputDirectory = picker.inputDirectory;
const list = picker.list;
const freeEntries = picker.freeEntries;

test "breadcrumbsPicker: input directory and sorted children" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "picker");
    var file = try tmp.dir.createFile(io, "picker/b.txt", .{});
    file.close(io);
    try tmp.dir.createDirPath(io, "picker/a-dir");

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buffer);
    const root = try std.fs.path.join(allocator, &.{ path_buffer[0..root_len], "picker" });
    defer allocator.free(root);

    const file_path = try std.fs.path.join(allocator, &.{ root, "b.txt" });
    defer allocator.free(file_path);
    const file_element = FileElement{ .path = file_path, .kind = .FILE };
    try std.testing.expectEqualStrings(root, inputDirectory(&file_element));

    const entries = try list(allocator, io, root);
    defer freeEntries(allocator, entries);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expect(entries[0].is_dir);
    try std.testing.expectEqualStrings("a-dir", entries[0].name);
    try std.testing.expectEqualStrings("b.txt", entries[1].name);
}
